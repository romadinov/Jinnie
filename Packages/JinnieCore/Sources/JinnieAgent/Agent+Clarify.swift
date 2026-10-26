import Foundation
import JinnieCore

// MARK: - Open questions: Jinnie asks, the owner answers, the Mac applies

extension Agent {
    /// Questions already raised for a project (any status), for the prompt, so the model doesn't ask them again.
    func askedQuestions(projectID: String) -> String {
        let list = store.all(Clarification.self).filter { $0.projectID == projectID }.sorted { $0.createdAt < $1.createdAt }
        guard !list.isEmpty else { return "(none yet)" }
        return list.map { c in "- \(c.question)" + (c.answer.map { " → answered: \($0)" } ?? (c.status == .dismissed ? " → skipped" : "")) }
            .joined(separator: "\n")
    }

    /// Saves new questions from a project brief: no near-duplicates of earlier ones, at most 3 open per project.
    func raiseQuestions(_ raw: [[String: Any]], projectID: String?) {
        let dir = Directory(store: store)
        let existing = store.all(Clarification.self).filter { $0.projectID == projectID }
        var open = existing.filter { $0.status == .open }.count
        var added = 0
        for o in raw {
            guard open < 3, let text = (o["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let words = Agent.wordSet(text)
            let repeated = existing.contains { c in
                let w = Agent.wordSet(c.question)
                return Double(words.intersection(w).count) / Double(max(1, min(words.count, w.count))) >= 0.6
            }
            if repeated { continue }
            var c = Clarification(question: text)
            c.why = (o["why"] as? String)?.nilIfEmpty
            c.options = (o["options"] as? [String]).flatMap { $0.isEmpty ? nil : Array($0.prefix(4)) }
            c.projectID = projectID
            c.personIDs = (o["people"] as? [String] ?? []).compactMap { dir.person(email: $0)?.id ?? dir.person(name: $0, projectHint: projectID)?.id }.nilIfEmptyArray
            c.itemIDs = (o["itemIds"] as? [String] ?? []).filter { store.get(Item.self, $0) != nil }.nilIfEmptyArray
            store.save(c)
            open += 1; added += 1
        }
        if added > 0 { log("Raised \(added) open question(s)") }
    }

    static let clarifySystem = Prompts.system + """

    Earlier you asked the owner a question to validate what Jinnie knows; the owner has answered. Make Jinnie's knowledge \
    base match the answer, using the mcp__jinnie__* tools. Look things up first (get_person, get_project, search) and use \
    ids where names are ambiguous. The owner's answer overrides anything in the sources. Typical fixes:
    - Someone's side, company or role → update_person (org, role) and update_stakeholder (side, role) on the project.
    - One record mixes up two different people (e.g. a school contact merged with a client contact who shares a first name) \
      → create_person for the right one, move_person_links from the wrong record to them with the project (plus item_ids \
      for related items outside the project, e.g. DMs), take the wrong emails and aliases off the other record \
      (update_person remove_emails / remove_aliases), and update_stakeholder for the new person.
    - Two records are the same person → merge_people.
    - A figure, plan or fact ("3 phases, not 4") → nothing to edit; it is recorded as a dated fact from the owner.
    Don't touch email, Slack, calendars or Uberdoer. Only write notes on a person when they add something; refer to \
    people by name or "they" there too (never "he"/"she"), and fix earlier notes with replace_notes if they are wrong.
    Return `result` (shown to the owner): one or two lines saying what you changed (names, roles, projects), and `fact`: the answer restated as \
    one self-contained, attributable statement ("Maria Chen (Salesforce) is the account lead for Initech"). \
    In both, and in anything you write, refer to people by name or "they": never "he", "she", "his", "her".
    """

    static let clarifyResultSchema = """
    {"type":"object","required":["result","fact"],"properties":{"result":{"type":"string"},"fact":{"type":"string"}}}
    """

    /// Applies answers given on any device, up to three at a time (each is a short, independent run), picking up answers
    /// that arrive meanwhile.
    public func applyClarifications(maxConcurrent: Int = 3) async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while true {
                while running < maxConcurrent, let c = claimNextAnswer() {
                    running += 1
                    group.addTask {
                        await self.applyClarification(c)
                        self.releaseQuestion(c.id)
                    }
                }
                if running == 0 { break }
                await group.next()
                running -= 1
            }
        }
    }

