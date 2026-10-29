import Foundation
import JinnieCore

// MARK: - Recordings: speaker-attributed transcripts → knowledge

extension Agent {
    /// Recordings transcribed on the Mac and not yet read (or whose speakers were renamed since).
    public var pendingRecordings: [Recording] {
        store.all(Recording.self).filter { $0.status == .ready && $0.processedAt == nil && !$0.segments.isEmpty }
    }

    public func processRecordings() async {
        guard claudeLimitedUntil == nil else { return }
        for rec in pendingRecordings.sorted(by: { $0.startedAt < $1.startedAt }) {
            var run = RunLog(kind: "recording")
            store.save(run)
            do {
                let stats = try await processRecording(rec)
                run.message = "\(rec.title): \(stats.description)"
            } catch {
                run.ok = false
                run.message = "\(rec.title): \(error)"
                log("Recording failed: \(error)")
                // Over the plan's limit: this and the rest stay pending until it resets.
                if (error as? ClaudeError)?.isLimit == true { run.finishedAt = Date(); store.save(run); return }
            }
            run.finishedAt = Date()
            store.save(run)
        }
    }

    @discardableResult
    func processRecording(_ rec: Recording) async throws -> ApplyStats {
        let dir = Directory(store: store)
        let names = rec.speakers.filter { $0.talkSeconds >= 1 }.map { s -> String in
            let n = rec.name(of: s.label, in: dir)
            return n == "You" ? "You (the owner, \(JinnieConfig.ownerName))" : (dir.person(id: s.personID)?.display ?? s.name ?? n + " (not identified yet)")
        }
        let meeting = rec.meetingItemID.flatMap { store.get(Item.self, $0) }
        let end = rec.startedAt.addingTimeInterval(rec.duration)
        let glossary = Set(store.all(Recording.self).flatMap { $0.corrections ?? [] }.filter { $0.remember == true }.map(\.to))
            .sorted().joined(separator: ", ")
        let task = """
        \(rec.isExternal
            ? "Below is the transcript Microsoft Teams made of a meeting recorded on \(Prompts.isoString(rec.startedAt)) (\(Int(rec.duration / 60)) min, until \(Prompts.isoString(end))). It was shared with the owner, who was most likely not in it: nothing in it is the owner's own commitment unless \"You\" speak. Speaker names come from Teams."
            : "Below is the transcript of a conversation the owner recorded on \(Prompts.isoString(rec.startedAt)) (\(Int(rec.duration / 60)) min, until \(Prompts.isoString(end))), transcribed and separated by speaker on the owner's Mac.") \
        \(meeting.map { "It was most likely the calendar meeting \"\($0.title)\" (item \($0.id))." } ?? "")
        Speakers: \(names.joined(separator: "; ")).
        Transcription can mishear names and terms (the owner speaks \(OwnerProfile.current.languages)): use the directory to read them correctly. \
        \(glossary.isEmpty ? "" : "Terms the owner uses (fix similar-sounding words): \(glossary). ")\
        Speaker separation can occasionally mix two voices; if a line clearly can't be that speaker, rely on the content.

        Return ONE item: sourceRef = "\(rec.id)", title = a descriptive meeting title (\"\(rec.title)\" is only a default), \
        occurredAt = the start time, author = the owner, summary = what was discussed and decided (3-5 sentences), facts = \
        decisions, numbers, dates, risks and opinions, each attributed to the speaker by name ("Dana Fischer said Acme \
        wants to start in November"). People: everyone identified, plus anyone mentioned who matters. \
        Actions: what "You" committed to → next actions; what others committed to deliver to the owner → waiting actions with \
        that person and any stated date. Unidentified speakers ("Speaker 3") can't own waiting actions: describe the commitment \
        in the item's facts instead.

        speakerGuesses: for each speaker marked "not identified", say who they most likely are when the content makes it \
        reasonably clear (they're addressed by name, introduce themselves, speak for a company or in a known role, or reply \
        to the owner by name). Use exact directory names, or "You" for the owner. Skip speakers you can't place.

        meetingMood: the tone. "heated" = open conflict: raised voices, blame, people talking over each other, sharp \
        pushback or frustration; "tense" = visible disagreement or pressure, but civil; "calm" = businesslike; "positive" = \
        warm, agreement, good news. Judge from what is said (the transcript has no voices), and say why in one sentence.

        TRANSCRIPT:
        \(rec.transcript(dir))
        """
        let open = store.all(Action.self).filter { $0.status == .open }
        var call = Claude.Call(prompt: task + "\n\n" + Prompts.extractionRules(directory: dir, openActions: open, today: Prompts.dayString(Date())))
        call.systemPrompt = Prompts.system
        call.strictMCP = true
        call.mcpConfig = #"{"mcpServers":{}}"#
        call.jsonSchema = Prompts.extractionSchema
        call.label = "recording"
        call.timeout = 1200
        let r = try await claude.run(call)
        guard r.structured != nil else { throw ClaudeError(message: "No structured output: \(r.text.prefix(300))") }
        let stats = apply(r.structured, source: .recording)
        // Keep the full speaker-attributed transcript on the item, and link the people who spoke.
        var fresh = store.get(Recording.self, rec.id) ?? rec
        if var item = store.find(Item.self, key: "recording:\(rec.id)") {
            item.text = rec.transcript(Directory(store: store))
            for id in rec.speakers.compactMap(\.personID) where !item.personIDs.contains(id) && dir.person(id: id)?.isMe != true { item.personIDs.append(id) }
            if let m = meeting { for pid in m.projectIDs where !item.projectIDs.contains(pid) { item.projectIDs.append(pid) } }
            item = store.save(item)
            fresh.itemID = item.id
            if fresh.title.hasPrefix("Recording") { fresh.title = item.title }
        }
        // Suggestions for unnamed voices, for one-tap confirmation (confirming also teaches Jinnie the voice).
        let me = dir.people.first(where: \.isMe)
        for g in (r.structured as? [String: Any])?["speakerGuesses"] as? [[String: Any]] ?? [] {
            guard let label = (g["speaker"] as? String).flatMap({ Int($0.filter(\.isNumber)) }).map({ $0 - 1 }),
                  let i = fresh.speakers.firstIndex(where: { $0.label == label && $0.personID == nil }),
                  let name = g["person"] as? String else { continue }
            let person = name.lowercased() == "you" ? me : (dir.person(name: name, projectHint: meeting?.projectIDs.first) ?? dir.person(email: name))
            guard let person, !fresh.speakers.contains(where: { $0.personID == person.id }) else { continue }
            fresh.speakers[i].suggestedPersonID = person.id
            fresh.speakers[i].suggestionWhy = (g["why"] as? String)?.nilIfEmpty
        }
        if let m = (r.structured as? [String: Any])?["meetingMood"] as? [String: Any], let mood = m["mood"] as? String {
            fresh.mood = mood
            fresh.moodWhy = (m["why"] as? String)?.nilIfEmpty
        }
        fresh.processedAt = Date()
        store.save(fresh)
        log("Recording \(fresh.title): \(stats.description) · $\(String(format: "%.2f", r.costUSD))")
        return stats
    }

