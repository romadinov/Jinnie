import JinnieCore
import SwiftUI

// MARK: - Recordings

struct RecordingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            #if os(macOS)
            RecordControl()
            #endif
            if model.recordings.isEmpty {
                Text(Self.hint).foregroundStyle(.secondary)
            }
            ForEach(model.recordings) { r in
                NavigationLink(value: Route.recording(r.id)) { RecordingRow(recording: r) }
                    .contextMenu { Button("Delete", role: .destructive) { model.deleteRecording(r) } }
                    .swipeActions { Button("Delete", role: .destructive) { model.deleteRecording(r) } }
            }
            let fixes = model.rememberedCorrections
            if !fixes.isEmpty {
                Panel(id: "recordings.fixes", title: "Word fixes", count: fixes.count) {
                    ForEach(fixes, id: \.from) { c in
                        HStack {
                            Text(c.from).strikethrough().foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            Text(c.to)
                            Spacer()
                            Button { model.forgetCorrection(c.from) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Stop fixing this in new recordings")
                        }
                    }
                    Text("Applied to every new transcript. Add one from a recording: Transcript → Replace a Word.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Recordings")
    }

    static let hint = "Record a meeting on the Mac (⌃⌥R, or Record in the toolbar or menu bar). Jinnie transcribes it on the Mac, separates the speakers, names the voices it knows, and asks you once about the others."
}

struct RecordingRow: View {
    @Environment(AppModel.self) private var model
    let recording: Recording

    var body: some View { rowContent.copyable({ recording.title }, label: "Copy Meeting Name") }

    @ViewBuilder var rowContent: some View {
        let r = recording
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(.tint)
                Text(r.title).font(.body.weight(.semibold)).lineLimit(1)
                MoodBadge(recording: r)
                Spacer()
                Text(Recording.clock(r.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(r.startedAt.formatted(.dateTime.weekday().day().month().hour().minute()))
                switch r.status {
                case .recording: Label("Recording", systemImage: "record.circle").foregroundStyle(.red)
                case .processing: Label("Transcribing on the Mac…", systemImage: "hourglass")
                case .failed: Label(r.error ?? "Failed", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                case .ready:
                    let named = r.speakers.filter { $0.personID != nil }.compactMap { model.person($0.personID) }.map { $0.isMe ? "You" : $0.firstName }
                    if !named.isEmpty { Text(named.joined(separator: ", ")) }
                    if !r.unnamedSpeakers.isEmpty {
                        Text("\(r.unnamedSpeakers.count) to name").foregroundStyle(.orange)
                    }
                }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct RecordingDetail: View {
    @Environment(AppModel.self) private var model
    let recordingID: String
    @State private var showLocal = false

    var body: some View {
        if let r = model.recording(recordingID) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.title).font(.title3.weight(.semibold))
                        Text("\(r.startedAt.formatted(date: .complete, time: .shortened)) · \(Recording.clock(r.duration))")
                            .font(.callout).foregroundStyle(.secondary)
                        if let m = model.item(r.meetingItemID) {
                            NavigationLink(value: Route.item(m.id)) { Label(m.title, systemImage: "calendar").font(.callout) }
                        }
                        if let mood = r.mood {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                MoodBadge(recording: r, showCalm: true)
                                if let why = r.moodWhy { Text(why).font(.callout).foregroundStyle(.secondary) }
                            }
                            .help("Meeting tone: \(mood)")
                        }
                        if let s = r.sourceURL, let url = URL(string: s) {
                            Link(destination: url) { Label("Transcribed by Teams · Watch in Stream", systemImage: "play.rectangle") }.font(.callout)
                            RecordingAudioControl(recording: r)
                        }
                        if let i = model.item(r.itemID) {
                            NavigationLink(value: Route.item(i.id)) { Label("What Jinnie learned", systemImage: "sparkles").font(.callout) }
                        } else if r.status == .ready {
                            Label(r.processedAt == nil ? "Jinnie is reading the transcript…" : "Processed", systemImage: "hourglass")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if r.status == .failed {
                            Text(r.error ?? "Failed").foregroundStyle(.orange)
                            #if os(macOS)
                            Button("Try again") { MeetingRecorder.shared.reprocess(r) }
                            #endif
                        }
                    }
                }
                if r.status == .ready && !r.segments.isEmpty {
                    RecordingSummary(recording: r)
                    MeetingNotesPanel(recording: r)
                }
                if !r.speakers.isEmpty {
                    Panel(id: "recording.speakers", title: "Speakers", count: r.speakers.count) {
                        ForEach(r.speakers.sorted { $0.talkSeconds > $1.talkSeconds }, id: \.label) { s in
                            SpeakerRow(recording: r, speaker: s)
                        }
                        Text("Naming a voice teaches Jinnie: next time it's recognised automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Panel(id: "recording.transcript", title: "Transcript") {
                    if let local = r.localSegments, !local.isEmpty {
                        Picker("Transcript", selection: $showLocal) {
                            Text("Teams").tag(false)
                            Text("Mac (Whisper)").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    if showLocal, let local = r.localSegments, !local.isEmpty {
                        TranscriptEditor(recording: { var c = r; c.segments = local; return c }(), readOnly: true)
                    } else {
                        TranscriptEditor(recording: r)
                    }
                }
            }
            .navigationTitle("Recording")
        } else {
            Text("Recording not found").foregroundStyle(.secondary)
        }
    }
}

/// Recording a Teams recording's audio on the Mac (played muted in the hidden browser), then Whisper.
struct RecordingAudioControl: View {
    @Environment(AppModel.self) private var model
    let recording: Recording

    var body: some View {
        let r = recording
        HStack(spacing: 10) {
            #if os(macOS)
            if TeamsAudio.shared.working == r.id {
                ProgressView(value: TeamsAudio.shared.progress).frame(width: 120)
                Text("\(TeamsAudio.shared.phase)… \(Int(TeamsAudio.shared.progress * 100))%").foregroundStyle(.secondary)
                Button("Stop") { TeamsAudio.shared.stop() }.buttonStyle(.borderless)
            } else { status(r) }
            #else
            status(r)
            #endif
        }
        .font(.callout)
    }

    @ViewBuilder private func status(_ r: Recording) -> some View {
        if r.audioPending {
            Label("Waiting for the Mac to record the audio (takes \(Int(r.duration / 60)) min)", systemImage: "hourglass").foregroundStyle(.secondary)
        } else if let e = r.audioError {
            Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2)
            Button("Try Again") { request(r) }.buttonStyle(.borderless)
        } else if r.localSegments?.isEmpty == false {
            Label("Audio recorded and transcribed on the Mac", systemImage: "waveform").foregroundStyle(.secondary)
            Button("Record Again") { request(r) }.buttonStyle(.borderless)
        } else {
            Button { request(r) } label: { Label("Record Audio", systemImage: "waveform.badge.plus") }
                .buttonStyle(.borderless)
                .help("The Mac plays the recording muted in its hidden browser and records the sound (real time: \(Int(r.duration / 60)) min), then transcribes it with Whisper. The Teams transcript stays.")
        }
    }

    private func request(_ r: Recording) {
        var c = r
        c.audioRequestedAt = Date()
        c.audioError = nil
        model.save(c)
        AgentHooks.shared?.runNow()
    }
}

/// The meeting's tone: red for heated, orange for tense, green for positive; calm shows only where asked.
struct MoodBadge: View {
    let recording: Recording
    var showCalm = false

    var body: some View {
        switch recording.mood {
        case "heated": Label("Heated", systemImage: "flame.fill").foregroundStyle(.red).font(.caption.weight(.semibold))
        case "tense": Label("Tense", systemImage: "exclamationmark.bubble").foregroundStyle(.orange).font(.caption.weight(.medium))
        case "positive": Label("Positive", systemImage: "hand.thumbsup").foregroundStyle(.green).font(.caption)
        case "calm" where showCalm: Label("Calm", systemImage: "equal.circle").foregroundStyle(.secondary).font(.caption)
        default: EmptyView()
        }
    }
}

/// Notes to email the participants: generated on request (by the Mac), then opened as a new email in Mimestream with the
/// recipients, subject and text filled in. Jinnie never sends; you review and send.
struct MeetingNotesPanel: View {
    @Environment(AppModel.self) private var model
    let recording: Recording

    var body: some View {
        let r = recording
        Panel(id: "recording.notes", title: "Meeting Notes") {
            if let notes = r.notes {
                let to = model.notesRecipients(r)
                VStack(alignment: .leading, spacing: 6) {
                    Text(to.emails.isEmpty ? "No recipients with a known email" : "To: " + to.emails.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                    if !to.missing.isEmpty {
                        Text("No email for \(to.missing.joined(separator: ", ")): add it on their page, or in Contacts.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let s = r.notesSubject { Text(s).font(.callout.weight(.semibold)) }
                    Text(notes).font(.callout)
                }
                .textSelection(.enabled)
            }
            HStack(spacing: 14) {
                if r.notesPending {
                    Label("Jinnie is writing the notes…", systemImage: "hourglass").foregroundStyle(.secondary)
                } else {
                    Button { model.requestNotes(r) } label: {
                        Label(r.notes == nil ? "Generate Meeting Notes" : "Generate Again", systemImage: "doc.text")
                    }
                }
                if let notes = r.notes {
                    Button {
                        MailComposer.compose(to: model.notesRecipients(r).emails, subject: r.notesSubject ?? r.title, body: notes)
                    } label: { Label("Send Meeting Notes", systemImage: "paperplane") }
                    .help("Opens a new email in \(MailComposer.appName), filled in. Nothing is sent until you send it.")
                    CopyAllButton { [r.notesSubject, notes].compactMap { $0 }.joined(separator: "\n\n") }
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }
}

/// The meeting summary, made on request by the Mac (asking from the iPhone works too: it syncs).
struct RecordingSummary: View {
    @Environment(AppModel.self) private var model
    let recording: Recording

    var body: some View {
        Panel(id: "recording.summary", title: "Summary") {
            if let text = recording.summary {
                Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                    .textSelection(.enabled)
            }
            HStack(spacing: 14) {
                if recording.summaryPending {
                    Label("Jinnie is summarising…", systemImage: "hourglass").foregroundStyle(.secondary)
                } else {
                    Button { request() } label: {
                        Label(recording.summary == nil ? "Summarise" : "Summarise Again", systemImage: "text.badge.star")
                    }
                }
                if let text = recording.summary {
                    CopyAllButton { text }
                    if let at = recording.summaryAt {
                        Text(at.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }

    private func request() {
        var r = recording
        r.summaryRequestedAt = Date()
        model.save(r)
        AgentHooks.shared?.runNow()
    }
}

/// One voice: who it is (or "Who is this?"), how much they talked, a sample, and on the Mac a play button.
struct SpeakerRow: View {
    @Environment(AppModel.self) private var model
    let recording: Recording
    let speaker: RecordedSpeaker
    @State private var choosing = false
    @State private var sampleIndex = 0

    var body: some View {
        let person = model.person(speaker.personID)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: person == nil ? "person.crop.circle.badge.questionmark" : "person.crop.circle.fill")
                    .foregroundStyle(person == nil ? Color.orange : Color.accentColor)
                Text(person.map { $0.isMe ? "You" : $0.name } ?? "Speaker \(speaker.label + 1)").font(.body.weight(.semibold))
                if speaker.namedBy == .voice, let m = speaker.match {
                    Text("recognised by voice · \(Int(m * 100))%").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Recording.clock(speaker.talkSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                #if os(macOS)
                let times = recording.sampleTimes(for: speaker.label)
                if !times.isEmpty, SnippetPlayer.shared.canPlay(recording) {
                    Button {
                        SnippetPlayer.shared.play(recording, at: times[sampleIndex % times.count])
                        sampleIndex += 1
                    } label: {
                        Label(times.count > 1 ? "Sample \(sampleIndex % times.count + 1)/\(times.count)" : "Sample", systemImage: "play.circle")
                    }
                    .buttonStyle(.borderless).help("Play a few seconds of this voice; press again for another sample")
                }
                #endif
                whoMenu(person)
            }
            if person == nil, let guess = model.person(speaker.suggestedPersonID) {
                HStack(spacing: 6) {
                    Text("Probably \(guess.isMe ? "you" : guess.name)\(speaker.suggestionWhy.map { ": \($0)" } ?? "")")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Button("Yes") { model.assignSpeaker(recording, label: speaker.label, personID: guess.id) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            if let sample = speaker.sample { Text("“\(sample)”").font(.callout).foregroundStyle(.secondary).lineLimit(3) }
        }
        .sheet(isPresented: $choosing) {
            PersonPicker(title: "Who is Speaker \(speaker.label + 1)?") { id in
                model.assignSpeaker(recording, label: speaker.label, personID: id)
                choosing = false
            } onCancel: { choosing = false }
        }
    }

    /// Likely people first: meeting attendees, then the meeting's project, then you; "Someone else…" opens a search.
    func whoMenu(_ current: Person?) -> some View {
        let meeting = model.item(recording.meetingItemID)
        let attendees = (meeting?.personIDs ?? []).compactMap { model.person($0) }.filter { !$0.isMe }
        let projectPeople = (meeting?.projectIDs.first).flatMap { model.project($0) }.map { model.people(for: $0).prefix(8).map(\.person) } ?? []
        let others = projectPeople.filter { p in !attendees.contains { $0.id == p.id } }
        let me = model.store.all(Person.self).first(where: \.isMe)
        return Menu(current == nil ? "Who is this?" : "Change") {
            if let me { Button("Me") { model.assignSpeaker(recording, label: speaker.label, personID: me.id) } }
            if !attendees.isEmpty {
                Section("In the meeting") { ForEach(attendees) { p in Button(p.name) { model.assignSpeaker(recording, label: speaker.label, personID: p.id) } } }
            }
            if !others.isEmpty {
                Section("On the project") { ForEach(others) { p in Button(p.name) { model.assignSpeaker(recording, label: speaker.label, personID: p.id) } } }
            }
            Button("Someone else…") { choosing = true }
            let others = recording.speakers.filter { $0.label != speaker.label }
            if !others.isEmpty {
                Section("Same voice as") {
                    ForEach(others, id: \.label) { o in
                        Button(recording.name(of: o.label, in: model.directory)) { model.mergeSpeaker(recording, speaker.label, into: o.label) }
                    }
                }
            }
            if current != nil { Divider(); Button("Not sure", role: .destructive) { model.assignSpeaker(recording, label: speaker.label, personID: nil) } }
        }
        .fixedSize()
    }
}

/// Search the directory, or add a new person by name.
struct PersonPicker: View {
    @Environment(AppModel.self) private var model
    let title: String
    let onPick: (String) -> Void
    let onCancel: () -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                let q = query.trimmingCharacters(in: .whitespaces)
                let matches = model.people.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || ($0.org ?? "").localizedCaseInsensitiveContains(q) }
                if !q.isEmpty && !matches.contains(where: { $0.name.caseInsensitiveCompare(q) == .orderedSame }) {
                    Button { if let p = model.addPerson(named: q) { onPick(p.id) } } label: { Label("Add “\(q)”", systemImage: "person.badge.plus") }
                }
                ForEach(matches.prefix(80)) { p in
                    Button { onPick(p.id) } label: {
                        VStack(alignment: .leading) {
                            Text(p.name)
                            if let o = p.org { Text(o).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: "Name or company")
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) } }
        }
        .frame(minWidth: 380, minHeight: 420)
    }
}

/// A person's voice: the recordings Jinnie learned it from (play, forget one) and "Forget voice". Wrong matches are best
/// fixed on the recording (Change → the right person), which also forgets the samples behind the mistake.
struct VoicePanel: View {
    @Environment(AppModel.self) private var model
    let person: Person
    @State private var confirmForget = false

    var body: some View {
        let samples = person.voiceSamples ?? []
        let heardIn = model.recordings.filter { r in r.speakers.contains { $0.personID == person.id } }
        if !samples.isEmpty || !heardIn.isEmpty {
            Panel(id: "person.voice", title: "Voice", count: samples.count) {
                if samples.isEmpty {
                    Text("Not learned yet: name \(person.isMe ? "yourself" : person.firstName) in a recording and Jinnie will recognise the voice next time.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(samples.enumerated()), id: \.offset) { i, sample in
                    let rec = model.recording(sample.recordingID)
                    let spk = rec?.speaker(sample.speakerLabel)
                    HStack {
                        Image(systemName: "waveform").foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            if let rec {
                                NavigationLink(value: Route.recording(rec.id)) { Text(rec.title).lineLimit(1) }
                                Text(rec.startedAt.formatted(date: .abbreviated, time: .shortened) + (spk?.sample.map { " · “\($0)”" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            } else {
                                Text("Sample from \(sample.addedAt.formatted(date: .abbreviated, time: .omitted))")
                            }
                        }
                        Spacer()
                        #if os(macOS)
                        if let rec, let at = spk?.sampleAt, SnippetPlayer.shared.canPlay(rec) {
                            Button { SnippetPlayer.shared.play(rec, at: at) } label: { Image(systemName: "play.circle") }.buttonStyle(.borderless)
                        }
                        #endif
                        Button("Forget") { model.forgetVoice(person, sampleAt: i) }.buttonStyle(.borderless)
                            .help("Jinnie stops using this sample to recognise \(person.firstName)")
                    }
                }
                if !samples.isEmpty {
                    Button("Forget \(person.isMe ? "my" : person.firstName + "'s") voice…", role: .destructive) { confirmForget = true }
                        .confirmationDialog("Forget this voice?", isPresented: $confirmForget) {
                            Button("Forget voice", role: .destructive) { model.forgetVoice(person) }
                        } message: { Text("Recordings keep their names; new ones won't recognise this voice until you name it again.") }
                }
            }
        }
    }
}

/// The transcript, correctable: click a line to fix it, or replace a misheard word everywhere (and in future
/// recordings). After corrections, Jinnie reads the transcript again.
struct TranscriptEditor: View {
    @Environment(AppModel.self) private var model
    let recording: Recording
    /// The Mac's own transcript of a Teams recording: shown and copied, not edited (fixes go into the main one).
    var readOnly = false
    @State private var editing: Int?
    @State private var draft = ""
    @State private var replacing = false
    @State private var from = ""
    @State private var to = ""
    @State private var remember = true
    @State private var changed = false
    @State private var note: String?
    @State private var editingLines = false

    var body: some View {
        let r = recording
        let turns = r.turns
        if turns.isEmpty {
            Text(r.status == .ready ? "No speech found." : "Not transcribed yet.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    CopyAllButton { "\(r.title)\n\(r.startedAt.formatted(date: .complete, time: .shortened))\n\n" + r.transcript(model.directory) }
                    if !readOnly {
                    Button { editingLines.toggle(); editing = nil } label: {
                        Label(editingLines ? "Done Editing" : "Edit Lines", systemImage: editingLines ? "checkmark" : "pencil")
                    }
                    .buttonStyle(.borderless)
                    Button { replacing.toggle() } label: { Label("Replace a Word…", systemImage: "character.cursor.ibeam") }
                        .buttonStyle(.borderless)
                    }
                    Spacer()
                    if changed {
                        Button("Update What Jinnie Learned") { model.rereadRecording(r); changed = false; note = "Jinnie will read the corrected transcript again." }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                if replacing {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Heard as", text: $from).textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("Should be", text: $to).textFieldStyle(.roundedBorder)
                        }
                        Toggle("Fix it in all recordings, past and future", isOn: $remember)
                        HStack {
                            Spacer()
                            Button("Cancel") { replacing = false }
                            Button("Replace") {
                                let n = model.replaceInTranscript(r, from, with: to, everywhere: remember)
                                note = n == 0 ? "\"\(from)\" wasn't found\(remember ? "; future recordings will still be fixed" : "")."
                                    : "Replaced \(n) time\(n == 1 ? "" : "s")\(remember ? " across your recordings" : "")."
                                if n > 0 { changed = true }
                                replacing = false; from = ""; to = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(from.trimmingCharacters(in: .whitespaces).isEmpty || to.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                }
                if !editingLines {
                    // One block, so a selection can span lines.
                    Text(selectable(turns, r))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                ForEach(Array(turns.enumerated()), id: \.offset) { i, turn in
                    let who = r.name(of: turn.label, in: model.directory)
                    if editing == i {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("[\(Recording.clock(turn.start))] \(who)").font(.caption).foregroundStyle(.secondary)
                            TextField("", text: $draft, axis: .vertical).lineLimit(2...12).textFieldStyle(.roundedBorder)
                            HStack {
                                Spacer()
                                Button("Cancel") { editing = nil }
                                Button("Save") { model.correctLine(r, turn, to: draft); editing = nil; changed = true; note = nil }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    } else {
                        Text("[\(Recording.clock(turn.start))] \(who): \(turn.text)")
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .textSelection(.disabled)
                            .onTapGesture { draft = turn.text; editing = i }
                            .help("Click to correct this line")
                    }
                }
                }
            }
        }
    }

    /// The transcript as one attributed text: time and speaker in bold, a blank line between turns.
    private func selectable(_ turns: [Recording.Turn], _ r: Recording) -> AttributedString {
        var out = AttributedString()
        for (i, turn) in turns.enumerated() {
            var head = AttributedString("[\(Recording.clock(turn.start))] \(r.name(of: turn.label, in: model.directory)): ")
            head.font = .callout.weight(.semibold)
            out += head
            out += AttributedString(turn.text.trimmingCharacters(in: .whitespaces) + (i < turns.count - 1 ? "\n\n" : ""))
        }
        return out
    }
}
