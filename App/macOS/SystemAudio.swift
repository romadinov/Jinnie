// Process audio taps adapted from AudioCap by Guilherme Rambo (BSD 2-Clause, https://github.com/insidegui/AudioCap):
// Copyright (c) 2024 Guilherme Rambo. Redistribution and use in source and binary forms, with or without modification,
// are permitted provided that the copyright notice and this condition are retained (see AudioCap's LICENSE).
import AudioToolbox
import AVFoundation
import Foundation

/// An app that is using audio right now, as Core Audio sees it (macOS 14.2+).
struct AudioProcess: Hashable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningInput: Bool
    let isRunningOutput: Bool

    /// The microphone this app is recording from (e.g. AirPods during a call), if Core Audio says.
    var inputDevice: AudioDeviceID? {
        let devices = (try? objectID.readArray(kAudioProcessPropertyDevices)) ?? []
        return devices.first { $0.hasInput }
    }

    /// Every process Core Audio knows about.
    static func all() -> [AudioProcess] {
        (try? AudioObjectID(kAudioObjectSystemObject).readArray(kAudioHardwarePropertyProcessObjectList)) .map { ids in
            ids.compactMap { id in
                let pid: pid_t = (try? id.read(kAudioProcessPropertyPID, default: pid_t(-1))) ?? -1
                guard pid > 0 else { return nil }
                return AudioProcess(objectID: id, pid: pid, bundleID: (try? id.readString(kAudioProcessPropertyBundleID)) ?? "",
                                    isRunningInput: ((try? id.read(kAudioProcessPropertyIsRunningInput, default: UInt32(0))) ?? 0) == 1,
                                    isRunningOutput: ((try? id.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0) == 1)
            }
        } ?? []
    }
}

/// Records what some apps play (the other people in a call), mixed to mono 16 kHz AAC, through a Core Audio process tap.
/// Needs NSAudioCaptureUsageDescription (without it every buffer is silent) and the user's "System Audio Recording" consent.
final class SystemAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "jinnie.system-audio", qos: .userInitiated)
    private(set) var processIDs: [AudioObjectID] = []
    private var outputListener: AudioObjectPropertyListenerBlock?

    func start(processes: [AudioObjectID], writingTo url: URL) throws {
        processIDs = processes
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try build()
        // AirPods connecting (or any change of output device) re-routes the call: rebuild the tap on the new device and
        // keep writing to the same file.
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.file != nil else { return }
            self.teardownTap()
            do { try self.build() } catch { NSLog("Jinnie: meeting audio lost after a device change: %@", error.localizedDescription) }
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
    }

    private func build() throws {
        guard let out = file else { return }
        let desc = CATapDescription(stereoMixdownOfProcesses: processIDs)
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw TapError("Couldn't create the audio tap (\(err))") }

        let outputID: AudioDeviceID = try AudioObjectID(kAudioObjectSystemObject).read(kAudioHardwarePropertyDefaultSystemOutputDevice, default: AudioDeviceID(kAudioObjectUnknown))
        let outputUID = try outputID.readString(kAudioDevicePropertyDeviceUID)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Jinnie meeting audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var asbd: AudioStreamBasicDescription = try tapID.read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard err == noErr else { teardownTap(); throw TapError("Couldn't create the aggregate device (\(err))") }
        guard let inFormat = AVAudioFormat(streamDescription: &asbd),
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: mono) else { teardownTap(); throw TapError("Unsupported tap format") }
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inInputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, bufferListNoCopy: inInputData, deallocator: nil) else { return }
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / inFormat.sampleRate + 32)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: cap) else { return }
            var fed = false
            converter.convert(to: pcm, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            try? out.write(from: pcm)
        }
        guard err == noErr else { teardownTap(); throw TapError("Couldn't start reading meeting audio (\(err))") }
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { teardownTap(); throw TapError("Couldn't start the aggregate device (\(err))") }
    }

    private func teardownTap() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }

    func stop() {
        if let listener = outputListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            outputListener = nil
        }
        teardownTap()
        queue.sync { file = nil }  // closes the file after the last buffer
    }

    deinit { stop() }

    struct TapError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}

// MARK: - Core Audio property access

extension AudioObjectID {
    /// A device with input streams (a microphone).
    var hasInput: Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr && size > 0
    }

    func read<T>(_ selector: AudioObjectPropertySelector, default value: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        var out = value
        let err = withUnsafeMutablePointer(to: &out) { AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0) }
        guard err == noErr else { throw SystemAudioTap.TapError("Core Audio property \(selector): \(err)") }
        return out
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        try read(selector, default: "" as CFString) as String
    }

    func readArray(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}
