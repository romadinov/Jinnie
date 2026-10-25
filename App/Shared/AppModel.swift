import Foundation
import JinnieCore
import Observation
#if os(iOS)
import UIKit
#endif

/// UI state for both apps: a cached snapshot of the store, refreshed whenever anything writes to it
/// (this process, the CLI/MCP server via Darwin notification, or iCloud).
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let store: Store
    private(set) var sync: CloudSync?
    var syncStatus = SyncStatus()

    private(set) var projects: [Project] = []
    private(set) var people: [Person] = []
    private(set) var items: [Item] = []
    private(set) var actions: [Action] = []
    private(set) var notes: [Note] = []
    private(set) var questions: [Question] = []
    private(set) var clarifications: [Clarification] = []
    private(set) var recordings: [Recording] = []
    private(set) var runs: [RunLog] = []
    private(set) var directory = Directory(people: [], projects: [])

    /// Where the user is ("Mac › Today", "iPhone › Projects"), for improvement notes.
    var place = "Today"

    // MARK: Expand/collapse (Uberdoer-style disclosure)
    /// Rows opened in place (actions, items). Not persisted.
    var expandedRows: Set<String> = []
    /// Sections the user closed; remembered across launches.
    var collapsedSections: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedSections") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsedSections), forKey: "collapsedSections") }
    }
    func toggleRow(_ id: String) {
        if expandedRows.contains(id) { expandedRows.remove(id) } else { expandedRows.insert(id) }
    }
    func toggleSection(_ id: String) {
        if collapsedSections.contains(id) { collapsedSections.remove(id) } else { collapsedSections.insert(id) }
    }

    var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    private init() {
        do { store = try Store() } catch { fatalError("Cannot open database: \(error)") }
        reload()
        // `-expandAll YES` (launch argument) opens every action row; for previews/screenshots.
        if UserDefaults.standard.bool(forKey: "expandAll") { expandedRows = Set(actions.map(\.id)) }
        NotificationCenter.default.addObserver(forName: Store.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        JinnieConfig.observeExternalChanges { [weak self] in
            MainActor.assumeIsolated {
                self?.reload()
                self?.sync?.localChangesCommitted()
            }
        }
        if JinnieConfig.cloudKitAvailable {
            let s = CloudSync(store: store)
            s.onStatus = { st in Task { @MainActor in AppModel.shared.syncStatus = st } }
            sync = s
            s.start()
        } else {
            syncStatus.state = "iCloud sync off (unsigned build)"
        }
    }

    private var reloadPending = false
    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadPending = false
                self?.reload()
                self?.sync?.localChangesCommitted()
            }
        }
    }

    func reload() {
        projects = store.all(Project.self).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        people = store.all(Person.self).filter { !$0.isMe }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        items = store.all(Item.self).sorted { $0.occurredAt > $1.occurredAt }
        actions = store.all(Action.self).sorted { ($0.due ?? "9999", $1.createdAt) < ($1.due ?? "9999", $0.createdAt) }
        notes = store.all(Note.self).sorted { $0.createdAt > $1.createdAt }
        questions = store.all(Question.self).sorted { $0.askedAt > $1.askedAt }
        clarifications = store.all(Clarification.self).sorted { $0.createdAt > $1.createdAt }
        recordings = store.all(Recording.self).sorted { $0.startedAt > $1.startedAt }
        runs = store.all(RunLog.self).sorted { $0.startedAt > $1.startedAt }
        directory = Directory(people: store.all(Person.self), projects: projects)
    }

    // MARK: Lookups

    func project(_ id: String?) -> Project? { directory.project(id: id) }
    func person(_ id: String?) -> Person? { directory.person(id: id) }
    func item(_ id: String?) -> Item? { id.flatMap { i in items.first { $0.id == i } } }

    func items(for project: Project) -> [Item] { items.filter { $0.projectIDs.contains(project.id) } }
    func items(for person: Person) -> [Item] { items.filter { $0.personIDs.contains(person.id) } }
    func actions(for project: Project) -> [Action] { actions.filter { $0.projectID == project.id } }
    func actions(for person: Person) -> [Action] { actions.filter { $0.personID == person.id } }
    /// News across projects from the last `days` days, newest first.
    func latestNews(days: Int = 7) -> [(project: Project, news: NewsItem)] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!.formatted(.iso8601.year().month().day())
        return projects.flatMap { p in (p.news ?? []).filter { $0.date >= cutoff }.map { (project: p, news: $0) } }
            .sorted { ($0.news.date, $0.news.important == true ? 1 : 0) > ($1.news.date, $1.news.important == true ? 1 : 0) }
    }

    /// Unique documents linked from a project's items, newest first.
    func documents(for project: Project) -> [(doc: DocLink, date: Date)] {
        var seen = Set<String>()
        var out: [(DocLink, Date)] = []
        for i in items(for: project) { for d in i.documents ?? [] where seen.insert(d.url).inserted { out.append((d, i.occurredAt)) } }
        return out.map { (doc: $0.0, date: $0.1) }
    }

    /// Project people, most involved first: members plus anyone appearing in its items, ranked by appearances.
    func people(for project: Project) -> [(person: Person, count: Int)] {
        var counts: [String: Int] = [:]
        for i in items(for: project) {
            for id in i.personIDs { counts[id, default: 0] += 1 }
            if let e = i.authorEmail, let a = directory.person(email: e) { counts[a.id, default: 0] += 1 }
        }
        let ids = Set(people.filter { $0.projectIDs.contains(project.id) }.map(\.id)).union(counts.keys)
        return ids.compactMap { person($0) }.filter { !$0.isMe }
            .map { (person: $0, count: counts[$0.id] ?? 0) }
            .sorted { ($0.count, $1.person.name) > ($1.count, $0.person.name) }
    }

    func personName(_ a: Action) -> String? { person(a.personID)?.name ?? a.personName }

    var openNext: [Action] { actions.filter { $0.kind == .next && isListed($0) } }
    var openWaiting: [Action] { actions.filter { $0.kind == .waiting && isListed($0) } }

    // MARK: Done, as in Uberdoer
    /// Completed or dropped here this session: they stay in place (struck through) so a mis-tap is one click to undo,
    /// until Clean Up or switching to another view.
    var recentlyClosed: Set<String> = []
    func isListed(_ a: Action) -> Bool { a.status == .open || recentlyClosed.contains(a.id) }
    func cleanUp() { recentlyClosed = [] }
    func toggleDone(_ a: Action) { setStatus(a, a.status == .open ? .done : .open) }

    func search(_ q: String) -> [Item] {
        store.search(q, types: [Item.type], limit: 50).compactMap { hit in items.first { $0.id == hit.id } }
    }

    // MARK: Writes

    @discardableResult
    func addNote(_ text: String) -> Note? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return store.save(Note(text: t, device: deviceName))
    }

    func deleteNote(_ n: Note) { store.delete(n) }

    @discardableResult
    func ask(_ text: String) -> Question? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return store.save(Question(text: t, device: deviceName))
    }

    func deleteQuestion(_ q: Question) { store.delete(q) }

    // MARK: Open questions (Jinnie asks you to validate something)

    var openClarifications: [Clarification] { clarifications.filter { $0.status == .open } }
    /// Answered but not yet applied by the Mac, or applied/failed recently: shown so you see what happened.
    var recentlyAnswered: [Clarification] {
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        return clarifications.filter { ($0.status == .answered || $0.status == .applied) && ($0.answeredAt ?? $0.createdAt) > cutoff }
            .sorted { ($0.answeredAt ?? .distantPast) > ($1.answeredAt ?? .distantPast) }
    }
    func clarifications(for project: Project) -> [Clarification] { openClarifications.filter { $0.projectID == project.id } }

    func answer(_ c: Clarification, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var c = c
        c.answer = t
        c.answeredAt = Date()
        c.status = .answered
        c.error = nil
        store.save(c)
        AgentHooks.shared?.runNow()
    }

    func dismiss(_ c: Clarification) { var c = c; c.status = .dismissed; store.save(c) }
    func retry(_ c: Clarification) { var c = c; c.error = nil; store.save(c); AgentHooks.shared?.runNow() }

    // MARK: Recordings (who said what)

    func recording(_ id: String?) -> Recording? { id.flatMap { i in recordings.first { $0.id == i } } }
    /// Recent recordings with someone still to be named.
    var recordingsToName: [Recording] {
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        return recordings.filter { $0.status == .ready && $0.startedAt > cutoff && !$0.unnamedSpeakers.isEmpty }
    }

    /// Names a speaker (nil = "not sure"); see Store.assignSpeaker (learns the voice, undoes a wrong match).
    func assignSpeaker(_ rec: Recording, label: Int, personID: String?) {
        store.assignSpeaker(recordingID: rec.id, label: label, personID: personID)
        AgentHooks.shared?.runNow()
    }

    func forgetVoice(_ person: Person, sampleAt index: Int? = nil) { store.forgetVoice(personID: person.id, sampleAt: index) }

    @discardableResult
    func addPerson(named name: String) -> Person? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        if let existing = directory.person(name: n) { return existing }
        return store.save(Person(name: n))
    }

    func deleteRecording(_ r: Recording) { store.delete(r) }

    func setStatus(_ a: Action, _ status: Action.Status) {
        var a = a
        a.status = status
        a.needsPush = true
        if status == .open { recentlyClosed.remove(a.id) } else { recentlyClosed.insert(a.id) }
        store.save(a)
    }

    func save<T: Entity>(_ value: T) { store.save(value) }
}
