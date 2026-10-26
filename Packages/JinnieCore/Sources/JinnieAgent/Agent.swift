import Foundation
import JinnieCore

/// The Mac-side brain: ingests sources through `claude -p`, applies what it learned to the store,
/// keeps Uberdoer in sync, answers questions and writes project summaries.
public final class Agent: @unchecked Sendable {
    public let store: Store
    public var claude: Claude
    /// Path to the `jinnie` binary, used as the MCP server that gives Claude read access to the knowledge base.
    public var jinnieBinary: String
    public var log: (String) -> Void

    private let questionLock = NSLock()
    private var answering = Set<String>()
    func claimQuestion(_ id: String) -> Bool { questionLock.withLock { answering.insert(id).inserted } }
    func releaseQuestion(_ id: String) { questionLock.withLock { _ = answering.remove(id) } }

    public init(store: Store, claude: Claude = Claude(), jinnieBinary: String, log: @escaping (String) -> Void = { print($0) }) {
        self.store = store
        var claude = claude
        claude.onUsage = { [store] label, cost in Usage.record(label: label, cost: cost, store: store) }
        self.claude = claude
        self.jinnieBinary = jinnieBinary
        self.log = log
    }

    // MARK: - Settings (device-local)

    /// Model for routine work (ingest, notes, answers to open questions, task context, tool discovery).
    public static let routineModel = "sonnet"

    public static let sourceIntervals: [Source: TimeInterval] = [.email: 3600, .slack: 3600, .calendar: 6 * 3600, .drive: 3600, .outlook: 1800, .remarkable: 1800]

    /// Weekends: connectors are read at most every `weekendInterval` (default 4 hours; 0 = as on weekdays). Little happens,
    /// and Monday's first run catches up from the last cursor anyway.
    public var weekendInterval: TimeInterval {
        get { store.meta("weekendInterval").flatMap(Double.init) ?? 4 * 3600 }
        set { store.setMeta("weekendInterval", String(newValue)) }
    }

    public func interval(for source: Source, at date: Date = Date()) -> TimeInterval {
        let base = Agent.sourceIntervals[source] ?? 1800
        return Calendar.current.isDateInWeekend(date) ? max(base, weekendInterval) : base
    }

