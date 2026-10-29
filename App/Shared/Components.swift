import JinnieCore
import SwiftUI

/// Hooks the Mac app installs so shared views can trigger agent work. On iPhone they're nil, and
/// requests travel to the Mac through iCloud instead (questions, summary requests).
@MainActor
final class AgentHooks {
    static var shared: AgentHooks?
    var runNow: () -> Void = {}
    var summarize: (String) -> Void = { _ in }
    var scan: (String) -> Void = { _ in }
    var scanCustomer: (String) -> Void = { _ in }
    var isRunning: () -> Bool = { false }
    var status: () -> String = { "" }
}

/// Puts text on the clipboard (Mac and iPhone).
enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

extension View {
    /// Right-click (Mac) or long-press (iPhone) → Copy: for rows, whose clicks open things rather than select text.
    func copyable(_ text: @escaping () -> String, label: String = "Copy") -> some View {
        textSelection(.disabled)  // rows open things on click; selectable text would swallow the click
            .contextMenu {
                Button { Clipboard.copy(text()) } label: { Label(label, systemImage: "doc.on.doc") }
            }
    }
}

/// "Select All & Copy": copies the whole text, and says so for a moment.
struct CopyAllButton: View {
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(text())
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Label(copied ? "Copied" : "Select All & Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
    }
}

extension Item {
    /// What Jinnie learned from this item, as plain text for copying.
    func learnedText(people: [Person], actions: [Action]) -> String {
        var out = [title, occurredAt.formatted(date: .complete, time: .shortened) + (author.map { " · \($0)" } ?? "")]
        if let link { out.append(link.absoluteString) }
        if !summary.isEmpty { out += ["", summary] }
        if !facts.isEmpty { out += ["", "Facts:"] + facts.map { "• \($0)" } }
        if !people.isEmpty { out += ["", "People: " + people.map(\.display).joined(separator: ", ")] }
        if !actions.isEmpty { out += ["", "Actions:"] + actions.map { "• \($0.title)" } }
        if let docs = documents, !docs.isEmpty { out += ["", "Documents:"] + docs.map { "• \($0.title): \($0.url)" } }
        if let text, !text.isEmpty { out += ["", text] } else if !excerpt.isEmpty { out += ["", "“\(excerpt)”"] }
        return out.joined(separator: "\n")
    }
}

/// Rotating disclosure chevron, as in Uberdoer.
struct Chevron: View {
    let open: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .rotationEffect(.degrees(open ? 90 : 0))
            .foregroundStyle(.secondary)
            .frame(width: 14, height: 14)
    }
}

/// A list section whose header collapses it. `id` should be stable (e.g. "project.<id>.people").
struct Panel<Content: View>: View {
    @Environment(AppModel.self) private var model
    let id: String
    let title: String
    var count: Int? = nil
    @ViewBuilder var content: Content

