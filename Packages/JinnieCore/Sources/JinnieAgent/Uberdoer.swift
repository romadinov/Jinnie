import Foundation
import JinnieCore

/// Talks to Uberdoer through its own MCP server binary (newline-delimited JSON-RPC over stdio).
/// No LLM in the loop: the binary writes ordinary CRDT ops into Uberdoer's database, the running
/// app merges them immediately and syncs them through iCloud. (Recommended by Uberdoer's agent.)
public final class Uberdoer: @unchecked Sendable {
    public static let defaultBinary = "/Applications/Uberdoer.app/Contents/MacOS/uberdoer-mcp"

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 1
    private let lock = NSLock()

    public static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: defaultBinary) }

    public init(binary: String = Uberdoer.defaultBinary) throws {
        // A scratch Jinnie database must never write into the real Uberdoer: require a test TASKER_DB alongside it.
        let env = ProcessInfo.processInfo.environment
        if env["JINNIE_HOME"] != nil && env["TASKER_DB"] == nil {
            throw ClaudeError(message: "JINNIE_HOME is set without TASKER_DB: refusing to touch the real Uberdoer")
        }
        process.executableURL = URL(fileURLWithPath: binary)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        _ = try request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [String: Any](),
            "clientInfo": ["name": "jinnie", "version": "0.1"],
        ])
        notify("notifications/initialized")
    }

    deinit {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func write(_ obj: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        input.fileHandleForWriting.write(data)
    }

    private func notify(_ method: String) { try? write(["jsonrpc": "2.0", "method": method]) }

    private func readLine() throws -> Data {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return Data(line)
            }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { throw ClaudeError(message: "uberdoer-mcp closed the connection") }
            buffer.append(chunk)
        }
    }

    private func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        try lock.withLock {
            let id = nextID; nextID += 1
            try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            while true {
                let line = try readLine()
                guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                guard (obj["id"] as? Int) == id else { continue }
                if let err = obj["error"] as? [String: Any] {
                    throw ClaudeError(message: "Uberdoer: \(err["message"] as? String ?? "error")")
                }
                return obj["result"] as? [String: Any] ?? [:]
            }
        }
    }

    /// Calls a tool and returns its structured result.
    @discardableResult
    public func call(_ tool: String, _ args: [String: Any]) throws -> [String: Any] {
        let r = try request("tools/call", ["name": tool, "arguments": args])
        if (r["isError"] as? Bool) == true {
            let text = (r["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ") ?? "error"
            throw ClaudeError(message: "Uberdoer \(tool): \(text)")
        }
        if let s = r["structuredContent"] as? [String: Any] { return s }
        if let text = (r["content"] as? [[String: Any]])?.first?["text"] as? String,
           let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { return obj }
        return [:]
    }

    // MARK: Typed helpers

    public struct TaskInfo {
        public var id: String
        public var title: String
        public var status: String      // available, completed, dropped, blocked, ...
        public var changed: String?
        public var note: String = ""
        public var isClosed: Bool { status == "completed" || status == "dropped" }
    }

    public func projects(folder: String?) throws -> [(id: String, name: String)] {
        var args: [String: Any] = [:]
        if let folder { args["folder"] = folder }
        let items = try call("list_projects", args)["items"] as? [[String: Any]] ?? []
        return items.compactMap { i in
            guard let id = i["id"] as? String, let name = i["name"] as? String else { return nil }
            return (id, name)
        }
    }

    public func createProject(path: String, note: String) throws -> String? {
        let r = try call("create_project", ["path": path, "note": note])
        return r["id"] as? String ?? (r["project"] as? [String: Any])?["id"] as? String
    }

    public func search(_ query: String, includeCompleted: Bool = true) throws -> [TaskInfo] {
        let items = try call("search_tasks", ["query": query, "include_completed": includeCompleted, "limit": 10])["items"] as? [[String: Any]] ?? []
        return items.compactMap(Uberdoer.taskInfo)
    }

    public func task(_ id: String) throws -> TaskInfo? {
        Uberdoer.taskInfo(try call("get_task", ["id": id]))
    }

    public func createTask(title: String, note: String, project: String?, tags: [String], due: String?, externalRef: String? = nil) throws -> String? {
        // literal: titles are taken as written (no #tag / due: shorthand parsing). external_ref makes creation idempotent
        // on Uberdoer's side too (an existing task with it is returned unchanged). Older Uberdoer builds ignore both.
        var args: [String: Any] = ["title": title, "note": note, "tags": tags, "literal": true]
        if let externalRef { args["external_ref"] = externalRef }
        if let project { args["project"] = project }
        if let due { args["due"] = due }
        let r = try call("create_task", args)
        return r["id"] as? String ?? (r["task"] as? [String: Any])?["id"] as? String
    }

    public func setNote(_ id: String, _ note: String) throws { try call("update_task", ["id": id, "note": note]) }

    /// Title, project, due date and the waiting-for tag as edited in Jinnie (`""` clears the due date). Literal: no
    /// shorthand parsing.
    public func updateTask(_ id: String, title: String, project: String?, due: String?, waiting: Bool) throws {
        var args: [String: Any] = ["id": id, "title": title, "literal": true, "due": due ?? ""]
        args[waiting ? "add_tags" : "remove_tags"] = [JinnieConfig.uberdoerWaitingTag]
        if let project { args["project"] = project }
        try call("update_task", args)
    }

    public func complete(_ id: String, undo: Bool = false) throws { try call("complete_task", ["id": id, "undo": undo]) }
    public func drop(_ id: String, undo: Bool = false) throws { try call("drop_task", ["id": id, "undo": undo]) }

    static func taskInfo(_ o: [String: Any]) -> TaskInfo? {
        guard let id = o["id"] as? String else { return nil }
        return TaskInfo(id: id, title: o["title"] as? String ?? "", status: o["status"] as? String ?? "", changed: o["changed"] as? String,
                        note: o["note"] as? String ?? "")
    }
}
