// Hush — per-app and per-simulator audio mixer for macOS
// Copyright (C) 2026 Flip Digital Labs
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreAudio
import ServiceManagement
import SwiftUI

/// A saved setting for a Mac app, keyed by bundle ID, re-applied every time it launches.
struct AppRule: Codable, Equatable {
    var name: String
    var volume: Float = 1
    var muted = false
    var isSimulator = false
    /// Lets macOS 26 keep the app muted from its very first sample, even before it's running.
    var bundleID: String?

    /// Full volume and unmuted: no rule needed.
    var isNeutral: Bool { !muted && volume >= 0.999 }
}

/// A saved setting for one simulator window, keyed by its UDID — so it survives every rebuild
/// and relaunch inside that simulator.
struct DeviceRule: Codable, Equatable {
    var name: String
    /// nil = follow "Mute all Simulators".
    var muted: Bool?
    var volume: Float = 1

    var isNeutral: Bool { muted == nil && volume >= 0.999 }
}

struct DormantRule: Identifiable {
    let key: String
    let rule: AppRule
    var id: String { key }
}

/// How settings combine — the most specific explicit choice wins:
///
///     Simulators:  Mute all Simulators  →  one simulator  →  one app in that simulator
///     Mac apps:    the app               →  one of its audio processes
///
/// Flipping a parent clears the overrides underneath it, so "mute all" really means all.
@MainActor
final class Mixer: ObservableObject {

    // MARK: Published state

    @Published private(set) var snapshot = AudioSnapshot()
    @Published private(set) var rules: [String: AppRule] = [:]
    @Published private(set) var deviceRules: [String: DeviceRule] = [:]
    /// "simapp:<device>|<bundle ID>" → explicit mute for one app in one simulator.
    @Published private(set) var simAppMutes: [String: Bool] = [:]
    /// Explicit mute for one process of a Mac app. Kept for the session only — processes
    /// (and their IDs) don't outlive a relaunch.
    @Published private(set) var processMutes: [AudioObjectID: Bool] = [:]
    /// The default for every simulator, including ones booted later.
    @Published private(set) var simulatorsMuted = false
    @Published private(set) var processErrors: [AudioObjectID: String] = [:]
    @Published private(set) var outputDeviceName = ""
    @Published private(set) var permission: AudioPermission.Status = .unknown
    @Published private(set) var launchAtLoginError: String?

