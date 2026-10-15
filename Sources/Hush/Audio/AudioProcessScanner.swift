// Hush — per-app and per-simulator audio mixer for macOS
// Copyright (C) 2026 Flip Digital Labs
// SPDX-License-Identifier: GPL-3.0-or-later
// Helper-to-app attribution (responsibility PID, parent walk) adapted from FineTune (GPL-3.0).
// See NOTICE.md.

import AppKit
import CoreAudio
import Darwin

/// One process that has connected to Core Audio (it may or may not be playing right now).
struct AudioProcess: Hashable, Identifiable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let path: String?
    /// Executable name, made unique within its app ("Helper · 4121").
    var label: String
    let isPlaying: Bool

    var id: AudioObjectID { objectID }
}

/// An app and its audio processes. On the Mac side that's one app (Chrome + its helpers);
/// inside a simulator it's one app in that one simulator.
struct AudioApp: Identifiable, Equatable {
    /// Stable identity used for rules. Survives quits, relaunches and rebuilds.
    let key: String
    let name: String
    let icon: NSImage
    let isSimulator: Bool
    /// A regular Dock app (as opposed to a background agent or daemon).
    let isUserFacing: Bool
    /// Bundle ID macOS 26 can keep muted across relaunches. Only set when it can't collide
    /// with something else (never for Simulator system apps or shared system services).
    let standingBundleID: String?
    var processes: [AudioProcess]

    var id: String { key }
    var isPlaying: Bool { processes.contains(where: \.isPlaying) }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.key == rhs.key && lhs.name == rhs.name && lhs.processes == rhs.processes
    }
}

/// One simulator window (a booted device, keyed by its UDID), one Android emulator, or the
/// pseudo-device for host-side services shared by every simulator.
struct SimulatorDevice: Identifiable, Equatable {
    let id: String
    let name: String
    /// "iOS 26.5"
    let detail: String
    let symbol: String
    /// A real simulator/emulator (as opposed to the shared-services group).
    let isDevice: Bool
    var apps: [AudioApp]

    var processes: [AudioProcess] { apps.flatMap(\.processes) }
    var isPlaying: Bool { apps.contains(where: \.isPlaying) }
}

struct AudioSnapshot: Equatable {
    var simulators: [SimulatorDevice] = []
    var apps: [AudioApp] = []

    var allProcesses: [AudioProcess] { simulators.flatMap(\.processes) + apps.flatMap(\.processes) }
}

@MainActor
enum AudioProcessScanner {

    // MARK: Caches

    private struct StaticInfo {
        let pid: pid_t
        let bundleID: String?
        let path: String?
    }

    private struct DeviceInfo {
        let id: String
        let name: String
        let detail: String
        let symbol: String
        let isDevice: Bool
    }

    private struct AppInfo {
        let key: String
        let name: String
        let icon: NSImage
        let isUserFacing: Bool
        let standingBundleID: String?
    }

    private enum Placement {
        case simulator(DeviceInfo, AppInfo)
        case mac(AppInfo)
    }

    /// A process object's PID, bundle ID, path and placement never change, so they're worked
    /// out once. Each scan then costs about one Core Audio call per process.
    private static var infoCache: [AudioObjectID: StaticInfo] = [:]
    private static var placementCache: [AudioObjectID: Placement] = [:]
    private static var deviceCache: [String: DeviceInfo] = [:]

    // MARK: Snapshot

