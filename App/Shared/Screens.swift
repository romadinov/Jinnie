import JinnieCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Capture

struct CaptureBox: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool
    var autofocus = false
    /// Fixed editor height (the Quick Note panel); nil = at least 90 pt, growing with its container.
    var editorHeight: CGFloat? = nil
    /// Start dictating as soon as it opens (the Voice Note shortcut).
    var listen = false
    var onSaved: () -> Void = {}
    @State private var dictation = Dictation()

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $text)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: editorHeight ?? 90, maxHeight: editorHeight)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Note anything — “Dana will send the signed CR by Wed”, “call Anna re SOW”…")
                            .foregroundStyle(.tertiary).padding(14).allowsHitTesting(false)
                    }
                }
            HStack {
                DictationStatus(dictation: dictation)
                Spacer()
                MicButton(text: $text, dictation: dictation, autoStart: listen, preload: true)
                Button("Save Note") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { if autofocus { focused = true } }
        .onDisappear { dictation.cancel() }
    }

    func save() {
        if model.addNote(text) != nil {
            text = ""
            AgentHooks.shared?.runNow()
            onSaved()
        }
    }
}

/// Single-line-growing note field pinned below a list (like a chat box). Reliable on both platforms,
/// unlike a TextEditor inside a List row, which on macOS doesn't take keyboard focus.
/// Mac: ↩ saves, ⌥↩ new line. iPhone: Save button (return adds a line).
struct ComposeBar: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var savedFlash = false
    @State private var dictation = Dictation()
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            MicButton(text: $text, dictation: dictation, size: 20).padding(.bottom, 8)
            TextField(savedFlash ? "Saved ✓ — Jinnie is on it" : "New note — “Dana will send the CR by Wed”…", text: $text, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .focused($focused)
                .keyboardDoneButton()
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.background, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary))
                #if os(macOS)
                .onSubmit(save)
                #endif
            Button(action: save) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
            }
            .buttonStyle(.plain)
            .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.accentColor)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Save note (⌘↩)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    func save() {
        guard model.addNote(text) != nil else { return }
        text = ""
        #if os(iOS)
        focused = false
        #endif
        savedFlash = true
        AgentHooks.shared?.runNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { savedFlash = false }
    }
}

extension View {
    /// iPhone: a Done button above the keyboard. No-op on the Mac.
    @ViewBuilder func keyboardDoneButton() -> some View {
        #if os(iOS)
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        #else
        self
        #endif
    }

    /// iPhone: dragging the list hides the keyboard.
    @ViewBuilder func dismissesKeyboardOnScroll() -> some View {
        #if os(iOS)
        scrollDismissesKeyboard(.interactively)
        #else
        self
        #endif
    }
}

// MARK: - Today

struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            #if os(iOS)
            if model.projects.isEmpty && model.items.isEmpty {
                Section {
                    Label("Jinnie's agent runs on your Mac", systemImage: "desktopcomputer").font(.headline)
                    Text("Install Jinnie for Mac (github.com/romadinov/Jinnie/releases), complete Set Up Jinnie there, and use the same Apple Account here. Projects, people and actions appear once it has read your sources. Notes you add here are processed by the Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            #endif
            let problems = model.sourceProblems
            if !problems.isEmpty {
                Section {
                    ForEach(problems, id: \.source) { p in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(p.source.label) isn't being read").font(.body.weight(.semibold))
                                Text(p.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    }
                    #if os(macOS)
                    Button("Open Setup…") { SetupWindow.shared.show() }
                    #else
                    Text("Fix it on your Mac: Jinnie → Set Up Jinnie.").font(.caption).foregroundStyle(.secondary)
                    #endif
                }
            }
            if !model.openClarifications.isEmpty {
                Panel(id: "today.questions", title: "Open questions", count: model.openClarifications.count) {
                    ForEach(model.openClarifications.prefix(5)) { ClarificationRow(clarification: $0) }
                    if model.openClarifications.count > 5 {
                        NavigationLink("All \(model.openClarifications.count) questions") { QuestionsView() }
                    }
                }
            }
            if !model.recordingsToName.isEmpty {
                Panel(id: "today.recordings", title: "Who was speaking?", count: model.recordingsToName.count) {
                    ForEach(model.recordingsToName.prefix(5)) { r in
                        NavigationLink(value: Route.recording(r.id)) { RecordingRow(recording: r) }
                        // Name them right here: play a sample, pick who it is.
                        ForEach(r.unnamedSpeakers, id: \.label) { s in SpeakerRow(recording: r, speaker: s).padding(.leading, 20) }
                    }
                }
            }
            let news = model.latestNews(days: 7)
            if !news.isEmpty {
                Panel(id: "today.news", title: "What's new", count: news.count) {
                    ForEach(news.prefix(12), id: \.news) { NewsRow(news: $0.news, project: $0.project) }
                }
            }
            Panel(id: "today.next", title: "Next actions", count: model.openNext.count) {
                if model.openNext.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
                ForEach(model.openNext) { ActionRow(action: $0) }
            }
            Panel(id: "today.waiting", title: "Waiting for", count: model.openWaiting.count) {
                if model.openWaiting.isEmpty { Text("Nobody owes you anything").foregroundStyle(.secondary) }
                ForEach(model.openWaiting) { ActionRow(action: $0) }
            }
            Panel(id: "today.recent", title: "Recent") {
                ForEach(model.items.prefix(25)) { item in
                    ItemRow(item: item)
                }
            }
        }
        .dismissesKeyboardOnScroll()
        .safeAreaInset(edge: .bottom, spacing: 0) { ComposeBar() }
        .navigationTitle("Today")
    }
}

// MARK: - Open questions

struct QuestionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let open = model.openClarifications, answered = model.recentlyAnswered
        List {
            Panel(id: "questions.open", title: "To validate", count: open.count) {
                if open.isEmpty {
                    Text("Nothing to check. Jinnie asks here when sources disagree or it isn't sure who someone is.").foregroundStyle(.secondary)
                }
                ForEach(open) { ClarificationRow(clarification: $0) }
            }
            if !answered.isEmpty {
                Panel(id: "questions.answered", title: "Answered", count: answered.count) {
                    ForEach(answered) { ClarificationRow(clarification: $0) }
                }
            }
        }
        .dismissesKeyboardOnScroll()
        .navigationTitle("Open questions")
    }
}

// MARK: - Notes

struct NotesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.notes) { n in
                VStack(alignment: .leading, spacing: 4) {
                    Text(n.text).textSelection(.enabled)
                    HStack(spacing: 6) {
                        if let e = n.processError {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(e)
                        } else if n.processedAt != nil {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Processed")
                        } else {
                            Image(systemName: "clock").help("Waiting for the Mac to process it")
                        }
                        Text("\(n.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())) · \(n.device)")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let item = model.item(n.itemID) {
                            NavigationLink(value: Route.item(item.id)) { Text("Details").fixedSize() }
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .contextMenu { Button("Delete", role: .destructive) { model.deleteNote(n) } }
                .swipeActions { Button("Delete", role: .destructive) { model.deleteNote(n) } }
            }
        }
        .overlay { if model.notes.isEmpty { EmptyHint(title: "No notes yet", systemImage: "note.text", message: "Write one below. Jinnie links it to projects, people and actions.") } }
        .dismissesKeyboardOnScroll()
        .safeAreaInset(edge: .bottom, spacing: 0) { ComposeBar() }
        .navigationTitle("Notes")
    }
}

// MARK: - Actions

struct ActionsView: View {
    @Environment(AppModel.self) private var model
    @State private var kind: Action.Kind = .next
    @State private var showClosed = false

    var body: some View {
        let list = model.actions.filter { $0.kind == kind && (showClosed || model.isListed($0)) }
        let groups = Dictionary(grouping: list) { model.project($0.projectID)?.name ?? "No project" }
        List {
            ForEach(groups.keys.sorted(), id: \.self) { key in
                Panel(id: "actions.\(key)", title: key, count: groups[key]!.count) {
                    ForEach(groups[key]!) { ActionRow(action: $0, showProject: false) }
                }
            }
        }
        .overlay { if list.isEmpty { EmptyHint(title: "No actions", systemImage: "checklist") } }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Kind", selection: $kind) {
                    Text("Next").tag(Action.Kind.next)
                    Text("Waiting").tag(Action.Kind.waiting)
                }.pickerStyle(.segmented).fixedSize()
            }
            ToolbarItem { Toggle("Show closed", isOn: $showClosed) }
            #if os(iOS)
            if !model.recentlyClosed.isEmpty {
                ToolbarItem { Button { withAnimation { model.cleanUp() } } label: { Image(systemName: "wand.and.sparkles") } }
            }
            #endif
        }
        .navigationTitle("Actions")
    }
}

