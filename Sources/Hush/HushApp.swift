// Hush — per-app and per-simulator audio mixer for macOS
// Copyright (C) 2026 Flip Digital Labs
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct HushApp: App {
    @StateObject private var mixer = Mixer()

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environmentObject(mixer)
        } label: {
            Image(systemName: mixer.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}
