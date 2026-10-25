import Foundation
import JinnieCore

/// `jinnie mcp` — stdio MCP server over the knowledge base. Used by the agent's own `claude -p` calls
/// (Ask, summaries) and usable from Claude Code: `claude mcp add --scope user jinnie -- <path>/jinnie mcp`.
struct MCPServer {
    let store: Store

    static let tools: [[String: Any]] = [
        tool("search", "Full-text search over everything Jinnie knows: items (emails, Slack threads, meetings, notes) with their facts, people, projects, actions. Words are OR-ed and prefix-matched; best matches first.",
             ["query": str("Words to find (English or Russian)"), "types": ["type": "array", "items": ["type": "string", "enum": ["item", "person", "project", "action", "note"]]], "limit": int("Max results, default 20")], required: ["query"]),
        tool("list_projects", "All projects with aliases, email domains, Uberdoer path, and counts.", [:]),
        tool("get_project", "A project: details, summary, people, open actions, waiting items and the most recent items with facts.",
             ["project": str("Project name, alias or id"), "items": int("Recent items to include, default 25")], required: ["project"]),
        tool("get_person", "A person: emails, org, role, projects, actions involving them and recent items.",
             ["person": str("Name, first name, alias or email")], required: ["person"]),
        tool("list_actions", "Actions (next = mine, waiting = expected from others), optionally filtered.",
             ["project": str("Project name"), "person": str("Person name or email"), "kind": ["type": "string", "enum": ["next", "waiting"]],
              "status": ["type": "string", "enum": ["open", "done", "dropped", "all"]]]),
        tool("recent_items", "Most recent items, optionally for one project or source.",
             ["project": str("Project name"), "source": ["type": "string", "enum": ["email", "slack", "calendar", "note"]], "days": int("Look-back days, default 14"), "limit": int("Default 30")]),
        tool("list_documents", "Documents (Drive docs, transcripts, decks, SOWs…) linked from items, newest first, optionally for one project.",
             ["project": str("Project name"), "query": str("Words in the title or kind"), "limit": int("Default 40")]),
        tool("get_item", "One item in full (summary, facts, excerpt, link, people, projects).", ["id": str("Item id")], required: ["id"]),
        tool("add_note", "Save a note to Jinnie (it will be processed into projects, people and actions on the next run).",
             ["text": str("The note")], required: ["text"]),
        tool("add_action", "Create an action in Jinnie: `next` (the owner will do it) or `waiting` (someone owes the owner something). It is synced to Uberdoer right away with context and links (tags Jinnie/Waiting, title `Person//What` for waiting). Prefer this over creating Uberdoer tasks directly.",
             ["kind": ["type": "string", "enum": ["next", "waiting"]], "title": str("Imperative for next; what is needed for waiting (without the person's name)"),
              "person": str("Person name or email (required for waiting)"), "project": str("Project name"), "due": str("YYYY-MM-DD"),
              "context": str("2-4 sentences addressed to the owner as 'you': background, who/when, why, what done looks like"),
              "item_id": str("Jinnie item id this comes from, if any (from search/get_project)")], required: ["kind", "title"]),
        tool("update_action", "Change a Jinnie action: complete, drop or reopen it (Uberdoer follows), or add context / a due date.",
             ["id": str("Action id (from list_actions/search)"), "status": ["type": "string", "enum": ["open", "done", "dropped"]],
              "due": str("YYYY-MM-DD, or empty to clear"), "context": str("Replace the context")], required: ["id"]),
        tool("update_person", "Correct or add what Jinnie knows about a person (role, organisation, nicknames, email, project membership).",
             ["person": str("Name or email"), "name": str("Corrected full name"), "email": str("Add an email"), "role": str("Role"), "org": str("Organisation"),
              "aliases": ["type": "array", "items": ["type": "string"]], "project": str("Project they belong to"), "notes": str("Append to notes"),
              "remove_aliases": ["type": "array", "items": ["type": "string"], "description": "Aliases that belong to someone else"],
              "remove_emails": ["type": "array", "items": ["type": "string"], "description": "Emails that belong to someone else"],
              "replace_notes": str("Replace the notes entirely (to correct them)")], required: ["person"]),
        tool("update_stakeholder", "Set someone's role on a project (and side), or mark them former / replaced. Use for 'X is Y's replacement as <role>': set X with the role and Y former with replaced_by X.",
             ["project": str("Project name"), "person": str("Name or email"), "side": ["type": "string", "enum": ["ours", "customer", "partner", "other"]],
              "role": str("Role on this project"), "responsibilities": str("What they own here"), "key": ["type": "boolean"],
              "former": ["type": "boolean"], "replaced_by": str("Name of their replacement")], required: ["project", "person"]),
        tool("update_project", "Add names, client email domains or a description to a project.",
             ["project": str("Project name"), "aliases": ["type": "array", "items": ["type": "string"]],
              "domains": ["type": "array", "items": ["type": "string"]], "description": str("One line")], required: ["project"]),
        tool("create_person", "Add a person Jinnie doesn't know yet (returns the existing one if the email is known).",
             ["name": str("Full name"), "email": str("Email, if known"), "org": str("Organisation"), "role": str("Role"),
              "project": str("Project they belong to"), "aliases": ["type": "array", "items": ["type": "string"]]], required: ["name"]),
        tool("move_person_links", "Re-point everything about one person to another: item mentions, actions, project roles. With `project`, only that project's links move and `from` leaves the project — use it to split a record that mixed up two people (e.g. create_person for the right one, then move the project's links to them).",
             ["from": str("Person id, name or email links are taken from"), "to": str("Person id, name or email they go to"),
              "project": str("Only this project's links (omit to move everything)"),
              "item_ids": ["type": "array", "items": ["type": "string"], "description": "Also move these items (e.g. a DM not linked to the project)"]], required: ["from", "to"]),
        tool("merge_people", "Two records are the same person: fold `merge` into `keep` (emails, aliases, all links) and delete `merge`.",
             ["keep": str("Person id, name or email to keep"), "merge": str("Person id, name or email to fold in")], required: ["keep", "merge"]),
        tool("remove_person_from_project", "Take someone off a project they were wrongly linked to (membership and stakeholder role).",
             ["person": str("Person id, name or email"), "project": str("Project name")], required: ["person", "project"]),
        tool("list_recordings", "Recent recordings with their speakers (named or 'Speaker N' with a sample of what they said).",
             ["days": int("Look-back days, default 14")]),
        tool("name_speaker", "Say who a speaker in a recording is (or correct a wrong name). Jinnie learns the voice, forgets the samples behind a wrong match, and re-reads the transcript.",
             ["recording": str("Recording id or title words"), "speaker": str("'Speaker 2', the current name, or the label number"), "person": str("Person name, email or id; 'me' for the owner; empty to clear")],
             required: ["recording", "speaker"]),
        tool("list_open_questions", "Questions Jinnie has asked the owner to validate, and the answers given.",
             ["status": ["type": "string", "enum": ["open", "answered", "applied", "dismissed", "all"]]]),
    ]

