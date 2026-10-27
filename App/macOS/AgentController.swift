import AppKit
import JinnieAgent
import JinnieCore
import Observation
import ServiceManagement

/// Owns the agent on the Mac: runs a cycle every 30 minutes (each source decides whether it is due),
/// reacts quickly to new notes and questions (from this Mac or synced from the iPhone), and
/// serialises everything so two `claude -p` runs never overlap.
@MainActor @Observable
final class AgentController {
    static let shared = AgentController()

    let agent: Agent
    private(set) var isRunning = false
    private(set) var current = ""
    private(set) var lastCycle: Date?
    var objectWillChangeHack = 0
    private var timer: Timer?
    private var queued: (force: Bool, quick: Bool)?
    private var summaryQueue: [String] = []
    /// Uberdoer re-announces our own MCP writes after merging them; ignore those echoes.
    private var ignoreUberdoerUntil = Date.distantPast
    private var uberdoerSyncPending = false
    private var uberdoerSyncQueued = false
    /// Questions don't wait behind ingest or history scans: they run in their own lane, in parallel.
    private(set) var isAnswering = false
    /// Answers to Jinnie's open questions: their own lane, so they don't queue behind Ask or each other.
    private(set) var isApplying = false

    private init() {
        let binary = Bundle.main.url(forAuxiliaryExecutable: "jinniectl")?.path
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/jinniectl").path
        agent = Agent(store: AppModel.shared.store, jinnieBinary: binary, log: { line in
            NSLog("Jinnie: %@", line)
            Task { @MainActor in AgentController.shared.current = line }
        })
        lastCycle = agent.store.meta("lastCycle").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    func start() {
        agent.migrateIfNeeded()
        SetupWindow.shared.showIfNeeded()
        let hooks = AgentHooks()
        hooks.runNow = { [weak self] in self?.answerNow(); self?.runQuick() }
        hooks.summarize = { [weak self] id in self?.summarize(id) }
        hooks.scan = { [weak self] id in self?.scan(id) }
        hooks.scanCustomer = { [weak self] id in self?.scanCustomer(id) }
        hooks.isRunning = { [weak self] in self?.isRunning ?? false }
        AgentHooks.shared = hooks
        // UI testing against a scratch database: no scheduler, no Uberdoer writes, no login item.
        // Testing: `-importAudio <file>` processes an audio file as if it had been recorded (works with JINNIE_NO_AGENT).
        if let path = UserDefaults.standard.string(forKey: "importAudio") { MeetingRecorder.shared.importAudio(URL(fileURLWithPath: path)) }
        if ProcessInfo.processInfo.environment["JINNIE_NO_AGENT"] != nil { return }
        // Once: strip Whisper's stock phrases ("Продолжение следует…") from transcripts made before they were filtered.
        if !UserDefaults.standard.bool(forKey: "removedHallucinations1") {
            let store = AppModel.shared.store
            for var rec in store.all(Recording.self) where rec.removeHallucinations() > 0 { store.save(rec) }
            UserDefaults.standard.set(true, forKey: "removedHallucinations1")
        }
        MeetingRecorder.shared.resumeInterrupted()
        MeetingDetector.shared.start()

        if agent.store.meta("bootstrapped") == nil {
            if Uberdoer.isInstalled { _ = try? agent.importUberdoerProjects() }
            // The agent only works while the app runs, so start with the Mac by default.
            try? SMAppService.mainApp.register()
            agent.store.setMeta("bootstrapped", "1")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { @MainActor in AgentController.shared.runNow(force: false) }
        }
        // Work that arrives from other devices (notes, questions, summary requests) is picked up quickly.
        NotificationCenter.default.addObserver(forName: Store.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AgentController.shared.checkInbox() }
        }
        // Completing/dropping a task in Uberdoer (on any device) closes the action here within seconds.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { AgentController.shared.uberdoerChanged() }
        }, "com.romadinov.uberdoer.changed" as CFString, nil, .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AgentController.shared.runNow(force: false) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.answerNow() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.runNow(force: false) }
    }

    private var inboxCheckPending = false
    func checkInbox() {
        guard !inboxCheckPending else { return }
        inboxCheckPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.inboxCheckPending = false
            let m = AppModel.shared
            let pendingNotes = m.notes.contains { $0.processedAt == nil && $0.processError == nil }
            let pendingQuestions = m.questions.contains { $0.answer == nil && $0.error == nil }
            if m.clarifications.contains(where: { $0.status == .answered && $0.error == nil }) { self.applyNow() }
            let pendingRecordings = m.recordings.contains { $0.status == .ready && $0.processedAt == nil && !$0.segments.isEmpty }
            let pendingSummaries = m.projects.contains { p in p.summaryRequestedAt.map { $0 > (p.summaryAt ?? .distantPast) } ?? false }
                || m.recordings.contains(where: \.summaryPending) || m.recordings.contains(where: \.notesPending)
            if pendingQuestions { self.answerNow() }
            // Completed/dropped/reopened in Jinnie (here or on the iPhone) → Uberdoer follows within seconds.
            if m.actions.contains(where: { $0.needsPush == true }) {
                let agent = self.agent
                Task.detached {
                    agent.pushStatusChanges()
                    await MainActor.run { self.ignoreUberdoerUntil = Date().addingTimeInterval(8) }
                }
            }
            if pendingNotes || pendingSummaries || pendingRecordings { self.runQuick() }
            if m.recordings.contains(where: \.audioPending) { TeamsAudio.shared.checkRequests(agent: self.agent) }
        }
    }

    func answerNow() {
        let m = AppModel.shared
        applyNow()
        guard !isAnswering, m.questions.contains(where: { $0.answer == nil && $0.error == nil }) else { return }
        isAnswering = true
        let agent = self.agent
        Task.detached {
            await agent.answerQuestions()
            await MainActor.run {
                self.isAnswering = false
                self.syncUberdoerNow()  // tasks Ask just created or completed
                self.answerNow()  // anything asked meanwhile
            }
        }
    }

    /// Applies answers to open questions as soon as they arrive (from this Mac or the iPhone).
    func applyNow() {
        guard !isApplying, AppModel.shared.clarifications.contains(where: { $0.status == .answered && $0.error == nil }) else { return }
        isApplying = true
        let agent = self.agent
        Task.detached {
            await agent.applyClarifications()
            await MainActor.run {
                self.isApplying = false
                self.applyNow()  // anything answered at the very end
            }
        }
    }

    func uberdoerChanged() {
        guard Date() > ignoreUberdoerUntil, !uberdoerSyncPending else { return }
        uberdoerSyncPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.syncUberdoerNow() }
    }

    private func syncUberdoerNow() {
        uberdoerSyncPending = false
        // A running cycle syncs Uberdoer itself, but may already be past that step: sync again afterwards.
        if isRunning { uberdoerSyncQueued = true; return }
        let agent = self.agent
        Task.detached {
            agent.syncUberdoer()
            await MainActor.run { self.ignoreUberdoerUntil = Date().addingTimeInterval(8) }
        }
    }

    /// Notes, questions, summary requests and Uberdoer — no source reads.
    func runQuick() { enqueue(force: false, quick: true) }

    func runNow(force: Bool) { enqueue(force: force, quick: false) }

    private func enqueue(force: Bool, quick: Bool) {
        if ProcessInfo.processInfo.environment["JINNIE_NO_AGENT"] != nil { current = "Agent disabled (JINNIE_NO_AGENT)"; return }
        if isRunning {
            let q = queued ?? (false, true)
            queued = (q.force || force, q.quick && quick)
            return
        }
        isRunning = true
        current = quick ? "Processing…" : "Reading sources…"
        let agent = self.agent
        Task.detached {
            if quick {
                await agent.processNotes()
                await agent.processRecordings()
                agent.syncUberdoer()
                await agent.summarizeRequested()
                await agent.summarizeRequestedRecordings()
            } else {
                await agent.runCycle(force: force)
            }
            await MainActor.run { self.finished(full: !quick) }
        }
    }

    private func finished(full: Bool) {
        isRunning = false
        current = ""
        ignoreUberdoerUntil = Date().addingTimeInterval(8)
        if uberdoerSyncQueued { uberdoerSyncQueued = false; syncUberdoerNow() }
        if full {
            lastCycle = Date()
            agent.store.setMeta("lastCycle", String(Date().timeIntervalSince1970))
            ContactsBridge.enrichAll(agent.store)  // emails, companies, job titles for people Jinnie learned (blanks only)
        }
        if let q = queued {
            queued = nil
            enqueue(force: q.force, quick: q.quick)
        }
    }

    func summarize(_ projectID: String) {
        guard var p = agent.store.get(Project.self, projectID) else { return }
        p.summaryRequestedAt = Date()
        agent.store.save(p)
        runQuick()
    }

    func scan(_ projectID: String) {
        guard !isRunning else { current = "Busy — try again when the current run finishes"; return }
        isRunning = true
        current = "Scanning project history…"
        let agent = self.agent
        Task.detached {
            _ = try? await agent.scanProject(projectID)
            agent.syncUberdoer()
            await MainActor.run { self.isRunning = false; self.current = "" }
        }
    }

    func scanCustomer(_ customerID: String) {
        guard !isRunning else { current = "Busy — try again when the current run finishes"; return }
        isRunning = true
        current = "Scanning customer history…"
        let agent = self.agent
        Task.detached {
            _ = try? await agent.scanCustomer(customerID)
            agent.syncUberdoer()
            await MainActor.run { self.isRunning = false; self.current = "" }
        }
    }

    func importProjects() {
        do { current = "Imported \(try agent.importUberdoerProjects()) projects" } catch { current = "\(error)" }
    }

    func learnContacts() {
        guard !isRunning else { return }
        isRunning = true
        current = "Learning contacts…"
        let agent = self.agent
        Task.detached {
            let msg: String
            do { msg = try await agent.learnContacts() } catch { msg = "\(error)" }
            var run = RunLog(kind: "learn-contacts")
            run.message = msg
            run.finishedAt = Date()
            agent.store.save(run)
            await MainActor.run { self.isRunning = false; self.current = msg }
        }
    }
}
