import Foundation
import JinnieCore

/// Reads handwritten notebooks from reMarkable Cloud: `rmapi` (ddvk fork) lists and downloads them, `rmc` turns each
/// page's strokes into SVG, `rsvg-convert` into a PNG that Claude can read.
///
/// Read-only by construction: the only rmapi commands used are `find` and `get` (rmapi can also move, delete and
/// "nuke", which Jinnie never calls). Sign-in is done once by the user: run `rmapi` and enter the code from
/// https://my.remarkable.com/device/desktop/connect.
public struct RemarkableReader: Sendable {
    public var rmapi: String
    public var rmc: String
    public var rsvg: String

    static func tool(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public init?() {
        guard let a = Self.tool("rmapi"), let c = Self.tool("rmc"), let r = Self.tool("rsvg-convert") else { return nil }
        rmapi = a; rmc = c; rsvg = r
    }

    /// What is missing, for Settings and errors.
    public static var missing: [String] { ["rmapi", "rmc", "rsvg-convert"].filter { tool($0) == nil } }

    public static var isSignedIn: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Library/Application Support/rmapi/rmapi.conf", ".config/rmapi/rmapi.conf", ".rmapi"]
            .contains { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) }
    }

    public struct Notebook: Sendable {
        public var id: String
        public var name: String
        /// Folder path ("Work/Acme"), empty at the root.
        public var folder: String
        public var modified: Date
    }

    public struct Page: Sendable {
        public var id: String
        public var number: Int
        /// When the page was last written on (from the notebook's .content).
        public var modified: String
        public var image: URL
    }

    // MARK: Listing

    /// Every notebook in the account (not in the trash), newest first.
    public func notebooks() throws -> [Notebook] {
        let out = try run(rmapi, ["-ni", "-json", "find", "/"], timeout: 180)
        guard let start = out.firstIndex(of: "["),
              let list = (try? JSONSerialization.jsonObject(with: Data(out[start...].utf8))) as? [[String: Any]] else {
            throw ClaudeError(message: "reMarkable: unexpected rmapi output: \(out.prefix(200))")
        }
        var byID: [String: [String: Any]] = [:]
        for e in list { if let id = e["id"] as? String, !id.isEmpty { byID[id] = e } }
        func path(_ parent: String) -> String? {
            var parts: [String] = []
            var p = parent
            var guardCount = 0
            while !p.isEmpty, guardCount < 20 {
                if p == "trash" { return nil }
                guard let e = byID[p] else { break }
                parts.insert((e["name"] as? String ?? "").trimmingCharacters(in: .whitespaces), at: 0)
                p = e["parent"] as? String ?? ""
                guardCount += 1
            }
            return parts.joined(separator: "/")
        }
        let iso = ISO8601DateFormatter()
        return list.compactMap { e -> Notebook? in
            guard e["type"] as? String == "DocumentType", let id = e["id"] as? String,
                  let folder = path(e["parent"] as? String ?? ""),
                  let modified = (e["modifiedClient"] as? String).flatMap(iso.date(from:)) else { return nil }
            return Notebook(id: id, name: (e["name"] as? String ?? "").trimmingCharacters(in: .whitespaces), folder: folder, modified: modified)
        }
        .sorted { $0.modified > $1.modified }
    }

    // MARK: Pages

    /// Downloads a notebook into `dir` and renders its written pages (in order, at most `maxPages`) as PNGs.
    /// Returns nil for documents that aren't notebooks (PDFs and ebooks with annotations are skipped for now).
    public func pages(of notebook: Notebook, into dir: URL, maxPages: Int = 20) throws -> [Page]? {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try run(rmapi, ["-ni", "get", "--id", notebook.id], cwd: dir, timeout: 180)
        guard let archive = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "rmdoc" || $0.pathExtension == "zip" }) else {
            throw ClaudeError(message: "reMarkable: download of \(notebook.name) produced no file")
        }
        let unpacked = dir.appendingPathComponent("doc")
        _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path], timeout: 60)
        let contentURL = unpacked.appendingPathComponent("\(notebook.id).content")
        guard let content = (try? JSONSerialization.jsonObject(with: Data(contentsOf: contentURL))) as? [String: Any] else {
            throw ClaudeError(message: "reMarkable: \(notebook.name) has no readable .content")
        }
        guard (content["fileType"] as? String ?? "notebook") == "notebook" else { return nil }

        // Page order: format 2 keeps pages in cPages with a sortable idx; format 1 in a plain list.
        var order: [(id: String, modified: String)] = []
        if let cp = (content["cPages"] as? [String: Any])?["pages"] as? [[String: Any]] {
            order = cp.filter { $0["deleted"] == nil }
                .sorted { (($0["idx"] as? [String: Any])?["value"] as? String ?? "") < (($1["idx"] as? [String: Any])?["value"] as? String ?? "") }
                .compactMap { p in (p["id"] as? String).map { ($0, p["modifed"] as? String ?? p["modified"] as? String ?? "") } }
        } else if let ids = content["pages"] as? [String] {
            order = ids.map { ($0, "") }
        }
        var out: [Page] = []
        for (n, p) in order.enumerated() {
            let rm = unpacked.appendingPathComponent(notebook.id).appendingPathComponent("\(p.id).rm")
            guard fm.fileExists(atPath: rm.path) else { continue }  // never written on
            let svg = dir.appendingPathComponent("p\(n + 1).svg")
            let png = dir.appendingPathComponent("page-\(n + 1).png")
            _ = try? run(rmc, ["-t", "svg", "-o", svg.path, rm.path], timeout: 60)
            guard let text = try? String(contentsOf: svg, encoding: .utf8), text.contains("<polyline") || text.contains("<path") else { continue }
            _ = try run(rsvg, ["-b", "white", "-w", "1200", svg.path, "-o", png.path], timeout: 60)
            out.append(Page(id: p.id, number: n + 1, modified: p.modified, image: png))
        }
        // Long notebooks: the most recently written pages matter most.
        if out.count > maxPages { out = Array(out.sorted { $0.modified > $1.modified }.prefix(maxPages)).sorted { $0.number < $1.number } }
        return out
    }

    // MARK: Process

    func run(_ exe: String, _ args: [String], cwd: URL? = nil, timeout: TimeInterval) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("jinnie-rm-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: file) }
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        p.waitUntilExit()
        timer.cancel()
        let out = String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
        if p.terminationReason == .uncaughtSignal { throw ClaudeError(message: "\(URL(fileURLWithPath: exe).lastPathComponent) timed out") }
        if p.terminationStatus != 0 {
            if out.contains("code") && out.contains("remarkable.com") {
                throw ClaudeError(message: "reMarkable sign-in needed: run ~/.local/bin/rmapi once and enter the code from my.remarkable.com/device/desktop/connect")
            }
            throw ClaudeError(message: "\(URL(fileURLWithPath: exe).lastPathComponent) failed: \(out.suffix(300))")
        }
        return out
    }
}