    /// The next answered question nobody is applying: claimed in memory and in the database (the CLI shares it).
    func claimNextAnswer() -> Clarification? {
        for c in store.all(Clarification.self).sorted(by: { ($0.answeredAt ?? .distantPast) < ($1.answeredAt ?? .distantPast) })
        where c.status == .answered && c.error == nil {
            guard claimQuestion(c.id) else { continue }
            guard var fresh = store.get(Clarification.self, c.id), fresh.status == .answered,
                  fresh.applyingAt.map({ Date().timeIntervalSince($0) > 900 }) ?? true else { releaseQuestion(c.id); continue }
            fresh.applyingAt = Date()
            store.save(fresh)
            return fresh
        }
        return nil
    }

    func applyClarification(_ c: Clarification) async {
        var c = c
        let dir = Directory(store: store)
        let project = dir.project(id: c.projectID)
        let people = (c.personIDs ?? []).compactMap { dir.person(id: $0) }.map { "\($0.display) [id \($0.id)]" }
        var call = Claude.Call(prompt: """
        Question you asked\(project.map { " about project \"\($0.name)\"" } ?? ""): \(c.question)
        \(c.why.map { "Why you asked: \($0)" } ?? "")
        \(people.isEmpty ? "" : "People it concerns: \(people.joined(separator: "; "))")
        \(c.previousAnswer.map { """
        The owner CHANGED their answer. Earlier answer: \($0)
        What you changed for it then: \(c.previousResult ?? "unknown")
        First undo those changes where they are wrong under the new answer (look the records up; split or move what was \
        merged or moved, restore sides, roles and notes), then apply the new answer.
        """ } ?? "")
        The owner's answer: \(c.answer ?? "")
        Today is \(Prompts.dayString(Date())).
        """)
        call.systemPrompt = Agent.clarifySystem
        call.mcpConfig = jinnieMCPConfig()
        call.strictMCP = true
        call.allowedTools = Agent.jinnieTools + Agent.jinnieWriteTools
        call.jsonSchema = Agent.clarifyResultSchema
        call.label = "clarify"
        call.model = Agent.routineModel
        call.timeout = 600
        do {
            let r = try await claude.run(call)
            let o = r.structured as? [String: Any] ?? [:]
            let fact = (o["fact"] as? String)?.nilIfEmpty ?? "\(c.question) — \(c.answer ?? "")"
            // A changed answer replaces the recorded one.
            var item = store.all(Item.self).first { $0.sourceRef == "clarification:\(c.id)" }
                ?? Item(source: .note, sourceRef: "clarification:\(c.id)", title: "Answer: \(c.question)", occurredAt: c.answeredAt ?? Date())
            item.occurredAt = c.answeredAt ?? Date()
            item.author = JinnieConfig.ownerName
            item.summary = fact
            item.facts = [fact]
            item.excerpt = "Q: \(c.question)\nA: \(c.answer ?? "")"
            item.projectIDs = c.projectID.map { [$0] } ?? []
            item.personIDs = c.personIDs ?? []
            store.save(item)
            // Re-read: the tools changed the record in another process.
            let applied = c.answer
            c = store.get(Clarification.self, c.id) ?? c
            // Changed again while this ran: the next pass applies the newer answer (and undoes this one).
            if c.answer != applied { c.previousAnswer = applied; c.previousResult = (o["result"] as? String) ?? fact; c.applyingAt = nil; store.save(c); return }
            c.status = .applied
            c.appliedAt = Date()
            c.applyingAt = nil
            c.result = (o["result"] as? String)?.nilIfEmpty ?? fact
            c.error = nil
            store.save(c)
            // Stakeholders and summary should show the answer now, not at the next daily refresh.
            if let pid = c.projectID, var p = store.get(Project.self, pid) { p.summaryRequestedAt = Date(); store.save(p) }
            log("Applied answer: \(c.result ?? "")")
        } catch {
            c = store.get(Clarification.self, c.id) ?? c
            c.error = "\(error)"
            c.applyingAt = nil
            store.save(c)
            log("Applying answer failed: \(error)")
        }
    }
}

extension Array {
    var nilIfEmptyArray: [Element]? { isEmpty ? nil : self }
}
