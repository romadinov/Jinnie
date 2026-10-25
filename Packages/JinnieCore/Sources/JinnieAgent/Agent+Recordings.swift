import Foundation
import JinnieCore

// MARK: - Recordings: speaker-attributed transcripts → knowledge

extension Agent {
    /// Recordings transcribed on the Mac and not yet read (or whose speakers were renamed since).
    public var pendingRecordings: [Recording] {
        store.all(Recording.self).filter { $0.status == .ready && $0.processedAt == nil && !$0.segments.isEmpty }
    }

    public func processRecordings() async {
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
            return n == "You" ? "You (the owner, \(JinnieConfig.ownerName))" : (dir.person(id: s.personID)?.display ?? n + " (not identified yet)")
        }
        let meeting = rec.meetingItemID.flatMap { store.get(Item.self, $0) }
        let end = rec.startedAt.addingTimeInterval(rec.duration)
        let task = """
        Below is the transcript of a conversation the owner recorded on \(Prompts.isoString(rec.startedAt)) \
        (\(Int(rec.duration / 60)) min, until \(Prompts.isoString(end))), transcribed and separated by speaker on the owner's Mac. \
        \(meeting.map { "It was most likely the calendar meeting \"\($0.title)\" (item \($0.id))." } ?? "")
        Speakers: \(names.joined(separator: "; ")).
        Transcription can mishear names and terms (the owner speaks \(OwnerProfile.current.languages)): use the directory to read them correctly. \
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
        fresh.processedAt = Date()
        store.save(fresh)
        log("Recording \(fresh.title): \(stats.description) · $\(String(format: "%.2f", r.costUSD))")
        return stats
    }

    /// The calendar meeting a recording most likely was: one that overlaps its start (±15 min).
    public static func meeting(for start: Date, duration: Double, items: [Item]) -> Item? {
        let window = start.addingTimeInterval(-15 * 60)...start.addingTimeInterval(max(duration, 600))
        return items.filter { ($0.source == .calendar || $0.sourceRef.hasPrefix("outlook-cal:")) && window.contains($0.occurredAt) }
            .min { abs($0.occurredAt.timeIntervalSince(start)) < abs($1.occurredAt.timeIntervalSince(start)) }
    }
}
