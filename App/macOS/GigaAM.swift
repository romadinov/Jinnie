import Foundation
import JinnieCore
import Observation

/// GigaAM v3 (Sber, MIT licence): Russian speech recognition, run on this Mac through sherpa-onnx. Much better than Whisper
/// on Russian conversation (tested on the owner's meetings), weaker on English words, so Whisper transcribes first and the
/// Russian stretches are read again with GigaAM. The model (about 225 MB) downloads the first time it's chosen.
@MainActor @Observable
final class GigaAM {
    static let shared = GigaAM()

    enum Status: Equatable { case notDownloaded, downloading, ready, failed(String) }
    private(set) var status: Status

    static let modelName = "sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16"
    static let modelURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(modelName).tar.bz2")!
    static let modelSHA256 = "f9620a0099019c6afcee26525ef9ed3297fa50dd5691c1902af0c948fc1a470b"
    nonisolated static var folder: URL { JinnieConfig.supportDirectory().appendingPathComponent("GigaAM", isDirectory: true) }
    nonisolated static var modelDirectory: URL { folder.appendingPathComponent(modelName, isDirectory: true) }
    nonisolated static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("encoder.int8.onnx").path)
    }

    private var recognizer: Recognizer?
    private var preparing: Task<Recognizer, Error>?

    init() { status = Self.isDownloaded ? .ready : .notDownloaded }

    /// Downloads (once) and loads the model.
    func prepare() async throws -> Recognizer {
        if let recognizer { return recognizer }
        if let preparing { return try await preparing.value }
        let t = Task<Recognizer, Error> { @MainActor in
            do {
                if !Self.isDownloaded {
                    status = .downloading
                    try await Task.detached { try await Self.download() }.value
                }
                let r = try await Task.detached { try Recognizer(directory: Self.modelDirectory) }.value
                recognizer = r
                status = .ready
                return r
            } catch {
                status = .failed(error.localizedDescription)
                throw error
            }
        }
        preparing = t
        defer { preparing = nil }
        return try await t.value
    }

    nonisolated private static func download() async throws {
        let (tmp, response) = try await URLSession.shared.download(from: modelURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("Couldn't download the GigaAM model") }
        let hash = Process()
        hash.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        hash.arguments = ["-a", "256", tmp.path]
        let out = Pipe()
        hash.standardOutput = out
        try hash.run(); hash.waitUntilExit()
        let sum = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ").first.map(String.init)
        guard sum == modelSHA256 else { throw Failure("The GigaAM model download didn't match its checksum") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xjf", tmp.path, "-C", folder.path]
        try tar.run(); tar.waitUntilExit()
        try? FileManager.default.removeItem(at: tmp)
        guard tar.terminationStatus == 0, isDownloaded else { throw Failure("Couldn't unpack the GigaAM model") }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// One loaded model. Decoding is serialised (sherpa-onnx recognizers aren't shared across threads here).
    final class Recognizer: @unchecked Sendable {
        private let handle: OpaquePointer
        private let lock = NSLock()
        private let strings: [UnsafeMutablePointer<CChar>]

        init(directory: URL) throws {
            var owned: [UnsafeMutablePointer<CChar>] = []
            func c(_ s: String) -> UnsafePointer<CChar> {
                let p = strdup(s)!
                owned.append(p)
                return UnsafePointer(p)
            }
            var config = SherpaOnnxOfflineRecognizerConfig()
            config.feat_config.sample_rate = 16000
            config.feat_config.feature_dim = 64
            config.model_config.transducer.encoder = c(directory.appendingPathComponent("encoder.int8.onnx").path)
            config.model_config.transducer.decoder = c(directory.appendingPathComponent("decoder.onnx").path)
            config.model_config.transducer.joiner = c(directory.appendingPathComponent("joiner.onnx").path)
            config.model_config.tokens = c(directory.appendingPathComponent("tokens.txt").path)
            config.model_config.num_threads = 4
            config.model_config.provider = c("cpu")
            config.model_config.model_type = c("nemo_transducer")
            config.decoding_method = c("greedy_search")
            guard let h = SherpaOnnxCreateOfflineRecognizer(&config) else {
                owned.forEach { free($0) }
                throw Failure("Couldn't load the GigaAM model")
            }
            handle = h
            strings = owned
        }

        deinit {
            SherpaOnnxDestroyOfflineRecognizer(handle)
            strings.forEach { free($0) }
        }

        /// Text for 16 kHz mono audio (up to about 25 s at a time).
        func transcribe(_ samples: ArraySlice<Float>) -> String {
            lock.lock(); defer { lock.unlock() }
            let rec = handle
            guard let stream = SherpaOnnxCreateOfflineStream(rec) else { return "" }
            defer { SherpaOnnxDestroyOfflineStream(stream) }
            samples.withUnsafeBufferPointer { buf in
                SherpaOnnxAcceptWaveformOffline(stream, 16000, buf.baseAddress, Int32(buf.count))
            }
            SherpaOnnxDecodeOfflineStream(rec, stream)
            guard let r = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
            defer { SherpaOnnxDestroyOfflineRecognizerResult(r) }
            return r.pointee.text.map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    /// Reads the Russian stretches again with GigaAM: consecutive lines of one speaker, mostly Cyrillic, close together,
    /// up to 20 s, become one line with GigaAM's text (from that speaker's own track on a call). English lines keep
    /// Whisper's text, which handles English words better.
    nonisolated static func refine(_ segments: [RecordedSegment], with recognizer: Recognizer,
                                   track: (RecordedSegment) -> [Float]) -> [RecordedSegment] {
        func russian(_ s: String) -> Bool {
            let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard letters.count >= 2 else { return false }
            return Double(letters.filter { (0x400...0x4FF).contains($0.value) }.count) / Double(letters.count) >= 0.5
        }
        let sorted = segments.sorted { $0.start < $1.start }
        var out: [RecordedSegment] = []
        var group: [RecordedSegment] = []
        func flush() {
            defer { group = [] }
            guard let first = group.first, let last = group.last else { return }
            let audio = track(first)
            let lo = max(0, Int((first.start - 0.2) * 16000)), hi = min(audio.count, Int((last.end + 0.3) * 16000))
            let text = hi > lo + 1600 ? Recording.withoutHallucinations(recognizer.transcribe(audio[lo..<hi])) : ""
            if text.isEmpty { out += group } else {
                out.append(RecordedSegment(speaker: first.speaker, start: first.start, end: last.end, text: text))
            }
        }
        for s in sorted {
            if russian(s.text), let first = group.first, let last = group.last,
               s.speaker == first.speaker, s.start - last.end <= 1.5, s.end - first.start <= 20 {
                group.append(s)
            } else {
                flush()
                if russian(s.text) { group = [s] } else { out.append(s) }
            }
        }
        flush()
        return out
    }
}
