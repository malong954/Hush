// Hush — per-app and per-simulator audio mixer for macOS
// Copyright (C) 2026 Flip Digital Labs
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MixerView: View {
    @EnvironmentObject private var mixer: Mixer
    @State private var listHeight: CGFloat = 160
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if mixer.permission != .authorized {
                PermissionBanner()
            }

            SimulatorSwitch()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !mixer.simulators.isEmpty {
                        SectionTitle("Simulators")
                        ForEach(mixer.simulators) { device in
                            DeviceRow(device: device, isExpanded: expansion("device:" + device.id))
                        }
                    }

                    SectionTitle("Apps")
                    if mixer.regularApps.isEmpty {
                        Text("No apps are using audio right now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(mixer.regularApps) { app in
                            AppRow(app: app, isExpanded: expansion("app:" + app.key))
                        }
                    }

                    if !mixer.dormantRules.isEmpty {
                        SectionTitle("Applied when they launch")
                        ForEach(mixer.dormantRules) { dormant in
                            DormantRuleRow(dormant: dormant)
                        }
                    }
                }
                .padding(.trailing, 4)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            // Menu bar windows size to their content, and a bare ScrollView has no natural
            // height — so measure the list and grow with it, scrolling past 460 pt.
            .frame(height: min(max(listHeight, 44), 460))
            .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }

            if let error = mixer.launchAtLoginError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(width: 360)
        .onAppear { mixer.refresh() }
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.vertical.3")
                .foregroundStyle(.secondary)
            Text("Hush")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Label(mixer.outputDeviceName, systemImage: "hifispeaker")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Current output device")
            SettingsMenu()
        }
    }
}

// MARK: - Simulator master switch

private struct SimulatorSwitch: View {
    @EnvironmentObject private var mixer: Mixer