    static func snapshot() -> AudioSnapshot {
        let objectIDs = (try? AudioObjectID.system.readObjectIDs(kAudioHardwarePropertyProcessObjectList)) ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let live = Set(objectIDs)
        infoCache = infoCache.filter { live.contains($0.key) }
        placementCache = placementCache.filter { live.contains($0.key) }

        // Only needed for processes we haven't placed before.
        var runningByPID: [pid_t: NSRunningApplication]?
        func runningApps() -> [pid_t: NSRunningApplication] {
            if let runningByPID { return runningByPID }
            var map: [pid_t: NSRunningApplication] = [:]
            for app in NSWorkspace.shared.runningApplications { map[app.processIdentifier] = app }
            runningByPID = map
            return map
        }

        var deviceInfos: [String: DeviceInfo] = [:]
        var deviceOrder: [String] = []
        var appsByKey: [String: AudioApp] = [:]
        var appDevice: [String: String] = [:]
        var simAppOrder: [String] = []
        var macAppOrder: [String] = []

        func add(_ process: AudioProcess, to info: AppInfo, isSimulator: Bool) {
            if appsByKey[info.key] == nil {
                appsByKey[info.key] = AudioApp(
                    key: info.key,
                    name: info.name,
                    icon: info.icon,
                    isSimulator: isSimulator,
                    isUserFacing: info.isUserFacing,
                    standingBundleID: info.standingBundleID,
                    processes: []
                )
                if isSimulator { simAppOrder.append(info.key) } else { macAppOrder.append(info.key) }
            }
            appsByKey[info.key]?.processes.append(process)
        }

        for objectID in objectIDs {
            guard let process = makeProcess(objectID, ownPID: ownPID) else { continue }

            let placement: Placement
            if let cached = placementCache[objectID] {
                placement = cached
            } else {
                let resolved = resolvePlacement(of: process, runningByPID: runningApps)
                placement = resolved.placement
                if resolved.cacheable { placementCache[objectID] = placement }
            }

            switch placement {
            case .simulator(let device, let app):
                if deviceInfos[device.id] == nil {
                    deviceInfos[device.id] = device
                    deviceOrder.append(device.id)
                }
                appDevice[app.key] = device.id
                add(process, to: app, isSimulator: true)
            case .mac(let app):
                if app.key == ownBundleID { continue }
                add(process, to: app, isSimulator: false)
            }
        }

        for key in Array(appsByKey.keys) {
            if let processes = appsByKey[key]?.processes {
                appsByKey[key]?.processes = disambiguated(processes)
            }
        }

        let simulators = deviceOrder.compactMap { deviceID -> SimulatorDevice? in
            guard let info = deviceInfos[deviceID] else { return nil }
            let apps = simAppOrder
                .filter { appDevice[$0] == deviceID }
                .compactMap { appsByKey[$0] }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return SimulatorDevice(id: info.id, name: info.name, detail: info.detail, symbol: info.symbol,
                                   isDevice: info.isDevice, apps: apps)
        }
        .sorted { lhs, rhs in
            if lhs.isDevice != rhs.isDevice { return lhs.isDevice }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let apps = macAppOrder
            .compactMap { appsByKey[$0] }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return AudioSnapshot(simulators: simulators, apps: apps)
    }

    private static func makeProcess(_ objectID: AudioObjectID, ownPID: pid_t) -> AudioProcess? {
        let info: StaticInfo
        if let cached = infoCache[objectID] {
            info = cached
        } else {
            guard let pid = try? objectID.read(kAudioProcessPropertyPID, default: pid_t(-1)), pid > 0 else { return nil }
            let rawBundleID = (try? objectID.readString(kAudioProcessPropertyBundleID)) ?? ""
            info = StaticInfo(pid: pid, bundleID: rawBundleID.isEmpty ? nil : rawBundleID, path: executablePath(for: pid))
            infoCache[objectID] = info
        }
        guard info.pid != ownPID else { return nil }

        let playing = (try? objectID.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0
        let label = info.path.map { executableName($0) } ?? info.bundleID ?? "Process \(info.pid)"
        return AudioProcess(objectID: objectID, pid: info.pid, bundleID: info.bundleID, path: info.path,
                            label: label, isPlaying: playing != 0)
    }

    /// Sorts an app's processes and appends the PID where two share a name.
    private static func disambiguated(_ processes: [AudioProcess]) -> [AudioProcess] {
        var sorted = processes.sorted { ($0.label, $0.pid) < ($1.label, $1.pid) }
        var counts: [String: Int] = [:]
        for process in sorted { counts[process.label, default: 0] += 1 }
        for index in sorted.indices where (counts[sorted[index].label] ?? 0) > 1 {
            sorted[index].label += " · \(sorted[index].pid)"
        }
        return sorted
    }

    // MARK: Placement

    private static let ownBundleID = Bundle.main.bundleIdentifier ?? "com.flipdigitallabs.hush"

    /// Path fragments that identify iOS/watchOS/visionOS Simulator processes and the Android Emulator.
    /// - Simulator apps:     ~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Containers/Bundle/Application/…
    /// - Simulator daemons:  …/CoreSimulator/…/<runtime>.simruntime/…/RuntimeRoot/…  (SpringBoard etc.)
    /// - Shared services:    /Library/Developer/PrivateFrameworks/CoreSimulator.framework/…
    static let simulatorPathMarkers = ["/CoreSimulator/", "/CoreSimulator.framework/", ".simruntime/",
                                       "/Android/sdk/emulator/", "/qemu-system-"]
    static let simulatorBundleIDs: Set<String> = ["com.apple.iphonesimulator"]

    /// Where user-installed Simulator apps live (as opposed to the runtime's own system apps).
    private static let userAppMarker = "/data/Containers/Bundle/Application/"

    private static let sharedSimulatorDevice = DeviceInfo(
        id: "sim-shared",
        name: "Simulator services",
        detail: "Shared by all simulators",
        symbol: "square.stack.3d.up",
        isDevice: false
    )

    private static func resolvePlacement(
        of process: AudioProcess,
        runningByPID: () -> [pid_t: NSRunningApplication]
    ) -> (placement: Placement, cacheable: Bool) {
        if let simulator = simulatorPlacement(for: process) {
            return (.simulator(simulator.device, simulator.app), true)
        }
        let mac = macApp(for: process, runningByPID: runningByPID)
        return (.mac(mac.app), mac.cacheable)
    }

    // MARK: Simulators

    private static func simulatorPlacement(for process: AudioProcess) -> (device: DeviceInfo, app: AppInfo)? {
        let path = process.path ?? ""
        guard simulatorPathMarkers.contains(where: { path.contains($0) })
                || simulatorBundleIDs.contains(process.bundleID ?? "") else { return nil }

        // Android: one "device" per emulator instance, named after its AVD.
        if path.contains("/emulator/") || path.contains("/qemu-system-") {
            let avd = androidAVDName(pid: process.pid) ?? "Android Emulator"
            let device = DeviceInfo(
                id: "android:\(avd)",
                name: avd.replacingOccurrences(of: "_", with: " "),
                detail: "Android Emulator",
                symbol: "candybarphone",
                isDevice: true
            )
            let app = AppInfo(key: "simapp:\(device.id)|emulator", name: "Emulator audio",
                              icon: symbolIcon("candybarphone"), isUserFacing: true, standingBundleID: nil)
            return (device, app)
        }

        // Which simulator window is this process running in?
        let device: DeviceInfo
        if let location = simulatorDeviceLocation(pid: process.pid, path: path) {
            device = deviceInfo(udid: location.udid, directory: location.directory)
        } else {
            device = sharedSimulatorDevice
        }
        return (device, simulatorApp(for: process, path: path, deviceID: device.id))
    }

    /// Finds the simulator a process belongs to, from (in order): a device path in its own
    /// executable path, its HOME / SIMULATOR_UDID environment, or its `launchd_sim` parent —
    /// every simulator window has its own `launchd_sim`, started with that device's path.
    private static func simulatorDeviceLocation(pid: pid_t, path: String) -> (udid: String, directory: String?)? {
        if let match = deviceMatch(in: path) { return match }

        if let environment = processArguments(pid: pid)?.environment {
            if let home = environmentValue("HOME", in: environment), let match = deviceMatch(in: home) { return match }
            if let udid = environmentValue("SIMULATOR_UDID", in: environment), !udid.isEmpty {
                return (udid.uppercased(), nil)
            }
        }

        var current = pid
        for _ in 0..<8 {
            guard let parent = parentPID(of: current), parent > 1 else { break }
            if let parentPath = executablePath(for: parent), parentPath.hasSuffix("/launchd_sim") {
                if let arguments = processArguments(pid: parent) {
                    for value in arguments.arguments + arguments.environment {
                        if let match = deviceMatch(in: value) { return match }
                    }
                    if let udid = environmentValue("SIMULATOR_UDID", in: arguments.environment), !udid.isEmpty {
                        return (udid.uppercased(), nil)
                    }
                }
                break
            }
            current = parent
        }
        return nil
    }

    /// ".../Devices/<UDID>/data/..." → the UDID and the device folder.
    private static let deviceRegex = try? NSRegularExpression(
        pattern: "/([0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12})/data(?=/|$)"
    )

    private static func deviceMatch(in string: String) -> (udid: String, directory: String?)? {
        guard let regex = deviceRegex else { return nil }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: range),
              let udidRange = Range(match.range(at: 1), in: string) else { return nil }
        return (String(string[udidRange]).uppercased(), String(string[..<udidRange.upperBound]))
    }

    /// Name and OS from the simulator's own device.plist — the same names the Simulator app
    /// shows in its Dock menu ("Audio Probe iPhone 17 Pro" · "iOS 26.5").
    private static func deviceInfo(udid: String, directory: String?) -> DeviceInfo {
        if let cached = deviceCache[udid] { return cached }

        let folder = directory ?? (NSHomeDirectory() + "/Library/Developer/CoreSimulator/Devices/" + udid)
        var name = "Simulator \(udid.prefix(8))"
        var detail = "Simulator"
        var deviceType = ""
        var readPlist = false

        if let data = FileManager.default.contents(atPath: folder + "/device.plist"),
           let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            readPlist = true
            if let value = plist["name"] as? String, !value.isEmpty { name = value }
            if let runtime = plist["runtime"] as? String { detail = runtimeLabel(runtime) }
            deviceType = plist["deviceType"] as? String ?? ""
        }

        let info = DeviceInfo(id: udid, name: name, detail: detail,
                              symbol: deviceSymbol(for: deviceType.isEmpty ? name : deviceType), isDevice: true)
        if readPlist { deviceCache[udid] = info }
        return info
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" → "iOS 26.5"
    static func runtimeLabel(_ identifier: String) -> String {
        let last = identifier.components(separatedBy: ".").last ?? identifier
        var parts = last.components(separatedBy: "-")
        guard parts.count >= 2 else { return last }
        var platform = parts.removeFirst()
        if platform == "xrOS" { platform = "visionOS" }
        return platform + " " + parts.joined(separator: ".")
    }

    private static func deviceSymbol(for type: String) -> String {
        let value = type.lowercased()
        if value.contains("iphone") { return "iphone" }
        if value.contains("ipad") { return "ipad" }
        if value.contains("watch") { return "applewatch" }
        if value.contains("apple-tv") || value.contains("appletv") || value.contains("apple tv") { return "appletv" }
        if value.contains("vision") { return "visionpro" }
        return "iphone"
    }

    /// The app inside a simulator a process belongs to: its .app bundle, or the daemon itself.
    private static func simulatorApp(for process: AudioProcess, path: String, deviceID: String) -> AppInfo {
        // Only look for the .app *after* the CoreSimulator marker, so a runtime that lives
        // inside Xcode.app isn't mistaken for an app called "Xcode".
        let searchFrom = path.range(of: "/CoreSimulator/", options: .backwards)?.upperBound ?? path.startIndex
        let tail = String(path[searchFrom...])

        if let relativeApp = innermostAppBundle(in: tail) {
            let appPath = String(path[..<searchFrom]) + relativeApp
            let bundle = Bundle(path: appPath)
            let bundleID = process.bundleID ?? bundle?.bundleIdentifier ?? baseName(appPath)
            return AppInfo(
                key: "simapp:\(deviceID)|\(bundleID)",
                name: displayName(of: bundle) ?? baseName(appPath),
                icon: cachedIcon(key: "simapp:\(bundleID)") { NSWorkspace.shared.icon(forFile: appPath) },
                isUserFacing: true,
                // Your own apps only: system apps in the runtime (SpringBoard…) are left to
                // per-process taps so nothing on the Mac side can ever match by accident.
                standingBundleID: path.contains(userAppMarker) ? bundleID : nil
            )
        }

        let name = path.isEmpty ? (process.bundleID ?? "Process \(process.pid)") : executableName(path)
        return AppInfo(key: "simapp:\(deviceID)|proc:\(name)", name: name, icon: symbolIcon("gearshape"),
                       isUserFacing: true, standingBundleID: nil)
    }

    private static func androidAVDName(pid: pid_t) -> String? {
        guard let arguments = processArguments(pid: pid)?.arguments else { return nil }
        if let index = arguments.firstIndex(of: "-avd"), index + 1 < arguments.count {
            return arguments[index + 1]
        }
        if let named = arguments.first(where: { $0.hasPrefix("@") && $0.count > 1 }) {
            return String(named.dropFirst())
        }
        return nil
    }

    // MARK: Mac apps

    private static func macApp(
        for process: AudioProcess,
        runningByPID: () -> [pid_t: NSRunningApplication]
    ) -> (app: AppInfo, cacheable: Bool) {
        let path = process.path ?? ""

        // 1. The process is itself a regular app.
        if let app = runningByPID()[process.pid], app.bundleURL?.pathExtension == "app",
           let bundleID = app.bundleIdentifier {
            return (appInfo(for: app, bundleID: bundleID), true)
        }

        // 2. A helper living inside an .app bundle (Chrome/Electron helpers, XPC services…).
        if let appPath = outermostAppBundle(in: path) {
            let bundle = Bundle(path: appPath)
            let bundleID = bundle?.bundleIdentifier ?? appPath
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                return (appInfo(for: app, bundleID: bundleID), true)
            }
            let info = AppInfo(
                key: bundleID,
                name: displayName(of: bundle) ?? baseName(appPath),
                icon: cachedIcon(key: bundleID) { NSWorkspace.shared.icon(forFile: appPath) },
                isUserFacing: true,
                standingBundleID: bundle?.bundleIdentifier
            )
            return (info, true)
        }

        // 3. A system service playing on someone's behalf (e.g. Safari's WebKit GPU process):
        //    credit the app macOS holds responsible for it — but never give a shared system
        //    service a standing tap.
        let isSystemBinary = path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/Library/Apple/")
        if isSystemBinary, let responsible = responsiblePID(for: process.pid),
           let app = runningByPID()[responsible], app.bundleURL?.pathExtension == "app",
           let bundleID = app.bundleIdentifier {
            let base = appInfo(for: app, bundleID: bundleID)
            let credited = AppInfo(key: base.key, name: base.name, icon: base.icon,
                                   isUserFacing: base.isUserFacing, standingBundleID: nil)
            return (credited, true)
        }

        // 4. A bare executable (a game run with `cargo run`, a CLI tool, a daemon). Not cached:
        //    its app may not have registered with the system yet.
        let executable = path.isEmpty ? (process.bundleID ?? "Process \(process.pid)") : executableName(path)
        let key = process.bundleID ?? "process:\(executable)"
        let info = AppInfo(
            key: key,
            name: executable,
            icon: cachedIcon(key: key) {
                path.isEmpty ? (NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage())
                             : NSWorkspace.shared.icon(forFile: path)
            },
            isUserFacing: false,
            standingBundleID: nil
        )
        return (info, false)
    }