    static func tool(_ name: String, _ desc: String, _ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": desc, "inputSchema": ["type": "object", "properties": props, "required": required]]
    }
    static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    static func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            guard let id else { continue } // notifications
            switch method {
            case "initialize":
                let version = (msg["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-06-18"
                reply(id, ["protocolVersion": version, "capabilities": ["tools": [String: Any]()],
                           "serverInfo": ["name": "jinnie", "version": "0.1.0"],
                           "instructions": "Jinnie is the owner's personal knowledge base: projects, people, attributed facts from email/Slack/calendar/notes, and actions."])
            case "ping": reply(id, [:])
            case "tools/list": reply(id, ["tools": MCPServer.tools])
            case "tools/call":
                let p = msg["params"] as? [String: Any] ?? [:]
                let name = p["name"] as? String ?? ""
                let args = p["arguments"] as? [String: Any] ?? [:]
                let result = call(name, args)
                let data = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
                reply(id, ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]])
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
            }
        }
    }

    func reply(_ id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }

    func send(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    // MARK: Tools

    func call(_ name: String, _ a: [String: Any]) -> Any {
        let dir = Directory(store: store)
        switch name {
        case "search":
            let types = a["types"] as? [String]
            let hits = store.search(a["query"] as? String ?? "", types: types, limit: a["limit"] as? Int ?? 20)
            return hits.compactMap { h -> [String: Any]? in
                switch h.type {
                case Item.type: return store.get(Item.self, h.id).map { itemJSON($0, dir, full: false) }
                case Person.type: return store.get(Person.self, h.id).map { personJSON($0, dir) }
                case Project.type: return store.get(Project.self, h.id).map { ["type": "project", "id": $0.id, "name": $0.name] }
                case Action.type: return store.get(Action.self, h.id).map { actionJSON($0, dir) }
                case Note.type: return store.get(Note.self, h.id).map { ["type": "note", "id": $0.id, "text": $0.text, "created": iso($0.createdAt)] }
                default: return nil
                }
            }
        case "list_projects":
            let items = store.all(Item.self)
            let actions = store.all(Action.self)
            return dir.projects.sorted { $0.name < $1.name }.map { p -> [String: Any] in
                ["id": p.id, "name": p.name, "aliases": p.aliases, "domains": p.domains, "status": p.status.rawValue,
                 "uberdoer": p.uberdoerPath ?? "", "items": items.filter { $0.projectIDs.contains(p.id) }.count,
                 "openActions": actions.filter { $0.projectID == p.id && $0.status == .open }.count]
            }
        case "get_project":
            guard let p = dir.project(named: a["project"] as? String ?? "") ?? dir.project(id: a["project"] as? String) else {
                return ["error": "No such project. Known: " + dir.projects.map(\.name).joined(separator: ", ")]
            }
            let items = store.all(Item.self).filter { $0.projectIDs.contains(p.id) }.sorted { $0.occurredAt > $1.occurredAt }
            let actions = store.all(Action.self).filter { $0.projectID == p.id }
            return ["id": p.id, "name": p.name, "aliases": p.aliases, "domains": p.domains, "description": p.description,
                    "uberdoer": p.uberdoerPath ?? "", "summary": p.summary ?? "", "summaryAt": p.summaryAt.map(iso) ?? "",
                    "stakeholders": (p.stakeholders ?? []).compactMap { s -> [String: Any]? in
                        guard let person = dir.person(id: s.personID) else { return nil }
                        return ["person": person.display, "side": s.side.rawValue, "role": s.role, "responsibilities": s.responsibilities ?? "",
                                "key": s.key ?? false, "former": s.former ?? false, "replacedBy": dir.person(id: s.replacedByID)?.name ?? ""]
                    },
                    "news": (p.news ?? []).map { ["date": $0.date, "headline": $0.headline, "detail": $0.detail ?? ""] },
                    "people": rankedPeople(p, items, dir),
                    "openActions": actions.filter { $0.status == .open }.map { actionJSON($0, dir) },
                    "recentlyClosedActions": actions.filter { $0.status != .open }.sorted { $0.updatedAt > $1.updatedAt }.prefix(15).map { actionJSON($0, dir) },
                    "items": items.prefix(a["items"] as? Int ?? 25).map { itemJSON($0, dir, full: true) },
                    "documents": documents(items, dir).prefix(30).map { $0 },
                    "itemCount": items.count]
        case "get_person":
            let q = a["person"] as? String ?? ""
            guard let p = dir.person(email: q) ?? dir.person(name: q) else {
                let candidates = store.search(q, types: [Person.type], limit: 5).compactMap { store.get(Person.self, $0.id)?.display }
                return ["error": "No unique match.", "candidates": candidates]
            }
            let items = store.all(Item.self).filter { $0.personIDs.contains(p.id) }.sorted { $0.occurredAt > $1.occurredAt }
            var o = personJSON(p, dir)
            o["actions"] = store.all(Action.self).filter { $0.personID == p.id }.map { actionJSON($0, dir) }
            o["recentItems"] = items.prefix(20).map { itemJSON($0, dir, full: false) }
            return o
        case "list_actions":
            var acts = store.all(Action.self)
            let status = a["status"] as? String ?? "open"
            if status != "all" { acts = acts.filter { $0.status.rawValue == status } }
            if let k = a["kind"] as? String { acts = acts.filter { $0.kind.rawValue == k } }
            if let pn = a["project"] as? String { let pid = dir.project(named: pn)?.id; acts = acts.filter { $0.projectID == pid } }
            if let pn = a["person"] as? String { let pid = (dir.person(email: pn) ?? dir.person(name: pn))?.id; acts = acts.filter { $0.personID == pid } }
            return acts.sorted { ($0.due ?? "9999") < ($1.due ?? "9999") }.map { actionJSON($0, dir) }
        case "recent_items":
            let days = Double(a["days"] as? Int ?? 14)
            var items = store.all(Item.self).filter { $0.occurredAt > Date().addingTimeInterval(-days * 86400) }
            if let pn = a["project"] as? String, let pid = dir.project(named: pn)?.id { items = items.filter { $0.projectIDs.contains(pid) } }
            if let s = a["source"] as? String { items = items.filter { $0.source.rawValue == s } }
            return items.sorted { $0.occurredAt > $1.occurredAt }.prefix(a["limit"] as? Int ?? 30).map { itemJSON($0, dir, full: false) }
        case "list_documents":
            var items = store.all(Item.self).filter { !($0.documents ?? []).isEmpty }
            if let pn = a["project"] as? String, let pid = dir.project(named: pn)?.id { items = items.filter { $0.projectIDs.contains(pid) } }
            var seen = Set<String>()
            var out: [[String: Any]] = []
            let q = (a["query"] as? String).map(Directory.norm)
            for i in items.sorted(by: { $0.occurredAt > $1.occurredAt }) {
                for d in i.documents ?? [] where !seen.contains(d.url) {
                    if let q, !Directory.norm(d.title + " " + (d.kind ?? "")).contains(q) { continue }
                    seen.insert(d.url)
                    out.append(documentJSON(d, i, dir))
                }
            }
            return Array(out.prefix(a["limit"] as? Int ?? 40))
        case "get_item":
            return store.get(Item.self, a["id"] as? String ?? "").map { itemJSON($0, dir, full: true) } ?? ["error": "Not found"]
        case "add_action":
            let kind = Action.Kind(rawValue: a["kind"] as? String ?? "next") ?? .next
            guard let title = (a["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return ["error": "title is required"] }
            var act = Action(kind: kind, title: title)
            let projectID = (a["project"] as? String).flatMap { dir.project(named: $0)?.id }
            if let pn = a["person"] as? String, !pn.isEmpty {
                if let p = dir.person(email: pn) ?? dir.person(name: pn, projectHint: projectID) { act.personID = p.id } else { act.personName = pn }
            } else if kind == .waiting { return ["error": "waiting actions need a person"] }
            act.projectID = projectID ?? dir.person(id: act.personID).flatMap { $0.projectIDs.count == 1 ? $0.projectIDs[0] : nil }
            act.due = (a["due"] as? String).flatMap { $0.count >= 10 ? String($0.prefix(10)) : nil }
            act.context = (a["context"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            act.itemID = (a["item_id"] as? String).flatMap { store.get(Item.self, $0)?.id }
            act = store.save(act)
            JinnieConfig.postExternalChange()
            return ["created": actionJSON(act, dir), "note": "Will appear in Uberdoer within seconds (the Mac app syncs it)."]
        case "update_action":
            guard var act = store.get(Action.self, a["id"] as? String ?? "") else { return ["error": "No such action"] }
            if let st = (a["status"] as? String).flatMap(Action.Status.init(rawValue:)), st != act.status { act.status = st; act.needsPush = true }
            if let d = a["due"] as? String { act.due = d.count >= 10 ? String(d.prefix(10)) : nil }
            if let c = a["context"] as? String, !c.isEmpty { act.context = c }
            act = store.save(act)
            JinnieConfig.postExternalChange()
            return ["updated": actionJSON(act, dir)]
        case "update_person":
            let q = a["person"] as? String ?? ""
            guard var p = person(q, dir) else { return ["error": "No unique person matches \(q)"] }
            if let n = a["name"] as? String, !n.isEmpty { p.aliases.append(p.name); p.name = n }
            if let e = (a["email"] as? String)?.lowercased(), !e.isEmpty, !p.emails.contains(e) { p.emails.append(e) }
            if let r = a["role"] as? String, !r.isEmpty { p.role = r }
            if let o = a["org"] as? String, !o.isEmpty { p.org = o }
            for al in a["aliases"] as? [String] ?? [] where !p.aliases.contains(al) { p.aliases.append(al) }
            if let pn = a["project"] as? String, let pr = dir.project(named: pn), !p.projectIDs.contains(pr.id) { p.projectIDs.append(pr.id) }
            if let n = a["notes"] as? String, !n.isEmpty { p.notes = p.notes.isEmpty ? n : p.notes + "\n" + n }
            for al in a["remove_aliases"] as? [String] ?? [] { p.aliases.removeAll { Directory.norm($0) == Directory.norm(al) } }
            for e in a["remove_emails"] as? [String] ?? [] { p.emails.removeAll { Directory.norm($0) == Directory.norm(e) } }
            if let n = a["replace_notes"] as? String { p.notes = n }
            p = store.save(p)
            JinnieConfig.postExternalChange()
            return ["updated": personJSON(p, dir)]
        case "update_stakeholder":
            guard var proj = dir.project(named: a["project"] as? String ?? "") else { return ["error": "No such project"] }
            let q = a["person"] as? String ?? ""
            guard let person = dir.person(email: q) ?? dir.person(name: q, projectHint: proj.id) else { return ["error": "No unique person matches \(q)"] }
            var list = proj.stakeholders ?? []
            var s = list.first { $0.personID == person.id } ?? Stakeholder(personID: person.id, side: .other, role: person.role ?? "")
            if let v = (a["side"] as? String).flatMap(Stakeholder.Side.init(rawValue:)) { s.side = v }
            if let v = a["role"] as? String, !v.isEmpty { s.role = v }
            if let v = a["responsibilities"] as? String, !v.isEmpty { s.responsibilities = v }
            if let v = a["key"] as? Bool { s.key = v }
            if let v = a["former"] as? Bool { s.former = v ? true : nil }
            if let v = a["replaced_by"] as? String, let r = dir.person(name: v, projectHint: proj.id) { s.replacedByID = r.id; s.former = true }
            list.removeAll { $0.personID == person.id }
            list.append(s)
            proj.stakeholders = list
            store.save(proj)
            if var pe = store.get(Person.self, person.id), !pe.projectIDs.contains(proj.id) { pe.projectIDs.append(proj.id); store.save(pe) }
            JinnieConfig.postExternalChange()
            return ["updated": ["person": person.name, "side": s.side.rawValue, "role": s.role, "former": s.former ?? false]]
        case "update_project":
            guard var p = dir.project(named: a["project"] as? String ?? "") else { return ["error": "No such project"] }
            for al in a["aliases"] as? [String] ?? [] where !p.aliases.contains(al) { p.aliases.append(al) }
            for d in (a["domains"] as? [String] ?? []).map({ $0.lowercased() }) where !p.domains.contains(d) { p.domains.append(d) }
            if let d = a["description"] as? String, !d.isEmpty { p.description = d }
            p = store.save(p)
            JinnieConfig.postExternalChange()
            return ["updated": ["name": p.name, "aliases": p.aliases, "domains": p.domains, "description": p.description]]
        case "create_person":
            guard let name = (a["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return ["error": "name is required"] }
            let email = (a["email"] as? String)?.lowercased().nilIfEmpty
            var p = email.flatMap { dir.person(email: $0) } ?? Person(name: name)
            if let email, !p.emails.contains(email) { p.emails.append(email) }
            if let o = (a["org"] as? String)?.nilIfEmpty { p.org = o }
            if let r = (a["role"] as? String)?.nilIfEmpty { p.role = r }
            for al in a["aliases"] as? [String] ?? [] where !p.aliases.contains(al) { p.aliases.append(al) }
            if let pn = a["project"] as? String, let pr = dir.project(named: pn), !p.projectIDs.contains(pr.id) { p.projectIDs.append(pr.id) }
            p = store.save(p)
            JinnieConfig.postExternalChange()
            return ["created": personJSON(p, dir)]
        case "move_person_links":
            guard let from = person(a["from"], dir), let to = person(a["to"], dir) else { return ["error": "Both people must match exactly one record (use ids from get_person)"] }
            var projectID: String?
            if let pn = (a["project"] as? String)?.nilIfEmpty {
                guard let pr = dir.project(named: pn) else { return ["error": "No such project"] }
                projectID = pr.id
            }
            var msg = store.movePersonLinks(from: from.id, to: to.id, projectID: projectID)
            var extra = 0
            for id in a["item_ids"] as? [String] ?? [] {
                guard var i = store.get(Item.self, id), i.personIDs.contains(from.id) else { continue }
                i.personIDs.removeAll { $0 == from.id }
                if !i.personIDs.contains(to.id) { i.personIDs.append(to.id) }
                store.save(i); extra += 1
            }
            if extra > 0 { msg += " (+\(extra) more items)" }
            JinnieConfig.postExternalChange()
            return ["moved": msg]
        case "merge_people":
            guard let keep = person(a["keep"], dir), let gone = person(a["merge"], dir) else { return ["error": "Both people must match exactly one record (use ids from get_person)"] }
            let msg = store.mergePeople(keep: keep.id, merge: gone.id)
            JinnieConfig.postExternalChange()
            return ["merged": msg]
        case "remove_person_from_project":
            guard let p = person(a["person"], dir), let pr = dir.project(named: a["project"] as? String ?? "") else { return ["error": "No such person or project"] }
            store.removePerson(p.id, fromProject: pr.id)
            JinnieConfig.postExternalChange()
            return ["removed": "\(p.name) from \(pr.name)"]
        case "list_recordings":
            let cutoff = Date().addingTimeInterval(-Double(a["days"] as? Int ?? 14) * 86400)
            return store.all(Recording.self).filter { $0.startedAt > cutoff }.sorted { $0.startedAt > $1.startedAt }.map { r in
                ["id": r.id, "title": r.title, "date": iso(r.startedAt), "minutes": Int(r.duration / 60),
                 "speakers": r.speakers.map { ["speaker": "Speaker \($0.label + 1)", "name": r.name(of: $0.label, in: dir), "sample": $0.sample ?? "",
                                               "namedBy": $0.namedBy?.rawValue ?? ""] }] as [String: Any]
            }
        case "name_speaker":
            let q = (a["recording"] as? String ?? "").lowercased()
            let recs = store.all(Recording.self).sorted { $0.startedAt > $1.startedAt }
            guard let r = recs.first(where: { $0.id == q }) ?? recs.first(where: { $0.title.lowercased().contains(q) }) else { return ["error": "No such recording"] }
            let sq = (a["speaker"] as? String ?? "").lowercased()
            let label = r.speakers.first { "speaker \($0.label + 1)" == sq || String($0.label + 1) == sq || r.name(of: $0.label, in: dir).lowercased() == sq }?.label
            guard let label else { return ["error": "No such speaker; speakers: \(r.speakers.map { "Speaker \($0.label + 1) (\(r.name(of: $0.label, in: dir)))" }.joined(separator: ", "))"] }
            let pq = (a["person"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            var personID: String?
            if !pq.isEmpty {
                if ["me", "you", "i"].contains(pq.lowercased()) { personID = dir.people.first(where: \.isMe)?.id }
                else { personID = person(pq, dir)?.id }
                guard personID != nil else { return ["error": "No unique person matches \(pq); create_person first"] }
            }
            store.assignSpeaker(recordingID: r.id, label: label, personID: personID)
            JinnieConfig.postExternalChange()
            return ["named": "Speaker \(label + 1) in \(r.title) → \(dir.person(id: personID)?.name ?? "unnamed")"]
        case "list_open_questions":
            let status = a["status"] as? String ?? "all"
            return store.all(Clarification.self).filter { status == "all" || $0.status.rawValue == status }
                .sorted { $0.createdAt > $1.createdAt }.map { c in
                    ["id": c.id, "question": c.question, "why": c.why ?? "", "status": c.status.rawValue, "answer": c.answer ?? "",
                     "project": dir.project(id: c.projectID)?.name ?? "", "result": c.result ?? ""] as [String: Any]
                }
        case "add_note":
            let text = a["text"] as? String ?? ""
            guard !text.isEmpty else { return ["error": "Empty note"] }
            let n = store.save(Note(text: text, device: "Claude"))
            JinnieConfig.postExternalChange()
            return ["saved": n.id]
        default:
            return ["error": "Unknown tool \(name)"]
        }
    }

    /// A person by id, email or unique name.
    func person(_ q: Any?, _ dir: Directory) -> Person? {
        guard let q = (q as? String)?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return nil }
        return dir.person(id: q) ?? dir.person(email: q) ?? dir.person(name: q)
    }

    func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    func itemJSON(_ i: Item, _ dir: Directory, full: Bool) -> [String: Any] {
        var o: [String: Any] = ["type": "item", "id": i.id, "source": i.source.rawValue, "title": i.title, "date": iso(i.occurredAt),
                                "summary": i.summary, "url": i.url ?? "", "from": [i.author, i.authorEmail].compactMap { $0 }.joined(separator: " "),
                                "projects": i.projectIDs.compactMap { dir.project(id: $0)?.name }]
        if let docs = i.documents, !docs.isEmpty {
            o["documents"] = docs.map { ["title": $0.title, "url": $0.url, "kind": $0.kind ?? ""] }
        }
        if full {
            o["facts"] = i.facts
            o["excerpt"] = i.excerpt
            o["people"] = i.personIDs.compactMap { dir.person(id: $0)?.display }
        } else if !i.facts.isEmpty {
            o["facts"] = Array(i.facts.prefix(5))
        }
        return o
    }

    /// Project people, most involved first (items they appear in or wrote).
    func rankedPeople(_ p: Project, _ items: [Item], _ dir: Directory) -> [[String: Any]] {
        var counts: [String: Int] = [:]
        for i in items {
            for id in i.personIDs { counts[id, default: 0] += 1 }
            if let e = i.authorEmail, let a = dir.person(email: e) { counts[a.id, default: 0] += 1 }
        }
        let members = Set(dir.people.filter { $0.projectIDs.contains(p.id) }.map(\.id)).union(counts.keys)
        return members.compactMap { dir.person(id: $0) }.filter { !$0.isMe }
            .sorted { (counts[$0.id] ?? 0, $1.name) > (counts[$1.id] ?? 0, $0.name) }
            .map { var o = personJSON($0, dir); o["itemCount"] = counts[$0.id] ?? 0; return o }
    }

    func documents(_ items: [Item], _ dir: Directory) -> [[String: Any]] {
        var seen = Set<String>()
        var out: [[String: Any]] = []
        for i in items { for d in i.documents ?? [] where seen.insert(d.url).inserted { out.append(documentJSON(d, i, dir)) } }
        return out
    }

    func documentJSON(_ d: DocLink, _ i: Item, _ dir: Directory) -> [String: Any] {
        ["title": d.title, "url": d.url, "kind": d.kind ?? "", "seenIn": "\(i.source.label): \(i.title)", "date": iso(i.occurredAt),
         "projects": i.projectIDs.compactMap { dir.project(id: $0)?.name }]
    }

    func personJSON(_ p: Person, _ dir: Directory) -> [String: Any] {
        ["type": "person", "id": p.id, "name": p.name, "emails": p.emails, "aliases": p.aliases, "org": p.org ?? "", "role": p.role ?? "",
         "projects": p.projectIDs.compactMap { dir.project(id: $0)?.name }, "notes": p.notes]
    }

    func actionJSON(_ a: Action, _ dir: Directory) -> [String: Any] {
        ["type": "action", "id": a.id, "kind": a.kind.rawValue, "title": a.title, "status": a.status.rawValue, "due": a.due ?? "",
         "person": dir.person(id: a.personID)?.display ?? a.personName ?? "", "project": dir.project(id: a.projectID)?.name ?? "",
         "source": a.itemID.flatMap { store.get(Item.self, $0) }.map { "\($0.source.label): \($0.title) (\($0.url ?? $0.id))" } ?? "",
         "created": iso(a.createdAt)]
    }
}
