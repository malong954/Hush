// Hush — per-app and per-simulator audio mixer for macOS
// Copyright (C) 2026 Flip Digital Labs
// SPDX-License-Identifier: GPL-3.0-or-later
// Property helpers follow AudioCap (BSD-2-Clause); device readiness adapted from FineTune
// (GPL-3.0). See NOTICE.md.

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Errors

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? { "\(operation) failed (\(fourCharCode(UInt32(bitPattern: status))))" }
}

/// Throws a `CoreAudioError` when `status` is not `noErr`.
func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
}

/// Renders a Core Audio four-char code ('who?', '!obj') when printable, otherwise the number.
func fourCharCode(_ value: UInt32) -> String {
    let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
    return String(Int32(bitPattern: value))
}

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

// MARK: - AudioObjectID conveniences

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != AudioObjectID(kAudioObjectUnknown) }

    /// Reads a fixed-size property value.
    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        default defaultValue: T
    ) throws -> T {
        var address = propertyAddress(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        try check(status, "Reading \(fourCharCode(selector))")
        return value
    }

    /// Reads a CFString property (returned +1 retained by the HAL).
    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = propertyAddress(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        try check(status, "Reading \(fourCharCode(selector))")
        guard let string = value?.takeRetainedValue() else { return "" }
        return string as String
    }

    /// Reads a variable-length array of object IDs (process list, stream list…).
    func readObjectIDs(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        var address = propertyAddress(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size), "Sizing \(fourCharCode(selector))")
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &ids), "Reading \(fourCharCode(selector))")
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// Number of streams a device exposes in the given scope.
    func streamCount(scope: AudioObjectPropertyScope) -> Int {
        var address = propertyAddress(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }

    var isAlive: Bool {
        ((try? self.read(kAudioDevicePropertyDeviceIsAlive, default: UInt32(0))) ?? 0) != 0
    }

    /// Freshly created aggregate devices can take a moment to come up. Pumps the run loop
    /// (so HAL notifications are delivered) until the device reports alive.
    @discardableResult
    func waitUntilAlive(timeout: TimeInterval) -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            if isAlive { return true }
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, false)
        }
        return isAlive
    }

    var isBluetooth: Bool {
        let transport = (try? self.read(kAudioDevicePropertyTransportType, default: UInt32(0))) ?? 0
        return transport == UInt32(kAudioDeviceTransportTypeBluetooth)
            || transport == UInt32(kAudioDeviceTransportTypeBluetoothLE)
    }

    /// Zero-based output channel indices the device uses for stereo (usually 0 and 1).
    var preferredStereoChannels: (left: Int, right: Int) {
        var address = propertyAddress(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput)
        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * channels.count)
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &channels)
        guard status == noErr else { return (0, 1) }
        return (Swift.max(0, Int(channels[0]) - 1), Swift.max(0, Int(channels[1]) - 1))
    }

    var nominalSampleRate: Double {
        (try? self.read(kAudioDevicePropertyNominalSampleRate, default: Float64(48_000))) ?? 48_000
    }

    static func defaultOutputDevice() -> AudioDeviceID {
        (try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown)))
            ?? AudioObjectID(kAudioObjectUnknown)
    }
}
