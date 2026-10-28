import Foundation
import JinnieCore
import Observation
import WhisperKit

/// On-device Whisper (WhisperKit, Core ML), as in Uberdoer. On the Mac it reuses the model Uberdoer already downloaded
/// (large-v3 turbo, ~630 MB); otherwise it downloads once into Application Support.
@MainActor @Observable
final class WhisperModel {
    static let shared = WhisperModel()

    enum Status: Equatable { case notDownloaded, downloading(Double), loading, ready, failed(String) }
    private(set) var status: Status
    private(set) var kit: WhisperKit?
    private var preparing: Task<WhisperKit?, Never>?

    /// The model meetings are transcribed with, chosen in Settings (Mac): turbo is fast; the full large-v3 is somewhat more
    /// accurate on languages other than English (e.g. Russian) and 2–3× slower. Downloaded once when first used.
    enum Choice: String, CaseIterable, Identifiable {
        case turbo, full, gigaam
        var id: String { rawValue }
        var label: String {
            switch self {
            case .turbo: "Whisper large-v3 turbo (fast)"
            case .full: "Whisper large-v3 (more accurate, slower)"
            case .gigaam: "Russian: GigaAM, English: Whisper turbo"
            }
        }
        var variant: String { self == .full ? "openai_whisper-large-v3-v20240930" : "openai_whisper-large-v3-v20240930_turbo_632MB" }
    }
    static var choice: Choice {
        get {
            let c = UserDefaults.standard.string(forKey: "transcriptionModel").flatMap(Choice.init) ?? .turbo
            #if os(macOS)
            return c
            #else
            return c == .gigaam ? .turbo : c  // GigaAM runs on the Mac
            #endif
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "transcriptionModel") }
    }

    static var variant: String {
        #if os(macOS)
        choice.variant
        #else
        WhisperKit.recommendedModels().default
        #endif
    }

    /// After the model choice changes: the next transcription loads (and if needed downloads) the new one.
    func reset() {
        kit = nil
        status = Self.existingFolder == nil ? .notDownloaded : .loading
    }

    static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jinnie/Whisper", isDirectory: true)
    }

    /// Model folders that may already hold the model: Jinnie's own, then Uberdoer's (Mac).
    static var knownFolders: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let rel = "models/argmaxinc/whisperkit-coreml/\(variant)"
        var out = [downloadBase.appendingPathComponent(rel)]
        #if os(macOS)
        out.append(support.appendingPathComponent("Tasker/Whisper").appendingPathComponent(rel))
        #endif
        return out
    }

    private static var existingFolder: URL? {
        knownFolders.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) || FileManager.default.fileExists(atPath: $0.appendingPathComponent("AudioEncoder.mlmodelc").path) }
    }

    var isDownloaded: Bool { Self.existingFolder != nil }

    init() { status = Self.existingFolder == nil ? .notDownloaded : .loading }

    /// Downloads (if needed) and loads the model. Safe to call repeatedly.
    @discardableResult
    func prepare() async -> WhisperKit? {
        if let kit { return kit }
        if let preparing { return await preparing.value }
        let t = Task<WhisperKit?, Never> { @MainActor in
            do {
                var folder = Self.existingFolder
                if folder == nil {
                    status = .downloading(0)
                    try FileManager.default.createDirectory(at: Self.downloadBase, withIntermediateDirectories: true)
                    folder = try await WhisperKit.download(variant: Self.variant, downloadBase: Self.downloadBase) { p in
                        Task { @MainActor in WhisperModel.shared.status = .downloading(p.fractionCompleted) }
                    }
                }
                status = .loading
                // The tokenizer goes in Jinnie's folder too: WhisperKit's default is ~/Documents/huggingface, and reading
                // Documents makes macOS ask for permission, which stalls transcription until answered.
                try FileManager.default.createDirectory(at: Self.downloadBase, withIntermediateDirectories: true)
                let k = try await WhisperKit(WhisperKitConfig(modelFolder: folder!.path, tokenizerFolder: Self.downloadBase, verbose: false, logLevel: .error,
                                                              prewarm: false, load: true, download: false))
                kit = k
                status = .ready
                return k
            } catch {
                status = .failed(error.localizedDescription)
                return nil
            }
        }
        preparing = t
        let k = await t.value
        preparing = nil
        return k
    }

    /// Short dictation. `language` nil = detect; if the detected language isn't one of `expected`, it is redone in `fallback`.
    func transcribe(_ samples: [Float], language: String?, expected: Set<String>, fallback: String) async -> String {
        guard let kit = await prepare(), !samples.isEmpty else { return "" }
        func run(_ lang: String?) async -> (String, String?) {
            let options = DecodingOptions(language: lang, temperatureFallbackCount: 2, usePrefillPrompt: lang != nil,
                                          detectLanguage: lang == nil, skipSpecialTokens: true, withoutTimestamps: true,
                                          chunkingStrategy: samples.count > 16000 * 28 ? .vad : nil)
            let results = (try? await kit.transcribe(audioArray: samples, decodeOptions: options)) ?? []
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return (text, results.first?.language)
        }
        var (text, detected) = await run(language)
        if language == nil, let d = detected, !expected.contains(d) { (text, _) = await run(fallback) }
        return Self.clean(text)
    }

    /// A long recording with word timings (for aligning with speakers). Language is detected per 30 s window.
    func transcribeLong(_ samples: [Float], progress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptionResult] {
        guard let kit = await prepare() else { throw WhisperError.notReady }
        // A clip of one window or less is decoded whole: splitting it at pauses (VAD) lost a 27 s passage in testing.
        if samples.count <= 16000 * 28 {
            let o = DecodingOptions(detectLanguage: true, skipSpecialTokens: true, wordTimestamps: true)
            return try await kit.transcribe(audioArray: samples, decodeOptions: o)
        }
        // No vocabulary prompt: with one, WhisperKit's word timings collapsed and whole sentences were dropped (tested
        // with whisperkit-cli --prompt). Names are corrected later from the directory when the agent reads the transcript.
        let options = DecodingOptions(detectLanguage: true, skipSpecialTokens: true, wordTimestamps: true, chunkingStrategy: .vad)
        let total = Double(samples.count) / 16000
        // Progress is approximate: windows of ~30 s, decoded roughly in order.
        var results = try await kit.transcribe(audioArray: samples, decodeOptions: options, callback: { p in
            progress(min(0.99, Double(p.windowId + 1) * 30 / max(total, 30)))
            return nil
        })
        // Recovery: on a long recording Whisper sometimes skips a whole window it judged silent (tested on a 1-hour
        // Russian meeting: 39 s of speech missing in one place, 8% of the text overall). Gaps of 8 s or more that hold
        // at least 3 s of speech are transcribed again on their own and added back.
        let spans = results.flatMap(\.segments).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { (start: Double($0.start), end: Double($0.end)) }
        for gap in Recording.gaps(spans, duration: total) {
            let lo = max(0, Int(gap.start * 16000)), hi = min(samples.count, Int(gap.end * 16000))
            guard hi > lo, Recording.speechSeconds(samples[lo..<hi]) >= 3 else { continue }
            var o = options
            o.chunkingStrategy = hi - lo > 16000 * 28 ? .vad : nil
            guard let more = try? await kit.transcribe(audioArray: Array(samples[lo..<hi]), decodeOptions: o) else { continue }
            for r in more {
                let shifted = r.segments.map { seg -> TranscriptionSegment in
                    var s = seg
                    s.start += Float(gap.start); s.end += Float(gap.start)
                    s.words = s.words?.map { w in var w = w; w.start += Float(gap.start); w.end += Float(gap.start); return w }
                    return s
                }
                results.append(TranscriptionResult(text: r.text, segments: shifted, language: r.language, timings: r.timings))
            }
        }
        return results
    }

    enum WhisperError: LocalizedError {
        case notReady
        var errorDescription: String? { "The Whisper model isn't available" }
    }

    /// Whisper sometimes "hears" stock phrases in near-silence; drop those.
    static func clean(_ s: String) -> String { Recording.withoutHallucinations(s) }
}
