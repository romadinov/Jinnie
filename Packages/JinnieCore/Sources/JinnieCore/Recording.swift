import Foundation

// MARK: - Recording (a meeting or conversation recorded on the Mac)

/// A recorded conversation: who spoke when (speaker separation) and what they said (transcription), done on the Mac.
/// Speakers are named automatically when their voice matches someone's voiceprint, otherwise by the owner, once;
/// that teaches Jinnie the voice. The audio itself stays on the Mac; this record syncs without it.
public struct Recording: Entity {
    public static let type = "recording"
    public var id = newID()
    public var updatedAt = Date()
    public var deleted = false

    public enum Status: String, Codable, Sendable { case recording, processing, ready, failed }

    public var title: String
    public var startedAt = Date()
    public var duration: Double = 0
    public var status: Status = .recording
    public var error: String?
    public var device: String = ""
    public var speakers: [RecordedSpeaker] = []
    public var segments: [RecordedSegment] = []
    /// The calendar meeting it most likely was (item id), for the title and likely speakers.
    public var meetingItemID: String?
    /// Set once the agent has extracted knowledge from the transcript; cleared when speakers are renamed.
    public var processedAt: Date?
    public var itemID: String?
    /// The meeting app whose audio was recorded too ("Zoom"), when it was an online call.
    public var app: String?
    /// Started by meeting detection rather than by hand.
    public var autoStarted: Bool?
    /// People known to be on the call without a calendar entry (a messenger call's caller).
    public var participantIDs: [String]?
    /// Word fixes made by the owner ("Innitek" → "Initech"); remembered ones are applied to every new transcript.
    public var corrections: [TranscriptCorrection]?
    /// A recording Jinnie read rather than made, e.g. "teams:<file id>" for a Teams meeting shared with the owner.
    public var externalID: String?
    /// Where to watch it (the Stream player), for an external recording.
    public var sourceURL: String?
    /// For an external recording: the owner asked the Mac to record its audio (by playing it in the hidden browser).
    public var audioRequestedAt: Date?
    /// When that audio was recorded and transcribed on the Mac, or why it failed.
    public var audioAt: Date?
    public var audioError: String?
    /// The Mac's own (Whisper) transcript of that audio, kept beside the Teams one; speakers taken from Teams by time.
    public var localSegments: [RecordedSegment]?

    public var audioPending: Bool { audioRequestedAt.map { $0 > (audioAt ?? .distantPast) } ?? false && audioError == nil }

    /// A written summary of the meeting (Markdown), made on request.
    public var summary: String?
    public var summaryAt: Date?
    /// Set from either device; the Mac summarises on its next quick run.
    public var summaryRequestedAt: Date?

    /// The tone of the meeting, judged from the transcript: positive, calm, tense or heated; and why.
    public var mood: String?
    public var moodWhy: String?
    public var isHeated: Bool { mood == "heated" }

    /// Meeting notes to send to the participants (plain text, with a subject), made on request.
    public var notesSubject: String?
    public var notes: String?
    public var notesAt: Date?
    public var notesRequestedAt: Date?
    public var notesPending: Bool { notesRequestedAt.map { $0 > (notesAt ?? .distantPast) } ?? false }

    public var summaryPending: Bool { summaryRequestedAt.map { $0 > (summaryAt ?? .distantPast) } ?? false }

    public init(title: String) { self.title = title }

    /// Transcribed elsewhere (Teams), with speaker names from there.
    public var isExternal: Bool { externalID != nil }

    public var searchText: String { ([title] + segments.map(\.text)).joined(separator: " ") }

    /// Start times of a speaker's longest stretches (at least 2 s, in order of length), for playing their voice.
    public func sampleTimes(for label: Int, max: Int = 5) -> [Double] {
        let mine = segments.filter { $0.speaker == label && $0.end - $0.start >= 2 }.sorted { $0.end - $0.start > $1.end - $1.start }
        return Array(mine.prefix(max).map(\.start))
    }

    /// One person split into two voices: `from`'s lines become `into`'s, talk time adds up, `from` goes.
    public mutating func mergeSpeaker(_ from: Int, into: Int) {
        guard from != into, let i = speakers.firstIndex(where: { $0.label == from }),
              let k = speakers.firstIndex(where: { $0.label == into }) else { return }
        for j in segments.indices where segments[j].speaker == from { segments[j].speaker = into }
        for j in (localSegments ?? []).indices where localSegments![j].speaker == from { localSegments![j].speaker = into }
        let a = speakers[i], b = speakers[k]
        if b.personID == nil, let p = a.personID { speakers[k].personID = p; speakers[k].namedBy = a.namedBy }
        if let ea = a.embedding, let eb = b.embedding, ea.count == eb.count {
            let wa = Float(a.talkSeconds), wb = Float(b.talkSeconds), w = max(wa + wb, 1)
            speakers[k].embedding = zip(ea, eb).map { ($0 * wa + $1 * wb) / w }
        } else if b.embedding == nil { speakers[k].embedding = a.embedding }
        speakers[k].talkSeconds += a.talkSeconds
        if speakers[k].sample == nil { speakers[k].sample = a.sample; speakers[k].sampleAt = a.sampleAt }
        speakers.remove(at: i)
    }

