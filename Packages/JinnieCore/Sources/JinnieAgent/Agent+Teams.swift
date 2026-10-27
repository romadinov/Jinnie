import Foundation
import JinnieCore

// MARK: - Teams recordings shared with the owner → recordings with Teams' own transcript

extension Agent {
    /// On unless turned off in Settings (meta "recordings.teams" = "0").
    public var readsTeamsRecordings: Bool { store.meta("recordings.teams") != "0" }
    public func setReadsTeamsRecordings(_ on: Bool) { store.setMeta("recordings.teams", on ? "1" : "0") }

    /// Off unless turned on in Settings: also record the audio of each new Teams recording (real time, on the Mac).
    public var recordsTeamsAudio: Bool { store.meta("recordings.teams.audio") == "1" }
    public func setRecordsTeamsAudio(_ on: Bool) { store.setMeta("recordings.teams.audio", on ? "1" : "0") }

    /// The hidden browser is playing a recording until then; Outlook reads wait (they'd navigate it away).
    public var browserBusyUntil: Date? {
        get { store.meta("browser.busyUntil").flatMap(Double.init).map(Date.init(timeIntervalSince1970:)).flatMap { $0 > Date() ? $0 : nil } }
        set { store.setMeta("browser.busyUntil", newValue.map { String($0.timeIntervalSince1970) }) }
    }

    static let teamsPerRun = 2

    /// Reads the transcripts of new Teams recordings the owner can open, skipping meetings Jinnie recorded on the Mac.
    /// Each becomes a Recording (speaker names from Teams), which `processRecordings` then learns from.
    @discardableResult
    public func ingestTeamsRecordings(reader: OutlookReader = OutlookReader(), days: Int? = nil, only: String? = nil) throws -> String {
        let cursorKey = "recordings.teams.since"
        let since = days.map { Date().addingTimeInterval(-Double($0) * 86400) }
            ?? store.meta(cursorKey).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
            ?? Date().addingTimeInterval(-2 * 86400)
        let found = try reader.sharedRecordings(since: since)
        let recordings = store.all(Recording.self)
        let known = Set(recordings.compactMap(\.externalID))
        let skipped = Set((store.meta("recordings.teams.skipped") ?? "").split(separator: ",").map(String.init))
        let mine = recordings.filter { !$0.isExternal }
        let candidates = found.filter { r in
            !known.contains("teams:\(r.id)") && !skipped.contains(r.id)
                && (only.map { r.title.localizedCaseInsensitiveContains($0) } ?? true)
                && !mine.contains { Agent.overlaps($0.startedAt, $0.duration, r.start, r.duration) }
        }
        var done: [String] = []
        var noTranscript: [String] = []
        for r in candidates.sorted(by: { $0.start < $1.start }).prefix(Agent.teamsPerRun) {
            log("Teams recording: \(r.title) (\(Prompts.isoString(r.start)))")
            guard let lines = try reader.transcript(of: r) else {
                // Transcripts can appear a little after the recording; give up after a day.
                if r.start < Date().addingTimeInterval(-86400) {
                    store.setMeta("recordings.teams.skipped", (Array(skipped) + [r.id]).suffix(300).joined(separator: ","))
                }
                noTranscript.append(r.title)
                continue
            }
            store.save(recording(from: r, lines: lines))
            done.append("\(r.title) (\(lines.count) lines)")
        }
        // Move the cursor past what is finished, keeping anything still waiting for its turn or its transcript.
        let waiting = candidates.filter { c in !done.contains { $0.hasPrefix(c.title) } }.map(\.start).min()
        if days == nil, only == nil {
            let next = min(waiting ?? Date(), Date()).addingTimeInterval(-3600)
            store.setMeta(cursorKey, String(max(next, since).timeIntervalSince1970))
        }
        var parts = ["\(found.count) shared recordings", "\(done.count) transcripts read"]
        if !done.isEmpty { parts.append(done.joined(separator: "; ")) }
        if !noTranscript.isEmpty { parts.append("no transcript yet: \(noTranscript.joined(separator: ", "))") }
        let left = candidates.count - done.count - noTranscript.count
        if left > 0 { parts.append("\(left) more next time") }
        return parts.joined(separator: " · ")
    }

    static func overlaps(_ a: Date, _ ad: Double, _ b: Date, _ bd: Double) -> Bool {
        let aEnd = a.addingTimeInterval(max(ad, 60)), bEnd = b.addingTimeInterval(max(bd, 60))
        return a < bEnd && b < aEnd
    }

    func recording(from r: TeamsRecording, lines: [TeamsTranscriptLine]) -> Recording {
        let dir = Directory(store: store)
        let me = store.all(Person.self).first(where: \.isMe)
        var rec = Recording(title: r.title)
        rec.startedAt = r.start
        rec.duration = max(r.duration, (lines.last?.t ?? 0) + 5)
        rec.device = "Teams"
        rec.app = "Teams"
        rec.externalID = "teams:\(r.id)"
        rec.sourceURL = r.playerURL
        var labels: [String: Int] = [:]
        for l in lines where labels[l.s] == nil { labels[l.s] = labels.count }
        rec.segments = lines.enumerated().map { i, l in
            let next = i + 1 < lines.count ? lines[i + 1].t : rec.duration
            return RecordedSegment(speaker: labels[l.s], start: l.t, end: max(l.t + 1, min(next, l.t + 60)), text: l.x)
        }
        rec.speakers = labels.sorted { $0.value < $1.value }.map { name, label in
            var s = RecordedSpeaker(label: label)
            let person = (me.map { Directory.norm($0.name) == Directory.norm(name) } == true) ? me : dir.person(name: name)
            s.personID = person?.id
            s.namedBy = person == nil ? nil : .owner
            s.name = person == nil ? name : nil
            let mine = rec.segments.filter { $0.speaker == label }
            s.talkSeconds = mine.reduce(0) { $0 + $1.end - $1.start }
            if let longest = mine.max(by: { $0.text.count < $1.text.count }) { s.sample = String(longest.text.prefix(160)); s.sampleAt = longest.start }
            return s
        }
        rec.meetingItemID = Agent.meeting(for: rec.startedAt, duration: rec.duration, items: store.all(Item.self))?.id
        rec.status = .ready
        if recordsTeamsAudio { rec.audioRequestedAt = Date() }
        return rec
    }
}
