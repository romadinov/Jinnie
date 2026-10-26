import Foundation

/// Everything Jinnie stores is an entity: a Codable value with an id, a last-modified time and a
/// tombstone flag. Entities are kept as JSON rows and synced as one CloudKit record each
/// (last writer wins on `updatedAt`).
public protocol Entity: Codable, Identifiable, Hashable, Sendable where ID == String {
    static var type: String { get }
    var id: String { get set }
    var updatedAt: Date { get set }
    var deleted: Bool { get set }
    /// Natural key used for de-duplication (e.g. "email:<thread id>"), if any.
    var naturalKey: String? { get }
    /// Text indexed for full-text search.
    var searchText: String { get }
}

public extension Entity {
    var naturalKey: String? { nil }
}

public func newID() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
}

// MARK: - Project

public struct Project: Entity {
    public static let type = "project"
    public var id = newID()
    public var updatedAt = Date()
    public var deleted = false

    public var name: String
    /// Other names it goes by ("Акме", "Acme Telco") — matched when resolving mentions.
    public var aliases: [String] = []
    /// E-mail domains of the client or partner ("acme-telco.example").
    public var domains: [String] = []
    /// Slack channels associated with the project.
    public var channels: [String] = []
    public var description: String = ""
    public var status: Status = .active
    /// Uberdoer project path ("Work : Acme") and id once known.
    public var uberdoerPath: String?
    public var uberdoerID: String?
    public var summary: String?
    public var summaryAt: Date?
    /// Set from any device to ask the Mac agent for a fresh summary.
    public var summaryRequestedAt: Date?
    /// Who matters on this project and in what role, on each side. Curated by the agent with the summary;
    /// corrected by notes and Ask ("Ravi replaces Lena").
    public var stakeholders: [Stakeholder]?
    /// Latest developments, newest first: short headlines with their sources.
    public var news: [NewsItem]?

    public enum Status: String, Codable, Sendable, CaseIterable { case active, onHold, done }

    public init(name: String) { self.name = name }

    public var searchText: String { ([name] + aliases + domains + channels + [description]).joined(separator: " ") }
}

public struct NewsItem: Codable, Hashable, Sendable {
    public var date: String          // YYYY-MM-DD
    public var headline: String      // <= 12 words
    public var detail: String?       // 1-2 sentences
    public var itemIDs: [String]
    /// Changes plans, money, dates or people: worth surfacing on Today.
    public var important: Bool?
    public init(date: String, headline: String, itemIDs: [String] = []) { self.date = date; self.headline = headline; self.itemIDs = itemIDs }
}

public struct Stakeholder: Codable, Hashable, Sendable {
    public enum Side: String, Codable, Sendable, CaseIterable {
        case ours, customer, partner, other
        public var label: String {
            switch self { case .ours: "Our team"; case .customer: "Customer"; case .partner: "Partners"; case .other: "Others" }
        }
    }
    public var personID: String
    public var side: Side
    /// Project role ("B2B Program Lead", "Solution Architect").
    public var role: String
    /// What they own or decide on this project.
    public var responsibilities: String?
    /// One of the few people who matter most.
    public var key: Bool?
    /// No longer on the project (left, replaced).
    public var former: Bool?
    public var replacedByID: String?

    public init(personID: String, side: Side, role: String) { self.personID = personID; self.side = side; self.role = role }
}

// MARK: - Person

public struct Person: Entity {
    public static let type = "person"
    public var id = newID()
    public var updatedAt = Date()
    public var deleted = false

    public var name: String
    public var emails: [String] = []
    /// Nicknames, first names, Slack handles, transliterations ("Бхарат").
    public var aliases: [String] = []
    public var org: String?
    public var role: String?
    public var projectIDs: [String] = []
    public var notes: String = ""
    public var isMe = false
    /// Voice samples (speaker embeddings) from recordings where this person was identified; newest last, at most 8.
    public var voiceSamples: [VoiceSample]?

    public init(name: String) { self.name = name }