    public func speaker(_ label: Int?) -> RecordedSpeaker? { label.flatMap { l in speakers.first { $0.label == l } } }
    public var unnamedSpeakers: [RecordedSpeaker] { speakers.filter { $0.personID == nil && $0.talkSeconds >= 3 } }

    /// "Dana Fischer", "You", or "Speaker 2".
    public func name(of label: Int?, in dir: Directory) -> String {
        guard let s = speaker(label) else { return "Unknown speaker" }
        guard let p = dir.person(id: s.personID) else { return s.name ?? "Speaker \(s.label + 1)" }
        return p.isMe ? "You" : p.name
    }

    /// Consecutive segments of the same speaker: what the transcript shows as one line.
    public struct Turn: Hashable, Sendable {
        public var label: Int?
        public var start: Double
        public var text: String
        /// Indices into `segments`.
        public var indices: [Int]
    }

    public var turns: [Turn] {
        var out: [Turn] = []
        for i in segments.indices.sorted(by: { segments[$0].start < segments[$1].start }) {
            let seg = segments[i]
            if var last = out.last, last.label == seg.speaker {
                last.text += " " + seg.text
                last.indices.append(i)
                out[out.count - 1] = last
            } else {
                out.append(Turn(label: seg.speaker, start: seg.start, text: seg.text, indices: [i]))
            }
        }
        return out.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Consecutive segments of the same speaker merged into turns, with times: "[03:12] Dana Fischer: …".
    public func transcript(_ dir: Directory) -> String {
        turns.map { "[\(Recording.clock($0.start))] \(name(of: $0.label, in: dir)): \($0.text.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n")
    }

    /// Replaces one line's text: its first segment takes the new text (and the whole time span), the rest go.
    public mutating func setText(of turn: Turn, to text: String) {
        guard let first = turn.indices.first, segments.indices.contains(first) else { return }
        let end = turn.indices.compactMap { segments.indices.contains($0) ? segments[$0].end : nil }.max() ?? segments[first].end
        segments[first].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        segments[first].end = end
        for i in turn.indices.dropFirst().sorted(by: >) where segments.indices.contains(i) { segments.remove(at: i) }
    }

    /// Stock phrases Whisper "hears" in silence or music, learned from subtitled training data.
    public static let hallucinations = [
        "Продолжение следует", "Субтитры сделал DimaTorzok", "Субтитры создавал DimaTorzok", "Редактор субтитров",
        "Корректор А.Егорова", "Субтитры", "Спасибо за просмотр", "Thank you for watching", "Thanks for watching",
        "Please subscribe", "[BLANK_AUDIO]", "(music)", "[Music]", "♪",
    ]

    /// A segment's text without those phrases; empty if nothing real is left.
    public static func withoutHallucinations(_ s: String) -> String {
        var t = s
        for j in hallucinations where t.localizedCaseInsensitiveContains(j) { t = t.replacingOccurrences(of: j, with: "", options: .caseInsensitive) }
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaningful = trimmed.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces).subtracting(CharacterSet(charactersIn: "?!")))
        return meaningful.isEmpty ? "" : trimmed
    }

    /// Removes those phrases from every segment (dropping segments left empty). Returns how many segments changed.
    @discardableResult
    public mutating func removeHallucinations() -> Int {
        var changed = 0
        segments = segments.compactMap { seg in
            let t = Recording.withoutHallucinations(seg.text)
            if t != seg.text { changed += 1 }
            guard !t.isEmpty else { return nil }
            var s = seg; s.text = t; return s
        }
        return changed
    }

    /// Replaces a word or phrase everywhere in the transcript (whole words, any case). Returns how many were replaced.
    @discardableResult
    public mutating func replace(_ from: String, with to: String) -> Int {
        var count = 0
        for i in segments.indices {
            let (text, n) = Recording.replacing(segments[i].text, from, to)
            segments[i].text = text
            count += n
        }
        return count
    }

    public static func replacing(_ text: String, _ from: String, _ to: String) -> (String, Int) {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: from.trimmingCharacters(in: .whitespaces)) + "(?![\\p{L}\\p{N}])"
        guard !from.trimmingCharacters(in: .whitespaces).isEmpty,
              let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return (text, 0) }
        let range = NSRange(text.startIndex..., in: text)
        let n = re.numberOfMatches(in: text, range: range)
        guard n > 0 else { return (text, 0) }
        return (re.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: to)), n)
    }

    public static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

