// Hush — per-app and per-simulator audio mixer for macOS
// Copyright (C) 2026 Flip Digital Labs
// SPDX-License-Identifier: GPL-3.0-or-later
// Tap + aggregate setup follows AudioCap (BSD-2-Clause); hardware-input stream usage, ramp
// and Bluetooth drift handling adapted from FineTune (GPL-3.0). See NOTICE.md.

import AudioToolbox
import CoreAudio
import Foundation

/// Shared between the main thread (writes `target`) and the HAL I/O thread (reads it and ramps
/// `current`). Aligned Float reads/writes are atomic on Apple silicon and x86-64, so no lock is
/// needed on the real-time thread.
final class GainState {
    var target: Float
    var current: Float
    /// Per-sample smoothing toward `target` (≈30 ms), so volume changes don't click.
    var rampCoefficient: Float = 0.0007

    init(gain: Float) {
        target = gain
        current = gain
    }
}

/// Takes over audio — one process, or (macOS 26) every process with a bundle ID — and re-plays
/// it at a chosen gain. Gain 0 is how Hush mutes; moving between muted and any volume is just
/// a gain change, never a rebuild.
///
/// How it works (macOS 14.2+ Core Audio process taps):
/// 1. A process tap with `.muted` captures the audio and keeps it from reaching the speakers
///    directly. A tap only takes effect while something is reading it, so it is always paired
///    with a running reader (2–3) — a bare tap on its own changes nothing.
/// 2. A private aggregate device combines the tap with the current output device.
/// 3. Our I/O block copies the tap's samples to that output device, multiplied by the gain
///    (or writes silence at gain 0).
///
/// Nothing is recorded or stored. Destroying the tap hands the audio straight back.
final class AppVolumeTap {
    let name: String
    let outputUID: String

    private let state: GainState
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// - Parameter tapDescription: from `TapDescriptions` (uuid, `.muted` and private already set).
    init(name: String, tapDescription: CATapDescription, outputDeviceID: AudioDeviceID, outputUID: String, gain: Float) throws {
        self.name = name
        self.outputUID = outputUID
        self.state = GainState(gain: Swift.min(Swift.max(gain, 0), 1))

        do {
            try start(tapDescription: tapDescription, outputDeviceID: outputDeviceID)
        } catch {
            invalidate()
            throw error
        }
    }

    deinit { invalidate() }

    var gain: Float { state.target }

    func setGain(_ gain: Float) {
        state.target = Swift.min(Swift.max(gain, 0), 1)
    }

    // MARK: Lifecycle

    private func start(tapDescription: CATapDescription, outputDeviceID: AudioDeviceID) throws {
        // 1. The tap.
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(tapDescription, &newTapID), "Creating the audio tap")
        tapID = newTapID

