import Foundation

// jinnie-gigaam <model folder> <clips.f32>
// Reads Russian speech with GigaAM v3 (sherpa-onnx) for Jinnie, in its own process: if the native engine faults, only this
// helper dies and Jinnie keeps Whisper's text.
// clips.f32: 16 kHz mono Float32 samples, the clips one after another. Standard input: one "offset count" line per clip
// (in samples). Standard output: a JSON array with one string per clip, in order.

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

final class Recognizer {
    private let handle: OpaquePointer
    private var strings: [UnsafeMutablePointer<CChar>] = []

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

    func transcribe(_ samples: UnsafeBufferPointer<Float>) -> String {
        guard let stream = SherpaOnnxCreateOfflineStream(handle) else { return "" }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        SherpaOnnxAcceptWaveformOffline(stream, 16000, samples.baseAddress, Int32(samples.count))
        SherpaOnnxDecodeOfflineStream(handle, stream)
        guard let r = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(r) }
        return r.pointee.text.map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

do {
    let args = CommandLine.arguments
    guard args.count == 3 else { throw Failure("usage: jinnie-gigaam <model folder> <clips.f32>") }
    let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let total = data.count / MemoryLayout<Float>.size
    var clips: [(Int, Int)] = []
    while let line = readLine() {
        let n = line.split(separator: " ").compactMap { Int($0) }
        guard n.count == 2, n[0] >= 0, n[1] > 0, n[0] + n[1] <= total else { throw Failure("bad clip: \(line)") }
        clips.append((n[0], n[1]))
    }
    let recognizer = try Recognizer(directory: URL(fileURLWithPath: args[1]))
    let texts = data.withUnsafeBytes { raw in
        let all = raw.bindMemory(to: Float.self)
        return clips.map { recognizer.transcribe(UnsafeBufferPointer(rebasing: all[$0.0 ..< $0.0 + $0.1])) }
    }
    FileHandle.standardOutput.write(try JSONEncoder().encode(texts))
} catch {
    FileHandle.standardError.write(Data("jinnie-gigaam: \(error)\n".utf8))
    exit(1)
}