    static let moodSchema = #"{"type":"object","required":["mood","why"],"properties":{"mood":{"type":"string","enum":["positive","calm","tense","heated"]},"why":{"type":"string"}}}"#

    /// The tone of recordings read before Jinnie judged moods (a few per cycle).
    public func assessMoods(limit: Int = 3) async {
        let dir = Directory(store: store)
        for rec in store.all(Recording.self).filter({ $0.processedAt != nil && $0.mood == nil && !$0.segments.isEmpty })
            .sorted(by: { $0.startedAt > $1.startedAt }).prefix(limit) {
            var call = Claude.Call(prompt: """
            What was the tone of this meeting? "heated" = open conflict: raised voices, blame, people talking over each other, \
            sharp pushback or frustration; "tense" = visible disagreement or pressure, but civil; "calm" = businesslike; \
            "positive" = warm, agreement, good news. Judge from what is said (there are no voices), and say why in one sentence, \
            naming who.

            "\(rec.title)", \(Prompts.isoString(rec.startedAt)):
            \(rec.transcript(dir))
            """)
            call.strictMCP = true
            call.mcpConfig = #"{"mcpServers":{}}"#
            call.model = Agent.routineModel
            call.jsonSchema = Agent.moodSchema
            call.label = "recording-mood"
            call.timeout = 600
            do {
                let r = try await claude.run(call)
                guard let o = r.structured as? [String: Any], let mood = o["mood"] as? String else { continue }
                var fresh = store.get(Recording.self, rec.id) ?? rec
                fresh.mood = mood
                fresh.moodWhy = (o["why"] as? String)?.nilIfEmpty
                store.save(fresh)
                log("Mood of \(rec.title): \(mood) · $\(String(format: "%.2f", r.costUSD))")
            } catch { log("Mood of \(rec.title) failed: \(error)") }
        }
    }