// MARK: - Projects

struct ProjectsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let active = model.projects.filter { $0.status != .done }
            .map { (project: $0, last: model.lastActivity(model.items(for: $0))) }
        List {
            Section {
                ForEach(active.filter { $0.last != nil }.sorted { $0.last! > $1.last! }, id: \.project.id) { entry in
                    NavigationLink(value: Route.project(entry.project.id)) { ProjectRow(project: entry.project, last: entry.last) }
                }
            }
            let quiet = active.filter { $0.last == nil }
            if !quiet.isEmpty {
                Panel(id: "projects.quiet", title: "Nothing learned yet", count: quiet.count) {
                    ForEach(quiet, id: \.project.id) { entry in
                        NavigationLink(value: Route.project(entry.project.id)) { Text(entry.project.name).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("Projects")
    }
}

struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let last: Date?
    var showCustomer = true

    var body: some View { rowContent.copyable({ project.name }, label: "Copy Name") }

    @ViewBuilder var rowContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(project.name).font(.body.weight(.semibold))
                if showCustomer, let c = model.customer(project.customerID), c.name != project.name {
                    Text(c.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                let open = model.actions(for: project).filter { $0.status == .open }
                let waiting = open.filter { $0.kind == .waiting }.count
                if open.count - waiting > 0 { Label("\(open.count - waiting)", systemImage: "checklist").font(.caption).foregroundStyle(.secondary) }
                if waiting > 0 { Label("\(waiting)", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary) }
            }
            if let preview = ProjectRow.preview(project.summary) {
                Text(preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            if let last {
                Text("Last activity \(last.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    /// First sentence of the summary's Status section, without markdown.
    static func preview(_ summary: String?) -> String? {
        guard let summary else { return nil }
        let body = summary.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("**Status") && !$0.hasPrefix("#") } ?? ""
        let plain = body.replacingOccurrences(of: "**", with: "")
        return plain.isEmpty ? nil : plain
    }
}

struct ProjectDetail: View {
    @Environment(AppModel.self) private var model
    let projectID: String
    @State private var editing = false

    var body: some View {
        if let p = model.project(projectID) {
            List {
                if let c = model.customer(p.customerID) {
                    NavigationLink(value: Route.customer(c.id)) {
                        Label("\(c.isProspect ? "Potential customer" : "Customer"): \(c.name)", systemImage: "building.2")
                    }
                }
                let questions = model.clarifications(for: p)
                if !questions.isEmpty {
                    Panel(id: "project.questions", title: "Open questions", count: questions.count) {
                        ForEach(questions) { ClarificationRow(clarification: $0, showProject: false) }
                    }
                }
                if let news = p.news, !news.isEmpty {
                    Panel(id: "project.news", title: "Latest news", count: news.count) {
                        ForEach(news, id: \.self) { NewsRow(news: $0) }
                    }
                }
                Panel(id: "project.summary", title: "Summary") {
                    if let s = p.summary {
                        MarkdownText(text: s)
                        if let at = p.summaryAt {
                            Text("Updated \(at.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No summary yet.").foregroundStyle(.secondary)
                    }
                    Button {
                        if let hooks = AgentHooks.shared { hooks.summarize(p.id) }
                        else { var q = p; q.summaryRequestedAt = Date(); model.save(q) }
                    } label: {
                        if p.summaryRequestedAt.map({ $0 > (p.summaryAt ?? .distantPast) }) ?? false {
                            Label("Summarizing…", systemImage: "hourglass")
                        } else {
                            Label(p.summary == nil ? "Generate summary" : "Refresh summary", systemImage: "sparkles")
                        }
                    }
                }

                let acts = model.actions(for: p).filter { model.isListed($0) }
                Panel(id: "project.next", title: "Next actions", count: acts.filter { $0.kind == .next }.count) {
                    ForEach(acts.filter { $0.kind == .next }) { ActionRow(action: $0, showProject: false) }
                }
                Panel(id: "project.waiting", title: "Waiting for", count: acts.filter { $0.kind == .waiting }.count) {
                    ForEach(acts.filter { $0.kind == .waiting }) { ActionRow(action: $0, showProject: false) }
                }
                let docs = model.documents(for: p)
                if !docs.isEmpty {
                    Panel(id: "project.documents", title: "Documents", count: docs.count) {
                        ForEach(docs.prefix(30), id: \.doc.url) { DocumentRow(doc: $0.doc, date: $0.date) }
                    }
                }
                if let list = p.stakeholders, !list.isEmpty {
                    ForEach(Stakeholder.Side.allCases, id: \.self) { side in
                        let group = list.filter { $0.side == side }
                            .sorted { ($0.former == true ? 1 : 0, $0.key == true ? 0 : 1) < ($1.former == true ? 1 : 0, $1.key == true ? 0 : 1) }
                        if !group.isEmpty {
                            Panel(id: "project.stakeholders.\(side.rawValue)", title: side == .customer ? "Customer — \(p.name)" : side.label,
                                  count: group.filter { $0.former != true }.count) {
                                ForEach(group, id: \.personID) { StakeholderRow(stakeholder: $0) }
                            }
                        }
                    }
                }
                Panel(id: "project.people", title: p.stakeholders?.isEmpty == false ? "Everyone involved" : "People", count: model.people(for: p).count) {
                    ForEach(model.people(for: p), id: \.person.id) { entry in
                        let person = entry.person
                        NavigationLink(value: Route.person(person.id)) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(person.name)
                                    Text([person.role, person.org, person.emails.first].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if entry.count > 0 { Text("\(entry.count)").font(.caption).foregroundStyle(.secondary).help("Items they appear in") }
                            }
                        }
                    }
                }
                Panel(id: "project.timeline", title: "Timeline", count: model.items(for: p).count) {
                    ForEach(model.items(for: p).prefix(100)) { item in
                        ItemRow(item: item)
                    }
                }
            }
            .navigationTitle(p.name)
            .toolbar {
                if let hooks = AgentHooks.shared {
                    Button("Scan History") { hooks.scan(p.id) }.help("Read this project's emails, meetings and documents from the last 6 months")
                }
                Button("Edit") { editing = true }
            }
            .sheet(isPresented: $editing) { ProjectEditor(project: p) }
        }
    }
}

struct StakeholderRow: View {
    @Environment(AppModel.self) private var model
    let stakeholder: Stakeholder

    var body: some View { rowContent.copyable({ (model.person(stakeholder.personID) ?? model.directory.person(id: stakeholder.personID))?.name ?? "" }, label: "Copy Name") }

    @ViewBuilder var rowContent: some View {
        if let person = model.person(stakeholder.personID) ?? model.directory.person(id: stakeholder.personID) {
            NavigationLink(value: Route.person(person.id)) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: stakeholder.key == true ? "star.fill" : "person")
                        .font(.caption).foregroundStyle(stakeholder.key == true ? Color.orange : Color.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(person.name).font(.body.weight(stakeholder.key == true ? .semibold : .regular))
                            Text(stakeholder.role).foregroundStyle(.secondary)
                        }
                        if let r = stakeholder.responsibilities { Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        if stakeholder.former == true {
                            let by = model.person(stakeholder.replacedByID)?.name
                            Text(by.map { "Former — replaced by \($0)" } ?? "Former").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .opacity(stakeholder.former == true ? 0.55 : 1)
            }
        }
    }
}

struct ProjectEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var project: Project
    @State private var aliases = ""
    @State private var domains = ""
    @State private var channels = ""
    @State private var customer = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $project.name)
                TextField("Customer (empty for internal work)", text: $customer)
                    .help("An existing customer's name, or a new one")
                if !model.customers.isEmpty {
                    Picker("Pick a customer", selection: $customer) {
                        Text("None (internal)").tag("")
                        ForEach(model.customers) { Text($0.isProspect ? "\($0.name) (potential)" : $0.name).tag($0.name) }
                        if !customer.isEmpty && !model.customers.contains(where: { $0.name == customer }) { Text("New: \(customer)").tag(customer) }
                    }
                }
                TextField("Aliases (comma separated)", text: $aliases)
                TextField("Email domains", text: $domains)
                TextField("Slack channels", text: $channels)
                TextField("Description", text: $project.description, axis: .vertical)
                Picker("Status", selection: $project.status) {
                    ForEach(Project.Status.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if let path = project.uberdoerPath { LabeledContent("Uberdoer", value: path) }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        project.aliases = split(aliases); project.domains = split(domains).map { $0.lowercased() }; project.channels = split(channels)
                        model.save(project)
                        if customer != (model.customer(project.customerID)?.name ?? "") { model.setCustomer(project, name: customer) }
                        dismiss()
                    }
                }
            }
            .onAppear {
                aliases = project.aliases.joined(separator: ", ")
                domains = project.domains.joined(separator: ", ")
                channels = project.channels.joined(separator: ", ")
                customer = model.customer(project.customerID)?.name ?? ""
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }
}

func split(_ s: String) -> [String] {
    s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

// MARK: - People

struct PeopleView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        let list = query.isEmpty ? model.people : model.people.filter {
            $0.searchText.localizedCaseInsensitiveContains(query)
        }
        List(list) { p in
            NavigationLink(value: Route.person(p.id)) {
                VStack(alignment: .leading) {
                    Text(p.name)
                    Text(([p.org] + p.projectIDs.map { model.project($0)?.name }).compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .textSelection(.disabled)
            .contextMenu {
                Button { Clipboard.copy(p.name) } label: { Label("Copy Name", systemImage: "doc.on.doc") }
                if let e = p.emails.first { Button { Clipboard.copy(e) } label: { Label("Copy \(e)", systemImage: "envelope") } }
            }
        }
        .searchable(text: $query)
        .navigationTitle("People")
    }
}

/// The person in your Contacts: fill blanks from there, open the card (Mac), or add them.
struct ContactsRow: View {
    @Environment(AppModel.self) private var model
    let person: Person
    @State private var allowed = ContactsBridge.allowed
    @State private var note: String?

    var body: some View {
        HStack(spacing: 14) {
            if !allowed {
                Button("Allow Contacts") { Task { allowed = await ContactsBridge.requestAccess() } }
            } else if let c = ContactsBridge.contact(for: person) {
                #if os(macOS)
                Button { ContactsBridge.open(c) } label: { Label("Open in Contacts", systemImage: "person.crop.square") }
                #endif
                if let q = ContactsBridge.enriched(person) {
                    Button { model.save(q); note = "Filled in from Contacts." } label: { Label("Fill In from Contacts", systemImage: "arrow.down.doc") }
                } else {
                    Label("In your Contacts", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
            } else {
                Button {
                    do { try ContactsBridge.add(person); note = "Added to Contacts." } catch { note = "Couldn't add: \(error.localizedDescription)" }
                } label: { Label("Add to Contacts", systemImage: "person.crop.circle.badge.plus") }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

struct PersonDetail: View {
    @Environment(AppModel.self) private var model
    let personID: String
    @State private var editing = false

    var body: some View {
        if let p = model.person(personID) {
            List {
                Section {
                    ForEach(p.emails, id: \.self) { e in LabeledContent("Email", value: e) }
                    if let org = p.org { LabeledContent("Organisation", value: org) }
                    if let role = p.role { LabeledContent("Role", value: role) }
                    if !p.aliases.isEmpty { LabeledContent("Also known as", value: p.aliases.joined(separator: ", ")) }
                    let projects = p.projectIDs.compactMap { model.project($0) }
                    if !projects.isEmpty {
                        HStack { Text("Projects"); Spacer(); ForEach(projects) { ProjectChip(name: $0.name) } }
                    }
                    if !p.notes.isEmpty { Text(p.notes) }
                    ContactsRow(person: p)
                }
                let acts = model.actions(for: p).filter { model.isListed($0) }
                if !acts.isEmpty {
                    Panel(id: "person.actions", title: "Actions", count: acts.count) { ForEach(acts) { ActionRow(action: $0) } }
                }
                VoicePanel(person: p)
                Panel(id: "person.timeline", title: "Timeline", count: model.items(for: p).count) {
                    ForEach(model.items(for: p).prefix(100)) { item in
                        ItemRow(item: item)
                    }
                }
            }
            .navigationTitle(p.name)
            .toolbar { Button("Edit") { editing = true } }
            .sheet(isPresented: $editing) { PersonEditor(person: p) }
        }
    }
}

struct PersonEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var person: Person
    @State private var emails = ""
    @State private var aliases = ""
    @State private var org = ""
    @State private var role = ""
    @State private var projects: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $person.name)
                TextField("Emails", text: $emails)
                TextField("Aliases / nicknames", text: $aliases)
                TextField("Organisation", text: $org)
                TextField("Role", text: $role)
                Section("Projects") {
                    ForEach(model.projects) { pr in
                        Toggle(pr.name, isOn: Binding(get: { projects.contains(pr.id) },
                                                      set: { if $0 { projects.insert(pr.id) } else { projects.remove(pr.id) } }))
                    }
                }
                TextField("Notes", text: $person.notes, axis: .vertical)
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Person")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        person.emails = split(emails).map { $0.lowercased() }
                        person.aliases = split(aliases)
                        person.org = org.isEmpty ? nil : org
                        person.role = role.isEmpty ? nil : role
                        person.projectIDs = Array(projects)
                        model.save(person); dismiss()
                    }
                }
            }
            .onAppear {
                emails = person.emails.joined(separator: ", "); aliases = person.aliases.joined(separator: ", ")
                org = person.org ?? ""; role = person.role ?? ""; projects = Set(person.projectIDs)
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }
}

// MARK: - Ask

struct AskView: View {
    @Environment(AppModel.self) private var model
    @State private var dictation = Dictation()
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.questions) { q in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(q.text).font(.headline)
                        if let a = q.answer {
                            MarkdownText(text: a)
                        } else if let e = q.error {
                            Text(e).foregroundStyle(.orange)
                        } else {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(AgentHooks.shared == nil ? "Thinking… (your Mac answers this)" : "Thinking…").foregroundStyle(.secondary)
                            }
                        }
                        Text(q.askedAt, format: .dateTime.day().month(.abbreviated).hour().minute()).font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .contextMenu { Button("Delete", role: .destructive) { model.deleteQuestion(q) } }
                    .swipeActions { Button("Delete", role: .destructive) { model.deleteQuestion(q) } }
                }
            }
            .dismissesKeyboardOnScroll()
            .overlay {
                if model.questions.isEmpty {
                    EmptyHint(title: "Ask anything", systemImage: "sparkle.magnifyingglass",
                              message: "“What did Dana promise last week?”, “Where are we with Acme billing?”")
                }
            }
            if dictation.isBusy { DictationStatus(dictation: dictation).padding(.horizontal) }
            HStack {
                // A spoken question is sent as soon as you stop talking.
                MicButton(text: $text, dictation: dictation, size: 20) { _ in send() }
                TextField("Ask Jinnie…", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .onChange(of: text) { _, new in
                        // On iPhone, Return in a growing field inserts a newline: treat it as Send.
                        if new.contains("\n") { text = new.replacingOccurrences(of: "\n", with: " "); send() }
                    }
                    .keyboardDoneButton()
                Button("Ask", action: send).buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .navigationTitle("Ask")
    }

    func send() {
        if model.ask(text) != nil {
            focused = false
            text = ""
            AgentHooks.shared?.runNow()
        }
    }
}

// MARK: - Search

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        List(query.count < 2 ? [] : model.search(query)) { item in
            ItemRow(item: item)
        }
        .searchable(text: $query, prompt: "Search everything")
        .navigationTitle("Search")
    }
}

// MARK: - Activity

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("iCloud") {
                LabeledContent("Status", value: model.syncStatus.state)
                if let d = model.syncStatus.lastSync { LabeledContent("Last sync", value: d.formatted(.relative(presentation: .named))) }
                LabeledContent("Pending uploads", value: "\(model.syncStatus.pending)")
                if let e = model.syncStatus.lastError { Text(e).foregroundStyle(.orange).font(.caption) }
            }
            let usage = model.runs.filter { $0.kind == "usage" }.sorted { $0.startedAt > $1.startedAt }
            if !usage.isEmpty {
                Section {
                    let today = usage.first { Calendar.current.isDateInToday($0.startedAt) }
                    let week = usage.filter { $0.startedAt > Date().addingTimeInterval(-7 * 86400) }
                    LabeledContent("Today", value: String(format: "$%.2f", today.map { Usage.total($0.message) } ?? 0))
                    if let today, !today.message.isEmpty { Text(today.message).font(.caption).foregroundStyle(.secondary) }
                    LabeledContent("Last 7 days", value: String(format: "$%.2f", week.map { Usage.total($0.message) }.reduce(0, +)))
                    ForEach(week.dropFirst(today == nil ? 0 : 1)) { d in
                        LabeledContent(d.startedAt.formatted(.dateTime.weekday().day().month(.abbreviated)), value: String(format: "$%.2f", Usage.total(d.message)))
                            .font(.callout)
                    }
                } header: {
                    Text("Usage")
                } footer: {
                    Text("Runs use your Claude subscription; amounts are the API-equivalent price, a measure of how much of your plan's limits Jinnie uses.")
                }
            }
            Section("Agent runs") {
                ForEach(model.runs.filter { $0.kind != "usage" }.prefix(100)) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: r.finishedAt == nil ? "clock" : (r.ok ? "checkmark.circle" : "exclamationmark.triangle"))
                                .foregroundStyle(r.finishedAt == nil ? Color.secondary : (r.ok ? Color.green : Color.orange))
                            Text(r.kind).font(.body.monospaced())
                            Spacer()
                            Text(r.startedAt, format: .dateTime.day().month(.abbreviated).hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }
                        if !r.message.isEmpty { Text(r.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
            }
        }
        .navigationTitle("Activity")
    }
}

