import Foundation
import JinnieCore

extension Agent {
    /// Two-way sync of actions with Uberdoer:
    /// - work projects get an Uberdoer project under the profile's work folder (matched by name first, created otherwise);
    /// - open actions without a task get one, tagged Jinnie (+ Waiting), titled `Person//What` for waiting items;
    /// - completing/dropping in Uberdoer closes the action here; an action Jinnie saw resolved is completed there.
    /// Idempotent: every task note carries `jinnie:<action id>`, looked up before creating.
    public func syncUberdoer() {
        guard Uberdoer.isInstalled else { log("Uberdoer is not installed; skipping task sync"); return }
        var run = RunLog(kind: "uberdoer")
        var created = 0, closedHere = 0, closedThere = 0, projectsCreated = 0, notesUpdated = 0, errors: [String] = []
        do {
            let ud = try Uberdoer()
            let dir = Directory(store: store)

            // Projects
            let existing = try ud.projects(folder: JinnieConfig.uberdoerWorkFolder)
            for var p in dir.projects where p.uberdoerPath != nil && p.uberdoerID == nil && p.status == .active {
                let match = existing.first { e in
                    let short = e.name.components(separatedBy: " : ").last ?? e.name
                    return ([p.name] + p.aliases).contains { Directory.norm($0) == Directory.norm(short) }
                }
                if let match {
                    p.uberdoerID = match.id
                    p.uberdoerPath = match.name
                } else {
                    p.uberdoerID = try ud.createProject(path: p.uberdoerPath!, note: "Created by Jinnie.\n\(p.description)")
                    projectsCreated += 1
                    log("Created Uberdoer project \(p.uberdoerPath!)")
                }
                store.save(p)
            }
            let projects = Directory(store: store)

            let recent = Date().addingTimeInterval(-30 * 86400)
            for var a in store.all(Action.self) where a.status == .open || a.needsPush == true || a.updatedAt > recent {
                do {
                    if let tid = a.uberdoerID {
                        guard let t = try ud.task(tid) else { continue }
                        if a.needsPush == true {
                            if try pushStatus(&a, task: t, ud: ud) { closedThere += 1 }
                            store.save(a)
                        } else if a.status == .open, !t.isClosed,
                                  try refreshNote(&a, task: t, ud: ud, person: projects.person(id: a.personID)) {
                            store.save(a); notesUpdated += 1
                        } else if t.changed != a.uberdoerChanged {
                            // Edited in Uberdoer: its open/closed state wins.
                            let status: Action.Status = t.status == "dropped" ? .dropped : (t.isClosed ? .done : .open)
                            if status != a.status { a.status = status; if status != .open { closedHere += 1 } }
                            a.uberdoerChanged = t.changed
                            store.save(a)
                        }
                        continue
                    }
                    guard a.status == .open else { continue }
                    let marker = "jinnie:\(a.id)"
                    if let found = try ud.search(marker).first {
                        a.uberdoerID = found.id; a.uberdoerChanged = found.changed; a.syncError = nil
                        store.save(a); continue
                    }
                    let person = projects.person(id: a.personID)
                    let project = projects.project(id: a.projectID)
                    let title = a.kind == .waiting ? "\(person?.name ?? a.personName ?? "Someone")//\(a.title)" : a.title
                    var tags = [JinnieConfig.uberdoerTag]
                    if a.kind == .waiting { tags.append(JinnieConfig.uberdoerWaitingTag) }
                    let body = note(for: a, person: person)
                    let id = try ud.createTask(title: title, note: body, project: project?.uberdoerPath, tags: tags, due: a.due, externalRef: "jinnie:\(a.id)")
                    a.uberdoerNoteHash = Agent.hash(body)
                    a.uberdoerID = id
                    a.uberdoerChanged = try id.flatMap { try ud.task($0)?.changed }
                    a.syncError = nil
                    store.save(a); created += 1
                } catch {
                    a.syncError = "\(error)"
                    store.save(a)
                    errors.append("\(a.title): \(error)")
                }
            }
        } catch {
            errors.append("\(error)")
        }
        run.ok = errors.isEmpty
        run.message = "\(created) tasks created, \(projectsCreated) projects created, \(closedHere) closed from Uberdoer, \(closedThere) closed in Uberdoer, \(notesUpdated) notes updated"
            + (errors.isEmpty ? "" : " · errors: " + errors.prefix(3).joined(separator: "; "))
        run.finishedAt = Date()
        if created + closedHere + closedThere + projectsCreated + notesUpdated > 0 || !errors.isEmpty {
            store.save(run)
            log("Uberdoer: \(run.message)")
        }
    }