    public func lastRun(_ source: Source) -> Date? {
        store.meta("cursor.\(source.rawValue)").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    func setLastRun(_ source: Source, _ d: Date) { store.setMeta("cursor.\(source.rawValue)", String(d.timeIntervalSince1970)) }

    /// Optional integrations need their own setup (a signed-in browser session, reMarkable tools): off until turned on.
    public static let optionalSources: Set<Source> = [.outlook, .remarkable]

    public func isEnabled(_ source: Source) -> Bool {
        let v = store.meta("enabled.\(source.rawValue)")
        return Agent.optionalSources.contains(source) ? v == "1" : v != "0"
    }
    public func setEnabled(_ source: Source, _ on: Bool) { store.setMeta("enabled.\(source.rawValue)", on ? "1" : "0") }

    /// Days of history the first run of a source reads.
    public var backfillDays: Int { store.meta("backfillDays").flatMap(Int.init) ?? 7 }

    // MARK: - Full cycle

    /// One scheduled pass. `force` ignores per-source intervals ("Sync now").
    public func runCycle(force: Bool = false) async {
        // Nothing to do for nobody: the owner profile comes from the setup assistant.
        guard OwnerProfile.exists else { log("Set up Jinnie first (owner profile missing)"); return }
        ensureOwner()
        // Once: seed people from mail headers so first names resolve from day one.
        if store.meta("contactsLearned") == nil, isEnabled(.email) {
            do {
                let msg = try await learnContacts()
                var run = RunLog(kind: "learn-contacts"); run.message = msg; run.finishedAt = Date(); store.save(run)
                store.setMeta("contactsLearned", "1")
            } catch { log("Learning contacts failed: \(error)") }
        }
        await processNotes()
        await processRecordings()
        if let until = pausedUntil { log("Background reading paused until \(until.formatted(date: .omitted, time: .shortened))"); syncUberdoer(); return }
        for source in Source.connectors where isEnabled(source) {
            let due = lastRun(source).map { Date().timeIntervalSince($0) >= interval(for: source) - 60 } ?? true
            if force || due { await ingest(source) }
        }
        syncUberdoer()
        await answerQuestions()
        await applyClarifications()
        if store.meta("customers.assigned.v2") == nil {
            do { try await assignCustomers() } catch { log("Customers: \(error)") }
        }
        if prospectsDue {
            do { try await discoverProspects() } catch { log("Prospects: \(error)") }
        }
        await summarizeRequested()
        await refreshSummaries()
        await enrichActions()
        syncUberdoer()  // actions found by first-time project scans; richer notes
    }

    /// Summaries requested from another device (or never written yet for projects with fresh activity).
    public enum ScanPolicy: Sendable { case ifOlderThan6h, ifNeverScanned, never }

    public var autoSummaries: Bool {
        get { store.meta("autoSummaries") != "0" }
        set { store.setMeta("autoSummaries", newValue ? "1" : "0") }
    }

    /// Projects whose summary should be (re)written now, most recently active first:
    /// - learned about (has items) but never summarised;
    /// - new items or actions since the last summary, at most every 2 hours;
    /// - active in the last 30 days and the summary is over a day old (dates and overdue items move).
    public static func projectsNeedingSummary(projects: [Project], items: [Item], actions: [Action], now: Date = Date()) -> [Project] {
        var latest: [String: Date] = [:]
        for i in items { for pid in i.projectIDs { latest[pid] = max(latest[pid] ?? .distantPast, i.updatedAt) } }
        for a in actions { if let pid = a.projectID { latest[pid] = max(latest[pid] ?? .distantPast, a.updatedAt) } }
        return projects.filter { p in
            guard p.status == .active, let activity = latest[p.id] else { return false }
            guard let at = p.summaryAt else { return true }
            let age = now.timeIntervalSince(at)
            // Easy on the plan's limits: new activity refreshes at most twice a day; otherwise daily, while active this week.
            if activity > at && age > 12 * 3600 { return true }
            return age > 24 * 3600 && now.timeIntervalSince(activity) < 7 * 86400
        }
        .sorted { (latest[$0.id] ?? .distantPast) > (latest[$1.id] ?? .distantPast) }
    }

    /// Keeps summaries fresh without being asked. A project seen for the first time gets its history scanned first.
    public func refreshSummaries(max: Int = 1) async {
        guard autoSummaries else { return }
        let items = store.all(Item.self)
        let due = Agent.projectsNeedingSummary(projects: store.all(Project.self), items: items, actions: store.all(Action.self))
        for p in due.prefix(max) {
            log("Refreshing summary of \(p.name)…")
            // A history scan costs a lot: only automatically for projects with real recent activity.
            let recent = items.filter { $0.projectIDs.contains(p.id) && $0.occurredAt > Date().addingTimeInterval(-14 * 86400) }.count
            let policy: ScanPolicy = recent >= 3 ? .ifNeverScanned : .never
            do { try await summarize(projectID: p.id, scan: policy) } catch { log("Summary for \(p.name) failed: \(error)") }
        }
    }

    // MARK: - Pause (limits)

    /// Background reading is paused until this time (the "Pause for today" menu item); notes, questions and Ask still run.
    public var pausedUntil: Date? {
        get { store.meta("pausedUntil").flatMap(Double.init).map(Date.init(timeIntervalSince1970:)).flatMap { $0 > Date() ? $0 : nil } }
        set { store.setMeta("pausedUntil", newValue.map { String($0.timeIntervalSince1970) }) }
    }

    public func summarizeRequested() async {
        for p in store.all(Project.self) where p.summaryRequestedAt.map({ $0 > (p.summaryAt ?? .distantPast) }) ?? false {
            do { try await summarize(projectID: p.id) } catch { log("Summary for \(p.name) failed: \(error)") }
        }
    }

    // MARK: - Ingest

    public func ingest(_ source: Source) async {
        var run = RunLog(kind: "ingest:\(source.rawValue)")
        store.save(run)
        let started = Date()
        do {
            if source == .outlook || source == .remarkable {
                if source == .outlook { try await ingestOutlook(&run) } else { try await ingestRemarkable(&run) }
                setLastRun(source, started)
                run.finishedAt = Date()
                store.save(run)
                return
            }
            let tools = try await tools(for: source)
            guard !tools.isEmpty else {
                if needsSignIn(source) {
                    throw ClaudeError(message: "\(source.label) is signed out in claude.ai. Reconnect it in claude.ai → Settings → Connectors, then Jinnie → Settings → Setup → Check connectors.")
                }
                throw ClaudeError(message: "No \(source.label) tools available. Connect \(source.label) in claude.ai → Settings → Connectors.")
            }
            let since = lastRun(source).map { $0.addingTimeInterval(-3600) } ?? Date().addingTimeInterval(-Double(backfillDays) * 86400)
            if source == .drive {
                log("Ingesting Drive since \(Prompts.isoString(since))…")
                let r = try await ingestDrive(since: since, tools: tools)
                setLastRun(source, started)
                run.message = "\(r.stats.description) · read \(r.files) files\(r.left > 0 ? ", \(r.left) left for the next sync" : "") · $\(String(format: "%.2f", r.cost))"
                log("Drive: \(run.message)")
                run.finishedAt = Date()
                store.save(run)
                return
            }
            let known = recentRefs(source, days: 3)
            let fetch: String
            switch source {
            case .email: fetch = Prompts.email(since: since, knownRefs: known)
            case .slack: fetch = Prompts.slack(since: since, knownRefs: known)
            case .calendar: fetch = Prompts.calendar(from: Date().addingTimeInterval(-86400 * 2), to: Date().addingTimeInterval(86400 * 7))
            default: return
            }
            log("Ingesting \(source.label) since \(Prompts.isoString(since))…")
            let result = try await extract(task: fetch, tools: tools, label: "ingest-\(source.rawValue)")
            let stats = apply(result.structured, source: source)
            setLastRun(source, started)
            run.message = "\(stats.description) · $\(String(format: "%.2f", result.costUSD)) · \(result.durationMs / 1000)s"
            if !result.denials.isEmpty { run.message += " · denied: \(Set(result.denials).sorted().joined(separator: ", "))" }
            log("\(source.label): \(run.message)")
        } catch {
            run.ok = false
            run.message = "\(error)"
            if run.message.hasPrefix("Signed out in claude.ai") {
                run.message = "\(source.label) is signed out in claude.ai. Reconnect it in claude.ai → Settings → Connectors."
                _ = try? await tools(for: source, refresh: true)   // records the sign-in state for Setup
            }
            log("\(source.label) failed: \(error)")
        }
        run.finishedAt = Date()
        store.save(run)
    }

    public func processNotes() async {
        let pending = store.all(Note.self).filter { $0.processedAt == nil && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.createdAt < $1.createdAt }
        guard !pending.isEmpty else { return }
        var run = RunLog(kind: "notes")
        store.save(run)
        for batch in stride(from: 0, to: pending.count, by: 15).map({ Array(pending[$0..<min($0 + 15, pending.count)]) }) {
            do {
                log("Processing \(batch.count) note(s)…")
                let result = try await extract(task: Prompts.notes(batch), tools: [], label: "notes")
                let stats = apply(result.structured, source: .note)
                for var n in batch {
                    n.processedAt = Date()
                    n.processError = nil
                    n.itemID = store.find(Item.self, key: "note:\(n.id)")?.id
                    store.save(n)
                }
                run.message = stats.description
            } catch {
                for var n in batch { n.processError = "\(error)"; store.save(n) }
                run.ok = false
                run.message = "\(error)"
                log("Notes failed: \(error)")
            }
        }
        run.finishedAt = Date()
        store.save(run)
    }

    func extract(task: String, tools: [String], label: String, timeout: TimeInterval = 1200) async throws -> ClaudeResult {
        let dir = Directory(store: store)
        let open = store.all(Action.self).filter { $0.status == .open }
        var call = Claude.Call(prompt: task + "\n\n" + Prompts.extractionRules(directory: dir, openActions: open, today: Prompts.dayString(Date())))
        call.systemPrompt = Prompts.system
        call.allowedTools = tools
        call.jsonSchema = Prompts.extractionSchema
        call.timeout = timeout
        call.label = label
        // Routine reads use the cheaper model; history scans keep the default (they decide what a project is about).
        if !label.hasPrefix("scan-") { call.model = Agent.routineModel }
        if tools.isEmpty { call.strictMCP = true; call.mcpConfig = #"{"mcpServers":{}}"# }
        let result = try await claude.run(call)
        try Agent.checkConnectorsReached(result, tools: tools)
        guard result.structured != nil else { throw ClaudeError(message: "No structured output: \(result.text.prefix(300))") }
        return result
    }

    /// A run that needed connector tools but never got one (claude.ai lists a signed-out connector without tools) must
    /// fail, not report "0 items": otherwise a signed-out connector looks like a quiet inbox.
    static func checkConnectorsReached(_ r: ClaudeResult, tools: [String]) throws {
        let connectorTools = tools.filter { $0.hasPrefix("mcp__claude_ai_") }
        guard !connectorTools.isEmpty, !r.usedAny(connectorTools),
              r.toolResults("ToolSearch").contains(where: { $0.contains("No matching deferred tools") }) else { return }
        throw ClaudeError(message: "Signed out in claude.ai: the connector offered no tools. Reconnect it in claude.ai → Settings → Connectors.")
    }

    func recentRefs(_ source: Source, days: Double) -> [String] {
        let cutoff = Date().addingTimeInterval(-days * 86400)
        return store.all(Item.self).filter { $0.source == source && $0.updatedAt > cutoff }.map(\.sourceRef)
    }

    // MARK: - Apply extraction

    public struct ApplyStats: CustomStringConvertible {
        public var items = 0, people = 0, projects = 0, actions = 0, resolved = 0
        public var description: String {
            "\(items) items, \(people) new people, \(projects) new projects, \(actions) new actions, \(resolved) resolved"
        }
    }

    /// Merges an extraction result into the store. Identity is decided here, not by the model:
    /// people by email then name, projects by name/alias/domain, items by source ref, actions by fuzzy title.
    @discardableResult
    public func apply(_ structured: Any?, source: Source, actionCutoff: Date? = nil) -> ApplyStats {
        var stats = ApplyStats()
        guard let root = structured as? [String: Any] else { return stats }
        var dir = Directory(store: store)

        // Directory updates (aliases, domains, roles) first, so this very batch already resolves with them.
        for u in root["projectUpdates"] as? [[String: Any]] ?? [] {
            guard let name = u["project"] as? String, var p = dir.project(named: name) else { continue }
            p.aliases = merge(p.aliases, (u["addAliases"] as? [String])?.filter { Directory.norm($0) != Directory.norm(p.name) })
            p.domains = merge(p.domains, (u["addDomains"] as? [String])?.map { $0.lowercased() })
            if p.description.isEmpty, let d = u["description"] as? String, !d.isEmpty { p.description = d }
            store.save(p)
            log("Project \(p.name): aliases \(p.aliases), domains \(p.domains)")
            dir = Directory(store: store)
        }
        for u in root["personUpdates"] as? [[String: Any]] ?? [] {
            guard let name = u["name"] as? String else { continue }
            let email = (u["email"] as? String)?.lowercased()
            guard var p = dir.resolvePerson(name: name, email: email) else { continue }
            if let r = u["role"] as? String, !r.isEmpty { p.role = r }
            if let o = u["org"] as? String, !o.isEmpty { p.org = o }
            p.aliases = merge(p.aliases, u["addAliases"] as? [String])
            if let pn = u["project"] as? String, let proj = dir.project(named: pn), !p.projectIDs.contains(proj.id) { p.projectIDs.append(proj.id) }
            store.save(p)
            // A changed role reshapes the project's stakeholder map: ask for a refresh now, not at the daily one.
            if u["role"] != nil {
                for pid in p.projectIDs { if var proj = store.get(Project.self, pid) { proj.summaryRequestedAt = Date(); store.save(proj) } }
            }
            dir = Directory(store: store)
        }

        // New projects next, so items can link to them.
        for np in root["newProjects"] as? [[String: Any]] ?? [] {
            guard let name = (np["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            if var existing = dir.project(named: name) {
                existing.aliases = merge(existing.aliases, np["aliases"] as? [String])
                existing.domains = merge(existing.domains, np["domains"] as? [String])
                if existing.customerID == nil, let c = np["customer"] as? String {
                    existing.customerID = customerID(named: c, domains: existing.domains, prospect: np["customerIsProspect"] as? Bool)
                }
                store.save(existing)
                dir = Directory(store: store)
                continue
            }
            var p = Project(name: name)
            p.aliases = np["aliases"] as? [String] ?? []
            p.domains = (np["domains"] as? [String] ?? []).map { $0.lowercased() }
            p.description = np["description"] as? String ?? ""
            if (np["isWork"] as? Bool) ?? true { p.uberdoerPath = "\(JinnieConfig.uberdoerWorkFolder) : \(name)" }
            if let c = np["customer"] as? String { p.customerID = customerID(named: c, domains: p.domains, prospect: np["customerIsProspect"] as? Bool) }
            store.save(p)
            stats.projects += 1
            log("New project: \(name)")
            dir = Directory(store: store)
        }

        for raw in root["items"] as? [[String: Any]] ?? [] {
            guard let ref = raw["sourceRef"] as? String, !ref.isEmpty else { continue }
            // Notes and notebooks are one source each; connectors reading several sources say which per item.
            let source = [.note, .remarkable, .recording].contains(source) ? source : ((raw["source"] as? String).flatMap(Source.init(rawValue:)) ?? source)
            let occurred = (raw["occurredAt"] as? String).flatMap(parseISODate) ?? Date()
            var item = store.find(Item.self, key: "\(source.rawValue):\(ref)")
                ?? Item(source: source, sourceRef: ref, title: raw["title"] as? String ?? "", occurredAt: occurred)
            item.title = raw["title"] as? String ?? item.title
            item.url = (raw["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? item.url
            item.author = raw["author"] as? String ?? item.author
            item.authorEmail = (raw["authorEmail"] as? String)?.lowercased() ?? item.authorEmail
            item.occurredAt = max(item.occurredAt, occurred)
            if let e = raw["excerpt"] as? String, !e.isEmpty { item.excerpt = String(e.prefix(800)) }
            item.summary = raw["summary"] as? String ?? item.summary
            if let t = raw["transcript"] as? String, !t.isEmpty { item.text = t }
            item.facts = merge(item.facts, raw["facts"] as? [String])
            var docs = item.documents ?? []
            for d in raw["documents"] as? [[String: Any]] ?? [] {
                guard let url = d["url"] as? String, url.hasPrefix("http"), !docs.contains(where: { $0.url == url }) else { continue }
                docs.append(DocLink(title: d["title"] as? String ?? url, url: url, kind: d["kind"] as? String))
            }
            item.documents = docs.isEmpty ? nil : docs

            // Projects
            var projectIDs = Set(item.projectIDs)
            for name in raw["projects"] as? [String] ?? [] {
                if let p = dir.project(named: name) { projectIDs.insert(p.id) }
            }
            if let email = item.authorEmail, let p = dir.project(forEmail: email) { projectIDs.insert(p.id) }

            // People
            var personIDs = Set(item.personIDs)
            for rp in raw["people"] as? [[String: Any]] ?? [] {
                guard let name = (rp["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
                let email = (rp["email"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces)
                if let email, JinnieConfig.ownerEmails.contains(email) { continue }
                if Directory.norm(name) == Directory.norm(JinnieConfig.ownerName) { continue }
                var person = dir.resolvePerson(name: name, email: email, projectHint: projectIDs.first)
                let isNew = person == nil
                if person == nil, email == nil, name.split(separator: " ").count < 2 { continue } // a bare unknown first name: too ambiguous to create
                var p = person ?? Person(name: name)
                if let email, !email.isEmpty, !p.emails.contains(email) { p.emails.append(email) }
                if name.split(separator: " ").count > p.name.split(separator: " ").count { p.aliases = merge(p.aliases, [p.name]); p.name = name }
                if p.org == nil, let org = rp["org"] as? String, !org.isEmpty { p.org = org }
                if p.role == nil, let role = rp["role"] as? String, !role.isEmpty { p.role = role }
                p.aliases = merge(p.aliases, rp["aliases"] as? [String])
                if let email, let proj = dir.project(forEmail: email) { projectIDs.insert(proj.id) }
                person = p
                personIDs.insert(p.id)
                if isNew { stats.people += 1 }
                store.save(p)
                dir = Directory(store: store)
            }
            // People seen on a project's item belong to it (only when the item has a single project).
            if projectIDs.count == 1, let pid = projectIDs.first {
                for id in personIDs {
                    if var p = dir.person(id: id), !p.projectIDs.contains(pid) { p.projectIDs.append(pid); store.save(p) }
                }
                dir = Directory(store: store)
            }
            item.projectIDs = Array(projectIDs)
            item.personIDs = Array(personIDs)
            item = store.save(item)
            stats.items += 1

            // Actions
            for ra in raw["actions"] as? [[String: Any]] ?? [] {
                guard let title = (ra["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { continue }
                let kind = Action.Kind(rawValue: ra["kind"] as? String ?? "next") ?? .next
                let projectID = (ra["project"] as? String).flatMap { dir.project(named: $0)?.id } ?? (projectIDs.count == 1 ? projectIDs.first : nil)
                let person = dir.resolvePerson(name: ra["person"] as? String, email: (ra["personEmail"] as? String)?.lowercased(), projectHint: projectID)
                let mentioned = (ra["person"] as? String)?.trimmingCharacters(in: .whitespaces)
                if kind == .waiting && person == nil && (mentioned ?? "").isEmpty { log("Skipped waiting action without a person: \(title)"); continue }
                var a = Action(kind: kind, title: title)
                if person == nil, let mentioned, !mentioned.isEmpty { a.personName = mentioned }
                a.projectID = projectID ?? person.flatMap { $0.projectIDs.count == 1 ? $0.projectIDs[0] : nil }
                a.personID = person?.id
                a.due = (ra["due"] as? String).flatMap { $0.count >= 10 ? String($0.prefix(10)) : nil }
                a.itemID = item.id
                a.context = (ra["context"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (item.summary.isEmpty ? nil : item.summary)
                a.quote = (ra["quote"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(400)) }
                if isDuplicate(a) { continue }
                // History scans read months back: only commitments from the last month can still be live.
                if let cutoff = actionCutoff, item.occurredAt < cutoff { continue }
                store.save(a)
                stats.actions += 1
            }
            for id in raw["resolvesActionIDs"] as? [String] ?? [] {
                if var a = store.get(Action.self, id), a.status == .open {
                    a.status = .done
                    a.needsPush = true
                    store.save(a)
                    stats.resolved += 1
                }
            }
        }
        resolvePendingPeople()
        return stats
    }

    /// Actions that named someone unknown at the time get linked once that person is learned.
    func resolvePendingPeople() {
        let dir = Directory(store: store)
        for var a in store.all(Action.self) where a.personID == nil && a.personName != nil {
            if let p = dir.person(name: a.personName!, projectHint: a.projectID) {
                a.personID = p.id
                a.personName = nil
                if a.projectID == nil, p.projectIDs.count == 1 { a.projectID = p.projectIDs[0] }
                store.save(a)
            }
        }
    }

    func isDuplicate(_ a: Action) -> Bool {
        let words = Agent.wordSet(a.title)
        return store.all(Action.self).contains { b in
            guard b.kind == a.kind, b.personID == a.personID, b.personName == a.personName, b.status == .open || b.updatedAt > Date().addingTimeInterval(-14 * 86400) else { return false }
            let w = Agent.wordSet(b.title)
            let overlap = Double(words.intersection(w).count) / Double(max(1, min(words.count, w.count)))
            return overlap >= 0.75
        }
    }

    static func wordSet(_ s: String) -> Set<String> {
        Set(Directory.norm(s).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
    }

    func merge(_ a: [String], _ b: [String]?) -> [String] {
        var out = a
        for x in b ?? [] where !x.isEmpty && !out.contains(where: { Directory.norm($0) == Directory.norm(x) }) { out.append(x) }
        return out
    }

    // MARK: - Owner

    func ensureOwner() {
        guard OwnerProfile.exists, !store.all(Person.self).contains(where: \.isMe) else { return }
        var me = Person(name: JinnieConfig.ownerName)
        me.emails = JinnieConfig.ownerEmails
        me.isMe = true
        me.org = OwnerProfile.current.organization.nilIfEmpty
        store.save(me)
    }

    // MARK: - Tool discovery

    /// Allow-list, not deny-list: a tool is usable only if its verb reads (get/list/search/read…) and no
    /// part of its name writes. Anything new or unexpected stays out until it is reviewed here.
    static let readVerbs: Set<String> = ["get", "list", "search", "read", "find", "fetch", "query", "lookup", "view", "describe", "download", "export"]
    static let writeWords: Set<String> = ["send", "reply", "forward", "create", "update", "delete", "trash", "untrash", "remove",
                                          "label", "unlabel", "spam", "mark", "unmark", "post", "schedule", "respond", "add", "edit",
                                          "move", "archive", "invite", "react", "upload", "set", "write", "cancel", "modify", "patch",
                                          "apply", "authenticate", "draft", "share", "permission", "permissions", "copy", "rename", "restore"]

    static func isReadOnly(_ action: String) -> Bool {
        var words = action.lowercased().split(separator: "_").map(String.init)
        if words.first == "slack" || words.first == "gcal" { words.removeFirst() }
        guard let verb = words.first, readVerbs.contains(verb) else { return false }
        return !words.contains { writeWords.contains($0) || $0.hasSuffix("draft") || $0.hasSuffix("drafts") }
    }

    static let serverPrefixes: [Source: String] = [
        .email: "mcp__claude_ai_Gmail__",
        .slack: "mcp__claude_ai_Slack__",
        .calendar: "mcp__claude_ai_Google_Calendar__",
        .drive: "mcp__claude_ai_Google_Drive__",
    ]

    /// Read-only tool names of the connector for `source`. Names come from the connector itself
    /// (asked once a day); anything that looks like a write is excluded before Claude ever sees it.
    /// The connector exists in claude.ai but needs signing in again (from the last tool discovery).
    public func needsSignIn(_ source: Source) -> Bool { store.meta("tools.\(source.rawValue).auth") == "1" }

    public func tools(for source: Source, refresh: Bool = false) async throws -> [String] {
        guard let prefix = Agent.serverPrefixes[source] else { return [] }  // e.g. Outlook: read by OutlookReader, not a connector
        let key = "tools.\(source.rawValue)"
        // Cached for a day, including "none" (a connector that isn't connected isn't re-checked every cycle).
        if !refresh, let cached = store.meta(key), let at = store.meta(key + ".at").flatMap(Double.init),
           Date().timeIntervalSince1970 - at < 86400 {
            return cached.split(separator: ",").map(String.init)
        }
        var call = Claude.Call(prompt: "Use ToolSearch (query \"+\(prefix.dropFirst("mcp__claude_ai_".count).dropLast(2))\", max_results 60; try other queries if needed) to find every deferred tool whose name starts with `\(prefix)`. Return all exact names. Do not call those tools.")
        call.jsonSchema = Prompts.toolDiscoverySchema
        call.label = "tools-\(source.rawValue)"
        call.model = Agent.routineModel
        call.timeout = 180
        let r = try await claude.run(call)
        let all = ((r.structured as? [String: Any])?["tools"] as? [String] ?? []).filter { $0.hasPrefix(prefix) }
        // A connector that is added in claude.ai but signed out (or whose access expired) only offers `authenticate`.
        store.setMeta(key + ".auth", all.contains { $0.hasSuffix("__authenticate") } ? "1" : nil)
        let readOnly = all.filter { name in
            Agent.isReadOnly(String(name.dropFirst(prefix.count)))
        }
        store.setMeta(key, readOnly.joined(separator: ","))
        store.setMeta(key + ".at", String(Date().timeIntervalSince1970))
        log("\(source.label) read-only tools: \(readOnly.joined(separator: ", "))")
        return readOnly
    }

    // MARK: - MCP config for retrieval

    func jinnieMCPConfig() -> String {
        let cfg: [String: Any] = ["mcpServers": ["jinnie": ["type": "stdio", "command": jinnieBinary, "args": ["mcp"],
                                                             "env": ["JINNIE_HOME": JinnieConfig.supportDirectory().path]]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: cfg), as: UTF8.self)
    }

    static let jinnieTools = ["mcp__jinnie__search", "mcp__jinnie__get_project", "mcp__jinnie__get_person",
                              "mcp__jinnie__list_actions", "mcp__jinnie__recent_items", "mcp__jinnie__get_item", "mcp__jinnie__list_projects",
                              "mcp__jinnie__list_documents", "mcp__jinnie__list_open_questions", "mcp__jinnie__list_recordings"]
    static let jinnieWriteTools = ["mcp__jinnie__add_action", "mcp__jinnie__update_action", "mcp__jinnie__update_person",
                                   "mcp__jinnie__update_project", "mcp__jinnie__add_note", "mcp__jinnie__update_stakeholder",
                                   "mcp__jinnie__create_person", "mcp__jinnie__move_person_links", "mcp__jinnie__merge_people",
                                   "mcp__jinnie__remove_person_from_project", "mcp__jinnie__name_speaker"]
    /// The user's Uberdoer MCP server (user scope), for tasks Jinnie didn't create.
    static let uberdoerTools = ["search_tasks", "get_task", "list_projects", "list_tags", "get_perspective_items", "list_perspectives",
                                "create_task", "update_task", "complete_task", "drop_task"].map { "mcp__uberdoer__" + $0 }
}
