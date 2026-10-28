import AudioToolbox
import AVFoundation
import Foundation
import JinnieCore
import Observation

/// Records a meeting: the microphone, plus the meeting app's audio (the other participants) through a process tap.
/// Each recording is saved to Jinnie's database as `.recording`, then `.processing` when it stops; Jinnie transcribes it.
/// Audio goes to Application Support/Jinnie/recordings (16 kHz AAC, ~15 MB/hour) as it is captured, so a crash loses nothing.
@MainActor @Observable
final class CallRecorder {
    static let shared = CallRecorder()

    enum State: Equatable { case idle, recording(Date), failed(String) }
    private(set) var state: State = .idle
    var isRecording: Bool { if case .recording = state { return true }; return false }
    private(set) var title: String?

    let store: Store
    private let engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var file: AVAudioFile?
    private var systemTap: SystemAudioTap?
    private var current: Recording?

    private init() {
        do { store = try Store() } catch { fatalError("Cannot open Jinnie's database: \(error)") }
    }

    static var folder: URL { JinnieConfig.supportDirectory().appendingPathComponent("recordings", isDirectory: true) }
    static func audioURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).m4a") }
    static func systemURL(_ id: String) -> URL { folder.appendingPathComponent("\(id)-meeting.m4a") }

    func toggle() { isRecording ? stop() : start(meeting: MeetingDetector.shared.activeMeeting()) }

    /// Starts recording the microphone, plus the audio of `meeting`'s app (the other participants) when there is one.
    func start(meeting: MeetingDetector.Detected? = nil, auto: Bool = false) {
        guard !isRecording else { return }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                state = .failed("Microphone access is off for Jinnie Recorder. Allow it in System Settings → Privacy & Security → Microphone.")
                return
            }
            do { try begin(meeting: meeting, auto: auto) } catch { state = .failed("Couldn't start recording: \(error.localizedDescription)"); teardown() }
        }
    }

    private func begin(meeting: MeetingDetector.Detected?, auto: Bool) throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let started = Date()
        var rec = Recording(title: "Recording \(started.formatted(date: .abbreviated, time: .shortened))")
        rec.startedAt = started
        rec.device = RecorderLink.deviceName
        // Record from the microphone the call uses (e.g. AirPods), not just the Mac's default input.
        if let device = meeting?.inputDevice, let unit = engine.inputNode.audioUnit {
            var dev = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                       AVEncoderBitRateKey: 32000]
        file = try AVAudioFile(forWriting: Self.audioURL(rec.id), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try installMicTap()
        engine.prepare()
        try engine.start()
        // AirPods connecting or switching to call mode reconfigures the engine (and stops it): pick up the new input format
        // and carry on writing to the same file.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            Task { @MainActor in
                let r = CallRecorder.shared
                guard r.isRecording else { return }
                do { try r.installMicTap(); r.engine.prepare(); try r.engine.start() }
                catch { NSLog("Jinnie Recorder: microphone lost after a device change: %@", error.localizedDescription) }
            }
        }
        if let meeting {
            rec.app = meeting.appName
            rec.autoStarted = auto ? true : nil
            if let item = meeting.calendarItem { rec.meetingItemID = item.id; rec.title = item.title }
            if !meeting.participants.isEmpty {
                rec.participantIDs = meeting.participants.map(\.id)
                rec.title = "\(meeting.appName) call with \(meeting.participants.map(\.name).joined(separator: ", "))"
            } else if let label = meeting.callerLabel { rec.title = "\(meeting.appName) call with \(label)" }
            // The other participants: the meeting app's own audio. If system audio recording isn't allowed, the microphone
            // recording still goes on.
            let tap = SystemAudioTap()
            do { try tap.start(processes: meeting.processIDs, writingTo: Self.systemURL(rec.id)); systemTap = tap }
            catch { NSLog("Jinnie Recorder: meeting audio not recorded: %@", error.localizedDescription) }
        }
        rec = store.save(rec)
        JinnieConfig.postExternalChange()
        current = rec
        title = rec.title
        state = .recording(started)
    }

    /// Converts whatever the input delivers (48 kHz built-in mic, 16/24 kHz AirPods in call mode) to 16 kHz mono.
    private func installMicTap() throws {
        guard let out = file else { return }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: mono) else { throw RecorderError.format }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / inFormat.sampleRate + 32)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: cap) else { return }
            var fed = false
            converter.convert(to: pcm, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            try? out.write(from: pcm)
        }
    }

    /// Stops and hands the recording to Jinnie (status `.processing`).
    func stop() {
        guard case .recording(let started) = state, var rec = current else { return }
        teardown()
        rec = store.get(Recording.self, rec.id) ?? rec  // edits made in Jinnie meanwhile (title, meeting)
        rec.duration = Date().timeIntervalSince(started)
        rec.status = .processing
        store.save(rec)
        current = nil
        title = nil
        state = .idle
        JinnieConfig.postExternalChange()
        RecorderLink.postFinished()
    }

    private func teardown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver); self.configObserver = nil }
        systemTap?.stop()
        systemTap = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        file = nil  // closes the file
    }

    /// Recordings this Mac's recorder left at `.recording` (it crashed or the Mac restarted): what was saved goes to Jinnie.
    func finishOrphans() {
        var any = false
        for var r in store.all(Recording.self) where r.status == .recording && r.device == RecorderLink.deviceName {
            if let f = try? AVAudioFile(forReading: Self.audioURL(r.id)) { r.duration = Double(f.length) / f.fileFormat.sampleRate }
            r.status = .processing
            store.save(r)
            any = true
        }
        if any { JinnieConfig.postExternalChange(); RecorderLink.postFinished() }
    }

    enum RecorderError: LocalizedError {
        case format
        var errorDescription: String? { "The microphone's audio format isn't supported" }
    }
}
