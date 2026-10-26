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

    var body: some View {
        let r = recording
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(.tint)
                Text(r.title).font(.body.weight(.semibold)).lineLimit(1)
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
                    TranscriptEditor(recording: r)
                }
            }
            .navigationTitle("Recording")
        } else {
            Text("Recording not found").foregroundStyle(.secondary)
        }
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
    @State private var editing: Int?
    @State private var draft = ""
    @State private var replacing = false
    @State private var from = ""
    @State private var to = ""
    @State private var remember = true
    @State private var changed = false
    @State private var note: String?

    var body: some View {
        let r = recording
        let turns = r.turns
        if turns.isEmpty {
            Text(r.status == .ready ? "No speech found." : "Not transcribed yet.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button { replacing.toggle() } label: { Label("Replace a Word…", systemImage: "character.cursor.ibeam") }
                        .buttonStyle(.borderless)
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
                            .onTapGesture { draft = turn.text; editing = i }
                            .help("Click to correct this line")
                    }
                }
            }
        }
    }
}
