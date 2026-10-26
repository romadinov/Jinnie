import Foundation
import JinnieCore

public struct ClaudeError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

public struct ClaudeResult: @unchecked Sendable {
    public var text: String
    public var structured: Any?
    public var costUSD: Double
    public var durationMs: Int
    public var denials: [String]
    /// The stream-json transcript, for reading tool results directly.
    public var transcript = Data()

    /// The text of every tool result whose call used a tool with this name suffix.
    public func toolResults(_ suffix: String) -> [String] {
        var ids = Set<String>()
        var out: [String] = []
        for line in transcript.split(separator: 0x0A) {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for c in content {
                if c["type"] as? String == "tool_use", (c["name"] as? String)?.hasSuffix(suffix) == true, let id = c["id"] as? String { ids.insert(id) }
                if c["type"] as? String == "tool_result", let id = c["tool_use_id"] as? String, ids.contains(id) {
                    if let s = c["content"] as? String { out.append(s) }
                    else if let parts = c["content"] as? [[String: Any]] { out.append(parts.compactMap { $0["text"] as? String }.joined()) }
                }
            }
        }
        return out
    }
}

/// Runs `claude -p` headless on the user's Claude subscription. The user's claude.ai connectors
/// (Gmail, Calendar, Slack) are available to it exactly as in an interactive session.
/// Tools are allow-listed per call and everything else is refused (`--permission-mode dontAsk`).
public struct Claude: Sendable {
    public var executable: String
    public var model: String?
    public var workDirectory: URL
    /// Called after every run with its label and cost (subscription usage, priced as API-equivalent dollars).
    public var onUsage: (@Sendable (String, Double) -> Void)?

    public init(executable: String? = nil, model: String? = nil, workDirectory: URL? = nil) {
        self.executable = executable ?? Claude.locate() ?? "/opt/homebrew/bin/claude"
        self.model = model
        self.workDirectory = workDirectory ?? JinnieConfig.supportDirectory().appendingPathComponent("agent")
    }

    /// GUI apps don't get the shell PATH, so look in the usual install locations.
    public static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            ProcessInfo.processInfo.environment["JINNIE_CLAUDE"],
            "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public struct Call: Sendable {
        public var prompt: String
        public var systemPrompt: String?
        public var allowedTools: [String] = []
        /// Built-in tools made available (`--tools`). ToolSearch loads MCP/connector tools; `Read` lets a call look at
        /// files Jinnie prepared (reMarkable page images), restricted further by `allowedTools` rules.
        public var builtinTools = ["ToolSearch"]
        /// MCP servers in addition to the user's own (JSON text for --mcp-config).
        public var mcpConfig: String?
        /// Only use servers from `mcpConfig` (drops claude.ai connectors and user-configured servers).
        public var strictMCP = false
        public var jsonSchema: String?
        public var timeout: TimeInterval = 900
        public var effort: String?
        /// Overrides the default model for this call ("sonnet" for routine extraction).
        public var model: String?
        /// Names the transcript file.
        public var label = "run"

