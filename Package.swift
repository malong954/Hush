// swift-tools-version:5.9
// Hush — per-app and per-simulator audio mixer for macOS
// Copyright (C) 2026 Flip Digital Labs
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// Hush — per-app mute & volume for macOS, built for muting Simulators while you work.
// Build the .app with ./build.sh (see README.md). Requires macOS 14.2+ (Core Audio process taps).
let package = Package(
    name: "Hush",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "Hush",
            path: "Sources/Hush"
        )
    ]
)