    private static func appInfo(for app: NSRunningApplication, bundleID: String) -> AppInfo {
        AppInfo(
            key: bundleID,
            name: app.localizedName ?? bundleID,
            icon: cachedIcon(key: bundleID) { app.icon ?? NSWorkspace.shared.icon(forFile: app.bundleURL?.path ?? "") },
            isUserFacing: app.activationPolicy == .regular,
            standingBundleID: bundleID
        )
    }

    // MARK: Helpers

    private static var iconCache: [String: NSImage] = [:]

    private static func cachedIcon(key: String, make: () -> NSImage) -> NSImage {
        if let icon = iconCache[key] { return icon }
        let icon = make()
        icon.size = NSSize(width: 32, height: 32)
        iconCache[key] = icon
        return icon
    }

    private static func symbolIcon(_ name: String) -> NSImage {
        cachedIcon(key: "symbol:\(name)") {
            NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        }
    }

    private static func displayName(of bundle: Bundle?) -> String? {
        guard let bundle else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    /// "/Applications/Foo.app" → "Foo"
    private static func baseName(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    /// ".../MacOS/com.apple.WebKit.GPU" → "com.apple.WebKit.GPU" (dots kept — not an extension)
    private static func executableName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private static func environmentValue(_ name: String, in environment: [String]) -> String? {
        let prefix = name + "="
        guard let entry = environment.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(entry.dropFirst(prefix.count))
    }

    nonisolated static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    nonisolated static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 && parent != pid ? parent : nil
    }

    /// A process's command-line arguments and environment (works for your own user's processes,
    /// which simulator processes are). Layout of KERN_PROCARGS2: argc, exec path, NUL padding,
    /// argv strings, then environment strings.
    nonisolated static func processArguments(pid: pid_t) -> (arguments: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argumentMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argumentMax, &size, nil, 0) == 0, argumentMax > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(argumentMax))
        size = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        let argumentCount = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // executable path
        while index < size, buffer[index] == 0 { index += 1 }   // padding

        var strings: [String] = []
        var start = index
        while index < size {
            if buffer[index] == 0 {
                if index > start {
                    strings.append(String(decoding: buffer[start..<index], as: UTF8.self))
                } else if strings.count >= argumentCount {
                    break   // end of the environment block
                }
                start = index + 1
            }
            index += 1
        }

        let arguments = Array(strings.prefix(argumentCount))
        let environment = Array(strings.dropFirst(argumentCount))
        return (arguments, environment)
    }

    /// `/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/…` → `/Applications/Google Chrome.app`
    nonisolated static func outermostAppBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// `…/Application/<UUID>/MyGame.app/MyGame` → `…/Application/<UUID>/MyGame.app`
    nonisolated static func innermostAppBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .backwards) else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    // `responsibility_get_pid_responsible_for_pid` is the private call Activity Monitor uses to
    // attribute XPC helpers to their app. Looked up dynamically; absent → that step is skipped.
    private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t

    private static let responsibilityFunction: ResponsibilityFunction? = {
        // RTLD_DEFAULT is ((void *)-2) on Darwin.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let function = responsibilityFunction else { return nil }
        let responsible = function(pid)
        return responsible > 0 && responsible != pid ? responsible : nil
    }
}