// MARK: - Navigation

enum Route: Hashable {
    case item(String), project(String), person(String), action(String), recording(String), customer(String)

    /// jinnie://action/<id>, jinnie://item/<id>, jinnie://project/<id>, jinnie://person/<id>
    init?(url: URL) {
        guard url.scheme == "jinnie", let host = url.host() else { return nil }
        let id = url.pathComponents.dropFirst().first ?? ""
        guard !id.isEmpty else { return nil }
        switch host {
        case "action": self = .action(id)
        case "item": self = .item(id)
        case "project": self = .project(id)
        case "person": self = .person(id)
        case "recording": self = .recording(id)
        case "customer": self = .customer(id)
        default: return nil
        }
    }
}

extension View {
    func jinnieDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            RouteView(route: route).textSelection(.enabled)
        }
    }
}

struct RouteView: View {
    @Environment(AppModel.self) private var model
    let route: Route
    var body: some View {
        content.onAppear {
            // "Mac › Projects › Acme", for improvement notes.
            let base = model.place.components(separatedBy: " › ").prefix(2).joined(separator: " › ")
            model.place = base + " › " + title
        }
    }

    var title: String {
        switch route {
        case .item(let id): "Item: " + (model.item(id)?.title ?? id)
        case .project(let id): "Project: " + (model.project(id)?.name ?? id)
        case .person(let id): "Person: " + (model.person(id)?.name ?? id)
        case .action(let id): "Action: " + (model.actions.first { $0.id == id }?.title ?? id)
        case .recording(let id): "Recording: " + (model.recording(id)?.title ?? id)
        case .customer(let id): "Customer: " + (model.customer(id)?.name ?? id)
        }
    }

