// Hush — per-app and per-simulator audio mixer for macOS
// Copyright (C) 2026 Flip Digital Labs
// SPDX-License-Identifier: GPL-3.0-or-later
// Permission check follows AudioCap (BSD-2-Clause) and FineTune (GPL-3.0). See NOTICE.md.

import AppKit
import Foundation

/// The "System Audio Recording Only" privacy permission that process taps need.
/// Without it a tap delivers silence — muting still works, but a 40% volume would sound muted.
///
/// macOS has no public API to read this permission, so (like AudioCap and FineTune) we look up
/// the TCC functions dynamically. If they're unavailable the status simply stays `.unknown`.
enum AudioPermission {
    enum Status {
        case unknown
        case authorized
        case denied
    }

    static func status() -> Status {
        guard let preflight = preflightFunction else { return .unknown }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt (only the first time — after that macOS stays silent).
    static func request(completion: @escaping (Bool) -> Void) {
        guard let request = requestFunction else {
            completion(false)
            return
        }
        request(service, nil, completion)
    }

    /// Privacy & Security → Screen & System Audio Recording.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: TCC lookup

    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let handle: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflightFunction: PreflightFunction? = {
        guard let tcc = AudioPermission.handle, let symbol = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunction.self)
    }()

    private static let requestFunction: RequestFunction? = {
        guard let tcc = AudioPermission.handle, let symbol = dlsym(tcc, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: RequestFunction.self)
    }()
}
