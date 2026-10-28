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
    private let queue: DispatchQueue = {
        let q = DispatchQueue(label: "jinnie.system-audio", qos: .userInitiated)
        q.setSpecific(key: SystemAudioTap.onQueue, value: true)
        return q
    }()
    private static let onQueue = DispatchSpecificKey<Bool>()
    private(set) var processIDs: [AudioObjectID] = []
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var writer: TapWriter?

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
        guard let inFormat = AVAudioFormat(streamDescription: &asbd) else { teardownTap(); throw TapError("Unsupported tap format") }
        let writer = TapWriter(declared: inFormat, out: out)
        self.writer = writer
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inInputData, _, _, _ in
            writer.receive(inInputData)
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
        // The device is stopped, so no more buffers arrive: write anything still held for measuring.
        // (The device-change listener already runs on `queue`: waiting on it there would deadlock.)
        if let writer {
            if DispatchQueue.getSpecific(key: Self.onQueue) == true { writer.finish() } else { queue.sync { writer.finish() } }
        }
        writer = nil
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


/// Writes the call audio as 16 kHz mono. The tap's declared format can be wrong: from 27 Oct 2026 every call was saved
/// at half its real rate (twice as fast, drifting from the microphone, transcribed as nonsense). So the first 3 s are
/// held while measuring how many frames really arrive per second; if that disagrees with the declared rate, the
/// measured one is used for everything.
final class TapWriter: @unchecked Sendable {
    private let declared: AVAudioFormat
    private let out: AVAudioFile
    private let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var held: [AVAudioPCMBuffer] = []
    private var heldFrames = 0
    private var firstAt: Date?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?

    init(declared: AVAudioFormat, out: AVAudioFile) { self.declared = declared; self.out = out }

    func receive(_ list: UnsafePointer<AudioBufferList>) {
        guard let b = AVAudioPCMBuffer(pcmFormat: declared, bufferListNoCopy: list, deallocator: nil), b.frameLength > 0 else { return }
        if let format { write(b, as: format); return }
        guard let copy = Self.copy(b) else { return }
        held.append(copy)
        heldFrames += Int(b.frameLength)
        let now = Date()
        if firstAt == nil { firstAt = now }
        let elapsed = now.timeIntervalSince(firstAt!)
        if elapsed >= 3 { decide(rate: Double(heldFrames - Int(b.frameLength)) / elapsed) }
    }

    /// Writes what is still held (a call shorter than the measuring window).
    func finish() {
        guard format == nil, let firstAt, !held.isEmpty else { return }
        let elapsed = Date().timeIntervalSince(firstAt)
        decide(rate: elapsed > 0.5 ? Double(heldFrames) / elapsed : declared.sampleRate)
    }

    private func decide(rate measured: Double) {
        let standard: [Double] = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000]
        var rate = declared.sampleRate
        if abs(measured / declared.sampleRate - 1) > 0.15 {
            rate = standard.min { abs($0 / measured - 1) < abs($1 / measured - 1) } ?? measured
            NSLog("Jinnie: call audio declared %.0f Hz but arrives at %.0f Hz; recording it as %.0f Hz", declared.sampleRate, measured, rate)
        }
        guard let f = AVAudioFormat(commonFormat: declared.commonFormat, sampleRate: rate, channels: declared.channelCount,
                                    interleaved: declared.isInterleaved) else { return }
        format = f
        for h in held { write(h, as: f) }
        held = []
    }

    private func write(_ b: AVAudioPCMBuffer, as f: AVAudioFormat) {
        // Same bytes, read at the right rate.
        guard let input = f == declared ? b : AVAudioPCMBuffer(pcmFormat: f, bufferListNoCopy: b.audioBufferList, deallocator: nil) else { return }
        if converter == nil || converter?.inputFormat != f { converter = AVAudioConverter(from: f, to: mono) }
        guard let converter else { return }
        let cap = AVAudioFrameCount(Double(input.frameLength) * 16000 / f.sampleRate + 32)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: cap) else { return }
        var fed = false
        converter.convert(to: pcm, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        try? out.write(from: pcm)
    }

    private static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        c.frameLength = b.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: b.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(c.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            guard let s = src[i].mData, let d = dst[i].mData else { continue }
            memcpy(d, s, Int(min(src[i].mDataByteSize, dst[i].mDataByteSize)))
        }
        return c
    }
}