public struct RecordedSpeaker: Codable, Hashable, Sendable {
    /// Cluster id from speaker separation (0-based).
    public var label: Int
    public var personID: String?
    /// Their voice in this recording (centroid embedding).
    public var embedding: [Float]?
    /// How the name was set: matched by voice, or given by the owner.
    public var namedBy: NamedBy?
    /// Similarity of the voice match (0…1), when matched automatically.
    public var match: Float?
    public var talkSeconds: Double = 0
    /// Something they said, to recognise them by.
    public var sample: String?
    /// Where that sample starts (seconds), for playback.
    public var sampleAt: Double?
    /// Who the agent thinks it is from what was said ("Thanks Alex", "as Acme's finance lead…"), for one-tap confirmation.
    public var suggestedPersonID: String?
    public var suggestionWhy: String?
    /// The name the transcript came with (Teams knows who spoke), when it matched no one in the directory yet.
    public var name: String?

    public enum NamedBy: String, Codable, Sendable { case voice, owner }

    public init(label: Int) { self.label = label }
}

public struct TranscriptCorrection: Codable, Hashable, Sendable {
    public var from: String
    public var to: String
    /// Apply to future transcripts too.
    public var remember: Bool?
    public init(from: String, to: String, remember: Bool) { self.from = from; self.to = to; self.remember = remember }
}

public struct RecordedSegment: Codable, Hashable, Sendable {
    public var speaker: Int?
    public var start: Double
    public var end: Double
    public var text: String
    public init(speaker: Int?, start: Double, end: Double, text: String) { self.speaker = speaker; self.start = start; self.end = end; self.text = text }
}

// MARK: - Voice matching

public enum Voice {
    /// Cosine similarity of two embeddings (0 when they can't be compared).
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// With two tracks (your microphone, and the meeting app's audio), the owner is the speaker who is much louder on the
    /// microphone than in the app's audio: remote participants are the other way round. Nil when it isn't clear.
    public static func ownerLabel(segments: [RecordedSegment], mic: [Float], system: [Float], sampleRate: Double = 16000) -> Int? {
        func energy(_ x: [Float], _ a: Int, _ b: Int) -> Double {
            guard a < b, a < x.count else { return 0 }
            var e = 0.0
            for i in a..<min(b, x.count) { e += Double(x[i] * x[i]) }
            return e
        }
        // Only meaningful when the app's audio was captured (an online call); in a room everyone is on the microphone.
        guard system.count > Int(sampleRate), system.contains(where: { abs($0) > 0.01 }) else { return nil }
        var micE: [Int: Double] = [:], sysE: [Int: Double] = [:], talk: [Int: Double] = [:]
        for s in segments {
            guard let l = s.speaker else { continue }
            let a = Int(s.start * sampleRate), b = Int(s.end * sampleRate)
            micE[l, default: 0] += energy(mic, a, b)
            sysE[l, default: 0] += energy(system, a, b)
            talk[l, default: 0] += s.end - s.start
        }
        let ratios = micE.keys.filter { (talk[$0] ?? 0) >= 3 }.map { ($0, (micE[$0] ?? 0) / max(sysE[$0] ?? 0, 1e-9)) }.sorted { $0.1 > $1.1 }
        guard let top = ratios.first, top.1 >= 3 else { return nil }
        if ratios.count > 1, ratios[1].1 * 2 > top.1 { return nil }
        return top.0
    }

    /// Same-speaker threshold for pyannote/wespeaker centroids from separate recordings. Deliberately strict: a wrong
    /// name is worse than asking.
    public static let threshold: Float = 0.62

    /// The person whose voiceprints best match `embedding`, if confidently above the threshold and clearly ahead of the
    /// runner-up. `candidates` (e.g. meeting attendees) get a small bonus.
    public static func bestMatch(_ embedding: [Float], people: [Person], candidates: Set<String> = []) -> (personID: String, similarity: Float)? {
        var scored: [(String, Float)] = []
        for p in people {
            guard let samples = p.voiceSamples, !samples.isEmpty else { continue }
            let best = samples.map { similarity(embedding, $0.embedding) }.max() ?? 0
            scored.append((p.id, best + (candidates.contains(p.id) ? 0.03 : 0)))
        }
        scored.sort { $0.1 > $1.1 }
        guard let top = scored.first, top.1 >= threshold else { return nil }
        if scored.count > 1, top.1 - scored[1].1 < 0.05 { return nil }  // two people sound alike: ask instead
        return (top.0, min(1, top.1))
    }