    public var naturalKey: String? { emails.first.map { "email:" + $0.lowercased() } }
    public var searchText: String { ([name] + emails + aliases + [org ?? "", role ?? "", notes]).joined(separator: " ") }
    public var display: String { emails.first.map { "\(name) <\($0)>" } ?? name }
    public var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

/// One sample of someone's voice: the speaker embedding from one recording, so it can be shown, played and forgotten.
public struct VoiceSample: Codable, Hashable, Sendable {
    public var embedding: [Float]
    public var recordingID: String?
    public var speakerLabel: Int?
    public var addedAt: Date
    public init(embedding: [Float], recordingID: String? = nil, speakerLabel: Int? = nil, addedAt: Date = Date()) {
        self.embedding = embedding; self.recordingID = recordingID; self.speakerLabel = speakerLabel; self.addedAt = addedAt
    }
}

// MARK: - Item (a piece of attributed information)

public enum Source: String, Codable, Sendable, CaseIterable {
    case email, slack, calendar, drive, outlook, remarkable, recording, note, manual
    /// Sources Jinnie reads on a schedule (claude.ai connectors, plus Outlook on the web and reMarkable Cloud).
    public static let connectors: [Source] = [.email, .slack, .calendar, .drive, .outlook, .remarkable]
    public var label: String {
        switch self {
        case .email: "Email"; case .slack: "Slack"; case .calendar: "Calendar"; case .drive: "Drive"; case .outlook: "Outlook"; case .remarkable: "reMarkable"; case .recording: "Recording"; case .note: "Note"; case .manual: "Manual"
        }
    }
    public var symbol: String {
        switch self {
        case .email: "envelope"; case .slack: "number"; case .calendar: "calendar"; case .drive: "doc.text"; case .outlook: "tray.full"; case .remarkable: "pencil.and.scribble"; case .recording: "waveform"; case .note: "note.text"; case .manual: "pencil"
        }
    }
}

/// A document referenced by an item (a Drive doc linked in an email, a transcript attached to a meeting…).
public struct DocLink: Codable, Hashable, Sendable {
    public var title: String
    public var url: String
    /// transcript, meeting notes, SOW, proposal, design, spreadsheet, slides… (free text)
    public var kind: String?
    public init(title: String, url: String, kind: String? = nil) { self.title = title; self.url = url; self.kind = kind }
}

/// One source document (an email thread, a Slack thread, a meeting, a note) and what was learned from it.
public struct Item: Entity {
    public static let type = "item"
    public var id = newID()
    public var updatedAt = Date()
    public var deleted = false

    public var source: Source
    /// Id in the source system (thread id, channel+ts, event id, note id).
    public var sourceRef: String
    public var url: String?
    public var title: String
    public var author: String?
    public var authorEmail: String?
    public var occurredAt: Date
    /// A short verbatim excerpt kept as evidence.
    public var excerpt: String = ""
    public var summary: String = ""
    /// Atomic statements learned from this item, each attributable to it.
    public var facts: [String] = []
    /// Documents this item links to or is (for Drive items, the document itself).
    public var documents: [DocLink]?
    public var projectIDs: [String] = []
    public var personIDs: [String] = []
    /// The full text, when Jinnie produced it itself (a transcribed handwritten notebook).
    public var text: String?

    public init(source: Source, sourceRef: String, title: String, occurredAt: Date) {
        self.source = source; self.sourceRef = sourceRef; self.title = title; self.occurredAt = occurredAt
    }

    public var naturalKey: String? { "\(source.rawValue):\(sourceRef)" }
    public var searchText: String {
        ([title, author ?? "", authorEmail ?? "", summary, excerpt, text ?? ""] + facts + (documents ?? []).map(\.title)).joined(separator: " ")
    }
}

// MARK: - Action

public struct Action: Entity {
    public static let type = "action"
    public var id = newID()
    public var updatedAt = Date()
    public var deleted = false

    public enum Kind: String, Codable, Sendable { case next, waiting }
    public enum Status: String, Codable, Sendable { case open, done, dropped }

