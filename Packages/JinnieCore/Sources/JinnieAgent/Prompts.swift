import Foundation
import JinnieCore

enum Prompts {
    static var owner: String {
        "\(JinnieConfig.ownerName) <\(JinnieConfig.ownerEmails.joined(separator: ", "))>"
    }

    static var system: String {
        let me = OwnerProfile.current
        let names = ([me.name, me.firstName] + me.nicknames).filter { !$0.isEmpty }
        return """
        You are Jinnie, the personal knowledge agent of \(me.name) (\(me.emails.joined(separator: ", "))), \
        \(me.description), who writes in \(me.languages). You read the owner's email, Slack, calendar and notes, \
        and record what matters: who said what, about which project, and what has to happen next.
        Rules:
        - You are strictly READ-ONLY on every external system. Never send, reply, post, create, edit, label, archive or delete anything.
        - Refer to people by name, or as "they", unless their pronouns are stated in a source; never infer pronouns from a name.
        - Attribute every fact to its source item. Never invent facts, people, emails or dates.
        - Use canonical names from the directory below whenever a mention matches (first names, nicknames, transliterations).
        - Use your tools directly. If a tool you need isn't listed (claude.ai connectors are deferred), load it with ToolSearch \
          (e.g. query "+Gmail", "+Slack", "+Calendar").
        - "Me", "I", \(names.map { "\"\($0)\"" }.joined(separator: ", ")) all mean \(me.name).
        """
    }

    /// The extraction contract shared by every source.
    static let extractionSchema = """
    {"type":"object","required":["items","newProjects"],"properties":{
      "items":{"type":"array","items":{"type":"object",
        "required":["sourceRef","title","occurredAt","summary","facts","projects","people","actions","resolvesActionIDs"],
        "properties":{
          "sourceRef":{"type":"string","description":"Stable id in the source system: Gmail thread id, Slack channelID:threadTs, calendar event id, or the note id given"},
          "source":{"type":["string","null"],"enum":["email","slack","calendar","drive","outlook",null],"description":"Where this item came from, when reading several sources"},
          "url":{"type":["string","null"],"description":"Deep link to the item if known"},
          "title":{"type":"string"},
          "author":{"type":["string","null"]},
          "authorEmail":{"type":["string","null"]},
          "occurredAt":{"type":"string","description":"ISO 8601 date-time of the latest message/event start"},
          "excerpt":{"type":"string","description":"Up to 500 chars quoted verbatim: the most informative part"},
          "transcript":{"type":["string","null"],"description":"Only for handwritten notebooks: the full transcription"},
          "summary":{"type":"string","description":"1-3 sentences: what this is about and what changed"},
          "facts":{"type":"array","items":{"type":"string"},"description":"Atomic, self-contained statements worth remembering (decisions, numbers, dates, commitments, preferences, context). Name people and projects explicitly."},
          "projects":{"type":"array","items":{"type":"string"},"description":"Canonical project names (existing or from newProjects)"},
          "people":{"type":"array","items":{"type":"object","required":["name"],"properties":{
            "name":{"type":"string","description":"Full name, canonical if known"},
            "email":{"type":["string","null"]},"org":{"type":["string","null"]},"role":{"type":["string","null"]},
            "aliases":{"type":"array","items":{"type":"string"}}}}},
          "actions":{"type":"array","items":{"type":"object","required":["kind","title"],"properties":{
            "kind":{"type":"string","enum":["next","waiting"],"description":"next = something the owner must do; waiting = something the owner needs from another person"},
            "title":{"type":"string","description":"next: imperative verb phrase. waiting: what the owner needs, without the person's name"},
            "person":{"type":["string","null"],"description":"For waiting: who owes it. For next: who it involves, if anyone"},
            "personEmail":{"type":["string","null"]},
            "project":{"type":["string","null"]},
            "due":{"type":["string","null"],"description":"YYYY-MM-DD only if a date was actually stated or clearly implied"},
            "context":{"type":"string","description":"2-4 sentences the owner could act on cold, addressed to the owner as 'you': background, who asked or promised and when, why it matters, what done looks like, any constraints or related numbers/dates"},
            "quote":{"type":["string","null"],"description":"The exact words (≤300 chars) in the source where it was asked for or promised"}}}},
          "resolvesActionIDs":{"type":"array","items":{"type":"string"},"description":"Ids of OPEN ACTIONS that this item shows are done or delivered"},
          "documents":{"type":"array","description":"Documents this item links to or attaches (Google Docs/Sheets/Slides/Drive files, transcripts, SharePoint, Confluence…). For a Drive item, include the document itself.","items":{"type":"object","required":["title","url"],"properties":{
            "title":{"type":"string"},"url":{"type":"string"},
            "kind":{"type":["string","null"],"description":"transcript, meeting notes, SOW, proposal, design, plan, spreadsheet, slides, contract…"}}}}
        }}},
      "projectUpdates":{"type":"array","description":"Facts about EXISTING projects that change how mentions should be matched: other names (a parent company, a programme name, a Russian spelling), client email domains, a description","items":{"type":"object","required":["project"],"properties":{
        "project":{"type":"string","description":"Existing project name"},
        "addAliases":{"type":"array","items":{"type":"string"}},
        "addDomains":{"type":"array","items":{"type":"string"}},
        "description":{"type":["string","null"],"description":"One line: client, what the engagement is (only if stated)"}}}},
      "personUpdates":{"type":"array","description":"Stated facts about people: role, organisation, nicknames, which project they belong to","items":{"type":"object","required":["name"],"properties":{
        "name":{"type":"string"},"email":{"type":["string","null"]},"role":{"type":["string","null"]},"org":{"type":["string","null"]},
        "addAliases":{"type":"array","items":{"type":"string"}},"project":{"type":["string","null"]}}}},
      "speakerGuesses":{"type":"array","description":"Recordings only: for unidentified speakers, who they most likely are from the content","items":{"type":"object","required":["speaker","person","why"],"properties":{
        "speaker":{"type":"string","description":"The label as in the transcript, e.g. 'Speaker 2'"},
        "person":{"type":"string","description":"Exact name from the directory, or 'You' for the owner"},
        "why":{"type":"string","description":"One short reason, e.g. 'is thanked by name and speaks for the client'"}}}},
      "newProjects":{"type":"array","items":{"type":"object","required":["name","isWork"],"properties":{
        "name":{"type":"string","description":"Short name, usually the client or initiative (e.g. 'Acme')"},
        "aliases":{"type":"array","items":{"type":"string"}},
        "domains":{"type":"array","items":{"type":"string"},"description":"Client email domains"},
        "description":{"type":"string"},
        "isWork":{"type":"boolean"}}}}
    }}
    """

