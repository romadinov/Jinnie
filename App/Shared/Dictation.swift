import AVFoundation
import Foundation
import Observation
import Speech
#if os(macOS)
import Carbon
#endif

/// Voice notes (from Uberdoer's Dictation): Whisper on device by default, Apple's recogniser while the model downloads.
/// Listening stops by itself after a pause (notes are longer than task titles, so the pause is longer), or on `stop()`.
@MainActor @Observable
final class Dictation {
    enum State: Equatable { case idle, starting, listening, transcribing, denied(String), failed(String) }
    enum Engine: String { case whisper, apple }

    private(set) var state: State = .idle
    /// What has been recognised so far in this session.
    private(set) var transcript = ""
    var isListening: Bool { state == .listening || state == .starting }
    var isBusy: Bool { isListening || state == .transcribing }

    /// Whisper (on-device, detects Russian/English by itself) unless the user picked Apple's recogniser.
    var engine: Engine {
        get { Engine(rawValue: UserDefaults.standard.string(forKey: "speech.engine") ?? "") ?? .whisper }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "speech.engine") }
    }
    /// The engine actually used for the current session (Apple while the Whisper model downloads).
    private(set) var activeEngine: Engine = .apple

    /// Languages offered in the menu (those the recogniser supports), Russian and English first.
    static var languages: [Locale] {
        let supported = SFSpeechRecognizer.supportedLocales()
        let preferred = ["ru-RU", "en-US", "en-GB"].map(Locale.init(identifier:)).filter { supported.contains($0) }
        let rest = Locale.preferredLanguages.map(Locale.init(identifier:))
            .compactMap { l in supported.first { $0.language.languageCode == l.language.languageCode } }
        var out: [Locale] = []
        for l in preferred + rest where !out.contains(l) { out.append(l) }
        return out
    }

    /// The language to listen in: the one picked in the menu, else (Mac) the current keyboard layout's
    /// language, else the system language.
    var locale: Locale {
        get {
            if let id = UserDefaults.standard.string(forKey: "speech.locale") { return Locale(identifier: id) }
            return Self.defaultLocale
        }
        set { UserDefaults.standard.set(newValue.identifier, forKey: "speech.locale") }
    }
    var followsKeyboard: Bool { UserDefaults.standard.string(forKey: "speech.locale") == nil }
    func followKeyboard() { UserDefaults.standard.removeObject(forKey: "speech.locale") }

    static var defaultLocale: Locale {
        let supported = SFSpeechRecognizer.supportedLocales()
        func match(_ code: String) -> Locale? {
            let lang = Locale(identifier: code).language.languageCode
            return supported.first { $0.identifier == code } ?? supported.first { $0.language.languageCode == lang && $0.region == Locale.current.region }
                ?? supported.first { $0.language.languageCode == lang }
        }
        #if os(macOS)
        if let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages),
           let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String],
           let first = langs.first, let l = match(first) { return l }
        #endif
        for code in Locale.preferredLanguages { if let l = match(code) { return l } }
        return Locale(identifier: "en-US")
    }

    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var onFinish: ((String) -> Void)?

    /// Starts listening. `onFinish` gets the final text once listening ends (pause, `stop()`, or error).
    func start(onFinish: @escaping (String) -> Void) {
        guard !isBusy else { return }
        self.onFinish = onFinish
        transcript = ""
        state = .starting
        let whisper = WhisperModel.shared
        activeEngine = engine == .whisper && whisper.isDownloaded ? .whisper : .apple
        // First use: fetch the model in the background; this session uses Apple's recogniser.
        if engine == .whisper && !whisper.isDownloaded { Task { await whisper.prepare() } }
        if activeEngine == .whisper {
            Task { @MainActor in
                guard await Self.microphoneAllowed() else {
                    self.state = .denied("Microphone access is off for Jinnie. Allow it in System Settings → Privacy & Security → Microphone.")
                    return
                }
                Task { await whisper.prepare() } // loads the model while you speak
                self.beginWhisper()
            }
            return
        }
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.state = .denied("Speech recognition is off for Jinnie. Allow it in System Settings → Privacy & Security → Speech Recognition.")
                    return
                }
                guard await Self.microphoneAllowed() else {
                    self.state = .denied("Microphone access is off for Jinnie. Allow it in System Settings → Privacy & Security → Microphone.")
                    return
                }
                self.begin()
            }
        }
    }

    static func microphoneAllowed() async -> Bool {
        #if os(iOS)
        await AVAudioApplication.requestRecordPermission()
        #else
        await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    // MARK: Whisper

    private var samples: [Float] = []
    private var heardSpeech = false
    private var startedAt = Date()
    private var lastSpeechAt = Date()
    private var noiseFloor: Float = 0
    private var partialTimer: Timer?
    private var partialBusy = false

    /// Whisper language: the one picked in the menu; "Automatic" = detect (Russian/English expected).
    private var whisperLanguage: String? { followsKeyboard ? nil : locale.language.languageCode?.identifier }
    private var keyboardLanguage: String { Self.defaultLocale.language.languageCode?.identifier ?? "en" }

    private func beginWhisper() {
        samples = []; heardSpeech = false; startedAt = Date(); lastSpeechAt = Date(); noiseFloor = 0
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let input = audio.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                state = .failed("Couldn't set up the microphone format."); return
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
                let cap = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / inFormat.sampleRate + 32)
                guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
                var fed = false
                converter.convert(to: out, error: nil) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true; status.pointee = .haveData; return buffer
                }
                guard let ch = out.floatChannelData?[0] else { return }
                let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
                Task { @MainActor in self?.appendWhisper(chunk) }
            }
            audio.prepare()
            try audio.start()
            state = .listening
            partialTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.partialWhisper() }
            }
        } catch {
            state = .failed("Couldn't start the microphone: \(error.localizedDescription)")
            teardown()
        }
    }

    /// Simple voice-activity check: louder than the room by a margin = speech.
    private func appendWhisper(_ chunk: [Float]) {
        guard state == .listening, !chunk.isEmpty else { return }
        samples += chunk
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed < 0.4 { noiseFloor = max(noiseFloor, rms); return }
        if rms > max(0.012, noiseFloor * 2.5) { heardSpeech = true; lastSpeechAt = Date() }
        if heardSpeech && Date().timeIntervalSince(lastSpeechAt) > Self.pause { stop() }
        else if !heardSpeech && elapsed > 10 { stop() }
        else if elapsed > 300 { stop() }  // a voice note, not a meeting: use Record for those
    }

    /// While speaking: re-transcribe what's been said so far, so the title fills in live.
    private func partialWhisper() {
        guard state == .listening, heardSpeech, !partialBusy, samples.count > 8000, WhisperModel.shared.status == .ready else { return }
        partialBusy = true
        let audio = samples
        Task { @MainActor in
            let text = await WhisperModel.shared.transcribe(audio, language: whisperLanguage, expected: ["ru", "en"], fallback: keyboardLanguage)
            if state == .listening && !text.isEmpty { transcript = text }
            partialBusy = false
        }
    }

    private func finishWhisper() {
        let audio = samples
        let spoke = heardSpeech
        teardown()
        state = .transcribing
        Task { @MainActor in
            let text = spoke ? await WhisperModel.shared.transcribe(audio, language: whisperLanguage, expected: ["ru", "en"], fallback: keyboardLanguage) : ""
            transcript = text
            state = .idle
            let done = onFinish
            onFinish = nil
            done?(text)
        }
    }

    // MARK: Apple

    private func begin() {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            state = .failed("Speech recognition for \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier) isn't available right now.")
            return
        }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = audio.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            audio.prepare()
            try audio.start()
            state = .listening
            armSilenceTimer(initial: true)

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        self.armSilenceTimer(initial: false)
                        if result.isFinal { self.finish() }
                    } else if error != nil, self.isListening {
                        self.finish()
                    }
                }
            }
        } catch {
            state = .failed("Couldn't start the microphone: \(error.localizedDescription)")
            teardown()
        }
    }

    /// Seconds of silence that end a voice note.
    static let pause: TimeInterval = 3

    /// Stops after a pause without new words (10 s grace before the first word).
    private func armSilenceTimer(initial: Bool) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: initial ? 10 : Self.pause, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    func stop() {
        guard isListening else { return }
        if activeEngine == .whisper { finishWhisper(); return }
        request?.endAudio()
        // Give the recogniser a moment to deliver the final result.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.finish() }
    }

    func cancel() {
        onFinish = nil
        teardown()
        state = .idle
    }

    private func finish() {
        guard isListening else { return }
        teardown()
        state = .idle
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let done = onFinish
        onFinish = nil
        done?(text)
    }

    private func teardown() {
        silenceTimer?.invalidate(); silenceTimer = nil
        partialTimer?.invalidate(); partialTimer = nil
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