    /// Summarises the recordings someone asked for (from either device).
    public func summarizeRequestedRecordings() async {
        for rec in store.all(Recording.self) where rec.summaryPending && !rec.segments.isEmpty {
            do { try await summarizeRecording(rec.id) } catch { log("Summary of \(rec.title) failed: \(error)") }
        }
        for rec in store.all(Recording.self) where rec.notesPending && !rec.segments.isEmpty {
            do { try await generateMeetingNotes(rec.id) } catch { log("Meeting notes for \(rec.title) failed: \(error)") }
        }
    }

    static let notesSchema = #"{"type":"object","required":["subject","body"],"properties":{"subject":{"type":"string"},"body":{"type":"string"}}}"#

    /// Meeting notes the owner can send to the participants: a subject and a plain-text email body.
    @discardableResult
    public func generateMeetingNotes(_ id: String) async throws -> (subject: String, body: String) {
        guard let rec = store.get(Recording.self, id) else { throw ClaudeError(message: "No such recording") }
        let dir = Directory(store: store)
        let meeting = rec.meetingItemID.flatMap { store.get(Item.self, $0) }
        let attendees = Set((meeting?.personIDs ?? []) + rec.speakers.compactMap(\.personID) + (rec.participantIDs ?? []))
            .compactMap { dir.person(id: $0) }.map { $0.isMe ? "\($0.name) (the owner, sender)" : $0.name }
        var call = Claude.Call(prompt: """
        Write meeting notes that \(JinnieConfig.ownerName) (the owner, shown as "You" in the transcript) will email to the \
        participants after this meeting: "\(rec.title)", \(Prompts.isoString(rec.startedAt)), \(Int(rec.duration / 60)) min.
        Participants: \(attendees.isEmpty ? "see the transcript" : attendees.joined(separator: ", ")).\(rec.isExternal && !rec.speakers.contains(where: { dir.person(id: $0.personID)?.isMe == true }) ? "\nThe owner was NOT in this meeting (Teams shared the recording with them): don't list them as an attendee, and open with a line saying they are sharing the notes from the recording." : "")
        The transcript was made automatically and can mishear names and terms: use the directory to read them right.

        subject: "Meeting notes: <short topic> (<day, e.g. 27 Oct>)".
        body: plain text, no Markdown (no asterisks or #), ready to paste into an email. In the language the meeting was \
        held in. Structure:
        - one opening line ("Hi all," or "Hi <name>," for two people) and one line saying these are the notes from the call;
        - "Attendees:" names;
        - "Summary:" 2-4 sentences;
        - "Decisions:" lines starting with "- ";
        - "Action items:" lines "- <Owner>: <what> (by <date>)" (omit the date if none was said), only what someone took on;
        - "Open questions:" if any;
        - a short closing line, then the owner's first name.
        Neutral and factual, as the participants would agree it happened: no opinions about people, no internal remarks, \
        nothing said privately or off-topic. Leave out a section that would be empty.

        DIRECTORY:
        \(dir.promptText)

        TRANSCRIPT:
        \(rec.transcript(dir))
        """)
        call.systemPrompt = Prompts.system
        call.strictMCP = true
        call.mcpConfig = #"{"mcpServers":{}}"#
        call.model = Agent.routineModel
        call.jsonSchema = Agent.notesSchema
        call.label = "meeting-notes"
        call.timeout = 900
        let r = try await claude.run(call)
        guard let o = r.structured as? [String: Any], let subject = o["subject"] as? String, let body = o["body"] as? String,
              !body.isEmpty else { throw ClaudeError(message: "No meeting notes: \(r.text.prefix(200))") }
        var fresh = store.get(Recording.self, id) ?? rec
        fresh.notesSubject = subject
        fresh.notes = body
        fresh.notesAt = Date()
        store.save(fresh)
        log("Meeting notes for \(fresh.title) · $\(String(format: "%.2f", r.costUSD))")
        return (subject, body)
    }