    static func extractionRules(directory: Directory, openActions: [Action], today: String) -> String {
        let actions = openActions.prefix(200).map { a -> String in
            let person = directory.person(id: a.personID)?.name ?? "-"
            let proj = directory.project(id: a.projectID)?.name ?? "-"
            return "- [\(a.id)] \(a.kind.rawValue): \(a.title) | person: \(person) | project: \(proj)\(a.due.map { " | due \($0)" } ?? "")"
        }.joined(separator: "\n")
        return """
        Today is \(today). The owner is \(owner).

        \(directory.promptText())

        OPEN ACTIONS already tracked (do not duplicate them; if an item shows one is done, put its id in resolvesActionIDs):
        \(actions.isEmpty ? "(none)" : actions)

        Extraction rules:
        - Never write "he", "she", "his", "her" about anyone, the owner included: repeat the name, or use "they". \
          In facts, call the owner by name ("\(OwnerProfile.current.firstName) to send the proposal"); in action context, "you".
        - Skip noise entirely: marketing, newsletters, receipts, automated notifications, social media, spam — unless they carry a real obligation or deadline for the owner.
        - Link each item to projects. Infer from people (a person's projects), email domains, channel names and content. An item may have no project.
        - Propose a newProject only for a clearly distinct, ongoing engagement or initiative (a client, a deal, an internal programme) that appears with real substance and matches no existing project or alias. Prefer the client name. Never create a project per email thread.
        - People: include everyone who matters in the item (not mailing lists, not the owner). Give email addresses exactly as seen.
        - next actions: only things the owner has committed to or clearly must do. Be specific ("Send Dana the revised SOW"), not vague.
        - waiting actions: only things the owner asked for / is relying on someone else to deliver. title is what is needed, e.g. "Signed SOW". person must be set.
        - Do not repeat an action that is already in OPEN ACTIONS (even with different wording). Do not create actions for things already done.
        - due: set only when a date was stated or unambiguous ("by Friday" → that Friday's date).
        - projectUpdates: when the owner (or a source) states that a project is also known as something, belongs to a parent company \
          ("Acme is part of Globex" → addAliases ["Globex"], addDomains ["globex.example", "team.globex.example"] if seen), or what it is — record it.
        - personUpdates: when a role, org, nickname or project membership is stated or obvious from a signature, record it.
        - documents: whenever an item links to or attaches a document (Google Docs/Sheets/Slides, Drive files, transcripts, decks), list it with its exact URL.
        """
    }

    // MARK: Sources

    static func email(since: Date, knownRefs: [String]) -> String {
        let epoch = Int(since.timeIntervalSince1970)
        return """
        Search Gmail for threads with messages after \(isoString(since)) using the query `after:\(epoch) -category:promotions -category:social` \
        (use several pages if needed, up to 60 threads; also search `in:sent after:\(epoch)` to see what the owner asked others for). \
        Read each potentially relevant thread fully. Return one item per thread (sourceRef = Gmail thread id, \
        url = the thread's viewUrl from the search result, occurredAt = the latest message time).
        Already ingested threads (skip unless they have messages after \(isoString(since))): \(knownRefs.prefix(150).joined(separator: ", "))
        """
    }