    /// Reads Outlook on the web (see OutlookReader) and extracts from what it shows. No tools for the model.
    func ingestOutlook(_ run: inout RunLog) async throws {
        guard OutlookReader.isInstalled else { throw ClaudeError(message: "agent-browser is not installed (npm i -g agent-browser)") }
        let reader = OutlookReader()
        let first = lastRun(.outlook) == nil
        log("Reading Outlook…")
        let inbox = try reader.conversations(folder: "inbox", pages: first ? 10 : 3)
        let sent = try reader.conversations(folder: "sentitems", pages: first ? 5 : 2)
        let events = try reader.events()
        let known = store.all(Item.self).filter { ($0.source == .outlook || $0.sourceRef.hasPrefix("outlook-cal:")) && $0.updatedAt > Date().addingTimeInterval(-3 * 86400) }.map(\.sourceRef)
        let since = lastRun(.outlook).map { $0.addingTimeInterval(-3600) }
        let r = try await extract(task: Prompts.outlook(inbox: inbox, sent: sent, events: events, since: since, knownRefs: known),
                                  tools: [], label: "ingest-outlook")
        let stats = apply(r.structured, source: .outlook, actionCutoff: first ? Date().addingTimeInterval(-30 * 86400) : nil)
        run.message = "\(inbox.count) inbox + \(sent.count) sent conversations, \(events.count) events → \(stats.description) · $\(String(format: "%.2f", r.costUSD))"
        if readsTeamsRecordings {
            do {
                let teams = try ingestTeamsRecordings(reader: reader)
                run.message += " · Teams: " + teams
            } catch {
                log("Teams recordings: \(error)")
                run.message += " · Teams recordings failed: \(error)"
            }
        }
        log("Outlook: \(run.message)")
    }

    /// Makes the Uberdoer task match the action's status (completed, dropped or reopened in Jinnie).
    /// Returns true if the task changed.
    func pushStatus(_ a: inout Action, task t: Uberdoer.TaskInfo, ud: Uberdoer) throws -> Bool {
        let tid = t.id
        var changed = true
        if !t.isClosed && a.status != .open {
            if a.status == .dropped { try ud.drop(tid) } else { try ud.complete(tid) }
        } else if t.isClosed && a.status == .open {
            if t.status == "dropped" { try ud.drop(tid, undo: true) } else { try ud.complete(tid, undo: true) }
        } else if t.isClosed && a.status != .open && (t.status == "dropped") != (a.status == .dropped) {
            if t.status == "dropped" { try ud.drop(tid, undo: true); try ud.complete(tid) }
            else { try ud.complete(tid, undo: true); try ud.drop(tid) }
        } else {
            changed = false
        }
        a.needsPush = nil
        a.uberdoerChanged = try ud.task(tid)?.changed
        return changed
    }

    /// Pushes only status changes made in Jinnie. Cheap, touches nothing else, safe to run during a cycle.
    public func pushStatusChanges() {
        let pending = store.all(Action.self).filter { $0.needsPush == true && $0.uberdoerID != nil }
        guard !pending.isEmpty, Uberdoer.isInstalled, let ud = try? Uberdoer() else { return }
        for var a in pending {
            do {
                guard let t = try ud.task(a.uberdoerID!) else { continue }
                if try pushStatus(&a, task: t, ud: ud) { log("Uberdoer: \(a.status.rawValue) “\(a.title)”") }
                store.save(a)
            } catch { log("Uberdoer push failed for \(a.title): \(error)") }
        }
    }

    /// The task note: links first (Uberdoer shows them as tappable), then enough context to act without
    /// opening anything, then the marker Jinnie uses to find the task again.
    func note(for a: Action, person: Person?) -> String {
        let item = a.itemID.flatMap { store.get(Item.self, $0) }
        let project = Directory(store: store).project(id: a.projectID)
        var lines: [String] = []
        if let url = item?.link { lines.append(url.absoluteString) }
        lines.append(a.jinnieURL)
        lines.append("")
        if let c = a.context, !c.isEmpty { lines.append(c); lines.append("") }
        if let q = a.quote, !q.isEmpty { lines.append("“\(q.trimmingCharacters(in: .whitespacesAndNewlines))”"); lines.append("") }
        if let person {
            let about = [person.role, person.org].compactMap { $0 }.joined(separator: ", ")
            lines.append("\(a.kind == .waiting ? "Waiting on" : "With"): \(person.display)\(about.isEmpty ? "" : " — \(about)")")
        } else if let name = a.personName {
            lines.append("\(a.kind == .waiting ? "Waiting on" : "With"): \(name)")
        }
        if let project { lines.append("Project: \(project.name)") }
        if let due = a.due { lines.append("Due: \(due)") }
        if let item {
            let who = item.author.map { " from \($0)" } ?? ""
            lines.append("Source: \(item.source.label)\(who) — \(item.title) (\(Prompts.dayString(item.occurredAt)))")
            if !item.summary.isEmpty, a.context == nil { lines.append(item.summary) }
            if let docs = item.documents, !docs.isEmpty {
                lines.append("Documents:")
                for d in docs.prefix(5) { lines.append("• \(d.title): \(d.url)") }
            }
        }
        lines.append("")
        lines.append("jinnie:\(a.id)")
        return lines.joined(separator: "\n")
    }

