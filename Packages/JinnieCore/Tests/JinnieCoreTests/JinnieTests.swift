import Foundation
import Testing
@testable import JinnieAgent
@testable import JinnieCore

func tempStore() throws -> Store {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jinnie-test-\(UUID().uuidString)")
    return try Store(url: dir.appendingPathComponent("t.sqlite"))
}

@Test func readOnlyFilter() {
    for ok in ["search_threads", "get_thread", "get_message", "list_labels", "slack_read_channel", "slack_search_public", "list_events",
               "search_files", "read_file_content", "download_file_content", "get_file_metadata", "export_document"] {
        #expect(Agent.isReadOnly(ok), "\(ok) should be allowed")
    }
    for bad in ["send_message", "reply", "forward", "unlabel_message", "untrash_thread", "unmark_thread_spam", "trash_message",
                "create_draft", "get_draft", "slack_send_message", "create_event", "respond_to_event", "apply_sensitive_thread_label",
                "update_message_labels", "authenticate",
                "create_file", "copy_file", "share_file", "move_file", "delete_file", "update_file_permissions"] {
        #expect(!Agent.isReadOnly(bad), "\(bad) should be blocked")
    }
}

@Test func resolvesFirstNameToPersonAndProject() throws {
    let store = try tempStore()
    var acme = Project(name: "Acme")
    acme.domains = ["acme-telco.example"]
    store.save(acme)
    var b = Person(name: "Dana Fischer")
    b.emails = ["dana.fischer@acme-telco.example"]
    b.projectIDs = [acme.id]
    store.save(b)
    store.save(Person(name: "Anna Smith"))

    let dir = Directory(store: store)
    #expect(dir.person(name: "Dana")?.id == b.id)
    #expect(dir.person(name: "dana fischer")?.id == b.id)
    #expect(dir.person(email: "Dana.Fischer@acme-telco.example")?.id == b.id)
    #expect(dir.project(forEmail: "someone@acme-telco.example")?.id == acme.id)
    #expect(dir.project(named: "acme")?.id == acme.id)
    #expect(dir.person(name: "Nobody") == nil)
}

@Test func applyCreatesWaitingActionLinkedToPersonAndProject() throws {
    let store = try tempStore()
    var acme = Project(name: "Acme")
    acme.domains = ["acme-telco.example"]
    store.save(acme)
    var b = Person(name: "Dana Fischer")
    b.emails = ["dana.fischer@acme-telco.example"]
    b.projectIDs = [acme.id]
    store.save(b)

    let agent = Agent(store: store, jinnieBinary: "/dev/null", log: { _ in })
    let extraction: [String: Any] = [
        "newProjects": [],
        "items": [[
            "sourceRef": "n1", "title": "Dana to send SOW", "occurredAt": "2026-10-23T10:00:00+11:00",
            "summary": "Dana will send the signed SOW by Friday.", "facts": ["Dana owes the signed SOW"],
            "projects": [], "people": [["name": "Dana"]],
            "actions": [["kind": "waiting", "title": "Signed SOW", "person": "Dana", "due": "2026-10-30"]],
            "resolvesActionIDs": [],
        ]],
    ]
    let stats = agent.apply(extraction, source: .note)
    #expect(stats.actions == 1)
    let a = try #require(store.all(Action.self).first)
    #expect(a.kind == .waiting)
    #expect(a.personID == b.id)
    #expect(a.projectID == acme.id)   // inferred from the person's single project
    #expect(a.due == "2026-10-30")
    let item = try #require(store.find(Item.self, key: "note:n1"))
    #expect(item.personIDs == [b.id])

    // Same action phrased differently on the next run is not duplicated.
    var again = extraction
    var items = again["items"] as! [[String: Any]]
    items[0]["sourceRef"] = "n2"
    items[0]["actions"] = [["kind": "waiting", "title": "the signed SOW", "person": "Dana Fischer"]]
    again["items"] = items
    #expect(agent.apply(again, source: .note).actions == 0)
}