        // 2. Private aggregate device: real output device (clock + speakers) + our tap.
        //    Tap drift compensation is turned off for Bluetooth outputs — there it causes a
        //    rhythmic crackle because tap and output already share the Bluetooth clock.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hush-\(name)",
            kAudioAggregateDeviceUIDKey: "com.flipdigitallabs.hush.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: !outputDeviceID.isBluetooth,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID),
                  "Creating the aggregate device")
        aggregateID = newAggregateID
        aggregateID.waitUntilAlive(timeout: 2)

        // The tap's streams come after the output device's own input streams (e.g. a headset
        // mic), so they're the trailing buffers of the aggregate's input list.
        let aggregateInputs = aggregateID.streamCount(scope: kAudioObjectPropertyScopeInput)
        let hardwareInputs = outputDeviceID.streamCount(scope: kAudioObjectPropertyScopeInput)
        let tapStreams = Swift.max(1, aggregateInputs - hardwareInputs)

        let stereo = outputDeviceID.preferredStereoChannels
        state.rampCoefficient = 1 - expf(-1 / (Float(aggregateID.nominalSampleRate) * 0.030))

        // 3. Real-time I/O block (no allocations, locks or logging inside).
        var newProcID: AudioDeviceIOProcID?
        let block = AppVolumeTap.makeIOBlock(state: state, tapStreams: tapStreams, left: stereo.left, right: stereo.right)
        try check(AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, nil, block), "Creating the audio callback")
        ioProcID = newProcID

        if let procID = newProcID, aggregateInputs > tapStreams {
            disableHardwareInputs(procID: procID, totalInputs: aggregateInputs, tapStreams: tapStreams)
        }

        try check(AudioDeviceStart(aggregateID, ioProcID), "Starting audio")
    }

    func invalidate() {
        if aggregateID.isValid {
            if let procID = ioProcID {
                _ = AudioDeviceStop(aggregateID, procID)
                _ = AudioDeviceDestroyIOProcID(aggregateID, procID)
                ioProcID = nil
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID.isValid {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Tells the HAL this callback never reads the output device's hardware inputs, so a duplex
    /// device (AirPods, USB interface) doesn't power up its mic — which would trigger a
    /// microphone prompt and drop AirPods into low-quality call mode.
    /// Layout of AudioHardwareIOProcStreamUsage: { void *mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[]; }
    private func disableHardwareInputs(procID: AudioDeviceIOProcID, totalInputs: Int, tapStreams: Int) {
        let pointerSize = MemoryLayout<UnsafeMutableRawPointer>.size
        let headerSize = pointerSize + MemoryLayout<UInt32>.size
        let totalSize = headerSize + totalInputs * MemoryLayout<UInt32>.size

        let raw = UnsafeMutableRawPointer.allocate(byteCount: totalSize, alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
        defer { raw.deallocate() }

        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(totalInputs), toByteOffset: pointerSize, as: UInt32.self)
        let firstTapStream = totalInputs - tapStreams
        for index in 0..<totalInputs {
            let isOn: UInt32 = index >= firstTapStream ? 1 : 0
            raw.storeBytes(of: isOn, toByteOffset: headerSize + index * MemoryLayout<UInt32>.size, as: UInt32.self)
        }

        var address = propertyAddress(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        _ = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(totalSize), raw)
    }

    // MARK: Real-time rendering

    private static func makeIOBlock(state: GainState, tapStreams: Int, left: Int, right: Int) -> AudioDeviceIOBlock {
        return { _, inputData, _, outputData, _ in
            AppVolumeTap.render(input: inputData, output: outputData, state: state,
                                tapStreams: tapStreams, leftChannel: left, rightChannel: right)
        }
    }

    private static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        state: GainState,
        tapStreams: Int,
        leftChannel: Int,
        rightChannel: Int
    ) {
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

        let target = state.target
        let startGain = state.current
        let coefficient = state.rampCoefficient

        // Locate the tap's left/right samples (interleaved stereo in one buffer, or two mono buffers).
        var leftSamples: UnsafeMutablePointer<Float>?
        var rightSamples: UnsafeMutablePointer<Float>?
        var inputStride = 1
        var inputFrames = 0

        let firstTap = Swift.max(0, inputs.count - tapStreams)
        let silent = target <= 0.0001 && startGain <= 0.0001
        if !silent, firstTap < inputs.count, let data = inputs[firstTap].mData {
            let channels = Swift.max(1, Int(inputs[firstTap].mNumberChannels))
            let base = data.assumingMemoryBound(to: Float.self)
            inputFrames = Int(inputs[firstTap].mDataByteSize) / (MemoryLayout<Float>.size * channels)
            inputStride = channels
            leftSamples = base
            if channels >= 2 {
                rightSamples = base + 1
            } else if firstTap + 1 < inputs.count, let second = inputs[firstTap + 1].mData {
                rightSamples = second.assumingMemoryBound(to: Float.self)
            } else {
                rightSamples = base
            }
        }

        var endGain = startGain
        var channelOffset = 0

        for buffer in outputs {
            let outputChannels = Swift.max(1, Int(buffer.mNumberChannels))
            defer { channelOffset += outputChannels }
            guard let outData = buffer.mData else { continue }

            memset(outData, 0, Int(buffer.mDataByteSize))
            guard let left = leftSamples, inputFrames > 0 else { continue }

            let out = outData.assumingMemoryBound(to: Float.self)
            let outputFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * outputChannels)
            let frames = Swift.min(outputFrames, inputFrames)

            for channel in 0..<outputChannels {
                let deviceChannel = channelOffset + channel
                let source: UnsafeMutablePointer<Float>
                if deviceChannel == leftChannel {
                    source = left
                } else if deviceChannel == rightChannel, let right = rightSamples {
                    source = right
                } else {
                    continue
                }

                var gain = startGain
                for frame in 0..<frames {
                    gain += (target - gain) * coefficient
                    out[frame * outputChannels + channel] = source[frame * inputStride] * gain
                }
                endGain = gain
            }
        }

        state.current = silent ? target : endGain
    }
}