    @Published var showBackgroundProcesses = false {
        didSet { UserDefaults.standard.set(showBackgroundProcesses, forKey: Keys.showBackground) }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = "Launch at login: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Private state

    private enum Keys {
        static let rules = "rules.v1"
        static let deviceRules = "deviceRules.v1"
        static let simAppMutes = "simAppMutes.v1"
        static let simulatorsMuted = "simulatorsMuted"
        static let showBackground = "showBackgroundProcesses"
        static let knownSimulatorApps = "knownSimulatorBundleIDs"
    }

    private static let silent: Float = 0.0001
    private static let full: Float = 0.999

    /// One tap + running reader per process that isn't at full volume (gain 0 = muted).
    /// Created the moment a process shows up and never rebuilt while it lives — so a new copy
    /// of an app (another simulator, a relaunch) can't disturb copies already muted, and going
    /// between muted and any volume is just a gain change.
    private var processTaps: [AudioObjectID: AppVolumeTap] = [:]
    /// macOS 26+: one muted tap, re-attached by the system on every launch of these bundle IDs.
    private var standingTap: AppVolumeTap?
    private var standingTapBundleIDs = Set<String>()
    /// A bundle-ID set the system refused (older macOS or unsupported) — not retried until it changes.
    private var refusedStandingSet: Set<String>?
    /// Taps to rebuild (woke from sleep, permission granted) — make-before-break.
    private var staleProcessTaps = Set<AudioObjectID>()
    private var standingTapIsStale = false
    /// Failed taps per process and output device, retried every few seconds rather than every pass.
    private var tapFailures: [AudioObjectID: (outputUID: String, message: String, at: Date)] = [:]
    /// User-installed Simulator apps seen before, so their next launch is muted instantly.
    private var knownSimulatorBundleIDs: [String] = []

    private var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var outputUID = ""
    private var isReconciling = false
    private var needsAnotherPass = false
    private var askedForPermission = false
    private var refreshTimer: Timer?

    // MARK: Init

    init() {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()

        if let data = defaults.data(forKey: Keys.rules),
           let saved = try? decoder.decode([String: AppRule].self, from: data) {
            // v1 kept Simulator apps here ("sim:<bundle ID>"); those are per-simulator now.
            rules = saved.filter { !$0.key.hasPrefix("sim:") }
        }
        if let data = defaults.data(forKey: Keys.deviceRules),
           let saved = try? decoder.decode([String: DeviceRule].self, from: data) {
            deviceRules = saved.filter { Self.simulatorStillExists($0.key) }
        }
        if let data = defaults.data(forKey: Keys.simAppMutes),
           let saved = try? decoder.decode([String: Bool].self, from: data) {
            simAppMutes = saved.filter { Self.simulatorStillExists(Self.deviceID(ofSimAppKey: $0.key)) }
        }
        simulatorsMuted = defaults.bool(forKey: Keys.simulatorsMuted)
        showBackgroundProcesses = defaults.bool(forKey: Keys.showBackground)
        knownSimulatorBundleIDs = defaults.stringArray(forKey: Keys.knownSimulatorApps) ?? []
        permission = AudioPermission.status()

        installListeners()
        updateOutputDevice()
        refresh()

        // Safety net: HAL notifications can be missed during rapid quit/relaunch cycles.
        // A scan is cheap (cached per process), so check every second.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    // MARK: Derived data for the UI

    var simulators: [SimulatorDevice] { snapshot.simulators }

    var regularApps: [AudioApp] {
        snapshot.apps.filter { app in
            showBackgroundProcesses || app.isUserFacing || app.isPlaying || rules[app.key] != nil
                || app.processes.contains { processMutes[$0.objectID] != nil }
        }
    }

    /// Mac-app rules for apps that aren't running right now.
    var dormantRules: [DormantRule] {
        let liveKeys = Set(snapshot.apps.map(\.key))
        return rules
            .filter { !liveKeys.contains($0.key) }
            .map { DormantRule(key: $0.key, rule: $0.value) }
            .sorted { $0.rule.name.localizedCaseInsensitiveCompare($1.rule.name) == .orderedAscending }
    }

    /// Simulator windows (not counting shared services) whose every app is muted.
    var mutedSimulatorCount: Int {
        simulators.filter { $0.isDevice && mutedAppCount(in: $0) == $0.apps.count }.count
    }

    var menuBarSymbol: String {
        let anyMuted = simulatorsMuted
            || rules.values.contains(where: \.muted)
            || deviceRules.values.contains { $0.muted == true }
            || simAppMutes.values.contains(true)
            || processMutes.values.contains(true)
        if anyMuted { return "speaker.slash.fill" }
        if !rules.isEmpty || !deviceRules.isEmpty { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    // MARK: Effective state

    func isMuted(device: SimulatorDevice) -> Bool { deviceRules[device.id]?.muted ?? simulatorsMuted }
    func volume(device: SimulatorDevice) -> Float { deviceRules[device.id]?.volume ?? 1 }

    func isMuted(_ app: AudioApp, in device: SimulatorDevice) -> Bool {
        simAppMutes[app.key] ?? isMuted(device: device)
    }

    func mutedAppCount(in device: SimulatorDevice) -> Int {
        device.apps.filter { isMuted($0, in: device) }.count
    }

    func isMuted(app: AudioApp) -> Bool { rules[app.key]?.muted ?? false }
    func volume(app: AudioApp) -> Float { rules[app.key]?.volume ?? 1 }

    func isMuted(_ process: AudioProcess, in app: AudioApp) -> Bool {
        processMutes[process.objectID] ?? isMuted(app: app)
    }

    func mutedProcessCount(in app: AudioApp) -> Int {
        app.processes.filter { isMuted($0, in: app) }.count
    }

    func error(for processes: [AudioProcess]) -> String? {
        for process in processes {
            if let message = processErrors[process.objectID] { return message }
        }
        return nil
    }

    // MARK: User actions — Simulators

    /// Mute / unmute every simulator, now and later. Clears per-simulator and per-app overrides.
    func setSimulatorsMuted(_ muted: Bool) {
        simulatorsMuted = muted
        UserDefaults.standard.set(muted, forKey: Keys.simulatorsMuted)
        deviceRules = deviceRules.compactMapValues { rule in
            var updated = rule
            updated.muted = nil
            return updated.isNeutral ? nil : updated
        }
        simAppMutes.removeAll()
        persistSimulatorRules()
        reconcile()
    }

    /// Mute / unmute one simulator window, including every app in it.
    func setMuted(_ muted: Bool, device: SimulatorDevice) {
        var rule = deviceRules[device.id] ?? DeviceRule(name: device.name)
        rule.name = device.name
        rule.muted = (muted == simulatorsMuted) ? nil : muted
        deviceRules[device.id] = rule.isNeutral ? nil : rule

        let prefix = "simapp:\(device.id)|"
        simAppMutes = simAppMutes.filter { !$0.key.hasPrefix(prefix) }
        persistSimulatorRules()
        reconcile()
    }

    func setVolume(_ volume: Float, device: SimulatorDevice) {
        var rule = deviceRules[device.id] ?? DeviceRule(name: device.name)
        rule.name = device.name
        rule.volume = Swift.min(Swift.max(volume, 0), 1)
        deviceRules[device.id] = rule.isNeutral ? nil : rule
        persistSimulatorRules()
        reconcile()
    }

    /// Mute / unmute one app inside one simulator.
    func toggleMute(_ app: AudioApp, in device: SimulatorDevice) {
        let muted = !isMuted(app, in: device)
        simAppMutes[app.key] = (muted == isMuted(device: device)) ? nil : muted
        persistSimulatorRules()
        reconcile()
    }

    // MARK: User actions — Mac apps

    /// Mute / unmute a Mac app, including all of its processes.
    func setMuted(_ muted: Bool, app: AudioApp) {
        var rule = rules[app.key] ?? AppRule(name: app.name)
        rule.name = app.name
        rule.bundleID = app.standingBundleID ?? rule.bundleID
        rule.muted = muted
        for process in app.processes { processMutes[process.objectID] = nil }
        store(rule, for: app.key)
    }

    func setVolume(_ volume: Float, app: AudioApp) {
        var rule = rules[app.key] ?? AppRule(name: app.name)
        rule.name = app.name
        rule.bundleID = app.standingBundleID ?? rule.bundleID
        rule.volume = Swift.min(Swift.max(volume, 0), 1)
        store(rule, for: app.key)
    }

    /// Mute / unmute one audio process of a Mac app.
    func toggleMute(_ process: AudioProcess, in app: AudioApp) {
        let muted = !isMuted(process, in: app)
        processMutes[process.objectID] = (muted == isMuted(app: app)) ? nil : muted
        reconcile()
    }

    func forgetRule(key: String) {
        rules[key] = nil
        persistRules()
        reconcile()
    }

    func resetAll() {
        rules = [:]
        deviceRules = [:]
        simAppMutes = [:]
        processMutes = [:]
        persistRules()
        knownSimulatorBundleIDs = []
        UserDefaults.standard.removeObject(forKey: Keys.knownSimulatorApps)
        setSimulatorsMuted(false)   // persists and reconciles
    }

    func requestPermission() {
        if permission == .denied {
            AudioPermission.openSettings()
            return
        }
        AudioPermission.request { @Sendable [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.permission = granted ? .authorized : AudioPermission.status()
                if granted { self.rebuildAll() }
            }
        }
    }

    // MARK: Refresh & reconcile

    func refresh() {
        let latest = AudioProcessScanner.snapshot()
        if latest != snapshot { snapshot = latest }

        let live = Set(latest.allProcesses.map(\.objectID))
        if processMutes.keys.contains(where: { !live.contains($0) }) {
            processMutes = processMutes.filter { live.contains($0.key) }
        }
        rememberSimulatorApps()

        let latestPermission = AudioPermission.status()
        if latestPermission != permission {
            let nowAuthorized = latestPermission == .authorized
            permission = latestPermission
            if nowAuthorized {
                rebuildAll()   // volume taps created before permission was granted only carry silence
                return
            }
        }
        reconcile()
    }

    /// Rebuilds every tap (wake from sleep, permission change). Each new tap is running before
    /// its old one goes away, so nothing leaks in between.
    func rebuildAll() {
        staleProcessTaps = Set(processTaps.keys)
        standingTapIsStale = standingTap != nil
        tapFailures.removeAll()
        refusedStandingSet = nil
        updateOutputDevice()
        reconcile()
    }

    func teardown() {
        refreshTimer?.invalidate()
        for tap in processTaps.values { tap.invalidate() }
        standingTap?.invalidate()
        processTaps.removeAll()
        standingTap = nil
        standingTapBundleIDs = []
    }

    /// Target gain for every live process: 0 = muted, 1 = untouched.
    private func targetGains() -> [AudioObjectID: Float] {
        var gains: [AudioObjectID: Float] = [:]
        for device in snapshot.simulators {
            let deviceVolume = volume(device: device)
            for app in device.apps {
                let gain: Float = isMuted(app, in: device) ? 0 : deviceVolume
                for process in app.processes { gains[process.objectID] = gain }
            }
        }
        for app in snapshot.apps {
            let appVolume = volume(app: app)
            for process in app.processes {
                gains[process.objectID] = isMuted(process, in: app) ? 0 : appVolume
            }
        }
        return gains
    }

    /// Makes the set of live taps match the rules. Safe to call as often as you like.
    func reconcile() {
        // Creating an aggregate device pumps the run loop, which can re-enter here.
        if isReconciling {
            needsAnotherPass = true
            return
        }
        isReconciling = true
        defer { isReconciling = false }

        repeat {
            needsAnotherPass = false
            reconcileOnce()
        } while needsAnotherPass
    }

    private func reconcileOnce() {
        // Taps play back through the output device (it's also their clock). With no output
        // device nothing can be heard anyway, so leave things as they are until one appears.
        guard outputDeviceID.isValid, !outputUID.isEmpty else { return }

        let gains = targetGains()
        var errors: [AudioObjectID: String] = [:]

        // 1. Standing tap (macOS 26+): one reader covers every current and future process of
        //    these apps, so their next launch is muted before Hush even sees it.
        let wantedStanding = standingBundleIDs(gains: gains)
        let standingCurrent = standingTap != nil && standingTapBundleIDs == wantedStanding
            && standingTap?.outputUID == outputUID && !standingTapIsStale
        if !standingCurrent {
            if wantedStanding.isEmpty {
                standingTap?.invalidate()
                standingTap = nil
                standingTapBundleIDs = []
            } else if refusedStandingSet != wantedStanding {
                if let description = TapDescriptions.standing(bundleIDs: Array(wantedStanding)),
                   let fresh = try? AppVolumeTap(name: "standing", tapDescription: description,
                                                 outputDeviceID: outputDeviceID, outputUID: outputUID, gain: 0) {
                    let old = standingTap
                    standingTap = fresh
                    standingTapBundleIDs = wantedStanding
                    standingTapIsStale = false
                    old?.invalidate()
                } else {
                    // Keep whatever older standing tap exists; per-process taps cover the rest.
                    refusedStandingSet = wantedStanding
                }
            }
        }

        // 2. One tap per process that isn't at full volume. Processes making sound go first.
        var wantedProcesses = Set<AudioObjectID>()
        let processes = snapshot.allProcesses.sorted { $0.isPlaying && !$1.isPlaying }
        for process in processes {
            let objectID = process.objectID
            guard let gain = gains[objectID], gain < Self.full else { continue }
            wantedProcesses.insert(objectID)

            if let tap = processTaps[objectID], tap.outputUID == outputUID, !staleProcessTaps.contains(objectID) {
                tap.setGain(gain)
                continue
            }
            if let failure = tapFailures[objectID], failure.outputUID == outputUID,
               Date().timeIntervalSince(failure.at) < 4 {
                errors[objectID] = failure.message
                continue
            }

            // Reading a tap needs the "System Audio Recording Only" permission; ask once.
            // If it was already denied, the banner explains it — never open Settings unasked.
            if permission == .unknown, !askedForPermission {
                askedForPermission = true
                requestPermission()
            }

            do {
                let fresh = try AppVolumeTap(
                    name: "\(process.pid)",
                    tapDescription: TapDescriptions.processes([objectID]),
                    outputDeviceID: outputDeviceID,
                    outputUID: outputUID,
                    gain: gain
                )
                let old = processTaps[objectID]
                processTaps[objectID] = fresh
                old?.invalidate()
                staleProcessTaps.remove(objectID)
                tapFailures[objectID] = nil
            } catch {
                tapFailures[objectID] = (outputUID: outputUID, message: error.localizedDescription, at: Date())
                errors[objectID] = error.localizedDescription
            }
        }

        // 3. Only now remove what's no longer wanted — replacements are already running.
        for objectID in Array(processTaps.keys) where !wantedProcesses.contains(objectID) {
            processTaps[objectID]?.invalidate()
            processTaps[objectID] = nil
            staleProcessTaps.remove(objectID)
        }
        // A standing tap must never keep muting a bundle ID that's now meant to be heard.
        if let current = standingTap, !standingTapBundleIDs.isSubset(of: wantedStanding) {
            current.invalidate()
            standingTap = nil
            standingTapBundleIDs = []
        }
        tapFailures = tapFailures.filter { gains[$0.key] != nil }

        if errors != processErrors { processErrors = errors }
    }

    /// Bundle IDs that should stay muted at the system level, including apps not running yet.
    /// A standing tap mutes every process with that bundle ID — it can't tell one simulator
    /// from another — so it's only used where that's exactly what you asked for.
    private func standingBundleIDs(gains: [AudioObjectID: Float]) -> Set<String> {
        guard TapDescriptions.supportsStandingTaps else { return [] }

        var candidates = Set<String>()
        for rule in rules.values where rule.muted {
            if let bundleID = rule.bundleID { candidates.insert(bundleID) }
        }

        let simulatorExceptions = deviceRules.values.contains { $0.muted == false } || simAppMutes.values.contains(false)
        if simulatorsMuted && !simulatorExceptions {
            candidates.formUnion(knownSimulatorBundleIDs)
        }

        // Never let a standing tap silence something that's meant to be heard — e.g. one
        // simulator you unmuted, or your Mac build of a game that shares its bundle ID.
        var audible = Set<String>()
        for process in snapshot.allProcesses where (gains[process.objectID] ?? 1) > Self.silent {
            if let bundleID = process.bundleID { audible.insert(bundleID) }
        }
        return candidates.filter { TapDescriptions.isPlausibleBundleID($0) && !audible.contains($0) }
    }

    private func rememberSimulatorApps() {
        var changed = false
        for app in snapshot.simulators.flatMap(\.apps) {
            guard let bundleID = app.standingBundleID else { continue }
            if let index = knownSimulatorBundleIDs.firstIndex(of: bundleID) {
                if index == knownSimulatorBundleIDs.count - 1 { continue }
                knownSimulatorBundleIDs.remove(at: index)
            }
            knownSimulatorBundleIDs.append(bundleID)   // most recent last
            changed = true
        }
        guard changed else { return }
        if knownSimulatorBundleIDs.count > 40 {
            knownSimulatorBundleIDs.removeFirst(knownSimulatorBundleIDs.count - 40)
        }
        UserDefaults.standard.set(knownSimulatorBundleIDs, forKey: Keys.knownSimulatorApps)
    }

    // MARK: Persistence

    private func store(_ rule: AppRule, for key: String) {
        rules[key] = rule.isNeutral ? nil : rule
        persistRules()
        reconcile()
    }

    private func persistRules() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: Keys.rules)
        }
    }

    private func persistSimulatorRules() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(deviceRules) {
            UserDefaults.standard.set(data, forKey: Keys.deviceRules)
        }
        if let data = try? encoder.encode(simAppMutes) {
            UserDefaults.standard.set(data, forKey: Keys.simAppMutes)
        }
    }