@Test func remoteApplyIsLastWriterWins() throws {
    let store = try tempStore()
    var n = store.save(Note(text: "v1", device: "Mac"))
    n.text = "older"
    n.updatedAt = n.updatedAt.addingTimeInterval(-10)
    let older = String(decoding: try Store.encoder.encode(n), as: UTF8.self)
    #expect(!store.applyRemote(type: Note.type, json: older))
    n.text = "newer"
    n.updatedAt = Date().addingTimeInterval(10)
    let newer = String(decoding: try Store.encoder.encode(n), as: UTF8.self)
    #expect(store.applyRemote(type: Note.type, json: newer))
    #expect(store.get(Note.self, n.id)?.text == "newer")
    #expect(store.search("newer").first?.id == n.id)
}

@Test func documentsAreMergedWithoutDuplicates() throws {
    let store = try tempStore()
    let agent = Agent(store: store, jinnieBinary: "/dev/null", log: { _ in })
    func run(_ docs: [[String: Any]]) {
        agent.apply(["newProjects": [], "items": [[
            "sourceRef": "t1", "title": "Acme weekly", "occurredAt": "2026-10-22T10:00:00+11:00", "summary": "s", "facts": [],
            "projects": [], "people": [], "actions": [], "resolvesActionIDs": [], "documents": docs,
        ]]], source: .drive)
    }
    run([["title": "Acme weekly - Transcript", "url": "https://docs.google.com/document/d/abc", "kind": "transcript"]])
    run([["title": "Acme weekly - Transcript", "url": "https://docs.google.com/document/d/abc", "kind": "transcript"],
         ["title": "SOW v3", "url": "https://docs.google.com/document/d/sow", "kind": "SOW"],
         ["title": "bogus", "url": "not a url"]])
    let item = try #require(store.find(Item.self, key: "drive:t1"))
    #expect(item.documents?.map(\.title) == ["Acme weekly - Transcript", "SOW v3"])
    #expect(store.search("SOW").first?.id == item.id)
}

@Test func summarySchedule() {
    let now = Date()
    func project(_ name: String, summaryAgo: Double?) -> Project {
        var p = Project(name: name)
        p.summaryAt = summaryAgo.map { now.addingTimeInterval(-$0 * 3600) }
        return p
    }
    func item(_ p: Project, hoursAgo: Double) -> Item {
        var i = Item(source: .email, sourceRef: UUID().uuidString, title: "t", occurredAt: now)
        i.projectIDs = [p.id]; i.updatedAt = now.addingTimeInterval(-hoursAgo * 3600)
        return i
    }
    let fresh = project("Learned", summaryAgo: nil)          // first items, never summarised → yes
    let empty = project("Empty", summaryAgo: nil)            // nothing known → no
    let busy = project("Busy", summaryAgo: 3)                // new item after summary, summary 3h old → yes
    let recent = project("Recent", summaryAgo: 1)            // new item but summarised 1h ago → wait
    let stale = project("Stale", summaryAgo: 30)             // no news, but over a day old and active this month → yes
    let dormant = project("Dormant", summaryAgo: 30)         // last activity 2 months ago → no
    let items = [item(fresh, hoursAgo: 1), item(busy, hoursAgo: 0.5), item(recent, hoursAgo: 0.2),
                 item(stale, hoursAgo: 48), item(dormant, hoursAgo: 24 * 60)]
    let due = Agent.projectsNeedingSummary(projects: [fresh, empty, busy, recent, stale, dormant], items: items, actions: [], now: now)
    #expect(due.map(\.name) == ["Busy", "Learned", "Stale"])
}

@Test func legacyNotesAreOnlyRewrittenWhenUntouched() {
    let id = "abc123"
    let untouched = "https://slack.com/x\nPerson: Dana Fischer <b@acme-telco.example>\nSource: Slack — SoW (2026-10-20)\nBelong wants to start ASAP.\njinnie:abc123"
    let edited = untouched + "\nCall after lunch, prefers Teams"
    #expect(Agent.looksLikeLegacyNote(untouched, actionID: id))
    #expect(!Agent.looksLikeLegacyNote(edited, actionID: id))
    #expect(!Agent.looksLikeLegacyNote("my own note", actionID: id))
}

