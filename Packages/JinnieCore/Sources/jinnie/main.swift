import Foundation
import JinnieCore
import JinnieAgent

let usage = """
jinnie — personal knowledge agent

  jinnie doctor [--connectors]  check what Jinnie needs (Claude Code, connectors, optional integrations) and how to fix it
  jinnie profile [key value]    show or set the owner profile (name, emails, organization, role, languages, nicknames, uberdoerFolder)
  jinnie run [--force]          one scheduled cycle (notes, sources due, Uberdoer, questions)
  jinnie ingest <email|slack|calendar|drive|outlook|notes>
  jinnie customers [--assign] [--discover]   list customers; --assign groups projects that have none;
                                --discover finds potential customers in general sales projects
  jinnie customers --scan <name>   read a customer's history (meetings, mail, documents, Slack)
  jinnie outlook-login          sign in to Outlook on the web (client Microsoft 365) in Jinnie's browser profile
  jinnie recordings [--process] [--moods] [--summarize <title>]
                                list recordings; --process reads pending transcripts; --moods judges the tone of older ones
  jinnie remarkable-peek        list reMarkable notebooks and which ones are due for transcription
  jinnie remarkable [--since YYYY-MM-DD] [--limit N] [--only <name>]   transcribe notebooks (backfill / one notebook)
  jinnie outlook-peek           show what Jinnie can read from Outlook right now
  jinnie claude-login [--same]  sign Jinnie in to its own Claude account (--same: share Claude Code's again)
  jinnie teams-recordings [--days N] [--only "<title>"] [--list] [--capture "<title>" <out.m4a>]
                                read Teams transcripts of meetings shared with you (skips ones Jinnie recorded)
  jinnie uberdoer               sync actions with Uberdoer
  jinnie import-projects        import projects from Uberdoer's work folder
  jinnie learn-contacts [days]  seed people from mail metadata (default 180 days)
  jinnie note <text…>           add a note
  jinnie ask <question…>
  jinnie summarize <project>
  jinnie summaries [--dry-run]  refresh summaries that are due (new project, new activity, or daily)
  jinnie stakeholders <project>|--all   rebuild project stakeholder maps
  jinnie scan <project> [days]  read a project's history from the sources (default 180 days)
  jinnie questions [all]        open questions Jinnie wants you to validate
  jinnie merge-people <keep id> <merge id>   fold a duplicate person into another
  jinnie raise <project> -- <question…>   add an open question yourself (e.g. one asked in chat)
  jinnie answer <id> <text…>    answer one (applied right away); `answer <id> --skip` dismisses it
  jinnie tools [--refresh]      show the read-only connector tools Jinnie may use
  jinnie projects | people | actions | items
  jinnie mcp                    MCP server (stdio) over the knowledge base
"""

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
let rest = Array(args.dropFirst())

let store: Store
do { store = try Store() } catch { FileHandle.standardError.write("Cannot open database: \(error)\n".data(using: .utf8)!); exit(1) }

if command == "mcp" {
    MCPServer(store: store).run()
    exit(0)
}

let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
let agent = Agent(store: store, claude: Claude(model: ProcessInfo.processInfo.environment["JINNIE_MODEL"]), jinnieBinary: selfPath)

func done() { JinnieConfig.postExternalChange(); exit(0) }

agent.migrateIfNeeded()

