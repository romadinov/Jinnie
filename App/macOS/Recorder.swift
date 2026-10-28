import AudioToolbox
import AVFoundation
import Foundation
import JinnieAgent
import JinnieCore
import Observation
import SpeakerKit
import SwiftUI
import WhisperKit

/// Records a meeting from the microphone, then on this Mac: Whisper transcribes it (word timings), SpeakerKit separates
/// the speakers and fingerprints each voice, and known voices are named. The agent then reads the transcript.
/// Audio is kept in Application Support/Jinnie/recordings (16 kHz AAC, ~15 MB/hour) so a crash or quit loses nothing.
@MainActor @Observable
final class MeetingRecorder {
    static let shared = MeetingRecorder()

    enum State: Equatable { case idle, recording(Date), processing(String, Double), failed(String) }
    private(set) var state: State = .idle
    var isRecording: Bool { if case .recording = state { return true }; return false }
    var isBusy: Bool { state != .idle && !(state.isFailure) }

    fileprivate let engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var file: AVAudioFile?
    private var systemTap: SystemAudioTap?
    private var current: Recording?
    private var speakerKit: SpeakerKit?

    static var folder: URL { JinnieConfig.supportDirectory().appendingPathComponent("recordings", isDirectory: true) }
    static func audioURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).m4a") }
    /// The meeting app's audio (the other participants), recorded alongside the microphone.
    static func systemURL(_ id: String) -> URL { folder.appendingPathComponent("\(id)-meeting.m4a") }

    // MARK: Recording

    func toggle() { isRecording ? stop() : start(meeting: MeetingDetector.shared.activeMeeting()) }

    /// Starts recording the microphone, plus the audio of `meeting`'s app (the other participants) when there is one.
    func start(meeting: MeetingDetector.Detected? = nil, auto: Bool = false) {
        guard state == .idle || state.isFailure else { return }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                state = .failed("Microphone access is off for Jinnie. Allow it in System Settings → Privacy & Security → Microphone.")
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
        rec.device = AppModel.shared.deviceName
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
            MainActor.assumeIsolated {
                let r = MeetingRecorder.shared
                guard r.isRecording else { return }
                do { try r.installMicTap(); r.engine.prepare(); try r.engine.start() }
                catch { NSLog("Jinnie: microphone lost after a device change: %@", error.localizedDescription) }
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
            // The other participants: the meeting app's own audio. If the user hasn't allowed system audio recording,
            // the microphone recording still goes on.
            let tap = SystemAudioTap()
            do { try tap.start(processes: meeting.processIDs, writingTo: Self.systemURL(rec.id)); systemTap = tap }
            catch { NSLog("Jinnie: meeting audio not recorded: %@", error.localizedDescription) }
        }
        rec = AppModel.shared.store.save(rec)
        current = rec
        state = .recording(started)
    }

    /// Converts whatever the input delivers (48 kHz built-in mic, 16/24 kHz AirPods in call mode) to 16 kHz mono.
    fileprivate func installMicTap() throws {
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

    func stop() {
        guard case .recording(let started) = state, var rec = current else { return }
        teardown()
        rec.duration = Date().timeIntervalSince(started)
        rec.status = .processing
        rec = AppModel.shared.store.save(rec)
        current = nil
        Task { await process(rec) }
    }

    private func teardown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver); self.configObserver = nil }
        systemTap?.stop()
        systemTap = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        file = nil  // closes the file
    }

    /// Recordings left unfinished by a quit or crash: process what was saved.
    func resumeInterrupted() {
        let store = AppModel.shared.store
        for var r in store.all(Recording.self) where (r.status == .recording || r.status == .processing) && r.id != current?.id {
            guard FileManager.default.fileExists(atPath: Self.audioURL(r.id).path), r.device == AppModel.shared.deviceName else { continue }
            if let f = try? AVAudioFile(forReading: Self.audioURL(r.id)) { r.duration = Double(f.length) / f.fileFormat.sampleRate }
            r.status = .processing
            r = store.save(r)
            let rec = r
            Task { await process(rec) }
        }
    }

    /// An audio file recorded elsewhere (Zoom, Teams, Voice Memos…): converted to Jinnie's format, then processed like a
    /// recording. The title is the file name; the date is the file's creation date.
    func importAudio(_ url: URL) {
        Task {
            state = .processing("Importing", 0)
            do {
                try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                let samples = try await Task.detached { try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path) }.value
                guard samples.count > 16000 else { throw RecorderError.empty }
                var rec = Recording(title: url.deletingPathExtension().lastPathComponent)
                rec.startedAt = ((try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate) ?? Date()
                rec.device = AppModel.shared.deviceName
                rec.duration = Double(samples.count) / 16000
                rec.status = .processing
                let dest = Self.audioURL(rec.id)
                try await Task.detached { try Self.write(samples, to: dest) }.value
                rec = AppModel.shared.store.save(rec)
                await process(rec)
            } catch {
                state = .failed("Couldn't import \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    nonisolated static func write(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else { throw RecorderError.format }
        var offset = 0
        while offset < samples.count {
            let n = min(16000 * 60, samples.count - offset)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { throw RecorderError.format }
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress! + offset, count: n) }
            try file.write(from: buf)
            offset += n
        }
    }

    /// Re-runs transcription and speaker separation (e.g. after an error).
    func reprocess(_ rec: Recording) { Task { await process(rec) } }

    // MARK: Processing

    func process(_ input: Recording) async {
        let store = AppModel.shared.store
        var rec = input
        do {
            state = .processing("Loading audio", 0)
            let path = Self.audioURL(rec.id).path
            let sysPath = Self.systemURL(rec.id).path
            let mic = try await Task.detached { try AudioProcessor.loadAudioAsFloatArray(fromPath: path) }.value
            // A call file that exists but can't be read is an error, never "no call audio": treating it as silence once
            // discarded two meetings, and later transcribed calls from the microphone alone.
            let system: [Float] = FileManager.default.fileExists(atPath: sysPath)
                ? try await Task.detached { try AudioProcessor.loadAudioAsFloatArray(fromPath: sysPath) }.value : []
            // A call where nobody else spoke (you waited alone, or it was a false start): not worth transcribing.
            // Only for call recordings with the meeting app's audio; recordings you start by hand are always kept.
            // Only when the call audio was actually read and covers the call: a file that failed to load is not silence
            // (that mistake once deleted two meetings).
            if rec.app != nil, !rec.isExternal, rec.processedAt == nil, rec.segments.isEmpty,
               !system.isEmpty, Double(system.count) >= 0.8 * Double(mic.count), Recording.speechSeconds(system[...]) < 5 {
                discard(rec, why: "nobody else spoke")
                return
            }
            // A call: each side is transcribed on its own. Mixing them first let the microphone drown the call side
            // (phone-quality audio): a 27-min call lost most of what the others said. Your lines come from the
            // microphone; everyone else's from the call audio, separated into speakers on that track alone.
            let isCall = !system.isEmpty && Double(system.count) >= 0.8 * Double(mic.count) && Recording.speechSeconds(system[...]) >= 5
            let samples = isCall ? system : Self.mix(mic, system)
            guard samples.count > 16000 || mic.count > 16000 else { throw RecorderError.empty }
            rec.duration = Double(max(mic.count, system.count)) / 16000

            state = .processing(isCall ? "Transcribing the call" : "Transcribing", 0)
            let transcription = try await WhisperModel.shared.transcribeLong(samples) { p in
                Task { @MainActor in MeetingRecorder.shared.state = .processing(isCall ? "Transcribing the call" : "Transcribing", p * (isCall ? 0.5 : 1)) }
            }
            let micTranscription = isCall ? try await WhisperModel.shared.transcribeLong(mic) { p in
                Task { @MainActor in MeetingRecorder.shared.state = .processing("Transcribing you", 0.5 + p * 0.5) }
            } : []

            state = .processing("Separating speakers", 0)
            let kit = try await speakers()
            let options = PyannoteDiarizationOptions(centroidSource: .finalAssignment)
            let diarization = try await kit.diarize(audioArray: samples, options: options)
            rec.segments = Self.merge(transcription, diarization)
            var callOwner: Int?
            if isCall {
                // You get a label of your own; lines your microphone caught from the speakers (no headphones) repeat
                // the call side and are dropped.
                let owner = (rec.segments.compactMap(\.speaker).max() ?? -1) + 1
                callOwner = owner
                let others = rec.segments
                for seg in micTranscription.flatMap(\.segments) {
                    let text = WhisperModel.clean(seg.text)
                    let a = Double(seg.start)
                    let b = max(Double(seg.end), a + 0.5)
                    guard !text.isEmpty, !Recording.repeats(text, at: a, in: others),
                          !Self.isEcho(a, b, mic: mic, system: system) else { continue }
                    rec.segments.append(RecordedSegment(speaker: owner, start: a, end: b, text: text))
                }
                rec.segments.sort { $0.start < $1.start }
            }
            // Russian read again with GigaAM (Settings → Transcription model), each speaker from their own track on a call.
            if WhisperModel.choice == .gigaam {
                state = .processing("Reading Russian with GigaAM", 0)
                do {
                    let giga = try await GigaAM.shared.prepare()
                    let owner = callOwner, micTrack = mic, callTrack = system, mixed = samples, segs = rec.segments
                    rec.segments = await Task.detached {
                        GigaAM.refine(segs, with: giga) { s in isCall ? (s.speaker == owner ? micTrack : callTrack) : mixed }
                    }.value
                } catch {
                    NSLog("Jinnie: GigaAM unavailable, keeping Whisper's text: %@", error.localizedDescription)
                }
            }
            if rec.segments.isEmpty {  // no speech found by separation: keep the plain transcript
                rec.segments = transcription.flatMap(\.segments).map {
                    RecordedSegment(speaker: nil, start: Double($0.start), end: Double($0.end), text: WhisperModel.clean($0.text))
                }.filter { !$0.text.isEmpty }
            }
            let languages = OwnerProfile.current.languages
            rec.segments.removeAll { Recording.foreignScript($0.text, languages: languages) }
            for c in AppModel.shared.rememberedCorrections { rec.replace(c.from, with: c.to) }
            rec.speakers = Self.speakers(from: rec.segments, diarization: diarization, keeping: rec.speakers)
            if let callOwner, let me = store.all(Person.self).first(where: \.isMe),
               let i = rec.speakers.firstIndex(where: { $0.label == callOwner }) {
                rec.speakers[i].personID = me.id
                rec.speakers[i].namedBy = .voice
                rec.speakers[i].match = 1
            }
            rec.absorbMinorSpeakers()

            // Name voices Jinnie knows; meeting attendees are the likely ones.
            let items = store.all(Item.self)
            let meeting = rec.noMeeting == true ? nil : (rec.meetingItemID.flatMap { id in items.first { $0.id == id } }
                ?? Agent.meeting(for: rec.startedAt, duration: rec.duration, items: items))
            rec.meetingItemID = meeting?.id
            if let m = meeting, rec.title.hasPrefix("Recording") { rec.title = m.title }
            let me = store.all(Person.self).first(where: \.isMe)
            // An online call: whoever is loud on the microphone but not in the app's audio is you. Learn your voice from it.
            if let me, let label = Voice.ownerLabel(segments: rec.segments, mic: mic, system: system),
               let i = rec.speakers.firstIndex(where: { $0.label == label }), rec.speakers[i].personID == nil {
                rec.speakers[i].personID = me.id
                rec.speakers[i].namedBy = .voice
                if let e = rec.speakers[i].embedding, var p = store.get(Person.self, me.id) {
                    Voice.learn(e, into: &p, recordingID: rec.id, label: label)
                    store.save(p)
                }
            }
            // Expected voices: the meeting's attendees and project people, known participants, and you.
            let projectPeople = store.all(Person.self).filter { p in !Set(p.projectIDs).isDisjoint(with: meeting?.projectIDs ?? []) }.map(\.id)
            Voice.identify(&rec.speakers, people: store.all(Person.self),
                           candidates: Set((meeting?.personIDs ?? []) + projectPeople + (rec.participantIDs ?? []) + [me?.id].compactMap { $0 }))
            // A one-to-one messenger call: once you are identified, the other voice is the caller. Learn it.
            if let ids = rec.participantIDs, ids.count == 1, rec.speakers.contains(where: { $0.personID == me?.id }), !rec.speakers.contains(where: { $0.personID == ids[0] }) {
                let others = rec.speakers.indices.filter { rec.speakers[$0].personID == nil && rec.speakers[$0].talkSeconds >= 3 }
                if others.count == 1 {
                    let i = others[0]
                    rec.speakers[i].personID = ids[0]
                    rec.speakers[i].namedBy = .voice
                    if let e = rec.speakers[i].embedding, var p = store.get(Person.self, ids[0]) {
                        Voice.learn(e, into: &p, recordingID: rec.id, label: rec.speakers[i].label)
                        store.save(p)
                    }
                }
            }

            rec.status = .ready
            rec.error = nil
            rec.processedAt = nil
            store.save(rec)
            state = .idle
            AgentHooks.shared?.runNow()
        } catch {
            rec.status = .failed
            rec.error = error.localizedDescription
            store.save(rec)
            state = .failed(error.localizedDescription)
        }
    }

    /// A microphone line that is really the call coming out of the speakers: quieter on the microphone than the call
    /// audio is at that moment (your own voice is the loudest thing on your microphone).
    nonisolated static func isEcho(_ a: Double, _ b: Double, mic: [Float], system: [Float]) -> Bool {
        let lo = max(0, Int(a * 16000)), hi = min(mic.count, system.count, Int(b * 16000))
        guard hi - lo > 1600 else { return false }
        var m = 0.0, c = 0.0
        for i in stride(from: lo, to: hi, by: 2) { m += Double(mic[i] * mic[i]); c += Double(system[i] * system[i]) }
        return m < c * 0.5
    }

    /// Whisper's lines with SpeakerKit's speakers; lines SpeakerKit skipped (no word timings) are put back with the
    /// speaker talking nearest to them.
    static func merge(_ transcription: [TranscriptionResult], _ diarization: DiarizationResult) -> [RecordedSegment] {
        var out: [RecordedSegment] = diarization.addSpeakerInfo(to: transcription).flatMap { $0 }.compactMap { seg in
            let text = WhisperModel.clean(seg.text)
            guard !text.isEmpty else { return nil }
            return RecordedSegment(speaker: seg.speaker.speakerId, start: Double(seg.startTime), end: Double(seg.endTime), text: text)
        }
        let merged0 = out
        for seg in transcription.flatMap(\.segments) {
            let text = WhisperModel.clean(seg.text)
            guard !text.isEmpty else { continue }
            let a = Double(seg.start), b = Double(seg.end)
            let overlap = merged0.reduce(0.0) { $0 + max(0, min($1.end, b) - max($1.start, a)) }
            guard overlap <= 0.5 * max(b - a, 0.1), !Recording.repeats(text, at: a, in: out) else { continue }
            out.append(RecordedSegment(speaker: merged0.min { abs($0.start - a) < abs($1.start - a) }?.speaker, start: a, end: b, text: text))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// The speaker (with at least a minute of talk) whose lines are loudest on the microphone relative to the call audio.
    nonisolated static func micHeaviest(_ segments: [RecordedSegment], mic: [Float], system: [Float]) -> Int? {
        var micE: [Int: Double] = [:], sysE: [Int: Double] = [:], talk: [Int: Double] = [:]
        for s in segments {
            guard let l = s.speaker else { continue }
            let a = max(0, Int(s.start * 16000)), b = Int(s.end * 16000)
            for i in stride(from: a, to: b, by: 4) {
                if i < mic.count { micE[l, default: 0] += Double(mic[i] * mic[i]) }
                if i < system.count { sysE[l, default: 0] += Double(system[i] * system[i]) }
            }
            talk[l, default: 0] += s.end - s.start
        }
        return talk.filter { $0.value >= 60 }.keys.max { (micE[$0] ?? 0) / max(sysE[$0] ?? 0, 1e-9) < (micE[$1] ?? 0) / max(sysE[$1] ?? 0, 1e-9) }
    }

    /// Puts a recording's audio aside (recordings/discarded, kept, never deleted here) and removes it from the list
    /// without transcribing it; notes why in Activity.
    private func discard(_ rec: Recording, why: String) {
        let store = AppModel.shared.store
        let aside = Self.folder.appendingPathComponent("discarded", isDirectory: true)
        try? FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        for url in [Self.audioURL(rec.id), Self.systemURL(rec.id)] where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.moveItem(at: url, to: aside.appendingPathComponent(url.lastPathComponent))
        }
        store.delete(rec)
        var run = RunLog(kind: "recording")
        run.message = "\(rec.title): not transcribed, \(why) (\(Recording.clock(rec.duration))); deleted"
        run.finishedAt = Date()
        store.save(run)
        state = .idle
    }

    /// Microphone and meeting audio summed into one track for transcription and speaker separation.
    nonisolated static func mix(_ mic: [Float], _ system: [Float]) -> [Float] {
        guard !system.isEmpty else { return mic }
        var out = [Float](repeating: 0, count: max(mic.count, system.count))
        for i in out.indices {
            let v = (i < mic.count ? mic[i] * 0.8 : 0) + (i < system.count ? system[i] : 0)
            out[i] = max(-1, min(1, v))
        }
        return out
    }

    private func speakers() async throws -> SpeakerKit {
        if let speakerKit { return speakerKit }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jinnie/SpeakerKit")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let kit = try await SpeakerKit(PyannoteConfig(downloadBase: base.path, download: true, load: true, verbose: false, logLevel: .error))
        speakerKit = kit
        return kit
    }

    /// One entry per speaker: their voice (centroid), how long they talked, and something they said.
    static func speakers(from segments: [RecordedSegment], diarization: DiarizationResult, keeping old: [RecordedSpeaker]) -> [RecordedSpeaker] {
        var talk: [Int: Double] = [:]
        var sample: [Int: RecordedSegment] = [:]
        for s in segments {
            guard let l = s.speaker else { continue }
            talk[l, default: 0] += s.end - s.start
            if s.text.count > (sample[l]?.text.count ?? 0), s.text.count < 240 { sample[l] = s }
        }
        // Transcribing again numbers the voices afresh: carry names over by how alike the voices sound, not by number.
        var unused = old
        return talk.keys.sorted().map { l in
            let e = diarization.speakerCentroidEmbeddings[l]
            var sp = RecordedSpeaker(label: l)
            if let e, let best = unused.indices.compactMap({ i -> (Int, Float)? in
                guard let oe = unused[i].embedding, oe.count == e.count else { return nil }
                return (i, Voice.similarity(e, oe))
            }).max(by: { $0.1 < $1.1 }), best.1 > 0.75 {
                let o = unused.remove(at: best.0)
                // Keep names you gave; a voice match is decided again (it may have been wrong).
                if o.namedBy == .owner { sp.personID = o.personID; sp.namedBy = o.namedBy }
                sp.suggestedPersonID = o.suggestedPersonID; sp.suggestionWhy = o.suggestionWhy; sp.name = o.name
            }
            sp.embedding = e
            sp.talkSeconds = talk[l] ?? 0
            sp.sample = sample[l]?.text
            sp.sampleAt = sample[l]?.start
            return sp
        }
    }

    enum RecorderError: LocalizedError {
        case format, empty
        var errorDescription: String? {
            switch self {
            case .format: "Couldn't set up the microphone format."
            case .empty: "The recording is empty."
            }
        }
    }
}

extension MeetingRecorder.State {
    var isFailure: Bool { if case .failed = self { return true }; return false }
}

/// Plays a few seconds of a recording (to recognise a speaker).
@MainActor
final class SnippetPlayer {
    static let shared = SnippetPlayer()
    private var stopTimer: Timer?

    private var players: [AVAudioPlayer] = []

    func canPlay(_ rec: Recording) -> Bool { FileManager.default.fileExists(atPath: MeetingRecorder.audioURL(rec.id).path) }

    /// The microphone and the meeting audio (the other people in an online call) together, from the same moment.
    func play(_ rec: Recording, at: Double, seconds: Double = 8) {
        stopTimer?.invalidate()
        players.forEach { $0.stop() }
        players = [MeetingRecorder.audioURL(rec.id), MeetingRecorder.systemURL(rec.id)]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .compactMap { try? AVAudioPlayer(contentsOf: $0) }
        guard !players.isEmpty else { return }
        let start = players[0].deviceCurrentTime + 0.05
        for p in players {
            p.currentTime = max(0, at - 0.3)
            p.prepareToPlay()
            p.play(atTime: start)
        }
        stopTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            Task { @MainActor in SnippetPlayer.shared.players.forEach { $0.stop() } }
        }
    }
}

/// Record / Stop with elapsed time and processing progress (Recordings view, toolbar).
struct RecordControl: View {
    var recorder = MeetingRecorder.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 10) {
                switch recorder.state {
                case .recording(let started):
                    Button { recorder.stop() } label: { Label("Stop", systemImage: "stop.circle.fill") }
                        .buttonStyle(.borderedProminent).tint(.red)
                    Text("Recording · \(Recording.clock(ctx.date.timeIntervalSince(started)))").monospacedDigit()
                case .processing(let step, let p):
                    ProgressView(value: p).frame(width: 120)
                    Text("\(step)…").foregroundStyle(.secondary)
                case .failed(let m):
                    Button { recorder.start() } label: { Label("Record", systemImage: "record.circle") }
                    Text(m).foregroundStyle(.orange).lineLimit(2)
                case .idle:
                    Button { recorder.start() } label: { Label("Record a meeting", systemImage: "record.circle") }
                        .buttonStyle(.borderedProminent)
                    Text("⌃⌥R · transcribed and separated by speaker on this Mac").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
