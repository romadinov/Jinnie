import Foundation
import JinnieCore

// MARK: - reMarkable: handwritten notebooks → transcripts → knowledge

extension Agent {
    /// Days of notebooks the first run reads (later runs read what changed since).
    public var remarkableBackfillDays: Int { store.meta("remarkableBackfillDays").flatMap(Int.init) ?? 30 }

    func remarkableSeen(_ id: String) -> Date? {
        store.meta("remarkable.seen.\(id)").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    /// Notebooks written on since they were last transcribed. `since` overrides the window (backfill from the CLI).
    public func remarkableDue(_ notebooks: [RemarkableReader.Notebook], since: Date?) -> [RemarkableReader.Notebook] {
        let window = since ?? Date().addingTimeInterval(-Double(remarkableBackfillDays) * 86400)
        return notebooks.filter { nb in
            if let seen = remarkableSeen(nb.id) { return nb.modified > seen.addingTimeInterval(1) }
            return nb.modified >= window
        }
    }

    /// Transcribes changed notebooks and extracts what they say. Several notebooks go into one `claude -p` call
    /// (at most ~15 pages), which reads the page images with the Read tool, restricted to this run's folder.
    @discardableResult
    public func ingestRemarkable(_ run: inout RunLog, since: Date? = nil, limit: Int = 25, matching: String? = nil) async throws -> ApplyStats {
        guard let reader = RemarkableReader() else {
            throw ClaudeError(message: "reMarkable needs \(RemarkableReader.missing.joined(separator: ", ")). See README → reMarkable.")
        }
        var all = try reader.notebooks()
        if let matching { all = all.filter { $0.name.localizedCaseInsensitiveContains(matching) } }
        let due = Array((matching == nil ? remarkableDue(all, since: since) : all).prefix(limit))
        guard !due.isEmpty else { run.message = "no new handwriting"; return ApplyStats() }
        log("reMarkable: \(due.count) notebook(s) to transcribe")
        let root = claude.workDirectory.appendingPathComponent("remarkable/\(newID())")
        defer { try? FileManager.default.removeItem(at: root) }

        var total = ApplyStats()
        var cost = 0.0
        var batch: [(RemarkableReader.Notebook, [RemarkableReader.Page])] = []
        var failures: [String] = []

        func flush() async {
            guard !batch.isEmpty else { return }
            do {
                let (stats, c) = try await transcribe(batch, root: root)
                total.items += stats.items; total.people += stats.people; total.projects += stats.projects
                total.actions += stats.actions; total.resolved += stats.resolved
                cost += c
                for (nb, _) in batch { store.setMeta("remarkable.seen.\(nb.id)", String(nb.modified.timeIntervalSince1970)) }
            } catch {
                failures.append("\(batch.map(\.0.name).joined(separator: ", ")): \(error)")
                log("reMarkable batch failed: \(error)")
            }
            batch = []
        }

        for nb in due.reversed() {  // oldest first, so later notes can resolve earlier commitments
            let dir = root.appendingPathComponent(nb.id)
            do {
                guard let pages = try reader.pages(of: nb, into: dir), !pages.isEmpty else {
                    store.setMeta("remarkable.seen.\(nb.id)", String(nb.modified.timeIntervalSince1970))
                    continue
                }
                if batch.reduce(0, { $0 + $1.1.count }) + pages.count > 15 { await flush() }
                batch.append((nb, pages))
            } catch {
                failures.append("\(nb.name): \(error)")
            }
        }
        await flush()
        run.message = "\(due.count) notebooks · \(total.description) · $\(String(format: "%.2f", cost))"
            + (failures.isEmpty ? "" : " · failed: \(failures.joined(separator: "; ").prefix(300))")
        if !failures.isEmpty && total.items == 0 { run.ok = false }
        return total
    }

    func transcribe(_ batch: [(RemarkableReader.Notebook, [RemarkableReader.Page])], root: URL) async throws -> (ApplyStats, Double) {
        let list = batch.map { nb, pages in
            """
            --- NOTEBOOK id=\(nb.id) name="\(nb.name)"\(nb.folder.isEmpty ? "" : " folder=\"\(nb.folder)\"") last written \(Prompts.isoString(nb.modified))
            \(pages.map { "page \($0.number): \($0.image.path)" }.joined(separator: "\n"))
            """
        }.joined(separator: "\n\n")
        let task = """
        These are the owner's handwritten notebooks from a reMarkable tablet. Use the Read tool to look at EVERY page image \
        listed (one PNG per page, in order). The owner writes quickly, by hand, in \(OwnerProfile.current.languages) (often mixed in \
        the same line), with abbreviations; "!" around a line marks something important; boxes, arrows and underlines group things.
        Notebook names usually start with the meeting date (YYYYMMDD, sometimes DDMMYYYY) and say who or what it was about \
        ("20261021 - Maria" = a meeting with Maria on 21 Oct 2026).

        For each notebook return ONE item:
        - sourceRef = the notebook id; title = the name without the date, made descriptive if it's just a name \
          ("Meeting with Maria Chen (Initech)"); occurredAt = the date in the name if there is one, otherwise the last-written time; \
          author = the owner.
        - transcript = a faithful transcription of all pages, line by line, in the original language(s). Mark page breaks with \
          "— page N —". Use the directory to read names and terms correctly (a scribble that could be "Maria" in a Initech meeting \
          is Maria); write [?] for a word you can't read rather than guessing.
        - summary, facts, people, projects as for any note: facts in English, attributed ("In the 21 Oct meeting with Maria \
          Chen: …"). Resolve first names through the directory and the notebook name.
        - actions: what the owner wrote as a to-do ("прислать", "send", "надо", "follow up", "check", a "!"-marked line) is a \
          next action for the owner, worded concretely with who it's for; "X will send / X to do" is a waiting action. \
          Notes older than 30 days rarely hold live tasks: only extract those that are clearly still open.

        \(list)
        """
        let dir = Directory(store: store)
        let open = store.all(Action.self).filter { $0.status == .open }
        var call = Claude.Call(prompt: task + "\n\n" + Prompts.extractionRules(directory: dir, openActions: open, today: Prompts.dayString(Date())))
        call.systemPrompt = Prompts.system
        call.builtinTools = ["Read"]
        call.allowedTools = ["Read(/\(root.path)/**)"]
        call.strictMCP = true
        call.mcpConfig = #"{"mcpServers":{}}"#
        call.jsonSchema = Prompts.extractionSchema
        call.label = "remarkable"
        call.timeout = 1500
        let r = try await claude.run(call)
        guard r.structured != nil else { throw ClaudeError(message: "No structured output: \(r.text.prefix(300))") }
        if !r.denials.isEmpty { log("reMarkable: denied \(Set(r.denials).sorted())") }
        let stats = apply(r.structured, source: .remarkable, actionCutoff: Date().addingTimeInterval(-30 * 86400))
        return (stats, r.costUSD)
    }
}