    /// The note format Jinnie wrote before notes carried context (to recognise untouched old notes).
    func legacyNote(for a: Action, person: Person?) -> String {
        var lines: [String] = []
        let item = a.itemID.flatMap { store.get(Item.self, $0) }
        if let url = item?.url { lines.append(url) }
        if let person { lines.append("Person: \(person.display)") }
        if let item {
            lines.append("Source: \(item.source.label) — \(item.title) (\(Prompts.dayString(item.occurredAt)))")
            if !item.summary.isEmpty { lines.append(item.summary) }
        }
        lines.append("jinnie:\(a.id)")
        return lines.joined(separator: "\n")
    }

    /// An old-format note nobody edited: links, "Person:"/"Source:" lines, the marker, and at most one free line
    /// (the item summary Jinnie wrote). Anything more means the user added to it, so it is left alone.
    static func looksLikeLegacyNote(_ note: String, actionID: String) -> Bool {
        guard note.contains("jinnie:\(actionID)") else { return false }
        let free = note.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            !line.isEmpty && !line.hasPrefix("http") && !line.hasPrefix("Person: ") && !line.hasPrefix("Source: ") && !line.hasPrefix("jinnie:")
        }
        return free.count <= 1
    }

    // MARK: - Context for actions created before actions carried it

    static let contextSchema = """
    {"type":"object","required":["actions"],"properties":{"actions":{"type":"array","items":{"type":"object","required":["id","context"],"properties":{
      "id":{"type":"string"},"context":{"type":"string"},"quote":{"type":["string","null"]}}}}}}
    """

    /// Writes context (and a quote where the source has one) for open actions that lack it, from what Jinnie stored.
    public func enrichActions(limit: Int = 40) async {
        let dir = Directory(store: store)
        let todo = store.all(Action.self).filter { $0.status == .open && $0.context == nil }.prefix(limit)
        guard !todo.isEmpty else { return }
        let blocks = todo.map { a -> String in
            let i = a.itemID.flatMap { store.get(Item.self, $0) }
            return """
            --- ACTION id=\(a.id) kind=\(a.kind.rawValue) title="\(a.title)" person=\(dir.person(id: a.personID)?.display ?? a.personName ?? "-") project=\(dir.project(id: a.projectID)?.name ?? "-") due=\(a.due ?? "-")
            source: \(i.map { "\($0.source.label) — \($0.title) (\(Prompts.dayString($0.occurredAt))) from \($0.author ?? "?")" } ?? "none")
            summary: \(i?.summary ?? "")
            facts: \((i?.facts ?? []).joined(separator: " | "))
            excerpt: \(i?.excerpt ?? "")
            """
        }.joined(separator: "\n")
        var call = Claude.Call(prompt: """
        For each action below, write `context`: 2-4 sentences addressed to the owner as "you" (never he/she/his/her for the owner) \
        that they could act on cold (background, who asked or promised and when, \
        why it matters, what done looks like, relevant numbers/dates) using ONLY the information given. If the excerpt contains the \
        exact words where it was asked for or promised, return them as `quote` (≤300 chars), else null.

        \(blocks)
        """)
        call.systemPrompt = Prompts.system
        call.jsonSchema = Agent.contextSchema
        call.strictMCP = true
        call.mcpConfig = #"{"mcpServers":{}}"#
        call.label = "enrich-actions"
        call.model = Agent.routineModel
        call.timeout = 600
        do {
            let r = try await claude.run(call)
            var n = 0
            for o in (r.structured as? [String: Any])?["actions"] as? [[String: Any]] ?? [] {
                guard let id = o["id"] as? String, var a = store.get(Action.self, id), let c = o["context"] as? String, !c.isEmpty else { continue }
                a.context = c
                a.quote = (o["quote"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                store.save(a); n += 1
            }
            log("Added context to \(n) actions")
        } catch { log("Enriching actions failed: \(error)") }
    }

    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.trimmingCharacters(in: .whitespacesAndNewlines).utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// Rewrites the Uberdoer note when Jinnie knows more than it wrote last time — but only if the user hasn't edited it.
    func refreshNote(_ a: inout Action, task t: Uberdoer.TaskInfo, ud: Uberdoer, person: Person?) throws -> Bool {
        let fresh = note(for: a, person: person)
        let freshHash = Agent.hash(fresh)
        guard a.uberdoerNoteHash != freshHash else { return false }
        let current = Agent.hash(t.note)
        let untouched = a.uberdoerNoteHash.map { $0 == current } ?? Agent.looksLikeLegacyNote(t.note, actionID: a.id)
        guard untouched else { return false }
        try ud.setNote(t.id, fresh)
        a.uberdoerNoteHash = freshHash
        a.uberdoerChanged = try ud.task(t.id)?.changed
        return true
    }

    // MARK: - Ask

    static let askSystem = Prompts.system + """

    The owner talks to you through Ask: questions, and requests to do things. When asked to do something, DO IT — don't \
    explain how the owner could do it, and don't ask for confirmation unless the target is genuinely ambiguous:
    - Add a task / remind me / follow up with X → mcp__jinnie__add_action (kind next; kind waiting when someone owes the owner \
      something). Resolve the person and project from the knowledge base first, write a useful context, link item_id if one fits. \
      It appears in Uberdoer automatically; never also create it with Uberdoer tools.
    - Complete / drop / reopen a Jinnie action → mcp__jinnie__update_action. Existing Uberdoer tasks that aren't Jinnie's \
      (no jinnie: marker) → the mcp__uberdoer__* tools (search_tasks first to find the id).
    - Corrections ("Sam is the CTO of Umbrella", "Dana is also Dee") → update_person / update_project. Project roles and \
      replacements ("Ravi replaces Lena as B2B Program Lead") → update_stakeholder for both people (and update_person for the role). \
      Notes to remember → add_note.
    - You cannot send email, post in Slack or change calendars: those stay read-only. Say so briefly if asked, and offer a task instead.
    After acting, reply in one or two lines with what you did (title, person, project, due).

    You answer questions from the Jinnie knowledge base (mcp__jinnie__* tools). Search it first, \
    with several phrasings, in each of the owner's languages (\(OwnerProfile.current.languages)) if useful. Only if the knowledge base lacks the answer, \
    look in Gmail/Slack/Calendar/Drive directly (read-only); for "where is the doc / what did we agree in the meeting" \
    questions, use list_documents and open transcripts in Drive if needed. Be concise and concrete. Cite sources inline as \
    markdown links using the item url when available, otherwise "(Email: <title>, <date>)". If you don't know, say so.
    """

    public func ask(_ question: String, earlier: [Question] = []) async throws -> String {
        var tools = Agent.jinnieTools + Agent.jinnieWriteTools + Agent.uberdoerTools
        for s in Source.connectors where isEnabled(s) {
            tools += (try? await self.tools(for: s)) ?? []
        }
        // Follow-ups ("follow up with him", "add that as a task") need the conversation so far.
        let history = earlier.compactMap { q -> String? in
            guard let ans = q.answer else { return nil }
            return "Owner: \(q.text)\nYou: \(ans.prefix(1500))"
        }.joined(separator: "\n\n")
        let prompt = (history.isEmpty ? "" : "Earlier in this conversation (most recent last):\n\(history)\n\n")
            + "Now: \(question)\n\nToday is \(Prompts.dayString(Date()))."
        var call = Claude.Call(prompt: prompt)
        call.systemPrompt = Agent.askSystem
        call.label = "ask"
        call.mcpConfig = jinnieMCPConfig()
        call.allowedTools = tools
        call.timeout = 600
        let r = try await claude.run(call)
        return r.text
    }

    /// Answers questions asked on any device (e.g. the iPhone) that have no answer yet.
    public func answerQuestions() async {
        for var q in store.all(Question.self) where q.answer == nil && q.error == nil {
            // The fast lane and a background cycle may both get here: each question is answered once.
            guard claimQuestion(q.id) else { continue }
            defer { releaseQuestion(q.id) }
            do {
                // The same conversation: questions from the last 2 hours before this one, oldest first.
                let earlier = store.all(Question.self)
                    .filter { $0.askedAt < q.askedAt && q.askedAt.timeIntervalSince($0.askedAt) < 2 * 3600 && $0.answer != nil }
                    .sorted { $0.askedAt < $1.askedAt }.suffix(6)
                q.answer = try await ask(q.text, earlier: Array(earlier))
                q.answeredAt = Date()
            } catch {
                q.error = "\(error)"
            }
            store.save(q)
        }
    }

    // MARK: - Summaries

    static let summarySystem = Prompts.system + """

    You write project status summaries from the Jinnie knowledge base (mcp__jinnie__* tools). Use get_project, \
    recent_items, list_actions and search. Output markdown only, no preamble:
    **Status** (2-3 sentences, include the date of the latest activity) · **Recent developments** (bullets, newest first, with dates and source links) · \
    **Decisions & key facts** · **Key documents** (markdown links, newest first, with kind — SOW, transcript, deck…) · **My next actions** · **Waiting on others** (Person — what, due) · **Risks / open questions** · **Key contacts** (the 3-6 people who matter most — by how often they appear and what they own — name, role/org, what they're responsible for) · **Other people** (one line).
    Base Key contacts on the project's `stakeholders` from get_project (side, role, former/replacedBy) — they are curated; \
    show our side and the customer's side separately, and mention replacements ("Ravi Shah — B2B Program Lead, replaced Lena Novak").
    Omit empty sections. Be specific; names and dates over adjectives.
    FIGURES AGE: every estimate, price, duration, headcount, percentage or target date must carry the date it was stated and \
    its source ("4.5 months build — 3 Jun estimate"). Before using one, search the knowledge base for later revisions \
    ("revised", "re-planned", "new estimate", "phases", "contingency", "SoW", "proposal", the number itself). The newest \
    statement wins; mention an older one only as superseded ("replaces the 3 Jun 4.5-month plan"). If the latest numbers live \
    in a document Jinnie hasn't read (a proposal PDF, an estimates sheet, a SoW), say so and link it rather than presenting an \
    older figure as current.
    """

    /// Reads a project's history from the sources: threads with its domains, aliases and people, meetings, documents.
    /// First scan goes back `days`; later scans only since the previous one. Old commitments are not turned into actions.
    @discardableResult
    public func scanProject(_ projectID: String, days: Int = 180, full: Bool = false) async throws -> ApplyStats {
        guard let p = store.get(Project.self, projectID) else { throw ClaudeError(message: "Unknown project") }
        let key = "projectScan.\(p.id)"
        let last = full ? nil : store.meta(key).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let since = last.map { $0.addingTimeInterval(-86400) } ?? Date().addingTimeInterval(-Double(days) * 86400)
        var tools: [String] = []
        for s in Source.connectors where isEnabled(s) && s != .slack { tools += (try? await self.tools(for: s)) ?? [] }
        if isEnabled(.slack) { tools += (try? await self.tools(for: .slack)) ?? [] }
        guard !tools.isEmpty else { throw ClaudeError(message: "No connectors available") }
        let dir = Directory(store: store)
        let people = dir.people.filter { $0.projectIDs.contains(p.id) }
        let started = Date()
        var run = RunLog(kind: "scan:\(p.name)")
        store.save(run)
        log("Scanning history of \(p.name) since \(Prompts.dayString(since))…")
        let task = """
        Build the history of the owner's project "\(p.name)" from \(Prompts.dayString(since)) until today.
        Known names: \(([p.name] + p.aliases).joined(separator: ", ")). Client email domains: \(p.domains.isEmpty ? "unknown — discover them" : p.domains.joined(separator: ", ")).
        Known people: \(people.map(\.display).joined(separator: "; ").nilIfEmpty ?? "none yet — discover them").
        \(p.description.isEmpty ? "" : "About: \(p.description)")
        1. Gmail: search with every name and alias, `from:`/`to:` each domain, and the known people's addresses, restricted with \
           `after:\(Prompts.dayString(since).replacingOccurrences(of: "-", with: "/"))`. Follow nextPageToken. Read the substantive threads \
           (up to ~40, most informative first; skim the rest by subject/snippet). One item per thread.
        2. Calendar (if available): meetings in that period whose title or attendees match. One item per meeting series instance that has content.
        3. Drive (if available): documents and meeting transcripts/notes whose names or content match. One item per document.
        4. Slack (if available): conversations mentioning the project or its people.
        Prioritise threads about estimates, pricing, proposals, SoW, timelines, phases, start dates, staffing and approvals: \
        never skip one where a number or date is set or revised. Record EVERY version of a figure as its own dated fact \
        ("On 2026-07-15 the estimate was re-planned into 3 phases; contingency cut from 40% to 30%").
        Attribute every fact. For people, capture role and organisation from signatures and context. List the client's email \
        domains and any other names of the project in projectUpdates. Only extract actions that are still open today.
        """
        do {
            let r = try await extract(task: task, tools: tools, label: "scan-\(p.name)", timeout: 2400)
            let stats = apply(r.structured, source: .email, actionCutoff: Date().addingTimeInterval(-30 * 86400))
            store.setMeta(key, String(started.timeIntervalSince1970))
            run.message = "\(stats.description) · $\(String(format: "%.2f", r.costUSD)) · \(r.durationMs / 1000)s"
            run.finishedAt = Date()
            store.save(run)
            log("\(p.name): \(run.message)")
            return stats
        } catch {
            run.ok = false; run.message = "\(error)"; run.finishedAt = Date(); store.save(run)
            throw error
        }
    }

    public func lastScan(_ projectID: String) -> Date? {
        store.meta("projectScan.\(projectID)").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    static let stakeholderSchema = """
    {"type":"object","required":["stakeholders"],"properties":{"stakeholders":{"type":"array","items":{"type":"object",
      "required":["person","side","role"],"properties":{
        "person":{"type":"string","description":"Exact name or email as in the knowledge base"},
        "side":{"type":"string","enum":["ours","customer","partner","other"],"description":"ours = the owner's own company incl. the owner; customer = the client; partner = e.g. Salesforce"},
        "role":{"type":"string","description":"Their role on THIS project (e.g. 'B2B Program Lead', 'Data migration lead', 'Account Executive')"},
        "responsibilities":{"type":["string","null"],"description":"One line: what they own, decide or deliver here"},
        "key":{"type":"boolean","description":"One of the 3-8 people who matter most"},
        "former":{"type":"boolean","description":"No longer on the project"},
        "replacedBy":{"type":["string","null"],"description":"Name of their replacement, if any"}}}},
      "news":{"type":"array","description":"Latest developments of the last 30 days, newest first, at most 10. One per development (merge items about the same thing).","items":{"type":"object","required":["date","headline","itemIds"],"properties":{
        "date":{"type":"string","description":"YYYY-MM-DD of the development"},
        "headline":{"type":"string","description":"At most 12 words, news style, concrete: who did or decided what"},
        "detail":{"type":["string","null"],"description":"1-2 sentences: what it means for the owner"},
        "itemIds":{"type":"array","items":{"type":"string"},"description":"Jinnie item ids it comes from (from recent_items/get_project)"},
        "important":{"type":"boolean","description":"Changes plans, scope, money, dates or people"}}}},
      "questions":{"type":"array","description":"At most 3 open questions for the owner (see the prompt). Empty if nothing is genuinely unclear.","items":{"type":"object","required":["question","why"],"properties":{
        "question":{"type":"string","description":"One short question the owner can answer in a few words"},
        "why":{"type":"string","description":"One sentence: what you saw that conflicts or is missing, with names, dates, sources"},
        "options":{"type":"array","items":{"type":"string"},"description":"2-4 likely answers, each a few words, when the answer is a choice"},
        "people":{"type":"array","items":{"type":"string"},"description":"Exact names of the people it is about"},
        "itemIds":{"type":"array","items":{"type":"string"},"description":"Jinnie item ids it comes from"}}}}}}
    """

    /// Rebuilds a project's stakeholder map from the knowledge base (people, their roles and notes, the items).
    @discardableResult
    public func refreshStakeholders(projectID: String) async throws -> [Stakeholder] {
        guard let p = store.get(Project.self, projectID) else { throw ClaudeError(message: "Unknown project") }
        let dir = Directory(store: store)
        let current = (p.stakeholders ?? []).compactMap { s -> String? in
            guard let person = dir.person(id: s.personID) else { return nil }
            return "- \(person.name) | \(s.side.rawValue) | \(s.role)\(s.former == true ? " | former" : "")"
        }.joined(separator: "\n")
        var call = Claude.Call(prompt: """
        List the stakeholders of project "\(p.name)" (id \(p.id)) on every side: our team (\(JinnieConfig.ownerName)'s company, \
        including \(JinnieConfig.ownerName) only if the owner has a role here — use the name exactly), the customer, and partners. \
        Use get_project (people with itemCount, roles, notes), get_person for anyone unclear, and search for role words \
        (lead, manager, architect, owner, sponsor, replacing). The owner's own statements (notes) override anything else: \
        e.g. "X is a replacement of Y as <role>" → X current with that role, Y former with replacedBy X. Skip people who only \
        appear in a digest or a CC with nothing to do. Give each a project-specific role; infer it from what they do if not stated.
        Also write `news`: the latest developments from the last 30 days (recent_items with this project, days 30), newest \
        first: decisions, approvals, dates set or moved, deliverables sent, people joining or leaving, risks raised. Not routine \
        meetings where nothing was decided. Refer to the owner as \"You\" (\"You send final demo videos\"), never by name or pronoun. \
        date = when it happened or was announced, never a future meeting's date. Today is \(Prompts.dayString(Date())).
        \(current.isEmpty ? "" : "Current list (keep what is still right, fix what changed):\n\(current)")
        Finally, `questions`: up to 3 things you are genuinely unsure about that the owner can settle in a few words and that         would change the stakeholders, the summary or the tasks. Good questions: which side or company someone is on; whether         a record mixes up two different people (an org or email domain that doesn't fit the project, the same first name in         different companies) or two records are one person; which of two conflicting figures or plans is current ("3 or 4         phases?"); who owns something when sources disagree. Not questions the knowledge base already answers, not trivia,         and none that repeat or rephrase one already asked:
        \(askedQuestions(projectID: p.id))
        """)
        call.systemPrompt = Prompts.system
        call.mcpConfig = jinnieMCPConfig()
        call.strictMCP = true
        call.allowedTools = Agent.jinnieTools
        call.jsonSchema = Agent.stakeholderSchema
        call.label = "brief-\(p.name)"
        call.timeout = 600
        let r = try await claude.run(call)
        var list: [Stakeholder] = []
        for o in (r.structured as? [String: Any])?["stakeholders"] as? [[String: Any]] ?? [] {
            guard let name = o["person"] as? String,
                  let person = dir.person(email: name) ?? dir.person(name: name, projectHint: p.id),
                  !list.contains(where: { $0.personID == person.id }) else { continue }
            var s = Stakeholder(personID: person.id, side: Stakeholder.Side(rawValue: o["side"] as? String ?? "") ?? .other,
                                role: o["role"] as? String ?? "")
            s.responsibilities = (o["responsibilities"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            s.key = o["key"] as? Bool
            s.former = (o["former"] as? Bool) == true ? true : nil
            s.replacedByID = (o["replacedBy"] as? String).flatMap { dir.person(name: $0, projectHint: p.id)?.id }
            list.append(s)
        }
        var news: [NewsItem] = []
        for o in (r.structured as? [String: Any])?["news"] as? [[String: Any]] ?? [] {
            guard let rawDate = o["date"] as? String, let h = o["headline"] as? String, !h.isEmpty else { continue }
            var n = NewsItem(date: String(rawDate.prefix(10)), headline: h,
                             itemIDs: (o["itemIds"] as? [String] ?? []).filter { store.get(Item.self, $0) != nil })
            n.detail = (o["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            n.important = (o["important"] as? Bool) == true ? true : nil
            news.append(n)
        }
        guard var fresh = store.get(Project.self, projectID) else { return list }
        if !list.isEmpty { fresh.stakeholders = list }
        if !news.isEmpty { fresh.news = news.sorted { $0.date > $1.date } }
        store.save(fresh)
        raiseQuestions((r.structured as? [String: Any])?["questions"] as? [[String: Any]] ?? [], projectID: projectID)
        // Everyone listed belongs to the project.
        for s in list {
            if var person = store.get(Person.self, s.personID), !person.isMe, !person.projectIDs.contains(projectID) {
                person.projectIDs.append(projectID); store.save(person)
            }
        }
        log("\(p.name): \(list.count) stakeholders, \(news.count) news")
        return list
    }

    @discardableResult
    public func summarize(projectID: String, scan: ScanPolicy = .ifOlderThan6h) async throws -> Project {
        // A summary is only as good as the history behind it: catch up on the project first.
        let last = lastScan(projectID)
        let needsScan = switch scan {
        case .ifOlderThan6h: last.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true
        case .ifNeverScanned: last == nil
        case .never: false
        }
        if needsScan {
            do { try await scanProject(projectID) } catch { log("Scan before summary failed: \(error)") }
        }
        do { try await refreshStakeholders(projectID: projectID) } catch { log("Stakeholders failed: \(error)") }
        guard var p = store.get(Project.self, projectID) else { throw ClaudeError(message: "Unknown project") }
        var call = Claude.Call(prompt: "Write the summary for project \"\(p.name)\" (id \(p.id)). Today is \(Prompts.dayString(Date())).")
        call.systemPrompt = Agent.summarySystem
        call.label = "summary-\(p.name)"
        call.mcpConfig = jinnieMCPConfig()
        call.strictMCP = true
        call.allowedTools = Agent.jinnieTools
        call.timeout = 600
        let r = try await claude.run(call)
        p.summary = r.text
        p.summaryAt = Date()
        store.save(p)
        return p
    }

    /// Imports the projects in Uberdoer's work folder so mentions resolve from day one.
    public func importUberdoerProjects() throws -> Int {
        let ud = try Uberdoer()
        let dir = Directory(store: store)
        var n = 0
        for (id, path) in try ud.projects(folder: JinnieConfig.uberdoerWorkFolder) {
            let name = path.components(separatedBy: " : ").last ?? path
            if dir.projects.contains(where: { $0.uberdoerID == id || Directory.norm($0.name) == Directory.norm(name) }) { continue }
            var p = Project(name: name)
            p.uberdoerID = id
            p.uberdoerPath = path
            store.save(p)
            n += 1
        }
        return n
    }
}

// MARK: - Bootstrap: learn contacts

extension Agent {
    static let contactsSchema = """
    {"type":"object","required":["people","projectDomains"],"properties":{
      "people":{"type":"array","items":{"type":"object","required":["name","email"],"properties":{
        "name":{"type":"string","description":"Full name; derive from the address if no display name (dana.fischer@… → Dana Fischer)"},
        "email":{"type":"string"},"org":{"type":["string","null"]},"role":{"type":["string","null"]},
        "project":{"type":["string","null"],"description":"Existing project name this person belongs to, if clear"}}}},
      "projectDomains":{"type":"array","items":{"type":"object","required":["project","domain"],"properties":{
        "project":{"type":"string","description":"Existing project name"},"domain":{"type":"string"}}}},
      "newProjects":{"type":"array","items":{"type":"object","required":["name","isWork"],"properties":{
        "name":{"type":"string"},"aliases":{"type":"array","items":{"type":"string"}},"domains":{"type":"array","items":{"type":"string"}},
        "description":{"type":"string"},"isWork":{"type":"boolean"}}}}
    }}
    """

    /// Seeds the people directory from mail metadata (senders/recipients only, no bodies).
    public func learnContacts(days: Int = 180) async throws -> String {
        let tools = try await tools(for: .email)
        guard !tools.isEmpty else { throw ClaudeError(message: "Gmail is not connected") }
        let dir = Directory(store: store)
        var call = Claude.Call(prompt: """
        Build the owner's contact directory from Gmail metadata. Use search_threads with view THREAD_VIEW_METADATA_ONLY \
        (pageSize 50, follow nextPageToken) for `in:sent newer_than:\(days)d` (up to 8 pages) and for \
        `-in:sent newer_than:\(days)d -category:promotions -category:social -category:updates` (up to 4 pages). Do not read bodies.
        Collect real people (skip noreply, notifications, mailing lists, the owner) the owner corresponds with. \
        Map each person's company domain to an existing project when the project obviously is that client \
        (e.g. a 'Acme' project ↔ acme-telco.example) and return those pairs in projectDomains. \
        Only propose newProjects for clients with substantial back-and-forth that match no existing project.

        \(dir.promptText())
        """)
        call.systemPrompt = Prompts.system
        call.allowedTools = tools
        call.jsonSchema = Agent.contactsSchema
        call.timeout = 1500
        call.label = "learn-contacts"
        let r = try await claude.run(call)
        guard let root = r.structured as? [String: Any] else { throw ClaudeError(message: "No structured output") }

        // Reuse the extraction merge for new projects; then domains; then people.
        apply(["items": [], "newProjects": root["newProjects"] ?? []], source: .manual)
        var d = Directory(store: store)
        var domains = 0
        for pd in root["projectDomains"] as? [[String: Any]] ?? [] {
            guard let name = pd["project"] as? String, let domain = (pd["domain"] as? String)?.lowercased(),
                  var p = d.project(named: name), !p.domains.contains(domain) else { continue }
            p.domains.append(domain)
            store.save(p); domains += 1
        }
        d = Directory(store: store)
        var added = 0, updated = 0
        for rp in root["people"] as? [[String: Any]] ?? [] {
            guard let name = rp["name"] as? String, let email = (rp["email"] as? String)?.lowercased(),
                  !JinnieConfig.ownerEmails.contains(email) else { continue }
            var p = d.person(email: email) ?? Person(name: name)
            let isNew = p.emails.isEmpty
            if !p.emails.contains(email) { p.emails.append(email) }
            if p.org == nil { p.org = rp["org"] as? String }
            if p.role == nil { p.role = rp["role"] as? String }
            let proj = (rp["project"] as? String).flatMap { d.project(named: $0) } ?? d.project(forEmail: email)
            if let proj, !p.projectIDs.contains(proj.id) { p.projectIDs.append(proj.id) }
            store.save(p)
            if isNew { added += 1 } else { updated += 1 }
            d = Directory(store: store)
        }
        resolvePendingPeople()
        store.setMeta("contactsLearned", "1")
        return "\(added) people added, \(updated) updated, \(domains) project domains · $\(String(format: "%.2f", r.costUSD))"
    }
}