switch command {
case "doctor":
    var checks = Setup.quickChecks(agent)
    if rest.contains("--connectors") { checks += await Setup.connectors(agent, refresh: true) }
    for c in checks {
        let mark = switch c.status { case .ok: "✓"; case .missing: c.level == .required ? "✗" : "–"; case .warning: "!"; case .unknown: "?" }
        print("\(mark) \(c.title) [\(c.level.rawValue)]: \(c.detail)")
        for s in c.steps { print("    \(s.text)\(s.command.map { "\n      $ \($0)" } ?? "")\(s.url.map { "\n      \($0)" } ?? "")") }
    }
    if !rest.contains("--connectors") { print("(Gmail, Calendar, Slack, Drive: run `doctor --connectors` to check; it asks Claude, ~20 s each)") }
    exit(0)
case "profile":
    var p = OwnerProfile.current
    if rest.count >= 2 {
        let value = rest.dropFirst().joined(separator: " ")
        let list = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        switch rest[0] {
        case "name": p.name = value
        case "emails": p.emails = list.map { $0.lowercased() }
        case "organization": p.organization = value
        case "role": p.role = value
        case "languages": p.languages = value
        case "nicknames": p.nicknames = list
        case "uberdoerFolder": p.uberdoerFolder = value
        default: print("Unknown key \(rest[0])"); exit(1)
        }
        do { try p.save() } catch { print("Failed: \(error)"); exit(1) }
    }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: (try? enc.encode(p)) ?? Data(), as: UTF8.self))
    exit(0)
case "run":
    await agent.runCycle(force: rest.contains("--force"))
    done()
case "ingest":
    guard let s = rest.first else { print(usage); exit(1) }
    if s == "notes" { await agent.processNotes() } else if let src = Source(rawValue: s) { await agent.ingest(src) } else { print(usage); exit(1) }
    done()
case "uberdoer":
    if rest.contains("--enrich") { await agent.enrichActions(limit: 200) }
    agent.syncUberdoer(); done()
case "customers":
    if args.contains("--assign") {
        do { print("Grouped \(try await agent.assignCustomers()) projects.") } catch { print("Failed: \(error)") }
    }
    if let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
        guard let c = Directory(store: store).customer(named: args[i + 1]) else { print("No such customer"); exit(1) }
        do { print(try await agent.scanCustomer(c.id)) } catch { print("Failed: \(error)") }
    }
    if args.contains("--discover") {
        do { print("New potential customers: \(try await agent.discoverProspects().joined(separator: ", "))") } catch { print("Failed: \(error)") }
    }
    let dir = Directory(store: store)
    for c in dir.customers.sorted(by: { $0.name < $1.name }) {
        print("\(c.name)\(c.isProspect ? " (potential)" : "")  [\(c.domains.joined(separator: ", "))]: " + dir.projects(of: c).map(\.name).joined(separator: ", "))
    }
    let noCustomer = dir.projects.filter { $0.customerID == nil && $0.status != .done }.map(\.name)
    if !noCustomer.isEmpty { print("No customer: " + noCustomer.joined(separator: ", ")) }
    exit(0)
case "claude-login":
    // Jinnie's own Claude login (`--same` goes back to sharing Claude Code's): the browser opens to sign in.
    if rest.contains("--same") {
        Claude.useSharedAccount()
        print("Jinnie now uses the same Claude account as Claude Code.")
        exit(0)
    }
    try FileManager.default.createDirectory(at: Claude.accountDirectory, withIntermediateDirectories: true)
    guard let exe = Claude.locate() else { print("Claude Code is not installed"); exit(1) }
    var login = ["auth", "login"]
    if let e = OwnerProfile.current.emails.first { login += ["--email", e] }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = login
    var env = Claude.environment()
    env["CLAUDE_CONFIG_DIR"] = Claude.accountDirectory.path
    p.environment = env
    try p.run()
    p.waitUntilExit()
    // Only a confirmed sign-in switches Jinnie; otherwise nothing changes.
    guard let email = Claude.activateOwnAccount() else { print("Not signed in; nothing changed."); exit(1) }
    print("Jinnie now runs as \(email). Claude Code in Terminal keeps its own account.")
    exit(0)
case "demo-seed":
    do { print(try DemoSeed.run(store: store)) } catch { print("Failed: \(error)"); exit(1) }
    done()
