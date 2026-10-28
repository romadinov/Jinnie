import Foundation
import JinnieCore
import Observation

/// GigaAM v3 (Sber, MIT licence): Russian speech recognition, run on this Mac through sherpa-onnx. Much better than Whisper
/// on Russian conversation (tested on the owner's meetings), weaker on English words, so Whisper transcribes first and the
/// Russian stretches are read again with GigaAM. The model (about 225 MB) downloads the first time it's chosen.
/// The engine is native C++ and runs in a helper process (`jinnie-gigaam`, next to the app's executable): a fault in it
/// once corrupted Jinnie's memory and crashed the app later, so now it can only end the helper, and Jinnie keeps Whisper's text.
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

    private var preparing: Task<Void, Error>?

    init() { status = Self.isDownloaded ? .ready : .notDownloaded }

    /// Downloads the model once.
    func prepare() async throws {
        if Self.isDownloaded { status = .ready; return }
        if let preparing { return try await preparing.value }
        let t = Task<Void, Error> { @MainActor in
            do {
                status = .downloading
                try await Task.detached { try await Self.download() }.value
                status = .ready
            } catch {
                status = .failed(error.localizedDescription)
                throw error
            }
        }
        preparing = t
        defer { preparing = nil }
        try await t.value
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

    nonisolated static var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/jinnie-gigaam") }

    /// Runs the helper on the clips (16 kHz mono) and returns one text per clip. Throws if the helper fails, crashes or
    /// takes longer than about 1 s per second of audio plus a minute.
    nonisolated static func transcribe(_ clips: [ArraySlice<Float>]) throws -> [String] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jinnie-gigaam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var samples: [Float] = [], lines = ""
        for c in clips {
            lines += "\(samples.count) \(c.count)\n"
            samples += c
        }
        let audio = folder.appendingPathComponent("clips.f32"), input = folder.appendingPathComponent("clips.txt")
        try samples.withUnsafeBufferPointer { try Data(buffer: $0).write(to: audio) }
        try Data(lines.utf8).write(to: input)

        let p = Process()
        p.executableURL = helper
        p.arguments = [modelDirectory.path, audio.path]
        p.standardInput = try FileHandle(forReadingFrom: input)
        let out = folder.appendingPathComponent("out.json"), err = folder.appendingPathComponent("err.txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        p.standardOutput = try FileHandle(forWritingTo: out)
        p.standardError = try FileHandle(forWritingTo: err)
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        if done.wait(timeout: .now() + 60 + Double(samples.count) / 16000) == .timedOut {
            p.terminate()
            throw Failure("GigaAM took too long")
        }
        guard p.terminationReason == .exit, p.terminationStatus == 0 else {
            let why = (try? String(contentsOf: err, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure(p.terminationReason == .uncaughtSignal ? "GigaAM crashed (signal \(p.terminationStatus))" : "GigaAM failed: \(why)")
        }
        let texts = try JSONDecoder().decode([String].self, from: Data(contentsOf: out))
        guard texts.count == clips.count else { throw Failure("GigaAM returned \(texts.count) of \(clips.count) clips") }
        return texts
    }

    /// Reads the Russian stretches again with GigaAM: consecutive lines of one speaker, mostly Cyrillic, close together,
    /// up to 20 s, become one line with GigaAM's text (from that speaker's own track on a call). English lines keep
    /// Whisper's text, which handles English words better.
    nonisolated static func refine(_ segments: [RecordedSegment], track: (RecordedSegment) -> [Float]) throws -> [RecordedSegment] {
        func russian(_ s: String) -> Bool {
            let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard letters.count >= 2 else { return false }
            return Double(letters.filter { (0x400...0x4FF).contains($0.value) }.count) / Double(letters.count) >= 0.5
        }
        // Groups of Russian lines (one speaker, close together, up to 20 s) and the plain lines between them, in order.
        enum Part { case keep(RecordedSegment), group([RecordedSegment]) }
        var parts: [Part] = []
        var group: [RecordedSegment] = []
        func flush() { if !group.isEmpty { parts.append(.group(group)); group = [] } }
        for s in segments.sorted(by: { $0.start < $1.start }) {
            if russian(s.text), let first = group.first, let last = group.last,
               s.speaker == first.speaker, s.start - last.end <= 1.5, s.end - first.start <= 20 {
                group.append(s)
            } else {
                flush()
                if russian(s.text) { group = [s] } else { parts.append(.keep(s)) }
            }
        }
        flush()

        var clips: [ArraySlice<Float>] = [], clipOf: [Int: Int] = [:]
        for (i, part) in parts.enumerated() {
            guard case .group(let g) = part, let first = g.first, let last = g.last else { continue }
            let audio = track(first)
            let lo = max(0, Int((first.start - 0.2) * 16000)), hi = min(audio.count, Int((last.end + 0.3) * 16000))
            guard hi > lo + 1600 else { continue }
            clipOf[i] = clips.count
            clips.append(audio[lo..<hi])
        }
        let texts = clips.isEmpty ? [] : try transcribe(clips)

        var out: [RecordedSegment] = []
        for (i, part) in parts.enumerated() {
            switch part {
            case .keep(let s): out.append(s)
            case .group(let g):
                let text = clipOf[i].map { Recording.withoutHallucinations(texts[$0]) } ?? ""
                if text.isEmpty { out += g } else {
                    out.append(RecordedSegment(speaker: g[0].speaker, start: g[0].start, end: g[g.count - 1].end, text: text))
                }
            }
        }
        return out
    }
}
