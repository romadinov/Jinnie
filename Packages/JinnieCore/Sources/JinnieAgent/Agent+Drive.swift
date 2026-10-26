import Foundation
import JinnieCore

/// Drive is read in two steps, because a single "look through Drive" run opened only a few of dozens of new files:
/// the model lists what changed, Jinnie picks the files it hasn't read (or that changed since), and the model reads
/// exactly those, a batch at a time. Every file opened is logged, so nothing is read twice unless it changes.
extension Agent {
    struct DriveFile: Codable, Sendable {
        var id: String
        var title: String
        var mimeType: String
        var modifiedTime: String
        var url: String?

        var modified: Date? { Agent.parseISO(modifiedTime) }
        var isMeetingNotes: Bool { title.localizedCaseInsensitiveContains("transcript") || title.localizedCaseInsensitiveContains("notes by gemini") }
        var isDeckOrSheet: Bool { ["presentation", "spreadsheet", "sheet", "powerpoint", "excel"].contains { mimeType.contains($0) } }
        var isReadable: Bool {
            ["google-apps.document", "google-apps.presentation", "google-apps.spreadsheet", "pdf", "officedocument", "msword",
             "ms-excel", "ms-powerpoint", "text/plain", "markdown", "csv"].contains { mimeType.contains($0) }
        }
        var kind: String { mimeType.split(whereSeparator: { $0 == "." || $0 == "/" }).last.map(String.init) ?? mimeType }
        /// Meeting notes first, then decks and spreadsheets, then documents and PDFs.
        var priority: Int { isMeetingNotes ? 0 : isDeckOrSheet ? 1 : 2 }
    }

    /// Files read per model call, and per sync; the rest wait for the next sync.
    static let driveBatch = 12
    static let driveFilesPerRun = 24

    /// id → modifiedTime of the version read. Seeded from Drive items read before this log existed.
    var driveRead: [String: Date] {
        get {
            if let data = store.meta("drive.read")?.data(using: .utf8),
               let raw = try? JSONDecoder().decode([String: Double].self, from: data) {
                return raw.mapValues(Date.init(timeIntervalSince1970:))
            }
            var seeded: [String: Date] = [:]
            for item in store.all(Item.self) where item.source == .drive { seeded[item.sourceRef] = item.updatedAt }
            return seeded
        }
        set {
            let raw = newValue.mapValues(\.timeIntervalSince1970)
            store.setMeta("drive.read", (try? JSONEncoder().encode(raw)).map { String(decoding: $0, as: UTF8.self) })
        }
    }

    var drivePending: [DriveFile] {
        get { store.meta("drive.pending")?.data(using: .utf8).flatMap { try? JSONDecoder().decode([DriveFile].self, from: $0) } ?? [] }
        set { store.setMeta("drive.pending", newValue.isEmpty ? nil : (try? JSONEncoder().encode(newValue)).map { String(decoding: $0, as: UTF8.self) }) }
    }

    /// Returns the stats, the cost, the files read and how many wait for the next sync.
    func ingestDrive(since: Date, tools: [String]) async throws -> (stats: ApplyStats, cost: Double, files: Int, left: Int) {
        var list = Claude.Call(prompt: Prompts.driveList(since: since))
        list.systemPrompt = Prompts.system
        list.allowedTools = tools
        list.jsonSchema = Prompts.driveListSchema
        list.model = Agent.routineModel   // Haiku garbled the long page tokens
        list.label = "drive-list"
        list.timeout = 600
        let listed = try await claude.run(list)
        try Agent.checkConnectorsReached(listed, tools: tools)
        // The files come from the search results themselves: having the model copy out a long listing was slow and
        // timed out (and it may skip or garble entries).
        var files: [DriveFile] = []
        var complete = false   // the last page read had no next page
        for text in listed.toolResults("search_files") {
            guard let data = text.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let found = obj["files"] as? [[String: Any]] else { continue }
            complete = (obj["nextPageToken"] as? String)?.isEmpty ?? true
            for f in found {
                guard let id = f["id"] as? String, let mime = f["mimeType"] as? String, let modified = f["modifiedTime"] as? String else { continue }
                files.append(DriveFile(id: id, title: f["title"] as? String ?? f["name"] as? String ?? "", mimeType: mime,
                                       modifiedTime: modified, url: f["viewUrl"] as? String ?? f["webViewLink"] as? String))
            }
        }
        // A listing that stopped early (a failed page) would move the cursor past files never seen: fail and retry.
        guard complete else {
            throw ClaudeError(message: "Drive: the file listing stopped before the last page (\(files.count) files seen); retrying next sync.")
        }
        // Files listed earlier but not read yet (over the per-sync limit), so the next sync doesn't list them again.
        var byID: [String: DriveFile] = [:]
        for f in drivePending + files { byID[f.id] = f }
        let read = driveRead
        let due = byID.values.filter { f in
            guard f.isReadable else { return false }
            guard let at = read[f.id] else { return true }
            return (f.modified ?? .distantFuture) > at
        }
        .sorted { ($0.priority, $1.modified ?? .distantPast) < ($1.priority, $0.modified ?? .distantPast) }

        var stats = ApplyStats()
        var cost = listed.costUSD
        let now = due.prefix(Agent.driveFilesPerRun)
        log("Drive: \(files.count) changed, \(due.count) to read, reading \(now.count)…")
        for start in stride(from: 0, to: now.count, by: Agent.driveBatch) {
            let batch = Array(now.dropFirst(start).prefix(Agent.driveBatch))
            let result = try await extract(task: Prompts.driveRead(batch), tools: tools, label: "ingest-drive")
            let s = apply(result.structured, source: .drive)
            stats.items += s.items; stats.people += s.people; stats.projects += s.projects
            stats.actions += s.actions; stats.resolved += s.resolved
            cost += result.costUSD
            var readLog = driveRead
            for f in batch { readLog[f.id] = f.modified ?? Date() }
            driveRead = readLog
        }
        drivePending = Array(due.dropFirst(now.count))
        return (stats, cost, now.count, due.count - now.count)
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