        public init(prompt: String) { self.prompt = prompt }
    }

    public func run(_ call: Call) async throws -> ClaudeResult {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        // stream-json so every run leaves a transcript (agent/traces) showing which tools it used.
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--no-session-persistence", "--permission-mode", "dontAsk",
                    // No built-in tools (Bash, file edits, web) except ToolSearch: MCP tools are deferred and
                    // claude.ai connectors attach after start-up, so ToolSearch is how they get loaded.
                    "--tools", call.builtinTools.joined(separator: ",")]
        if !call.allowedTools.isEmpty { args += ["--allowedTools", call.allowedTools.joined(separator: ",")] }
        // Runs that only use Jinnie's own MCP server (strict) don't need ToolSearch: without it the local tools are
        // loaded up front, which saves a model turn per run. Connector runs keep it (claude.ai connectors are deferred).
        if call.strictMCP && call.builtinTools == ["ToolSearch"], let i = args.firstIndex(of: "--tools") { args[i + 1] = "" }
        if let m = call.model ?? model { args += ["--model", m] }
        if let e = call.effort { args += ["--effort", e] }
        if let s = call.systemPrompt { args += ["--append-system-prompt", s] }
        if let schema = call.jsonSchema { args += ["--json-schema", schema] }
        var mcpFile: URL?
        defer { if let f = mcpFile { try? FileManager.default.removeItem(at: f) } }
        if let mcp = call.mcpConfig {
            removeStaleMCPConfigs()
            let file = workDirectory.appendingPathComponent("mcp-\(UUID().uuidString).json")
            try mcp.write(to: file, atomically: true, encoding: .utf8)
            mcpFile = file
            args += ["--mcp-config", file.path]
            if call.strictMCP { args.append("--strict-mcp-config") }
        }
        let output = try await Claude.spawn(executable, args: args, stdin: call.prompt, cwd: workDirectory, timeout: call.timeout)
        saveTrace(output.stdout, label: call.label)
        let lines = output.stdout.split(separator: 0x0A)
        let resultLine = lines.reversed().lazy
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
            .first { $0["type"] as? String == "result" }
        guard let obj = resultLine else {
            let err = String(decoding: output.stderr, as: UTF8.self)
            let out = String(decoding: output.stdout.prefix(2000), as: UTF8.self)
            throw ClaudeError(message: "claude exited \(output.status): \(err.isEmpty ? out : err)")
        }
        let text = obj["result"] as? String ?? ""
        if (obj["is_error"] as? Bool) == true {
            throw ClaudeError(message: "claude: \(text.isEmpty ? (obj["subtype"] as? String ?? "error") : text)")
        }
        let denials = (obj["permission_denials"] as? [[String: Any]] ?? []).compactMap { $0["tool_name"] as? String }
        onUsage?(call.label, obj["total_cost_usd"] as? Double ?? 0)
        return ClaudeResult(text: text,
                            structured: obj["structured_output"],
                            costUSD: obj["total_cost_usd"] as? Double ?? 0,
                            durationMs: obj["duration_ms"] as? Int ?? 0,
                            denials: denials,
                            transcript: output.stdout)
    }

    public var tracesDirectory: URL { workDirectory.appendingPathComponent("traces") }

    /// Keeps the last 60 transcripts for debugging and audit.
    func saveTrace(_ data: Data, label: String) {
        let dir = tracesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        try? data.write(to: dir.appendingPathComponent("\(f.string(from: Date()))-\(label).jsonl"))
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), files.count > 60 {
            for old in files.prefix(files.count - 60) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
        }
    }

    /// Config files left by runs that were killed before they could remove their own (older than a day).
    func removeStaleMCPConfigs() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-86_400)
        for name in (try? fm.contentsOfDirectory(atPath: workDirectory.path)) ?? [] where name.hasPrefix("mcp-") && name.hasSuffix(".json") {
            let url = workDirectory.appendingPathComponent(name)
            if let d = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, d < cutoff { try? fm.removeItem(at: url) }
        }
    }

    struct Output { var status: Int32; var stdout: Data; var stderr: Data }

    static func spawn(_ exe: String, args: [String], stdin: String, cwd: URL, timeout: TimeInterval) async throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        env.removeValue(forKey: "ANTHROPIC_API_KEY")  // always the subscription, never API billing
        env.removeValue(forKey: "CLAUDECODE")
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe

        let outBox = DataBox(), errBox = DataBox()
        outPipe.fileHandleForReading.readabilityHandler = { h in outBox.append(h.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { h in errBox.append(h.availableData) }

        return try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outBox.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errBox.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: Output(status: proc.terminationStatus, stdout: outBox.data, stderr: errBox.data))
            }
            do {
                try p.run()
            } catch {
                cont.resume(throwing: ClaudeError(message: "Cannot start \(exe): \(error.localizedDescription)"))
                return
            }
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    func append(_ d: Data) { lock.withLock { _data.append(d) } }
    var data: Data { lock.withLock { _data } }
}