case "teams-recordings":
    do {
        let days = args.firstIndex(of: "--days").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }
        let only = args.firstIndex(of: "--only").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        if let i = args.firstIndex(of: "--capture"), i + 2 < args.count {
            // Records one recording's audio into a file (testing): --capture "<title>" <out.m4a>
            let all = try OutlookReader().sharedRecordings(since: Date().addingTimeInterval(-Double(days ?? 14) * 86400))
            guard let r = all.first(where: { "\($0.title) \(ISO8601DateFormatter().string(from: $0.start))".localizedCaseInsensitiveContains(args[i + 1]) }) else { print("No such recording"); exit(1) }
            print("Recording \(r.title) (\(Int(r.duration / 60)) min)…")
            var last = -1
            try OutlookReader().captureAudio(playerURL: r.playerURL, duration: r.duration, to: URL(fileURLWithPath: args[i + 2])) { p in
                let pct = Int(p * 100); if pct / 10 != last / 10 { print("\(pct)%"); last = pct }; return true
            }
            print("Saved \(args[i + 2])")
        } else if args.contains("--list") {
            for r in try OutlookReader().sharedRecordings(since: Date().addingTimeInterval(-Double(days ?? 7) * 86400)) {
                print("\(r.start.formatted(date: .abbreviated, time: .shortened))  \(Int(r.duration / 60)) min  \(r.title)")
            }
        } else {
            print(try agent.ingestTeamsRecordings(days: days, only: only))
        }
    } catch { print("Failed: \(error)") }
    exit(0)
case "outlook-login":
    do {
        let r = OutlookReader()
        try r.login()
        print("A browser window is open: sign in to Outlook and choose 'Stay signed in'. Then press Return here (leave the window open).")
        _ = readLine()
        print(try r.finishLogin() ? "Signed in. Jinnie reads Outlook on its next sync." : "Still not signed in. Run this again.")
    } catch { print("Failed: \(error)") }
    exit(0)
case "outlook-peek":
    do {
        let r = OutlookReader()
        let inbox = try r.conversations(folder: "inbox", pages: 1)
        print("Inbox: \(inbox.count) conversations"); inbox.prefix(5).forEach { print("  " + $0.prefix(140)) }
        let ev = try r.events()
        print("Calendar: \(ev.count) events"); ev.prefix(5).forEach { print("  " + $0.prefix(140)) }
    } catch { print("Failed: \(error)") }
    exit(0)
case "recordings":
    if rest.contains("--process") { await agent.processRecordings() }
    if rest.contains("--moods") { await agent.assessMoods(limit: 20) }
    if let i = rest.firstIndex(of: "--notes"), i + 1 < rest.count {
        let recs = store.all(Recording.self).sorted { $0.startedAt > $1.startedAt }
        guard let rec = recs.first(where: { $0.id == rest[i + 1] }) ?? recs.first(where: { $0.title.localizedCaseInsensitiveContains(rest[i + 1]) }) else { print("No such recording"); exit(1) }
        do { let n = try await agent.generateMeetingNotes(rec.id); print("Subject: \(n.subject)\n\n\(n.body)") } catch { print("Failed: \(error)") }
        exit(0)
    }
    if let i = rest.firstIndex(of: "--summarize"), i + 1 < rest.count {
        let key = rest[i + 1]
        let recs = store.all(Recording.self).sorted { $0.startedAt > $1.startedAt }
        guard let rec = recs.first(where: { $0.id == key }) ?? recs.first(where: { $0.title.localizedCaseInsensitiveContains(key) }) else { print("No such recording"); exit(1) }
        do { print(try await agent.summarizeRecording(rec.id)) } catch { print("Failed: \(error)") }
        exit(0)
    }
    let dir = Directory(store: store)
    for r in store.all(Recording.self).sorted(by: { $0.startedAt > $1.startedAt }) {
        print("[\(r.id)] \(r.status.rawValue)  \(Prompts_day(r.startedAt))  \(r.title)  \(Recording.clock(r.duration))\(r.processedAt == nil ? "" : "  (read)")")
        for s in r.speakers { print("    \(r.name(of: s.label, in: dir))\(s.namedBy.map { " [\($0.rawValue)\(s.match.map { String(format: " %.2f", $0) } ?? "")]" } ?? "")  \(Recording.clock(s.talkSeconds))  \(s.sample ?? "")") }
        if let e = r.error { print("    error: \(e)") }
    }
    done()