    var body: some View {
        let total = mixer.simulators.filter(\.isDevice).count
        let mutedCount = mixer.mutedSimulatorCount
        let isOn = mixer.simulatorsMuted

        HStack(spacing: 10) {
            Image(systemName: isOn ? "iphone.slash" : "iphone.gen3")
                .font(.system(size: 20))
                .frame(width: 28)
                .foregroundStyle(isOn ? Color.red : Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Mute all Simulators")
                    .font(.system(size: 13, weight: .semibold))
                Text(total == 0 ? "iOS Simulator & Android Emulator" : "\(mutedCount) of \(total) muted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help("Also applies to every relaunch and to simulators you boot later. Expand a simulator below to make exceptions.")

            Spacer()

            Toggle("Mute all Simulators", isOn: Binding(
                get: { mixer.simulatorsMuted },
                set: { mixer.setSimulatorsMuted($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isOn ? Color.red.opacity(0.10) : Color.primary.opacity(0.05))
        )
    }
}

// MARK: - Rows

/// One simulator window. Expands into the apps running inside it.
private struct DeviceRow: View {
    @EnvironmentObject private var mixer: Mixer
    let device: SimulatorDevice
    @Binding var isExpanded: Bool

    var body: some View {
        let total = device.apps.count
        let mutedCount = mixer.mutedAppCount(in: device)
        let allMuted = mutedCount == total

        VStack(alignment: .leading, spacing: 0) {
            ParentRow(
                isExpanded: $isExpanded,
                canExpand: true,
                icon: Image(systemName: device.symbol),
                isSymbol: true,
                title: device.name,
                subtitle: "\(device.detail) · \(total) \(total == 1 ? "app" : "apps")",
                isPlaying: device.isPlaying,
                mutedCount: mutedCount,
                total: total,
                volume: mixer.volume(device: device),
                error: mixer.error(for: device.processes),
                setVolume: { mixer.setVolume($0, device: device) },
                toggleMute: { mixer.setMuted(!allMuted, device: device) }
            )

            if isExpanded {
                ForEach(device.apps) { app in
                    ChildRow(
                        icon: Image(nsImage: app.icon),
                        isSymbol: false,
                        title: app.name,
                        isPlaying: app.isPlaying,
                        isMuted: mixer.isMuted(app, in: device),
                        error: mixer.error(for: app.processes),
                        toggle: { mixer.toggleMute(app, in: device) }
                    )
                }
            }
        }
    }
}

/// One Mac app. Expands into its audio processes when it has more than one.
private struct AppRow: View {
    @EnvironmentObject private var mixer: Mixer
    let app: AudioApp
    @Binding var isExpanded: Bool

    var body: some View {
        let total = app.processes.count
        let mutedCount = mixer.mutedProcessCount(in: app)
        let allMuted = mutedCount == total

        VStack(alignment: .leading, spacing: 0) {
            ParentRow(
                isExpanded: $isExpanded,
                canExpand: total > 1,
                icon: Image(nsImage: app.icon),
                isSymbol: false,
                title: app.name,
                subtitle: total > 1 ? "\(total) audio processes" : nil,
                isPlaying: app.isPlaying,
                mutedCount: mutedCount,
                total: total,
                volume: mixer.volume(app: app),
                error: mixer.error(for: app.processes),
                setVolume: { mixer.setVolume($0, app: app) },
                toggleMute: { mixer.setMuted(!allMuted, app: app) }
            )

            if isExpanded && total > 1 {
                ForEach(app.processes) { process in
                    ChildRow(
                        icon: Image(systemName: "waveform"),
                        isSymbol: true,
                        title: process.label,
                        isPlaying: process.isPlaying,
                        isMuted: mixer.isMuted(process, in: app),
                        error: mixer.processErrors[process.objectID],
                        toggle: { mixer.toggleMute(process, in: app) }
                    )
                }
            }
        }
    }
}

/// Shared layout for a simulator or app row: chevron, icon, name, status, slider, mute.
private struct ParentRow: View {
    @Binding var isExpanded: Bool
    let canExpand: Bool
    let icon: Image
    let isSymbol: Bool
    let title: String
    let subtitle: String?
    let isPlaying: Bool
    let mutedCount: Int
    let total: Int
    let volume: Float
    let error: String?
    let setVolume: (Float) -> Void
    let toggleMute: () -> Void

    var body: some View {
        let allMuted = total > 0 && mutedCount == total
        let partlyMuted = mutedCount > 0 && !allMuted

        HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(canExpand ? 1 : 0)
            .disabled(!canExpand)
            .help(isExpanded ? "Collapse" : "Show what's inside")

            RowIcon(icon: icon, isSymbol: isSymbol, size: 22, dimmed: allMuted)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if isPlaying {
                        PlayingDot(isMuted: allMuted)
                    }
                    Spacer(minLength: 4)
                    Text(allMuted ? "Muted" : partlyMuted ? "\(mutedCount) of \(total) muted" : "\(Int((volume * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(allMuted ? Color.red : partlyMuted ? Color.orange : Color.secondary)
                }

                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Slider(
                    value: Binding(get: { Double(volume) }, set: { setVolume(Float($0)) }),
                    in: 0...1
                )
                .controlSize(.mini)
                .disabled(allMuted)

                if let error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            MuteButton(isMuted: allMuted, help: allMuted ? "Unmute all" : partlyMuted ? "Mute all" : "Mute", action: toggleMute)
        }
        .padding(.vertical, 4)
    }
}

/// An app inside a simulator, or one process of a Mac app.
private struct ChildRow: View {
    let icon: Image
    let isSymbol: Bool
    let title: String
    let isPlaying: Bool
    let isMuted: Bool
    let error: String?
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                RowIcon(icon: icon, isSymbol: isSymbol, size: 16, dimmed: isMuted)
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(isMuted ? Color.secondary : Color.primary)
                if isPlaying {
                    PlayingDot(isMuted: isMuted)
                }
                Spacer(minLength: 4)
                if isMuted {
                    Text("Muted")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                MuteButton(isMuted: isMuted, help: isMuted ? "Unmute" : "Mute", action: toggle)
            }
            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.leading, 40)
        .padding(.vertical, 2)
    }
}

private struct RowIcon: View {
    let icon: Image
    let isSymbol: Bool
    let size: CGFloat
    let dimmed: Bool

    var body: some View {
        Group {
            if isSymbol {
                icon
                    .font(.system(size: size * 0.72))
                    .foregroundStyle(.secondary)
            } else {
                icon
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .opacity(dimmed ? 0.5 : 1)
    }
}

private struct PlayingDot: View {
    let isMuted: Bool

    var body: some View {
        Circle()
            .fill(isMuted ? Color.secondary : Color.green)
            .frame(width: 6, height: 6)
            .help(isMuted ? "Producing audio (muted)" : "Producing audio")
    }
}

private struct MuteButton: View {
    let isMuted: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 18)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isMuted ? Color.red : Color.secondary)
        .help(help)
    }
}

private struct DormantRuleRow: View {
    @EnvironmentObject private var mixer: Mixer
    let dormant: DormantRule

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "app.dashed")
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(dormant.rule.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(dormant.rule.muted ? "Muted" : "\(Int((dormant.rule.volume * 100).rounded()))% volume")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                mixer.forgetRule(key: dormant.key)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Forget this rule")
        }
        .padding(.leading, 18)
        .padding(.vertical, 3)
    }
}

private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

// MARK: - Permission & settings

private struct PermissionBanner: View {
    @EnvironmentObject private var mixer: Mixer

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(mixer.permission == .denied
                     ? "Hush needs System Audio Recording access. Turn on Hush under Screen & System Audio Recording → System Audio Recording Only."
                     : "Hush needs one-time permission to route app audio. Nothing is recorded.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button(mixer.permission == .denied ? "Open Privacy Settings" : "Allow Access") {
                    mixer.requestPermission()
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }
}

private struct SettingsMenu: View {
    @EnvironmentObject private var mixer: Mixer

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    var body: some View {
        Menu {
            Text("Hush \(Self.version)")
            Button("Hush on GitHub…") {
                if let url = URL(string: "https://github.com/malong954/Hush") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Toggle("Show background processes", isOn: $mixer.showBackgroundProcesses)
            Toggle("Launch at login", isOn: $mixer.launchAtLogin)
            Divider()
            Button("Reset everything") { mixer.resetAll() }
            Divider()
            Button("Quit Hush") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