    var body: some View {
        let open = !model.collapsedSections.contains(id)
        Section {
            if open { content }
        } header: {
            Button { withAnimation(.snappy(duration: 0.15)) { model.toggleSection(id) } } label: {
                HStack(spacing: 6) {
                    Chevron(open: open)
                    Text(title)
                    if let count { Text("\(count)").foregroundStyle(.tertiary) }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Lightweight markdown: headings, bullets, numbered lines and inline styling/links.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
        .textSelection(.enabled)
    }

    private var blocks: [String] {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @ViewBuilder
    private func lineView(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let indent = CGFloat(raw.prefix { $0 == " " }.count / 2) * 14
        if line.hasPrefix("#") {
            inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                .font(.headline).padding(.top, 6)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(String(line.dropFirst(2)))
            }.padding(.leading, indent)
        } else {
            inline(line).padding(.leading, indent)
        }
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }
}

struct SourceBadge: View {
    let source: Source
    var body: some View {
        Image(systemName: source.symbol)
            .foregroundStyle(.secondary)
            .frame(width: 18)
            .help(source.label)
    }
}

/// Where a task or headline came from, as a small chip that opens it there (Slack thread, email, meeting…).
/// Items with nowhere to open (notes, handwriting, recordings) open their details in Jinnie.
struct SourceLink: View {
    @Environment(\.openURL) private var openURL
    let item: Item
    var showAuthor = true

    var body: some View {
        let label = HStack(spacing: 3) {
            Image(systemName: item.source.symbol)
            Text([item.source.label, showAuthor ? item.author.map { $0.split(separator: " ").first.map(String.init) ?? $0 } : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .lineLimit(1)
            if item.link != nil { Image(systemName: "arrow.up.right").imageScale(.small) }
        }
        .font(.caption)
        .foregroundStyle(.tint)
        .help("\(item.title) · \(item.occurredAt.formatted(.dateTime.day().month(.abbreviated)))")
        if let url = item.link {
            Button { openURL(url) } label: { label }.buttonStyle(.borderless)
        } else {
            NavigationLink(value: Route.item(item.id)) { label }.buttonStyle(.borderless)
        }
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View { rowContent.copyable({ item.title }, label: "Copy Title") }

    @ViewBuilder var rowContent: some View {
        let open = model.expandedRows.contains(item.id)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Chevron(open: open)
                SourceBadge(source: item.source)
                Text(item.title).font(.body.weight(.medium)).lineLimit(open ? 3 : 1)
                // A recorded meeting (or its calendar entry) shows its tone: red when heated.
                if let rec = model.recordings.first(where: { $0.itemID == item.id || $0.meetingItemID == item.id || (item.source == .recording && $0.id == item.sourceRef) }) {
                    MoodBadge(recording: rec)
                }
                Spacer()
                Text(item.occurredAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !item.summary.isEmpty {
                Text(item.summary).font(.callout).foregroundStyle(.secondary).lineLimit(open ? nil : 2)
            }
            let tags = item.projectIDs.compactMap { model.project($0)?.name }
            if !tags.isEmpty || item.author != nil {
                HStack(spacing: 6) {
                    if let a = item.author { Text(a).font(.caption).foregroundStyle(.secondary) }
                    ForEach(tags, id: \.self) { t in ProjectChip(name: t) }
                }
            }
            if open { ItemPanel(item: item).padding(.top, 4).padding(.leading, 20) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // Clicks open the row; selectable text would swallow them (Copy is in the context menu; the opened panel is selectable).
        .textSelection(.disabled)
        .onTapGesture { withAnimation(.snappy(duration: 0.15)) { model.toggleRow(item.id) } }
    }
}

/// What an item row shows when opened in place.
struct ItemPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !item.facts.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(item.facts, id: \.self) { f in
                        HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•").foregroundStyle(.secondary); Text(f) }
                    }
                }
                .font(.callout)
            }
            if !item.excerpt.isEmpty {
                Text("“\(item.excerpt)”").font(.callout).italic().foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
            }
            let people = item.personIDs.compactMap { model.person($0) }
            if !people.isEmpty {
                Text(people.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(item.documents ?? [], id: \.url) { DocumentRow(doc: $0) }
            let actions = model.actions.filter { $0.itemID == item.id }
            ForEach(actions) { ActionRow(action: $0) }
            HStack(spacing: 14) {
                if let url = item.link {
                    Button { openURL(url) } label: { Label("Open in \(item.source.label)", systemImage: "arrow.up.right.square") }
                }
                NavigationLink(value: Route.item(item.id)) { Label("Details", systemImage: "info.circle") }
                CopyAllButton { item.learnedText(people: item.personIDs.compactMap { model.person($0) }, actions: actions) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .textSelection(.enabled)
    }
}

/// One headline in a project's news feed. Opens in place to show the items it came from.
struct NewsRow: View {
    @Environment(AppModel.self) private var model
    let news: NewsItem
    var project: Project? = nil

    var body: some View { rowContent.copyable({ [news.headline, news.detail].compactMap { $0 }.joined(separator: "\n") }, label: "Copy Headline") }

    @ViewBuilder var rowContent: some View {
        let key = "news." + (project?.id ?? "") + news.date + news.headline
        let open = model.expandedRows.contains(key)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Chevron(open: open)
                if news.important == true { Circle().fill(Color.orange).frame(width: 7, height: 7) }
                Text(news.headline).font(.body.weight(.semibold))
                Spacer(minLength: 4)
                Text(NewsRow.day(news.date)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if let project { ProjectChip(name: project.name) }
                if let d = news.detail { Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(open ? nil : 2) }
            }
            .padding(.leading, 22)
            let sources = news.itemIDs.compactMap { model.item($0) }
            if !open, !sources.isEmpty {
                HStack(spacing: 10) {
                    ForEach(sources.prefix(4)) { SourceLink(item: $0) }
                    if sources.count > 4 { Text("+\(sources.count - 4)").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.leading, 22)
            }
            if open {
                ForEach(news.itemIDs.compactMap { model.item($0) }) { ItemRow(item: $0) }
                    .padding(.leading, 22)
            }
        }
        .contentShape(Rectangle())
        // Clicks open the row; selectable text would swallow them (Copy is in the context menu; the opened panel is selectable).
        .textSelection(.disabled)
        .onTapGesture { withAnimation(.snappy(duration: 0.15)) { model.toggleRow(key) } }
    }

    static func day(_ iso: String) -> String {
        guard let d = parseISODate(iso) else { return iso }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

struct ProjectChip: View {
    let name: String
    var body: some View {
        Text(name)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
    }
}

struct ItemDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let item: Item

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SourceBadge(source: item.source)
                    Text(item.title).font(.title3.weight(.semibold))
                }
                HStack(spacing: 12) {
                    Text(item.occurredAt, format: .dateTime.weekday().day().month().year().hour().minute())
                    if let a = item.author { Text(a) }
                    if let url = item.link {
                        Button("Open in \(item.source.label)") { openURL(url) }.buttonStyle(.borderless)
                    }
                    CopyAllButton { item.learnedText(people: item.personIDs.compactMap { model.person($0) },
                                                     actions: model.actions.filter { $0.itemID == item.id }) }
                }
                .font(.callout).foregroundStyle(.secondary)
                if !item.summary.isEmpty { Text(item.summary) }
                if !item.facts.isEmpty {
                    Section {
                        ForEach(item.facts, id: \.self) { f in
                            HStack(alignment: .firstTextBaseline) { Text("•"); Text(f) }
                        }
                    } header: { Text("Facts").font(.headline) }
                }
                if let docs = item.documents, !docs.isEmpty {
                    Text("Documents").font(.headline)
                    ForEach(docs, id: \.url) { DocumentRow(doc: $0) }
                }
                let people = item.personIDs.compactMap { model.person($0) }
                if !people.isEmpty {
                    Text("People").font(.headline)
                    ForEach(people) { p in Text(p.display).font(.callout) }
                }
                let actions = model.actions.filter { $0.itemID == item.id }
                if !actions.isEmpty {
                    Text("Actions").font(.headline)
                    ForEach(actions) { a in ActionRow(action: a) }
                }
                if let text = item.text, !text.isEmpty {
                    Text(item.source == .remarkable ? "Transcript" : "Text").font(.headline)
                    Text(text).font(.callout.monospaced()).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                } else if !item.excerpt.isEmpty {
                    Text("Excerpt").font(.headline)
                    Text(item.excerpt).font(.callout).foregroundStyle(.secondary)
                        .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .textSelection(.enabled)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(item.title)
    }
}

struct DocumentRow: View {
    @Environment(\.openURL) private var openURL
    let doc: DocLink
    var date: Date?

    var body: some View { rowContent.copyable({ "\(doc.title)\n\(doc.url)" }, label: "Copy Title and Link") }

    @ViewBuilder var rowContent: some View {
        Button {
            if let url = URL(string: doc.url) { openURL(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: DocumentRow.symbol(doc)).foregroundStyle(.tint).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(doc.title).lineLimit(1)
                    HStack(spacing: 6) {
                        if let k = doc.kind { Text(k) }
                        if let date { Text(date, format: .dateTime.day().month(.abbreviated)) }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func symbol(_ d: DocLink) -> String {
        let k = (d.kind ?? "").lowercased(), u = d.url.lowercased()
        if k.contains("transcript") || k.contains("notes") { return "text.bubble" }
        if u.contains("spreadsheets") || k.contains("sheet") { return "tablecells" }
        if u.contains("presentation") || k.contains("slide") || k.contains("deck") { return "rectangle.on.rectangle" }
        return "doc.text"
    }
}

struct ActionRow: View {
    @Environment(AppModel.self) private var model
    let action: Action
    var showProject = true
    @State private var editing = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Chevron(open: model.expandedRows.contains(action.id))
            CheckCircle(action: action, overdue: isOverdue) { withAnimation(.snappy(duration: 0.15)) { model.toggleDone(action) } }
            details
        }
        .contentShape(Rectangle())
        // Clicks open the row; selectable text would swallow them (Copy is in the context menu; the opened panel is selectable).
        .textSelection(.disabled)
        .onTapGesture { withAnimation(.snappy(duration: 0.15)) { model.toggleRow(action.id) } }
        #if os(iOS)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { withAnimation { model.toggleDone(action) } } label: {
                Label(action.status == .open ? "Complete" : "Reopen", systemImage: action.status == .open ? "checkmark" : "arrow.uturn.backward")
            }.tint(.green)
        }
        .swipeActions(edge: .trailing) {
            if action.status == .open {
                Button(role: .destructive) { withAnimation { model.setStatus(action, .dropped) } } label: { Label("Drop", systemImage: "minus.circle") }
            }
        }
        #endif
        .contextMenu {
            if action.status == .open {
                Button("Complete") { model.setStatus(action, .done) }
                Button("Drop") { model.setStatus(action, .dropped) }
            } else {
                Button("Reopen") { model.setStatus(action, .open) }
            }
            if let item = model.item(action.itemID), let url = item.link {
                Link("Open source (\(item.source.label))", destination: url)
            }
            if let url = action.uberdoerURL { Link("Open in Uberdoer", destination: url) }
            Divider()
            Button { editing = true } label: { Label("Edit…", systemImage: "pencil") }
            Button { Clipboard.copy(action.title) } label: { Label("Copy", systemImage: "doc.on.doc") }
            if let who = model.personName(action) { Button { Clipboard.copy(who) } label: { Label("Copy “\(who)”", systemImage: "person") } }
        }
        .sheet(isPresented: $editing) { ActionEditor(action: action) }
    }

    private var details: some View {
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if action.kind == .waiting {
                        Text("\(model.personName(action) ?? "?")").bold() + Text(" // ") .foregroundColor(.secondary) + Text(action.title)
                    } else {
                        Text(action.title)
                    }
                }
                .strikethrough(action.status != .open, color: .secondary)
                .foregroundStyle(action.status == .open ? Color.primary : Color.secondary)
                let open = model.expandedRows.contains(action.id)
                if !open, let c = action.context, !c.isEmpty {
                    Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if showProject, let p = model.project(action.projectID) { ProjectChip(name: p.name) }
                    if action.kind == .next, let who = model.personName(action) { Text(who).font(.caption).foregroundStyle(.secondary) }
                    if let due = action.due {
                        HStack(spacing: 3) { Image(systemName: "calendar"); Text(NewsRow.day(due)) }
                            .font(.caption).lineLimit(1).fixedSize()
                            .foregroundStyle(isOverdue ? .red : .secondary)
                    }
                    if action.uberdoerID != nil {
                        Image(systemName: "checklist").font(.caption).foregroundStyle(.secondary).help("In Uberdoer")
                    } else if let e = action.syncError {
                        Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).help(e)
                    }
                    if let item = model.item(action.itemID) { SourceLink(item: item) }
                }
                if open { ActionPanel(action: action) { editing = true }.padding(.top, 6) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    var isOverdue: Bool {
        guard let due = action.due, action.status == .open else { return false }
        return due < Date().formatted(.iso8601.year().month().day())
    }
}

/// What an action row shows when opened in place: the context, the quote, who, the source and its documents, links.
struct ActionPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let action: Action
    var edit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let c = action.context { Text(c).font(.callout) }
            if let q = action.quote {
                Text("“\(q)”").font(.callout).italic().foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
            }
            if let p = model.person(action.personID) {
                Label([p.display, p.role, p.org].compactMap { $0 }.joined(separator: " · "), systemImage: "person")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let item = model.item(action.itemID) {
                Label("\(item.source.label): \(item.title) · \(item.occurredAt.formatted(.dateTime.day().month(.abbreviated)))",
                      systemImage: item.source.symbol)
                    .font(.caption).foregroundStyle(.secondary)
                ForEach((item.documents ?? []).prefix(4), id: \.url) { DocumentRow(doc: $0) }
            }
            HStack(spacing: 14) {
                if let item = model.item(action.itemID), let url = item.link {
                    Button { openURL(url) } label: { Label("Source", systemImage: "arrow.up.right.square") }
                }
                if let url = action.uberdoerURL {
                    Button { openURL(url) } label: { Label("Uberdoer", systemImage: "checklist") }
                }
                Button(action: edit) { Label("Edit", systemImage: "pencil") }
                NavigationLink(value: Route.action(action.id)) { Label("Details", systemImage: "info.circle") }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .textSelection(.enabled)
    }
}

struct ActionDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let actionID: String
    @State private var editing = false

    var body: some View {
        if let a = model.actions.first(where: { $0.id == actionID }) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(a.kind == .waiting ? "Waiting for" : "Next action").font(.caption).foregroundStyle(.secondary)
                        Text(a.kind == .waiting ? "\(model.personName(a) ?? "?") // \(a.title)" : a.title).font(.title3.weight(.semibold))
                    }
                    if let c = a.context { Text(c) }
                    if let q = a.quote {
                        Text("“\(q)”").italic().foregroundStyle(.secondary)
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
                    }
                }
                Section {
                    if let p = model.person(a.personID) {
                        NavigationLink(value: Route.person(p.id)) {
                            LabeledContent(a.kind == .waiting ? "Waiting on" : "With") {
                                Text([p.name, p.role, p.org].compactMap { $0 }.joined(separator: " · "))
                            }
                        }
                    } else if let n = a.personName { LabeledContent("Person", value: n) }
                    if let p = model.project(a.projectID) {
                        NavigationLink(value: Route.project(p.id)) { LabeledContent("Project", value: p.name) }
                    }
                    if let d = a.due { LabeledContent("Due", value: d) }
                    LabeledContent("Status", value: a.status.rawValue.capitalized)
                    LabeledContent("Noted", value: a.createdAt.formatted(.dateTime.day().month().year()))
                }
                if let item = model.item(a.itemID) {
                    Section("Source") {
                        ItemRow(item: item)
                        if let url = item.link {
                            Button { openURL(url) } label: { Label("Open in \(item.source.label)", systemImage: "arrow.up.right.square") }
                        }
                        ForEach(item.documents ?? [], id: \.url) { DocumentRow(doc: $0) }
                    }
                }
                Section {
                    if let url = a.uberdoerURL {
                        Button { openURL(url) } label: { Label("Open in Uberdoer", systemImage: "checklist") }
                    } else if let e = a.syncError {
                        Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        Label("Not in Uberdoer yet", systemImage: "clock").foregroundStyle(.secondary)
                    }
                    if a.status == .open {
                        Button("Complete") { model.setStatus(a, .done) }
                        Button("Drop", role: .destructive) { model.setStatus(a, .dropped) }
                    } else {
                        Button("Reopen") { model.setStatus(a, .open) }
                    }
                }
            }
            .navigationTitle(a.title)
            .toolbar { Button("Edit") { editing = true } }
            .sheet(isPresented: $editing) { ActionEditor(action: a) }
        } else {
            EmptyHint(title: "Action not found", systemImage: "questionmark")
        }
    }
}

/// "Add Next Action" / "Add Waiting For" at the end of a list of actions: opens the editor filled in from where it is
/// (project, person). The new action goes to Uberdoer on the next sync, like the ones Jinnie finds.
struct AddActionButton: View {
    var kind: Action.Kind = .next
    var projectID: String?
    var personID: String?
    @State private var adding: Action?

    var body: some View {
        Button {
            var a = Action(kind: kind, title: "")
            a.projectID = projectID
            a.personID = personID
            adding = a
        } label: {
            Label(kind == .waiting ? "Add Waiting For" : "Add Next Action", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .sheet(item: $adding) { QuickAddActions(template: $0) }
    }
}

/// Add actions by typing them: "Waiting on Dana and the vendor team for the PoC" → one waiting-for per person, in the
/// project the text names (QuickAction). Shows what will be added; "More Options…" opens the full editor.
struct QuickAddActions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let template: Action
    @State private var text = ""
    @State private var editing: Action?
    @FocusState private var focused: Bool

    var body: some View {
        let parsed = QuickAction.parse(text, in: model.directory, defaultProjectID: template.projectID, defaultKind: template.kind)
            .map { a -> Action in
                var a = a
                if a.personID == nil && a.personName == nil, let p = template.personID { a.personID = p; a.personName = model.person(p)?.name }
                return a
            }
        NavigationStack {
            Form {
                Section {
                    TextField(template.kind == .waiting ? "Waiting on Dana and Omar for the migration PoC" : "Send Dana the CR draft",
                              text: $text, axis: .vertical)
                        .focused($focused)
                        .onSubmit { add(parsed) }
                } footer: {
                    Text("Start with “Waiting on …” for waiting-for; name several people to track each separately. A project or customer named in the text is used.")
                }
                if !parsed.isEmpty {
                    Section(parsed.count == 1 ? "Will add" : "Will add \(parsed.count)") {
                        ForEach(Array(parsed.enumerated()), id: \.offset) { _, a in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.kind == .waiting ? "\(a.personName ?? "?") // \(a.title)" : a.title)
                                let known = a.personID != nil || a.personName == nil
                                Text([a.kind == .waiting ? "Waiting for" : "Next action", model.project(a.projectID)?.name ?? "No project",
                                      known ? nil : "\(a.personName ?? "") isn't in Jinnie yet"].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(known ? Color.secondary : Color.orange)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Actions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(parsed.count > 1 ? "Add \(parsed.count)" : "Add") { add(parsed) }.disabled(parsed.isEmpty)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("More Options…") { editing = parsed.first ?? template }
                }
            }
            .sheet(item: $editing) { a in
                ActionEditor(action: a, isNew: true) { dismiss() }
            }
            .onAppear { focused = true }
        }
        .frame(minWidth: 460, minHeight: 320)
    }

    func add(_ actions: [Action]) {
        guard !actions.isEmpty else { return }
        for a in actions { model.save(a) }
        AgentHooks.shared?.runNow()
        dismiss()
    }
}

/// Correct an action: what, next or waiting, who, project, due date, context. Saved in Jinnie and pushed to its Uberdoer
/// task on the next sync.
struct ActionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var action: Action
    var isNew = false
    var onSaved: () -> Void = {}
    @State private var hasDue = false
    @State private var due = Date()
    @State private var context = ""
    @State private var choosingPerson = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Kind", selection: $action.kind) {
                    Text("Next action").tag(Action.Kind.next)
                    Text("Waiting for").tag(Action.Kind.waiting)
                }
                .pickerStyle(.segmented)
                TextField("What", text: $action.title, axis: .vertical)
                LabeledContent(action.kind == .waiting ? "Waiting on" : "With") {
                    HStack {
                        Text(model.person(action.personID)?.name ?? action.personName ?? "Nobody").foregroundStyle(.secondary)
                        Button("Change…") { choosingPerson = true }
                        if action.personID != nil || action.personName != nil {
                            Button("Clear") { action.personID = nil; action.personName = nil }
                        }
                    }
                }
                Picker("Project", selection: $action.projectID) {
                    Text("None").tag(String?.none)
                    ForEach(model.projects.filter { $0.status != .done || $0.id == action.projectID }) { Text($0.name).tag(Optional($0.id)) }
                }
                Toggle("Due date", isOn: $hasDue)
                if hasDue { DatePicker("Due", selection: $due, displayedComponents: .date) }
                TextField("Context", text: $context, axis: .vertical)
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Action" : "Edit Action")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        action.title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        action.due = hasDue ? Self.day.string(from: due) : nil
                        let c = context.trimmingCharacters(in: .whitespacesAndNewlines)
                        action.context = c.isEmpty ? nil : c
                        if !isNew { action.needsEditPush = true }
                        if let p = action.personID { action.personName = model.person(p)?.name }
                        model.save(action)
                        AgentHooks.shared?.runNow()
                        dismiss()
                        onSaved()
                    }
                    .disabled(action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $choosingPerson) {
                PersonPicker(title: action.kind == .waiting ? "Waiting on" : "With") { id in
                    action.personID = id
                    action.personName = model.person(id)?.name
                    choosingPerson = false
                } onCancel: { choosingPerson = false }
            }
            .onAppear {
                context = action.context ?? ""
                if let d = action.due.flatMap({ Self.day.date(from: $0) }) { hasDue = true; due = d }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Uberdoer's completion circle: a thin ring (red when overdue) that fills with a small check when done.
/// Dropped shows a dash. Clicking toggles done ↔ open.
struct CheckCircle: View {
    let action: Action
    var overdue = false
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ZStack {
                Circle()
                    .strokeBorder(stroke, lineWidth: 1.5)
                    .background(Circle().fill(action.status == .open ? Color.clear : Color.secondary.opacity(0.25)))
                if action.status == .done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                } else if action.status == .dropped {
                    Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        .help(action.status == .open ? "Complete" : "Mark incomplete")
    }

    var stroke: Color {
        if action.status != .open { return .secondary }
        return overdue ? .red : .secondary
    }
}

struct EmptyHint: View {
    let title: String
    let systemImage: String
    var message: String = ""
    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }
}

// MARK: - Open questions

/// A question Jinnie wants you to validate: tap a suggested answer or type your own. The Mac applies it to people,
/// stakeholders and facts, then refreshes the project.
struct ClarificationRow: View {
    @Environment(AppModel.self) private var model
    let clarification: Clarification
    var showProject = true
    @State private var text = ""
    @State private var changing = false
    @FocusState private var focused: Bool

    var body: some View {
        let c = clarification
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon(c)).foregroundStyle(color(c))
                Text(c.question).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if c.status == .open {
                    Button { withAnimation { model.dismiss(c) } } label: { Image(systemName: "xmark").font(.caption) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Skip: don't know or doesn't matter")
                }
            }
            Group {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if showProject, let p = model.project(c.projectID) { ProjectChip(name: p.name).fixedSize() }
                    if let why = c.why {
                        Text(why).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if c.status == .open {
                    if let options = c.options, !options.isEmpty {
                        FlowButtons(options: options) { model.answer(c, $0) }
                    }
                    HStack(spacing: 6) {
                        TextField("Your answer…", text: $text, axis: Self.fieldAxis)
                            .lineLimit(1...4)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused)
                            .keyboardDoneButton()
                            .onSubmit(send)
                        Button("Answer", action: send).buttonStyle(.borderedProminent).controlSize(.small).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else if changing {
                    HStack(spacing: 6) {
                        TextField("Correct answer…", text: $text, axis: Self.fieldAxis)
                            .lineLimit(1...4)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused)
                            .keyboardDoneButton()
                            .onSubmit(sendChange)
                        Button("Cancel") { changing = false; text = "" }.controlSize(.small)
                        Button("Change", action: sendChange).buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else if let a = c.answer {
                    HStack(alignment: .firstTextBaseline) {
                        Text("You: \(a)").font(.callout)
                        Spacer(minLength: 4)
                        Button("Change answer…") { text = a; changing = true; focused = true }
                            .buttonStyle(.borderless).font(.caption)
                    }
                    if let e = c.error {
                        HStack {
                            Text(e).font(.caption).foregroundStyle(.orange).lineLimit(2)
                            Button("Retry") { model.retry(c) }.buttonStyle(.borderless)
                        }
                    } else if c.status == .applied, let r = c.result {
                        Text(r).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Applying on the Mac…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 24)
        }
        .padding(.vertical, 2)
    }

    /// On the Mac a growing field inside a List changes the row's height without the table noticing, so rows overlap.
    #if os(macOS)
    static let fieldAxis = Axis.horizontal
    #else
    static let fieldAxis = Axis.vertical
    #endif

    func send() {
        model.answer(clarification, text)
        text = ""
        focused = false
    }

    func sendChange() {
        model.changeAnswer(clarification, text)
        text = ""
        changing = false
        focused = false
    }

    func icon(_ c: Clarification) -> String {
        switch c.status {
        case .open: "questionmark.bubble"
        case .answered: c.error == nil ? "hourglass" : "exclamationmark.triangle"
        case .applied: "checkmark.bubble"
        case .dismissed: "xmark.bubble"
        }
    }

    func color(_ c: Clarification) -> Color {
        switch c.status {
        case .open: .accentColor
        case .answered: c.error == nil ? .secondary : .orange
        case .applied: .green
        case .dismissed: .secondary
        }
    }
}

/// Suggested answers as small buttons that wrap onto several lines. A wrapping layout rather than ViewThatFits, which
/// measures every alternative on each pass and, inside a Mac List, made the Questions page lag and rows overlap.
struct FlowButtons: View {
    let options: [String]
    let action: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options, id: \.self) { o in
                Button(o) { action(o) }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}

/// Lays subviews out left to right, starting a new line when the next one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [], row = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// Tabs at the top of a page (Today, Customers): one list at a time instead of a long page of collapsible panels.
/// Wraps onto a second line when they don't fit (iPhone). Not a sideways ScrollView: iOS took it for the page's scroll
/// view and hid it under the navigation bar.
struct TabStrip<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    var count: (Tab) -> Int = { _ in 0 }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tabs) { t in
                let on = t == selection, n = count(t)
                Button { selection = t } label: {
                    HStack(spacing: 5) {
                        Text(title(t))
                        if n > 0 { Text("\(n)").monospacedDigit().foregroundStyle(on ? Color.white.opacity(0.85) : Color.secondary) }
                    }
                    .font(.callout.weight(on ? .semibold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.12)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.vertical, 8)
    }
}