    /// Adds a voice sample, keeping the 8 newest (one per recording and speaker).
    public static func learn(_ embedding: [Float], into person: inout Person, recordingID: String? = nil, label: Int? = nil) {
        var samples = (person.voiceSamples ?? []).filter { !($0.recordingID != nil && $0.recordingID == recordingID && $0.speakerLabel == label) }
        samples.append(VoiceSample(embedding: embedding, recordingID: recordingID, speakerLabel: label))
        person.voiceSamples = Array(samples.suffix(8))
    }

    /// Forgets the samples that make `embedding` sound like this person: the fix for a wrong voice match.
    @discardableResult
    public static func unlearn(_ embedding: [Float], from person: inout Person) -> Int {
        let before = person.voiceSamples?.count ?? 0
        person.voiceSamples = person.voiceSamples?.filter { similarity(embedding, $0.embedding) < threshold }
        if person.voiceSamples?.isEmpty == true { person.voiceSamples = nil }
        return before - (person.voiceSamples?.count ?? 0)
    }

    /// Assigns names by voice: each person at most once per recording, best matches first.
    public static func identify(_ speakers: inout [RecordedSpeaker], people: [Person], candidates: Set<String> = []) {
        var taken = Set(speakers.compactMap(\.personID))
        let order = speakers.indices.filter { speakers[$0].personID == nil && speakers[$0].embedding != nil }
        var proposals: [(idx: Int, person: String, sim: Float)] = []
        for i in order {
            if let m = bestMatch(speakers[i].embedding!, people: people, candidates: candidates) { proposals.append((i, m.personID, m.similarity)) }
        }
        for p in proposals.sorted(by: { $0.sim > $1.sim }) where !taken.contains(p.person) {
            speakers[p.idx].personID = p.person
            speakers[p.idx].namedBy = .voice
            speakers[p.idx].match = p.sim
            taken.insert(p.person)
        }
    }
}

// MARK: - Naming speakers

public extension Store {
    /// Names a speaker (nil = "not sure") and teaches Jinnie the voice. If the voice had been matched to someone else, the
    /// samples that caused that match are forgotten first, so the mistake doesn't come back. Other recordings still waiting
    /// for names are re-checked, and the transcript is re-read by the agent.
    func assignSpeaker(recordingID: String, label: Int, personID: String?) {
        guard var r = get(Recording.self, recordingID), let i = r.speakers.firstIndex(where: { $0.label == label }) else { return }
        let previous = r.speakers[i].personID
        if let e = r.speakers[i].embedding {
            if let previous, previous != personID, var old = get(Person.self, previous) {
                Voice.unlearn(e, from: &old)
                save(old)
            }
            if let personID, var p = get(Person.self, personID) {
                Voice.learn(e, into: &p, recordingID: r.id, label: label)
                save(p)
            }
        }
        // The same person on another voice: speaker separation split one person in two. Merge into that voice.
        if let personID, let k = r.speakers.firstIndex(where: { $0.label != label && $0.personID == personID }) {
            r.mergeSpeaker(label, into: r.speakers[k].label)
            r.processedAt = nil
            save(r)
            relabelRecordings(except: r.id)
            return
        }
        r.speakers[i].personID = personID
        r.speakers[i].namedBy = personID == nil ? nil : .owner
        r.speakers[i].match = nil
        r.speakers[i].suggestedPersonID = nil
        r.processedAt = nil
        save(r)
        relabelRecordings(except: r.id)
    }

    /// Merges two voices that are one person (speaker separation split them): see `Recording.mergeSpeaker`.
    func mergeSpeaker(recordingID: String, _ from: Int, into: Int) {
        guard var r = get(Recording.self, recordingID), from != into else { return }
        let target = r.speaker(into)?.personID
        if let e = r.speaker(from)?.embedding, let target, var p = get(Person.self, target) {
            Voice.learn(e, into: &p, recordingID: r.id, label: from)
            save(p)
        }
        r.mergeSpeaker(from, into: into)
        r.processedAt = nil
        save(r)
    }

    /// Forgets one voice sample (or all of them) of a person.
    func forgetVoice(personID: String, sampleAt index: Int? = nil) {
        guard var p = get(Person.self, personID) else { return }
        if let index, var samples = p.voiceSamples, samples.indices.contains(index) {
            samples.remove(at: index)
            p.voiceSamples = samples.isEmpty ? nil : samples
        } else {
            p.voiceSamples = nil
        }
        save(p)
    }

    /// Recordings that still have unnamed voices get another try with what Jinnie now knows.
    func relabelRecordings(except id: String? = nil) {
        let people = all(Person.self)
        for var other in all(Recording.self) where other.id != id && other.status == .ready && !other.unnamedSpeakers.isEmpty {
            let before = other.speakers.map(\.personID)
            Voice.identify(&other.speakers, people: people)
            if other.speakers.map(\.personID) != before { other.processedAt = nil; save(other) }
        }
    }
}
