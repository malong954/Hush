// Hush — per-app and per-simulator audio mixer for macOS
// Copyright (C) 2026 Flip Digital Labs
// SPDX-License-Identifier: GPL-3.0-or-later

import AudioToolbox
import CoreAudio
import Foundation

/// Builds the process-tap descriptions Hush uses. Every tap is `.muted` (the audio never reaches
/// the speakers directly) and private to Hush. A tap only takes effect while it's being read,
/// so each one is handed to an `AppVolumeTap`, which keeps it read for as long as it exists.
enum TapDescriptions {

    /// Specific running processes.
    static func processes(_ objectIDs: [AudioObjectID]) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        prepare(description)
        return description
    }

    // MARK: Standing taps (macOS 26+)

    /// macOS 26 lets a tap target bundle IDs and "restore" them: the system re-attaches the tap
    /// itself the instant an app with that bundle ID starts again — before Hush even hears about
    /// the new process — so relaunches and rebuilds are silent from the first sample.
    static let supportsStandingTaps: Bool = {
        guard #available(macOS 26.0, *) else { return false }
        let probe = CATapDescription(stereoMixdownOfProcesses: [])
        return probe.responds(to: NSSelectorFromString("setBundleIDs:"))
            && probe.responds(to: NSSelectorFromString("setProcessRestoreEnabled:"))
    }()

    /// Every process with one of `bundleIDs`, now and on every future launch. Nil when
    /// unsupported or if the result wouldn't be a plain include-list tap for exactly those IDs.
    static func standing(bundleIDs: [String]) -> CATapDescription? {
        let ids = bundleIDs.filter(isPlausibleBundleID).sorted()
        guard supportsStandingTaps, !ids.isEmpty else { return nil }

        // Include-list tap with no explicit processes, filled by bundle ID. Set through KVC so
        // this compiles against any SDK; the setters are checked for above.
        let description = CATapDescription(stereoMixdownOfProcesses: [])
        if description.responds(to: NSSelectorFromString("setExclusive:")) {
            description.setValue(false, forKey: "exclusive")
        }
        description.setValue(ids, forKey: "bundleIDs")
        description.setValue(true, forKey: "processRestoreEnabled")

        // Safety: an exclusive ("everything except…") tap would mute the whole Mac.
        guard !description.isExclusive,
              (description.value(forKey: "bundleIDs") as? [String])?.sorted() == ids else { return nil }

        prepare(description)
        return description
    }

    static func isPlausibleBundleID(_ value: String) -> Bool {
        !value.isEmpty && value.contains(".") && !value.contains("/") && !value.contains(" ")
    }

    private static func prepare(_ description: CATapDescription) {
        description.uuid = UUID()
        description.muteBehavior = .muted
        description.isPrivate = true
    }
}