    /// A readable summary of a recording: overview, decisions, action items with owners, open questions.
    @discardableResult
    public func summarizeRecording(_ id: String) async throws -> String {
        guard let rec = store.get(Recording.self, id) else { throw ClaudeError(message: "No such recording") }
        let dir = Directory(store: store)
        let meeting = rec.meetingItemID.flatMap { store.get(Item.self, $0) }
        let projects = (meeting?.projectIDs ?? []).compactMap { dir.project(id: $0)?.name }
        var call = Claude.Call(prompt: """
        Summarise this meeting for \(JinnieConfig.ownerName) (the owner, shown as "You" if they spoke\(rec.isExternal ? "; they were most likely not in it" : "")).
        Meeting: "\(rec.title)", \(Prompts.isoString(rec.startedAt)), \(Int(rec.duration / 60)) min.\(projects.isEmpty ? "" : " Project: \(projects.joined(separator: ", ")).")
        The transcript was made automatically and can mishear names and terms: use the directory below to read them right.

        Write Markdown, in English, with these sections (leave out a section that would be empty):
        **Overview**: 2-4 sentences: what the meeting was for and where it ended up.
        **Key points**: bullets, each attributed to the speaker by name where it matters.
        **Decisions**: bullets.
        **Action items**: bullets, "Owner: what (by when)", only what someone actually took on.
        **Open questions and risks**: bullets.
        Be concrete (names, numbers, systems, dates); no filler. Reply with the summary only.

        DIRECTORY:
        \(dir.promptText)

        TRANSCRIPT:
        \(rec.transcript(dir))
        """)
        call.systemPrompt = Prompts.system
        call.strictMCP = true
        call.mcpConfig = #"{"mcpServers":{}}"#
        call.model = Agent.routineModel
        call.label = "recording-summary"
        call.timeout = 900
        let r = try await claude.run(call)
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClaudeError(message: "Empty summary") }
        var fresh = store.get(Recording.self, id) ?? rec
        fresh.summary = text
        fresh.summaryAt = Date()
        store.save(fresh)
        log("Summarised \(fresh.title) · $\(String(format: "%.2f", r.costUSD))")
        return text
    }

    /// The calendar meeting a recording most likely was: one that started from 15 minutes before the recording (you joined
    /// late) to 10 minutes after it (you were early). Not one that merely starts during it: a 10:00 meeting 30 minutes into
    /// a 9:30 call is a different meeting (it took a Teams call's title and attendees once).
    public static func meeting(for start: Date, duration: Double, items: [Item]) -> Item? {
        let window = start.addingTimeInterval(-15 * 60)...start.addingTimeInterval(min(max(duration, 60), 600))
        return items.filter { ($0.source == .calendar || $0.sourceRef.hasPrefix("outlook-cal:")) && window.contains($0.occurredAt) }
            .min { abs($0.occurredAt.timeIntervalSince(start)) < abs($1.occurredAt.timeIntervalSince(start)) }
    }
}
