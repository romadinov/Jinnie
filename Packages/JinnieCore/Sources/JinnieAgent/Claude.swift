import Foundation
import JinnieCore

public struct ClaudeError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    /// The plan's usage limit refused the run ("You've hit your weekly limit · resets Oct 31 at 4pm (Australia/Melbourne)").
    public var isLimit: Bool { Claude.isLimitMessage(message) }
}

public struct ClaudeResult: @unchecked Sendable {
    public var text: String
    public var structured: Any?
    public var costUSD: Double
    public var durationMs: Int
    public var denials: [String]
    /// The stream-json transcript, for reading tool results directly.
    public var transcript = Data()

    /// Whether the run called any of these tools.
    public func usedAny(_ names: [String]) -> Bool {
        let set = Set(names)
        for line in transcript.split(separator: 0x0A) {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            if content.contains(where: { $0["type"] as? String == "tool_use" && set.contains($0["name"] as? String ?? "") }) { return true }
        }
        return false
    }

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
    /// While this returns a future time, runs fail at once without starting `claude` (the plan's limit was hit).
    public var limitedUntil: (@Sendable () -> Date?)?
    /// Called when a run is refused by the plan's limit, with when it resets (nil: unknown).
    public var onLimit: (@Sendable (Date?) -> Void)?

    public init(executable: String? = nil, model: String? = nil, workDirectory: URL? = nil) {
        self.executable = executable ?? Claude.locate() ?? "/opt/homebrew/bin/claude"
        self.model = model
        self.workDirectory = workDirectory ?? JinnieConfig.supportDirectory().appendingPathComponent("agent")
    }

    /// Jinnie's own Claude login, separate from the one Claude Code uses in Terminal (Claude Code keeps a login per
    /// CLAUDE_CONFIG_DIR, in a Keychain entry keyed by the folder's path, so the folder must never move).
    public static var accountDirectory: URL { JinnieConfig.supportDirectory().appendingPathComponent("claude-account", isDirectory: true) }
    /// Written only after a sign-in in `accountDirectory` is confirmed: until then Jinnie keeps using Claude Code's login.
    static var activeMarker: URL { accountDirectory.appendingPathComponent(".jinnie-active") }
    public static var usesOwnAccount: Bool { FileManager.default.fileExists(atPath: activeMarker.path) }

    /// `claude auth status` for a config folder (nil: Claude Code's default): signed in, and as whom.
    public static func accountStatus(configDirectory: URL?) -> (loggedIn: Bool, email: String?) {
        guard let exe = locate() else { return (false, nil) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["auth", "status", "--json"]
        var env = environment()
        if let configDirectory { env["CLAUDE_CONFIG_DIR"] = configDirectory.path } else { env.removeValue(forKey: "CLAUDE_CONFIG_DIR") }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (false, nil) }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let json = (try? JSONSerialization.jsonObject(with: data[start...])) as? [String: Any] else { return (false, nil) }
        return (json["loggedIn"] as? Bool == true, json["email"] as? String)
    }

    /// After a sign-in in `accountDirectory`: switches Jinnie to it if it worked. Returns the email, or nil.
    @discardableResult
    public static func activateOwnAccount() -> String? {
        let s = accountStatus(configDirectory: accountDirectory)
        guard s.loggedIn else { return nil }
        FileManager.default.createFile(atPath: activeMarker.path, contents: Data())
        return s.email ?? "your account"
    }

    /// Back to Claude Code's login; Jinnie's own stays signed in for later.
    public static func useSharedAccount() { try? FileManager.default.removeItem(at: activeMarker) }

    /// The environment every `claude` process gets: the usual PATH, never an API key, and Jinnie's own login if set up.
    public static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        env.removeValue(forKey: "ANTHROPIC_API_KEY")  // always the subscription, never API billing
        env.removeValue(forKey: "CLAUDECODE")
        if usesOwnAccount { env["CLAUDE_CONFIG_DIR"] = accountDirectory.path } else { env.removeValue(forKey: "CLAUDE_CONFIG_DIR") }
        return env
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
        if let until = limitedUntil?() {
            throw ClaudeError(message: "Claude usage limit reached; Jinnie waits until \(until.formatted(date: .abbreviated, time: .shortened))")
        }
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
            if Claude.isLimitMessage(text) { onLimit?(Claude.limitReset(in: text)) }
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

    static func isLimitMessage(_ s: String) -> Bool {
        let l = s.lowercased()
        return (l.contains("hit your") && l.contains("limit")) || l.contains("usage limit")
    }

    /// When the limit resets, from "… · resets Oct 31 at 4pm (Australia/Melbourne)" or "… · resets 4:30pm (…)".
    static func limitReset(in text: String, now: Date = Date()) -> Date? {
        guard let r = text.range(of: #"resets (.+?) \(([^)]+)\)"#, options: .regularExpression) else { return nil }
        let m = String(text[r]).dropFirst("resets ".count)
        guard let open = m.lastIndex(of: "(") else { return nil }
        let when = m[..<open].trimmingCharacters(in: .whitespaces)
        let zone = TimeZone(identifier: String(m[m.index(after: open)...].dropLast())) ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.defaultDate = cal.startOfDay(for: now)  // the year and day the text leaves out, never the current minutes
        for format in ["MMM d 'at' ha", "MMM d 'at' h:mma", "MMM d, ha", "ha", "h:mma"] {
            f.dateFormat = format
            guard var d = f.date(from: when) else { continue }
            // Without a year (or a day), the parsed time may land in the past: the next such time is meant.
            let step: Calendar.Component = format.hasPrefix("MMM") ? .year : .day
            while d < now.addingTimeInterval(-3600) { d = cal.date(byAdding: step, value: 1, to: d) ?? d.addingTimeInterval(86400) }
            return d
        }
        return nil
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
        p.environment = Claude.environment()
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