    /// "simapp:<device>|<bundle ID>" → "<device>"
    private static func deviceID(ofSimAppKey key: String) -> String {
        let body = key.hasPrefix("simapp:") ? String(key.dropFirst("simapp:".count)) : key
        return body.components(separatedBy: "|").first ?? body
    }

    /// Drops saved settings for simulators that have since been deleted (Claude sessions create
    /// and delete probe simulators often). Non-UDID ids (Android, shared services) are kept.
    private static func simulatorStillExists(_ deviceID: String) -> Bool {
        guard UUID(uuidString: deviceID) != nil else { return true }
        let folder = NSHomeDirectory() + "/Library/Developer/CoreSimulator/Devices/" + deviceID
        return FileManager.default.fileExists(atPath: folder)
    }

    // MARK: System listeners

    private func updateOutputDevice() {
        let deviceID = AudioObjectID.defaultOutputDevice()
        outputDeviceID = deviceID
        outputUID = deviceID.isValid ? ((try? deviceID.readString(kAudioDevicePropertyDeviceUID)) ?? "") : ""
        outputDeviceName = deviceID.isValid ? ((try? deviceID.readString(kAudioObjectPropertyName)) ?? "") : "No output device"
    }

    private func installListeners() {
        // Apps starting/stopping audio → re-scan right away. Delivered on the main queue, so
        // it's handled right here rather than hopping again.
        var processListAddress = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        let processListChanged: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        _ = AudioObjectAddPropertyListenerBlock(.system, &processListAddress, DispatchQueue.main, processListChanged)

        // Headphones plugged in / output switched → move volume taps to the new device.
        var outputAddress = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let outputChanged: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.updateOutputDevice()
                self?.reconcile()
            }
        }
        _ = AudioObjectAddPropertyListenerBlock(.system, &outputAddress, DispatchQueue.main, outputChanged)

        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildAll() }
        }

        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.teardown() }
        }
    }
}