@Test func splitsAMergedPersonByProjectAndMergesDuplicates() throws {
    let store = try tempStore()
    let initech = store.save(Project(name: "Initech"))
    let school = store.save(Project(name: "School"))
    var mariaA = Person(name: "Maria Rossi"); mariaA.projectIDs = [initech.id, school.id]
    mariaA = store.save(mariaA)
    var initechItem = Item(source: .email, sourceRef: "t1", title: "Initech pricing", occurredAt: Date()); initechItem.projectIDs = [initech.id]; initechItem.personIDs = [mariaA.id]
    var schoolItem = Item(source: .email, sourceRef: "t2", title: "Term dates", occurredAt: Date()); schoolItem.projectIDs = [school.id]; schoolItem.personIDs = [mariaA.id]
    store.save(initechItem); store.save(schoolItem)
    var act = Action(kind: .waiting, title: "Pricing approval"); act.personID = mariaA.id; act.projectID = initech.id
    store.save(act)
    var p = store.get(Project.self, initech.id)!
    p.stakeholders = [Stakeholder(personID: mariaA.id, side: .partner, role: "AE")]
    store.save(p)

    // Split: the Initech side belongs to a different Maria.
    let mariaB = store.save(Person(name: "Maria Chen"))
    store.movePersonLinks(from: mariaA.id, to: mariaB.id, projectID: initech.id)
    #expect(store.get(Item.self, initechItem.id)!.personIDs == [mariaB.id])
    #expect(store.get(Item.self, schoolItem.id)!.personIDs == [mariaA.id])
    #expect(store.get(Action.self, act.id)!.personID == mariaB.id)
    #expect(store.get(Project.self, initech.id)!.stakeholders!.map(\.personID) == [mariaB.id])
    #expect(store.get(Person.self, mariaA.id)!.projectIDs == [school.id])
    #expect(store.get(Person.self, mariaB.id)!.projectIDs == [initech.id])

    // Merge: a duplicate record folds in, keeping its email as well.
    var dup = Person(name: "M. Chen"); dup.emails = ["mchen@vendor.example"]; dup = store.save(dup)
    var dupItem = Item(source: .email, sourceRef: "t3", title: "Kickoff", occurredAt: Date()); dupItem.personIDs = [dup.id, mariaB.id]
    store.save(dupItem)
    store.mergePeople(keep: mariaB.id, merge: dup.id)
    #expect(store.get(Person.self, dup.id)?.deleted == true)
    #expect(store.get(Person.self, mariaB.id)!.emails == ["mchen@vendor.example"])
    #expect(store.get(Item.self, dupItem.id)!.personIDs == [mariaB.id])
}

@Test func openQuestionsAreNotRepeated() throws {
    let store = try tempStore()
    let acme = store.save(Project(name: "Acme"))
    let agent = Agent(store: store, jinnieBinary: "/bin/false", log: { _ in })
    agent.raiseQuestions([["question": "Does the Acme plan have 3 or 4 phases?", "why": "Two versions", "options": ["3", "4"]]], projectID: acme.id)
    agent.raiseQuestions([["question": "Acme plan: 3 or 4 phases?", "why": "again"],
                          ["question": "Is Kim Park on Northwind's side?", "why": "x"]], projectID: acme.id)
    let qs = store.all(Clarification.self)
    #expect(qs.count == 2)
    #expect(qs.first { $0.question.contains("phases") }?.options == ["3", "4"])
}

@Test func fullNameWithAnotherSurnameIsADifferentPerson() throws {
    let store = try tempStore()
    var a = Person(name: "Maria Rossi"); a.emails = ["maria.rossi@school.example"]; store.save(a)
    let kate = store.save(Person(name: "Kate"))
    let dir = Directory(store: store)
    #expect(dir.person(name: "Maria Chen") == nil)
    #expect(dir.resolvePerson(name: "Maria Chen", email: "mchen@vendor.example") == nil)
    #expect(dir.person(name: "Maria")?.id == a.id)
    #expect(dir.person(name: "Maria Rossi")?.id == a.id)
    #expect(dir.person(name: "Kate Smith")?.id == kate.id)

    // Once both exist, a bare "Maria" (even an alias of one of them) is settled by the project.
    let initech = store.save(Project(name: "Initech"))
    var b = Person(name: "Maria Chen"); b.projectIDs = [initech.id]; store.save(b)
    var a2 = store.get(Person.self, a.id)!; a2.aliases = ["Maria"]; store.save(a2)
    let dir2 = Directory(store: store)
    #expect(dir2.person(name: "Maria", projectHint: initech.id)?.id == b.id)
    #expect(dir2.person(name: "Maria") == nil)
}