    @ViewBuilder var content: some View {
        switch route {
        case .item(let id): if let i = model.item(id) { ItemDetail(item: i) }
        case .project(let id): ProjectDetail(projectID: id)
        case .person(let id): PersonDetail(personID: id)
        case .action(let id): ActionDetail(actionID: id)
        case .recording(let id): RecordingDetail(recordingID: id)
        case .customer(let id): CustomerDetail(customerID: id)
        }
    }
}

enum Section_: String, CaseIterable, Identifiable {
    case today = "Today", notes = "Notes", actions = "Actions", customers = "Customers", projects = "Projects", people = "People",
         questions = "Questions", recordings = "Recordings", ask = "Ask", search = "Search", activity = "Activity"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .today: "sun.max"; case .notes: "note.text"; case .actions: "checklist"; case .customers: "building.2"; case .projects: "folder"
        case .people: "person.2"; case .questions: "questionmark.bubble"; case .recordings: "waveform"; case .ask: "sparkles"; case .search: "magnifyingglass"; case .activity: "waveform.path.ecg"
        }
    }
    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .today: TodayView()
        case .notes: NotesView()
        case .actions: ActionsView()
        case .customers: CustomersView()
        case .projects: ProjectsView()
        case .people: PeopleView()
        case .questions: QuestionsView()
        case .recordings: RecordingsView()
        case .ask: AskView()
        case .search: SearchView()
        case .activity: ActivityView()
        }
    }
}
