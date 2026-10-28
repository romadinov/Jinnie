import Foundation
import JinnieAgent
import JinnieCore

/// Fictional sample data for demos and screenshots (Northwind Consulting and its clients). Refuses to write into a store
/// that already holds anything, so it can never touch real data: point JINNIE_HOME at an empty folder first.
enum DemoSeed {
    struct NotEmpty: Error, CustomStringConvertible {
        var description: String { "This store isn't empty. Set JINNIE_HOME to an empty folder for demo data." }
    }

    static func run(store: Store) throws -> String {
        guard store.all(Item.self).isEmpty, store.all(Person.self).isEmpty else {
            throw NotEmpty()
        }
        var profile = OwnerProfile()
        profile.name = "Alex Morgan"
        profile.emails = ["alex.morgan@northwind.example"]
        profile.organization = "Northwind Consulting"
        profile.role = "Solution architect"
        try profile.save()

        let now = Date()
        func ago(_ days: Double, _ hours: Double = 0) -> Date { now.addingTimeInterval(-(days * 86400 + hours * 3600)) }
        func day(_ d: Date) -> String { ISO8601DateFormatter.string(from: d, timeZone: .current, formatOptions: [.withFullDate]) }

        // People
        func person(_ name: String, _ email: String, _ org: String, _ role: String, me: Bool = false) -> Person {
            var p = Person(name: name)
            p.emails = [email]; p.org = org; p.role = role; p.isMe = me
            return store.save(p)
        }
        let me = person("Alex Morgan", "alex.morgan@northwind.example", "Northwind Consulting", "Solution architect", me: true)
        let chris = person("Chris Young", "chris.young@northwind.example", "Northwind Consulting", "Delivery lead")
        let priya = person("Priya Shah", "priya.shah@northwind.example", "Northwind Consulting", "Account executive")
        let dana = person("Dana Fischer", "dana.fischer@acme.example", "Acme", "VP Sales Operations")
        let raj = person("Raj Patel", "raj.patel@acme.example", "Acme", "IT lead")
        let mia = person("Mia Chen", "mia.chen@globex.example", "Globex", "Programme manager")
        let tom = person("Tom Becker", "tom.becker@globex.example", "Globex", "Data architect")
        let lena = person("Lena Novak", "lena.novak@initech.example", "Initech", "CFO")

        // Customers and projects
        func customer(_ name: String, _ domain: String, _ desc: String, prospect: Bool = false) -> Customer {
            var c = Customer(name: name)
            c.domains = [domain]; c.description = desc; c.prospect = prospect ? true : nil
            return store.save(c)
        }
        let acme = customer("Acme", "acme.example", "Manufacturer; Revenue Cloud rollout across three regions.")
        let globex = customer("Globex", "globex.example", "Telecom; migrating 2 million subscriptions to Salesforce.")
        let initech = customer("Initech", "initech.example", "Software company evaluating usage-based billing.", prospect: true)

        func project(_ name: String, _ c: Customer?, _ desc: String, _ summary: String) -> Project {
            var p = Project(name: name)
            p.description = desc; p.customerID = c?.id; p.summary = summary; p.summaryAt = ago(0, 2)
            return store.save(p)
        }
        var acmeP = project("Acme Revenue Cloud", acme, "Quote-to-cash rollout, phase 2: EMEA and APAC.",
                            "Phase 2 is on track for the 14 November go-live. Dana Fischer signed off the EMEA price books; APAC tax rules are the open risk. Raj Patel owns the SSO cutover, due Friday.")
        var globexP = project("Globex Migration", globex, "Subscription and asset migration from the legacy billing system.",
                              "The cutover rehearsal failed on asset hierarchies: 12% of records loaded without parent links. Mia Chen wants a fix plan before Thursday's steering committee; Tom Becker is checking the mapping rules.")
        var initechP = project("Initech Discovery", initech, "Presales: usage-based billing for their API platform.",
                               "Lena Novak liked the usage-rating demo and asked for a fixed-price discovery proposal by next week. Priya Shah leads the commercial side.")
        _ = project("Partner Enablement", nil, "Internal: certification plan for the delivery team.",
                    "Two of five consultants are certified; the next exam window opens on the 20th.")

        // Items (sources)
        func item(_ src: Source, _ ref: String, _ title: String, _ when: Date, by author: Person, url: String,
                  summary: String, facts: [String], projects: [Project], people: [Person]) -> Item {
            var i = Item(source: src, sourceRef: ref, title: title, occurredAt: when)
            i.url = url; i.author = author.name; i.authorEmail = author.emails.first
            i.summary = summary; i.facts = facts
            i.projectIDs = projects.map(\.id); i.personIDs = people.map(\.id)
            return store.save(i)
        }
        let e1 = item(.email, "demo-e1", "EMEA price books: approved", ago(0, 3), by: dana, url: "https://mail.google.com/mail/#all/demo1",
                      summary: "Dana approved the EMEA price books and asked for the APAC tax matrix by Wednesday.",
                      facts: ["Dana Fischer approved the EMEA price books", "APAC tax matrix is due Wednesday"], projects: [acmeP], people: [dana])
        let s1 = item(.slack, "demo-s1", "#globex-migration: rehearsal results", ago(0, 5), by: tom, url: "https://northwind.slack.com/archives/C01/p1",
                      summary: "Tom reported that 12% of assets loaded without parent links in the cutover rehearsal.",
                      facts: ["12% of assets loaded without parent links", "Tom Becker suspects the mapping of bundle components"], projects: [globexP], people: [tom, mia])
        let c1 = item(.calendar, "demo-c1", "Globex steering committee", ago(-2), by: mia, url: "https://calendar.google.com/calendar/event?eid=demo1",
                      summary: "Steering committee: cutover go/no-go.", facts: [], projects: [globexP], people: [mia, tom, chris])
        let e2 = item(.email, "demo-e2", "Initech: next steps after the demo", ago(1, 2), by: lena, url: "https://mail.google.com/mail/#all/demo2",
                      summary: "Lena asked for a fixed-price discovery proposal and a reference customer.",
                      facts: ["Lena Novak wants a fixed-price discovery proposal by next Tuesday", "Initech bills 40 million API calls a month"], projects: [initechP], people: [lena])
        let s2 = item(.slack, "demo-s2", "DM from Raj Patel", ago(0, 1), by: raj, url: "https://northwind.slack.com/archives/D01/p2",
                      summary: "Raj will finish the SSO cutover on Friday and needs the test users list.",
                      facts: ["SSO cutover moves to Friday"], projects: [acmeP], people: [raj])

        // News
        acmeP.news = [NewsItem(date: day(ago(0, 3)), headline: "EMEA price books approved", itemIDs: [e1.id]),
                      NewsItem(date: day(ago(0, 1)), headline: "SSO cutover moves to Friday", itemIDs: [s2.id])]
        acmeP.news?[0].detail = "Dana Fischer signed off; APAC tax matrix is the next dependency."
        acmeP.news?[0].important = true
        globexP.news = [NewsItem(date: day(ago(0, 5)), headline: "Cutover rehearsal failed on asset hierarchies", itemIDs: [s1.id])]
        globexP.news?[0].detail = "12% of assets loaded without parent links; fix plan needed before the steering committee."
        globexP.news?[0].important = true
        initechP.news = [NewsItem(date: day(ago(1, 2)), headline: "Initech asks for a discovery proposal", itemIDs: [e2.id])]
        initechP.news?[0].detail = "Fixed price, due next Tuesday, with a reference customer."
        func stake(_ p: Person, _ side: Stakeholder.Side, _ role: String, key: Bool = false) -> Stakeholder {
            var s = Stakeholder(personID: p.id, side: side, role: role); s.key = key ? true : nil; return s
        }
        acmeP.stakeholders = [stake(dana, .customer, "Executive sponsor", key: true), stake(raj, .customer, "IT lead"), stake(me, .ours, "Solution architect")]
        globexP.stakeholders = [stake(mia, .customer, "Programme manager", key: true), stake(tom, .customer, "Data architect"), stake(chris, .ours, "Delivery lead")]
        initechP.stakeholders = [stake(lena, .customer, "Decision maker", key: true), stake(priya, .ours, "Account executive")]
        acmeP = store.save(acmeP); globexP = store.save(globexP); initechP = store.save(initechP)

        // Actions
        func action(_ kind: Action.Kind, _ title: String, _ p: Project, _ who: Person?, due: Date?, from: Item, context: String, quote: String?) {
            var a = Action(kind: kind, title: title)
            a.projectID = p.id; a.personID = who?.id; a.due = due.map(day); a.itemID = from.id; a.context = context; a.quote = quote
            a.uberdoerID = "demo-\(UUID().uuidString.prefix(6))"
            store.save(a)
        }
        action(.next, "Send the APAC tax matrix to Dana", acmeP, dana, due: ago(-1), from: e1,
               context: "Dana approved EMEA and needs APAC tax rules before configuring the second region.", quote: "Can you get me the APAC tax matrix by Wednesday?")
        action(.next, "Draft the asset hierarchy fix plan", globexP, mia, due: ago(-2), from: s1,
               context: "Mia wants a plan before Thursday's steering committee.", quote: "We need a credible fix before the go/no-go.")
        action(.next, "Write the Initech discovery proposal", initechP, lena, due: ago(-5), from: e2,
               context: "Fixed price, two weeks, with a reference customer.", quote: "Could you send a fixed-price proposal by Tuesday?")
        action(.waiting, "Bundle component mapping review", globexP, tom, due: ago(-1), from: s1,
               context: "Tom is checking why bundle components lost their parents.", quote: "I'll go through the mapping rules tonight.")
        action(.waiting, "Test users list for SSO", acmeP, raj, due: ago(-3), from: s2,
               context: "Raj needs it to finish the SSO cutover on Friday.", quote: nil)

        // A question to clarify, and an answered Ask
        var q = Clarification(question: "Is Priya Shah also the account executive for Globex, or only for Initech?")
        q.why = "Priya appears in Globex threads but only signs Initech proposals."
        q.options = ["Both", "Only Initech"]; q.personIDs = [priya.id]
        store.save(q)
        var ask = Question(text: "What's blocking the Globex cutover?", device: "iPhone")
        ask.answer = """
        The cutover rehearsal failed on asset hierarchies: 12% of assets loaded without parent links (Tom Becker, Slack, today).
        - Tom is reviewing the bundle component mapping; he expects an answer tomorrow.
        - Mia Chen wants a fix plan before Thursday's steering committee, which decides go/no-go.
        - Your action: draft the asset hierarchy fix plan, due Thursday.
        """
        ask.answeredAt = ago(0, 0.2)
        store.save(ask)

        // Recordings: a heated one, and a calm one shared from Teams
        func recording(_ title: String, _ when: Date, minutes: Double, app: String, lines: [(Person, Double, String)],
                       mood: String, why: String, summary: String, notesSubject: String, notes: String, teams: Bool = false) {
            var r = Recording(title: title)
            r.startedAt = when; r.duration = minutes * 60; r.status = .ready; r.app = app
            r.device = teams ? "Teams" : "Alex’s MacBook Pro"
            if teams { r.externalID = "teams:demo"; r.sourceURL = "https://northwind-my.sharepoint.example/stream" }
            let speakers = Array(NSOrderedSet(array: lines.map(\.0.id))) as! [String]
            r.segments = lines.enumerated().map { i, l in
                RecordedSegment(speaker: speakers.firstIndex(of: l.0.id), start: l.1, end: i + 1 < lines.count ? lines[i + 1].1 : l.1 + 20, text: l.2)
            }
            r.speakers = speakers.enumerated().map { i, id in
                var s = RecordedSpeaker(label: i); s.personID = id; s.namedBy = .voice; s.match = 0.91
                s.talkSeconds = r.segments.filter { $0.speaker == i }.reduce(0) { $0 + $1.end - $1.start }
                return s
            }
            r.mood = mood; r.moodWhy = why
            r.summary = summary; r.summaryAt = when.addingTimeInterval(minutes * 60 + 600)
            r.notesSubject = notesSubject; r.notes = notes; r.notesAt = r.summaryAt
            r.processedAt = r.summaryAt
            store.save(r)
        }
        recording("Globex cutover planning", ago(0, 2), minutes: 34, app: "Zoom", lines: [
            (mia, 0, "Twelve percent without parent links is not a rounding error. How did this pass the last rehearsal?"),
            (me, 9, "It didn't fail last time because bundles weren't in scope. The mapping treats components as standalone assets."),
            (tom, 21, "That's on our side too. The legacy system exports bundles flat, there's no parent ID in the extract."),
            (mia, 33, "I can't take a no-go to the steering committee without a date. What do you need from us?"),
            (me, 44, "A parent reference in the extract, and two days to rerun the load with a hierarchy check."),
            (tom, 58, "I can add the parent ID by Wednesday if the export team agrees."),
            (mia, 66, "Then I want the fix plan in writing before Thursday. Alex, can you own that?"),
            (me, 74, "Yes. I'll send it tomorrow with the rerun schedule."),
        ], mood: "heated", why: "Mia Chen pushed back hard on the failed rehearsal and pressed for a date; Tom Becker conceded the export gap.",
           summary: """
        **Overview**: The rehearsal failed because bundle components were migrated without parent links. The team agreed a fix: a parent ID in the extract and a rerun with a hierarchy check.

        **Decisions**
        - Add the parent ID to the legacy extract (Tom Becker, by Wednesday).
        - Rerun the load with a hierarchy check before go/no-go.

        **Action items**
        - Alex Morgan: send the written fix plan and rerun schedule (tomorrow).
        - Tom Becker: add the parent reference to the export (Wednesday).
        """,
           notesSubject: "Meeting notes: Globex cutover planning (\(ago(0, 2).formatted(.dateTime.day().month(.abbreviated))))",
           notes: """
        Hi all,

        Here are the notes from today's cutover planning call.

        Attendees: Mia Chen, Tom Becker, Alex Morgan

        Summary:
        The rehearsal loaded 12% of assets without parent links because the legacy extract exports bundles flat. We agreed to add a parent reference to the extract and rerun the load with a hierarchy check.

        Action items:
        - Tom Becker: add the parent ID to the export (by Wednesday)
        - Alex Morgan: send the written fix plan and rerun schedule (tomorrow)

        Thanks,
        Alex
        """)
        recording("Acme weekly sync", ago(1, 4), minutes: 28, app: "Teams", lines: [
            (dana, 0, "Good news first: EMEA price books are approved. Thank you all."),
            (raj, 8, "SSO is moving to Friday, I just need the test users list."),
            (me, 16, "I'll get the list to you today, and the APAC tax matrix to Dana by Wednesday."),
            (dana, 27, "Perfect. Then we're on track for the fourteenth."),
        ], mood: "positive", why: "Dana Fischer opened with an approval and thanked the team; everything stayed on schedule.",
           summary: "**Overview**: Phase 2 is on track. EMEA price books are approved; SSO moves to Friday.",
           notesSubject: "Meeting notes: Acme weekly sync", notes: "Hi Dana, hi Raj,\n\nThanks for today's sync. Price books approved; SSO on Friday.\n\nAlex", teams: true)

        // A voice note
        var n = Note(text: "Remind me to ask Lena which reference customer would carry the most weight with her board.", device: "iPhone")
        n.processedAt = ago(0, 4)
        store.save(n)

        return "Demo data: 8 people, 3 customers, 4 projects, 5 items, 5 actions, 2 recordings, 1 question, 1 note."
    }
}