@Test func voicesAreMatchedOnlyWhenClear() throws {
    let store = try tempStore()
    func v(_ x: [Float]) -> [Float] { x + Array(repeating: 0, count: 6) }
    var me = Person(name: "Alex Example"); me.isMe = true; me.voiceSamples = [VoiceSample(embedding: v([1, 0, 0, 0]))]; me = store.save(me)
    var b = Person(name: "Dana Fischer"); b.voiceSamples = [VoiceSample(embedding: v([0, 1, 0, 0]))]; b = store.save(b)
    var j = Person(name: "Sam Ortiz"); j.voiceSamples = [VoiceSample(embedding: v([0, 0.9, 0.44, 0]))]; j = store.save(j)
    let people = store.all(Person.self)

    var speakers = [RecordedSpeaker(label: 0), RecordedSpeaker(label: 1), RecordedSpeaker(label: 2)]
    speakers[0].embedding = v([0.95, 0.1, 0, 0])      // clearly the owner
    speakers[1].embedding = v([0, 0.97, 0.2, 0])      // between Dana and Sam: too close to call
    speakers[2].embedding = v([0, 0, 0, 1])           // nobody known
    Voice.identify(&speakers, people: people)
    #expect(speakers[0].personID == me.id && speakers[0].namedBy == .voice)
    #expect(speakers[1].personID == nil)
    #expect(speakers[2].personID == nil)

    // One person is never given to two speakers: the better match wins, the other stays unnamed.
    var two = [RecordedSpeaker(label: 0), RecordedSpeaker(label: 1)]
    two[0].embedding = v([0, 1, 0, 0]); two[1].embedding = v([0, 0.99, 0.05, 0])
    Voice.identify(&two, people: people)
    #expect(two[0].personID == b.id)
    #expect(two[1].personID == nil)

    var p = b
    for i in 0..<10 { Voice.learn(v([Float(i), 1, 0, 0]), into: &p, recordingID: "r\(i)", label: 0) }
    #expect(p.voiceSamples?.count == 8)
    Voice.learn(v([9, 1, 0, 0]), into: &p, recordingID: "r9", label: 0)   // same recording and speaker: replaced, not added
    #expect(p.voiceSamples?.count == 8)

    // A wrong match is undone: the samples that made the voice match are forgotten, others stay.
    var wrong = b
    wrong.voiceSamples = [VoiceSample(embedding: v([0, 1, 0, 0])), VoiceSample(embedding: v([1, 0, 0, 0]))]
    #expect(Voice.unlearn(v([0, 0.98, 0.1, 0]), from: &wrong) == 1)
    #expect(wrong.voiceSamples?.count == 1)
}

@Test func recordingTranscriptMergesTurns() throws {
    let store = try tempStore()
    var me = Person(name: "Alex Example"); me.isMe = true; me = store.save(me)
    let b = store.save(Person(name: "Dana Fischer"))
    var r = Recording(title: "Acme weekly")
    var s0 = RecordedSpeaker(label: 0); s0.personID = me.id
    var s1 = RecordedSpeaker(label: 1); s1.personID = b.id
    r.speakers = [s0, s1, RecordedSpeaker(label: 2)]
    r.segments = [RecordedSegment(speaker: 1, start: 3, end: 5, text: "We want to start"),
                  RecordedSegment(speaker: 1, start: 5, end: 7, text: "in November."),
                  RecordedSegment(speaker: 0, start: 8, end: 10, text: "I'll send the SoW."),
                  RecordedSegment(speaker: 2, start: 61, end: 64, text: "Finance is on leave.")]
    let t = r.transcript(Directory(store: store))
    #expect(t == "[00:03] Dana Fischer: We want to start in November.\n[00:08] You: I'll send the SoW.\n[01:01] Speaker 3: Finance is on leave.")
}

@Test func schemasAreValidJSON() throws {
    for (name, schema) in [("extraction", Prompts.extractionSchema), ("stakeholders", Agent.stakeholderSchema),
                           ("clarify", Agent.clarifyResultSchema), ("contacts", Agent.contactsSchema), ("tools", Prompts.toolDiscoverySchema)] {
        #expect((try? JSONSerialization.jsonObject(with: Data(schema.utf8))) != nil, "\(name) schema is not valid JSON")
    }
}