case "remarkable-peek":
    guard let r = RemarkableReader() else { print("Missing: \(RemarkableReader.missing.joined(separator: ", "))"); exit(1) }
    do {
        let all = try r.notebooks()
        let due = Set(agent.remarkableDue(all, since: nil).map(\.id))
        print("\(all.count) notebooks, \(due.count) due")
        for nb in all.prefix(15) { print("\(due.contains(nb.id) ? "•" : " ") \(Prompts_day(nb.modified))  \(nb.folder.isEmpty ? "" : nb.folder + "/")\(nb.name)") }
    } catch { print("Failed: \(error)") }
    exit(0)
case "remarkable":
    func opt(_ k: String) -> String? { rest.firstIndex(of: k).flatMap { rest.indices.contains($0 + 1) ? rest[$0 + 1] : nil } }
    var run = RunLog(kind: "ingest:remarkable")
    do {
        try await agent.ingestRemarkable(&run, since: opt("--since").flatMap(parseISODate), limit: opt("--limit").flatMap(Int.init) ?? 25,
                                         matching: opt("--only"))
    } catch { run.ok = false; run.message = "\(error)" }
    run.finishedAt = Date(); store.save(run)
    print(run.message); done()
case "push":
    agent.pushStatusChanges(); done()
case "set-status":   // set-status <action id> <open|done|dropped>  (as if clicked in the app)
    guard rest.count == 2, var a = store.get(Action.self, rest[0]), let st = Action.Status(rawValue: rest[1]) else { print(usage); exit(1) }
    a.status = st; a.needsPush = true; store.save(a); done()
case "import-projects":
    do { print("Imported \(try agent.importUberdoerProjects()) projects") } catch { print("Failed: \(error)") }
    done()
case "learn-contacts":
    do { print(try await agent.learnContacts(days: Int(rest.first ?? "") ?? 180)) } catch { print("Failed: \(error)") }
    done()
case "note":
    let n = store.save(Note(text: rest.joined(separator: " "), device: Host.current().localizedName ?? "Mac"))
    print("Saved note \(n.id)"); done()
case "ask":
    do { print(try await agent.ask(rest.joined(separator: " "))) } catch { print("Failed: \(error)") }
    exit(0)
case "summaries":
    let due = Agent.projectsNeedingSummary(projects: store.all(Project.self), items: store.all(Item.self), actions: store.all(Action.self))
    print("Due: \(due.map(\.name).joined(separator: ", "))")
    if !rest.contains("--dry-run") { await agent.refreshSummaries(max: 10) }
    done()
case "stakeholders":   // stakeholders <project> | --all
    let dir = Directory(store: store)
    let targets = rest.contains("--all") ? dir.projects.filter { p in p.status == .active && p.summary != nil } : [dir.project(named: rest.joined(separator: " "))].compactMap { $0 }
    guard !targets.isEmpty else { print("Unknown project. Known: \(dir.projects.map(\.name).joined(separator: ", "))"); exit(1) }
    for p in targets {
        do {
            let list = try await agent.refreshStakeholders(projectID: p.id)
            print("\(p.name):"); for s in list { print("  [\(s.side.rawValue)] \(dir.person(id: s.personID)?.name ?? "?") — \(s.role)\(s.former == true ? " (former)" : "")") }
        } catch { print("\(p.name): failed: \(error)") }
    }
    done()
case "scan":
    let dir = Directory(store: store)
    let days = Int(rest.filter { $0 != "--full" }.last ?? "") ?? 180
    let words = rest.filter { $0 != "--full" }
    let name = (Int(words.last ?? "") != nil ? words.dropLast() : words[...]).joined(separator: " ")
    guard let p = dir.project(named: name) else { print("Unknown project. Known: \(dir.projects.map(\.name).joined(separator: ", "))"); exit(1) }
    do { print(try await agent.scanProject(p.id, days: days, full: CommandLine.arguments.contains("--full")).description) } catch { print("Failed: \(error)") }
    done()