    public var kind: Kind
    /// For `next`: the action. For `waiting`: what I need from the person.
    public var title: String
    public var personID: String?
    /// The name as mentioned, when it matched no known person (resolved later as people are learned).
    public var personName: String?
    public var projectID: String?
    public var due: String?           // YYYY-MM-DD
    public var status: Status = .open
    public var itemID: String?
    public var createdAt = Date()
    public var uberdoerID: String?
    public var uberdoerChanged: String?
    public var syncError: String?
    /// Jinnie changed `status` itself (e.g. saw the item delivered); Uberdoer must follow.
    public var needsPush: Bool?
    /// Why this action exists: background, who asked, what "done" looks like (from the source).
    public var context: String?
    /// The words in the source where the commitment or request was made.
    public var quote: String?
    /// Fingerprint of the note Jinnie last wrote into the Uberdoer task; a different note there means the user edited it.
    public var uberdoerNoteHash: String?

    public init(kind: Kind, title: String) { self.kind = kind; self.title = title }

    public var searchText: String { [title, context ?? "", quote ?? "", personName ?? ""].joined(separator: " ") }

    /// Opens this action in Jinnie (Mac or iPhone).
    public var jinnieURL: String { "jinnie://action/\(id)" }
    /// Reveals the task in Uberdoer.
    public var uberdoerURL: URL? { uberdoerID.flatMap { URL(string: "uberdoer://task/\($0)") } }
}

// MARK: - Note (captured by the user on Mac or iPhone)

public struct Note: Entity {
    public static let type = "note"
    public var id = newID()
    public var updatedAt = Date()
    public var deleted = false

    public var text: String
    public var createdAt = Date()
    public var device: String = ""
    /// Set by the Mac agent after it has extracted knowledge from the note.
    public var processedAt: Date?
    public var itemID: String?
    public var processError: String?

    public init(text: String, device: String) { self.text = text; self.device = device }

    public var searchText: String { text }
}

// MARK: - Question (asked from any device, answered by the Mac agent)

public struct Question: Entity {
    public static let type = "question"
    public var id = newID()
    public var updatedAt = Date()
    public var deleted = false

    public var text: String
    public var askedAt = Date()
    public var device: String = ""
    public var answer: String?
    public var answeredAt: Date?
    public var error: String?

    public init(text: String, device: String) { self.text = text; self.device = device }

    public var searchText: String { text + " " + (answer ?? "") }
}

// MARK: - Clarification (an open question Jinnie asks the owner to validate)

/// Something Jinnie isn't sure about and the owner can settle in a few words: which side someone is on, whether two
/// records are one person, which of two figures is right. Raised by the agent, answered on any device, applied on the Mac.
public struct Clarification: Entity {
    public static let type = "clarification"
    public var id = newID()
    public var updatedAt = Date()
    public var deleted = false

    public enum Status: String, Codable, Sendable { case open, answered, applied, dismissed }

    public var question: String
    /// Why Jinnie asks: what it saw that conflicts or is missing.
    public var why: String?
    /// Likely answers, offered as one-tap buttons.
    public var options: [String]?
    public var projectID: String?
    public var personIDs: [String]?
    public var itemIDs: [String]?
    public var status: Status = .open
    public var answer: String?
    public var answeredAt: Date?
    public var appliedAt: Date?
    /// Claimed by a process (the app or the CLI) that is applying the answer; others leave it alone for a while.
    public var applyingAt: Date?
    /// What the agent changed after the answer.
    public var result: String?
    public var error: String?
    public var createdAt = Date()
    /// Set when the owner changed an answer that was already applied: what was answered and changed before, to undo.
    public var previousAnswer: String?
    public var previousResult: String?

    public init(question: String) { self.question = question }

    public var searchText: String { [question, why ?? "", answer ?? ""].joined(separator: " ") }
}

// MARK: - Run log (what the agent did; synced so the iPhone can show it)

public struct RunLog: Entity {
    public static let type = "run"
    public var id = newID()
    public var updatedAt = Date()
    public var deleted = false

    public var kind: String            // ingest:email, notes, uberdoer, summary, ask
    public var startedAt = Date()
    public var finishedAt: Date?
    public var ok = true
    public var message: String = ""

    public init(kind: String) { self.kind = kind }
    public var searchText: String { "" }
}

public enum EntityRegistry {
    public static let types: [any Entity.Type] = [Project.self, Person.self, Item.self, Action.self, Note.self, Question.self, Clarification.self, Recording.self, RunLog.self]
    public static func type(named name: String) -> (any Entity.Type)? { types.first { $0.type == name } }
}