@Test func improvementNotesAppendTaskPaperLines() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jinnie-notes-\(UUID().uuidString)")
    let notes = ImprovementNotes(file: dir.appendingPathComponent("Improvement notes.md"))
    try notes.add("Status line says stuck (scan)", context: "Mac › Today", build: "0.1.0 (2)", device: "MacBook Pro, macOS 27")
    let shot = try notes.add("Speaker names\nshould show (role)", context: "iPhone › Recording", build: "0.1.0 (2)", device: "iPhone, iOS 27", screenshot: Data([1, 2, 3]))
    let text = try String(contentsOf: notes.file, encoding: .utf8)
    let lines = text.components(separatedBy: "\n")
    #expect(lines[0] == "Improvement notes:")
    #expect(lines[1].hasPrefix("\t- Status line says stuck [scan] @date(") || lines[1].hasPrefix("\t- Status line says stuck (scan) @date("))
    #expect(lines[1].contains("@where(Mac › Today) @build(0.1.0 [2]) @device(MacBook Pro, macOS 27)"))
    #expect(lines[2].contains("@screenshot(Improvement notes/\(shot!))"))
    #expect(lines[3] == "\t\tshould show (role)")
    #expect(FileManager.default.fileExists(atPath: notes.attachmentsDirectory.appendingPathComponent(shot!).path))
}

@Test func correctingASpeakerMovesTheVoice() throws {
    let store = try tempStore()
    let voice: [Float] = [0, 1, 0.1, 0, 0, 0]
    var dana = Person(name: "Dana Fischer"); dana.voiceSamples = [VoiceSample(embedding: [0, 1, 0, 0, 0, 0])]; dana = store.save(dana)
    let omar = store.save(Person(name: "Omar Haddad"))
    // Recording 1: the voice was (wrongly) matched to Dana.
    var r1 = Recording(title: "Weekly"); r1.status = .ready
    var s = RecordedSpeaker(label: 0); s.embedding = voice; s.personID = dana.id; s.namedBy = .voice; s.talkSeconds = 60
    r1.speakers = [s]; r1 = store.save(r1)
    // Recording 2: same voice, waiting for a name (Dana's print was removed by hand… or never matched).
    var r2 = Recording(title: "Follow-up"); r2.status = .ready
    var s2 = RecordedSpeaker(label: 1); s2.embedding = [0, 0.99, 0.12, 0, 0, 0]; s2.talkSeconds = 40
    r2.speakers = [s2]; r2 = store.save(r2)

    store.assignSpeaker(recordingID: r1.id, label: 0, personID: omar.id)
    #expect(store.get(Person.self, dana.id)!.voiceSamples == nil)                       // the bad sample is forgotten
    #expect(store.get(Person.self, omar.id)!.voiceSamples?.first?.recordingID == r1.id)  // and learned for Omar
    #expect(store.get(Recording.self, r1.id)!.speakers[0].namedBy == .owner)
    #expect(store.get(Recording.self, r2.id)!.speakers[0].personID == omar.id)          // recognised elsewhere too
    #expect(store.get(Recording.self, r2.id)!.processedAt == nil)
}

@Test func ownerIsTheVoiceLoudestOnTheMicrophone() {
    let sr = 100.0  // tiny sample rate keeps the test fast
    var mic = [Float](repeating: 0.001, count: 3000), sys = [Float](repeating: 0.001, count: 3000)
    for i in 0..<1000 { mic[i] = 0.5; sys[i] = 0.05 }          // 0–10 s: the owner (loud on the mic, echo in the app)
    for i in 1000..<2000 { mic[i] = 0.08; sys[i] = 0.6 }       // 10–20 s: a remote participant
    for i in 2000..<3000 { mic[i] = 0.07; sys[i] = 0.5 }       // 20–30 s: another one
    let segs = [RecordedSegment(speaker: 0, start: 10, end: 20, text: "remote"),
                RecordedSegment(speaker: 1, start: 0, end: 10, text: "me"),
                RecordedSegment(speaker: 2, start: 20, end: 30, text: "remote 2")]
    #expect(Voice.ownerLabel(segments: segs, mic: mic, system: sys, sampleRate: sr) == 1)
    // Only microphone audio (an in-room meeting): no way to tell.
    #expect(Voice.ownerLabel(segments: segs, mic: mic, system: [], sampleRate: sr) == nil)
    #expect(Voice.ownerLabel(segments: segs, mic: mic, system: [Float](repeating: 0, count: 3000), sampleRate: sr) == nil)
}