case "summarize":
    let dir = Directory(store: store)
    guard let p = dir.project(named: rest.joined(separator: " ")) else { print("Unknown project. Known: \(dir.projects.map(\.name).joined(separator: ", "))"); exit(1) }
    do { print(try await agent.summarize(projectID: p.id).summary ?? "") } catch { print("Failed: \(error)") }
    done()
case "questions":
    let dir = Directory(store: store)
    for c in store.all(Clarification.self).filter({ rest.contains("all") || $0.status == .open }).sorted(by: { $0.createdAt > $1.createdAt }) {
        print("[\(c.id)] \(c.status.rawValue)  {\(dir.project(id: c.projectID)?.name ?? "-")} \(c.question)")
        if let w = c.why { print("    why: \(w)") }
        if let o = c.options { print("    options: \(o.joined(separator: " | "))") }
        if let a = c.answer { print("    answer: \(a)\(c.result.map { " → \($0)" } ?? "")\(c.error.map { " ✗ \($0)" } ?? "")") }
    }
case "merge-people":
    guard rest.count == 2 else { print("Usage: merge-people <keep id> <merge id>"); exit(1) }
    print(store.mergePeople(keep: rest[0], merge: rest[1])); done()
case "raise":
    guard let sep = rest.firstIndex(of: "--"), let p = Directory(store: store).project(named: rest[..<sep].joined(separator: " ")) else {
        print("Usage: raise <project> -- <question>"); exit(1)
    }
    var c = Clarification(question: rest[(sep + 1)...].joined(separator: " "))
    c.projectID = p.id
    print(store.save(c).id); done()
case "answer":
    guard let id = rest.first, var c = store.get(Clarification.self, id) else { print("Unknown question id"); exit(1) }
    if rest.contains("--skip") { c.status = .dismissed; store.save(c); done() }
    c.answer = rest.dropFirst().joined(separator: " ")
    c.answeredAt = Date(); c.status = .answered; c.error = nil
    store.save(c)
    await agent.applyClarifications()
    print(store.get(Clarification.self, id)?.result ?? store.get(Clarification.self, id)?.error ?? "")
    done()
case "tools":
    for s in Source.connectors {
        do { print("\(s.label): \(try await agent.tools(for: s, refresh: rest.contains("--refresh")).joined(separator: ", "))") }
        catch { print("\(s.label): \(error)") }
    }
case "projects":
    for p in store.all(Project.self).sorted(by: { $0.name < $1.name }) {
        print("\(p.name)  [\(p.aliases.joined(separator: ", "))]  \(p.domains.joined(separator: ", "))  → \(p.uberdoerPath ?? "-")")
    }
case "people":
    let dir = Directory(store: store)
    for p in dir.people.sorted(by: { $0.name < $1.name }) {
        print("\(p.display)  \(p.org ?? "")  \(p.projectIDs.compactMap { dir.project(id: $0)?.name }.joined(separator: ", "))")
    }
case "actions":
    let dir = Directory(store: store)
    for a in store.all(Action.self).filter({ $0.status == .open }) {
        let who = dir.person(id: a.personID)?.name ?? a.personName ?? ""
        print("[\(a.kind.rawValue)] \(a.kind == .waiting ? "\(who)//" : "")\(a.title)  {\(dir.project(id: a.projectID)?.name ?? "-")} \(a.due ?? "") \(a.uberdoerID == nil ? "(not in Uberdoer\(a.syncError.map { ": \($0)" } ?? ""))" : "")")
    }
case "items":
    for i in store.all(Item.self).sorted(by: { $0.occurredAt > $1.occurredAt }).prefix(40) {
        print("\(Prompts_day(i.occurredAt)) [\(i.source.rawValue)] \(i.title) — \(i.summary)")
    }
default:
    print(usage)
}

func Prompts_day(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: d) }