    static func slack(since: Date, knownRefs: [String]) -> String {
        let day = dayString(since.addingTimeInterval(-86400))
        return """
        Look through Slack for conversations since \(isoString(since)) that involve the owner: direct messages, group DMs, \
        @-mentions of the owner, threads the owner replied in, and messages in channels the owner is a member of that concern the owner's projects. \
        Use Slack search (e.g. `after:\(day)` together with `to:me`, `from:me`, `is:dm`) and read threads for context. \
        Return one item per conversation thread (sourceRef = channelID:threadTs, url = the Slack permalink if available, \
        title = channel or DM name + topic). Ignore bots and automated alerts.
        Already ingested (skip unless they have newer messages): \(knownRefs.prefix(150).joined(separator: ", "))
        """
    }

    static func calendar(from: Date, to: Date) -> String {
        """
        List the owner's calendar events between \(isoString(from)) and \(isoString(to)) on the primary calendar. \
        For each meeting with other attendees (skip personal blocks, focus time, OOO, holidays), return one item: \
        sourceRef = event id, title = event title, occurredAt = start time, author = organiser, people = attendees, \
        facts = agenda/description facts worth remembering, projects inferred from attendees and title. \
        Add a next action only if the description clearly asks the owner to prepare something. \
        Put attached or linked documents (agenda docs, Gemini notes, transcripts, decks) in documents.
        """
    }

    static func outlook(inbox: [String], sent: [String], events: [String], since: Date?, knownRefs: [String]) -> String {
        """
        Below is what the owner's Outlook (a client's Microsoft 365 mailbox, e.g. a telco client) shows, read from Outlook \
        on the web. Mail lines are conversations as listed: unread/external flags, senders, subject, time (relative to today, \
        e.g. "Thu 8:46 PM" = this week's Thursday), then the start of the latest message. Only previews are available, not full bodies.
        \(since.map { "Only consider conversations and events from \(isoString($0)) onwards (earlier ones were already read)." } ?? "This is the first read: consider everything shown.")
        - Mail: one item per conversation (source "outlook", sourceRef = "outlook:" + the subject lowercased without RE:/FW: prefixes, \
          url = null, title = subject, author = latest sender, occurredAt = the listed time resolved to a date). Skip digests, \
          newsletters and automated notices unless they carry a real obligation (an approved access request is a fact worth keeping).
        - Sent items show what the owner promised or asked for: use them for next and waiting actions.
        - Calendar: one item per meeting with other people (source "calendar", sourceRef = "outlook-cal:" + title lowercased + date, \
          author = organiser). Skip cancelled ones unless the cancellation matters.
        Already ingested refs (skip unless they have something newer): \(knownRefs.prefix(200).joined(separator: ", "))

        INBOX:
        \(inbox.joined(separator: "\n"))

        SENT:
        \(sent.joined(separator: "\n"))

        CALENDAR:
        \(events.joined(separator: "\n"))
        """
    }

    static func drive(since: Date, knownRefs: [String]) -> String {
        """
        Look through the owner's Google Drive for files created or modified since \(isoString(since)) (use the Drive search \
        tools with a modified-time filter; include files shared with the owner).
        1. MEETING TRANSCRIPTS AND NOTES are the priority: Google Meet transcripts ("… - Transcript", usually in "Meet Recordings"), \
           Gemini "Notes by Gemini" docs, and any other meeting notes. Read each one fully. Return one item per meeting \
           (sourceRef = file id, url = the file's web link, title = meeting name, occurredAt = meeting time, author = organiser, \
           people = participants, facts = decisions, numbers, dates, risks and opinions worth remembering, attributed by name). \
           Extract commitments carefully: what the owner agreed to do → next actions; what others agreed to deliver to the owner \
           → waiting actions with that person, due dates as stated. documents = the file itself (kind "transcript" or "meeting notes").
        2. OTHER DOCUMENTS that concern the owner's projects (SOWs, proposals, designs, plans, estimates, contracts, decks, \
           spreadsheets): read enough to summarise them. One item per document (sourceRef = file id, url = web link, \
           summary = what it is and its current state, facts = key figures/dates/decisions, documents = the file itself with its kind). \
           Do not extract actions from documents unless they clearly assign something to the owner or someone owes the owner something.
        Skip personal files, images, auto-generated exports and anything unrelated to work or the owner's commitments.
        Already ingested (skip unless modified since \(isoString(since))): \(knownRefs.prefix(150).joined(separator: ", "))
        """
    }

    static func notes(_ notes: [Note]) -> String {
        let body = notes.map { n in "--- NOTE id=\(n.id) written \(isoString(n.createdAt)) on \(n.device)\n\(n.text)" }.joined(separator: "\n\n")
        return """
        These are notes the owner wrote (often terse, in \(OwnerProfile.current.languages)). Treat each note as one item \
        (sourceRef = the note id, title = a short descriptive title, occurredAt = the time given, author = the owner). \
        Resolve first names to people in the directory (e.g. a first name that matches one person on a project means that person and that project). \
        Anything phrased as a to-do ("need to", "надо", "send", "call") is a next action; "X will send / X owes me / waiting for X" is a waiting action.

        \(body)
        """
    }

    static let toolDiscoverySchema = """
    {"type":"object","required":["tools"],"properties":{"tools":{"type":"array","items":{"type":"string"}}}}
    """

    static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = .current; return f.string(from: d)
    }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f.string(from: d)
    }
}
