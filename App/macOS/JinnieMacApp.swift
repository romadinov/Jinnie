import AppKit
import Carbon.HIToolbox
import JinnieAgent
import JinnieCore
import ServiceManagement
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

@main
struct JinnieMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @State private var agent = AgentController.shared
    /// Sparkle: checks the GitHub releases feed daily; updates are EdDSA-signed and notarized.
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        Window("Jinnie", id: "main") {
            MacRoot()
                .environment(model)
                .environment(agent)
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .help) {
                if ImprovementNoteRequest.isAvailable {
                    Button("Suggest an Improvement…") { ImprovementNoteRequest.shared.start() }.keyboardShortcut("i", modifiers: [.command, .shift])
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
                Button("Install Command-Line Tool…") { CommandLineTool.install() }
            }
            CommandGroup(after: .newItem) {
                Button("Quick Note…") { CaptureController.shared.show() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Sync Now") { agent.runNow(force: true) }.keyboardShortcut("r", modifiers: [.command])
                PauseReadingButton(agent: agent)
                Button("Import Recording…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.audio, .movie]
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { MeetingRecorder.shared.importAudio(url) }
                }
            }
        }

        MenuBarExtra {
            MenuBarContent().environment(model).environment(agent)
        } label: {
            Image(systemName: MeetingRecorder.shared.isRecording ? "record.circle" : (agent.isRunning ? "sparkles" : "brain"))
        }

        Settings {
            TabView {
                MacSettings().tabItem { Label("General", systemImage: "gearshape") }
                SetupView().tabItem { Label("Setup", systemImage: "checklist") }
            }
            .environment(model).environment(agent)
            .frame(width: 680, height: 720)
        }
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeys.apply()
        NSApp.registerForRemoteNotifications()
        MainActor.assumeIsolated { CrashReporter.shared.start() }
        Task { @MainActor in AgentController.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await AppModel.shared.sync?.syncNow() }
    }
}

// MARK: - Root window

struct MacRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(AgentController.self) private var agent
    @State private var section: Section_? = .today
    @State private var path = NavigationPath()

    var body: some View {
        // A plain sidebar column next to a NavigationStack, like Uberdoer's Mac layout: NavigationSplitView on macOS 27
        // highlighted the clicked row but kept showing the first section's page.
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // Plain buttons, not List selection (which macOS 27 highlighted without updating the binding reliably).
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Section_.allCases) { s in
                            Button { section = s } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: s.symbol).frame(width: 18).foregroundStyle(section == s ? Color.white : Color.accentColor)
                                    Text(s.rawValue)
                                    Spacer()
                                    if s == .questions, model.openClarifications.count > 0 {
                                        Text("\(model.openClarifications.count)").font(.caption).foregroundStyle(section == s ? Color.white : Color.secondary)
                                    }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .foregroundStyle(section == s ? Color.white : Color.primary)
                                .background(RoundedRectangle(cornerRadius: 6).fill(section == s ? Color.accentColor : Color.clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 8)
                }
                AgentStatusFooter().padding(10)
            }
            .frame(width: 190)
            Divider()
            NavigationStack(path: $path) {
                (section ?? .today).view.jinnieDestinations().textSelection(.enabled)
            }
            .id(section)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: section, initial: true) { path = NavigationPath(); model.cleanUp(); model.place = "Mac › \((section ?? .today).rawValue)" }
        .sheet(item: Binding(get: { ImprovementNoteRequest.shared.pending }, set: { ImprovementNoteRequest.shared.pending = $0 })) { p in
            ImprovementNoteView(pending: p) { ImprovementNoteRequest.shared.pending = nil }
        }
        .onOpenURL { url in
            if url.scheme == "jinnie", url.host() == "capture" { CaptureController.shared.show(); return }
            guard let route = Route(url: url) else { return }
            if case .action = route { section = .actions } else if case .project = route { section = .projects } else if case .recording = route { section = .recordings }
            DispatchQueue.main.async { path = NavigationPath(); path.append(route) }
        }
        .toolbar {
            ToolbarItem {
                Button { withAnimation { model.cleanUp() } } label: { Label("Clean Up", systemImage: "wand.and.sparkles") }
                    .help("Hide completed and dropped items")
                    .disabled(model.recentlyClosed.isEmpty)
            }
            ToolbarItem {
                Button { CaptureController.shared.show() } label: { Label("Quick Note", systemImage: "square.and.pencil") }
            }
            ToolbarItem {
                let rec = MeetingRecorder.shared
                Button { rec.toggle() } label: {
                    Label(rec.isRecording ? "Stop Recording" : "Record", systemImage: rec.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(rec.isRecording ? Color.red : Color.primary)
                }
                .help(rec.isRecording ? "Stop and transcribe (⌃⌥R)" : "Record a meeting (⌃⌥R)")
            }
            ToolbarItem {
                Button { agent.runNow(force: true) } label: { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(agent.isRunning)
            }
        }
    }
}

struct AgentStatusFooter: View {
    @Environment(AgentController.self) private var agent
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if agent.isRunning { ProgressView().controlSize(.mini) } else { Image(systemName: "checkmark.circle").foregroundStyle(.green) }
                Text(agent.isRunning ? agent.current : "Idle").lineLimit(1)
            }
            if let until = agent.agent.claudeLimitedUntil {
                // Recording and transcription go on; reading waits for the plan's limit to reset.
                Text("Claude limit reached · reading resumes \(until.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.orange)
            }
            if let last = agent.lastCycle {
                Text("Last run \(last.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pause or resume background reading; in the menu bar menu and the main menu (File).
struct PauseReadingButton: View {
    let agent: AgentController

    var body: some View {
        let _ = agent.objectWillChangeHack  // the pause lives in the store; this re-reads it after a change
        if let until = agent.agent.pausedUntil {
            Button("Resume Background Reading (paused until \(until.formatted(date: .omitted, time: .shortened)))") {
                agent.agent.pausedUntil = nil; agent.objectWillChangeHack += 1; agent.runNow(force: false)
            }
        } else {
            Button("Pause Background Reading for Today") {
                // Until 6:00 tomorrow: saves the plan's limits; notes, open questions and Ask keep working.
                agent.agent.pausedUntil = Calendar.current.date(bySettingHour: 6, minute: 0, second: 0, of: Date().addingTimeInterval(86400))
                agent.objectWillChangeHack += 1
            }
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(AgentController.self) private var agent
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Quick Note…  \(HotKeys.captureShortcut?.display ?? "")") { CaptureController.shared.show() }
        Button("Voice Note…  \(Shortcut.load(HotKeys.voiceKey, default: .voiceDefault)?.display ?? "")") { CaptureController.shared.show(listen: true) }
        Button(MeetingRecorder.shared.isRecording ? "Stop Recording" : "Record a Meeting  \(Shortcut.load(HotKeys.recordKey, default: .recordDefault)?.display ?? "")") { MeetingRecorder.shared.toggle() }
        Button("Open Jinnie") { NSApp.activate(); openWindow(id: "main") }
        Divider()
        Text(agent.isRunning ? agent.current : "Next: \(model.openNext.count) · Waiting: \(model.openWaiting.count)")
        Button("Sync Now") { agent.runNow(force: true) }.disabled(agent.isRunning)
        PauseReadingButton(agent: agent)
        Divider()
        if ImprovementNoteRequest.isAvailable {
            Button("Suggest an Improvement…") { NSApp.activate(); openWindow(id: "main"); ImprovementNoteRequest.shared.start() }
        }
        Button("Set Up Jinnie…") { SetupWindow.shared.show() }
        SettingsLink { Text("Settings…") }
        Button("Quit Jinnie") { NSApp.terminate(nil) }
    }
}

// MARK: - Global capture

enum HotKeys {
    static let captureKey = "hotkey.capture"
    static let voiceKey = "hotkey.voice"
    static let recordKey = "hotkey.record"
    static var captureShortcut: Shortcut? { Shortcut.load(captureKey, default: .captureDefault) }

    static func apply() {
        HotKeyCenter.shared.register(id: 1, captureShortcut) { MainActor.assumeIsolated { CaptureController.shared.show() } }
        // Voice note: Quick Note that starts listening at once. Record: start/stop a meeting recording.
        HotKeyCenter.shared.register(id: 2, Shortcut.load(voiceKey, default: .voiceDefault)) { MainActor.assumeIsolated { CaptureController.shared.show(listen: true) } }
        // Record (⌃⌥R) belongs to Jinnie Recorder, which runs even when Jinnie doesn't.
        RecorderLink.send(.reloadSettings)
    }
}

extension Shortcut {
    static let captureDefault = Shortcut(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥J")
    // Not ⌃⌥V: that is Uberdoer's voice entry.
    static let voiceDefault = Shortcut(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(controlKey | optionKey | shiftKey), display: "⌃⌥⇧J")
    static let recordDefault = Shortcut(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥R")
}

final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
}

/// A Spotlight-like floating panel: opens over any app (all Spaces, full screen) without bringing
/// the main window forward; ⌘↩ saves, Esc closes, focus returns to the previous app.
@MainActor
final class CaptureController {
    static let shared = CaptureController()
    private var panel: CapturePanel?

    func show(listen: Bool = false) {
        if let panel, panel.isVisible {
            if !listen { panel.makeKeyAndOrderFront(nil); return }
            panel.close()  // reopen listening
        }
        let size = NSSize(width: 560, height: 230)
        let panel = CapturePanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                                 backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        for b in [NSWindow.ButtonType.miniaturizeButton, .zoomButton, .closeButton] { panel.standardWindowButton(b)?.isHidden = true }

        let root = CaptureForm(listen: listen, onDone: { [weak panel] in panel?.close() })
            .environment(AppModel.shared)
            .frame(width: size.width, height: size.height)
        let controller = NSHostingController(rootView: root)
        // Fixed size. Letting the panel follow the SwiftUI content's preferred size made AppKit and SwiftUI resize
        // each other until AppKit raised "too many layout passes" and the app crashed (seen with the TextEditor).
        controller.sizingOptions = []
        panel.contentViewController = controller
        panel.setContentSize(size)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - f.height * 0.2))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }
}

struct CaptureForm: View {
    var listen = false
    let onDone: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "brain").foregroundStyle(.tint)
                Text("Jinnie note").font(.headline)
                Spacer()
                Text("⌘↩ save · ⌘D dictate · esc close").font(.caption).foregroundStyle(.secondary)
            }
            CaptureBox(autofocus: true, editorHeight: 130, listen: listen, onSaved: onDone)
        }
        .padding(14)
        .padding(.top, 14)  // room for the hidden title bar
    }
}

// MARK: - Settings

struct MacSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(AgentController.self) private var agent
    @State private var recording = false
    @State private var shortcut = HotKeys.captureShortcut
    @State private var recordingVoice = false
    @State private var voiceShortcut = Shortcut.load(HotKeys.voiceKey, default: .voiceDefault)
    @State private var recordingRecord = false
    @State private var recordShortcut = Shortcut.load(HotKeys.recordKey, default: .recordDefault)
    @State private var cliInstalled = CommandLineTool.isInstalled

    var body: some View {
        Form {
            Section("Capture") {
                LabeledContent("Global shortcut") {
                    Button(recording ? "Press keys…" : (shortcut?.display ?? "None")) { recording = true }
                        .background(ShortcutRecorder(active: $recording) { s in
                            shortcut = s; Shortcut.save(s, HotKeys.captureKey); HotKeys.apply()
                        })
                }
                LabeledContent("Voice note") {
                    Button(recordingVoice ? "Press keys…" : (voiceShortcut?.display ?? "None")) { recordingVoice = true }
                        .background(ShortcutRecorder(active: $recordingVoice) { s in
                            voiceShortcut = s; Shortcut.save(s, HotKeys.voiceKey); HotKeys.apply()
                        })
                }
                LabeledContent("Record a meeting (start/stop)") {
                    Button(recordingRecord ? "Press keys…" : (recordShortcut?.display ?? "None")) { recordingRecord = true }
                        .background(ShortcutRecorder(active: $recordingRecord) { s in
                            recordShortcut = s; Shortcut.save(s, HotKeys.recordKey); HotKeys.apply()
                        })
                }
                Text("Voice notes and recordings are transcribed on this Mac with Whisper (Russian and English); recordings are also separated by speaker, and voices you name are recognised next time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Meetings") {
                MeetingSettings()
            }
            Section("General") {
                Toggle("Open at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                        agent.objectWillChangeHack += 1
                    }))
            }
            Section("Summaries") {
                Toggle(isOn: Binding(get: { agent.agent.autoSummaries }, set: { agent.agent.autoSummaries = $0; agent.objectWillChangeHack += 1 })) {
                    VStack(alignment: .leading) {
                        Text("Keep project summaries up to date")
                        Text("New project → history scan + summary. New activity → refresh (at most every 12 h). Projects active this week → daily refresh. One per run.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Claude account") {
                ClaudeAccountSettings()
            }
            Section("Command line") {
                LabeledContent("jinniectl") {
                    Button(cliInstalled ? "Reinstall…" : "Install…") { CommandLineTool.install(); cliInstalled = CommandLineTool.isInstalled }
                }
                Text(cliInstalled ? "Installed in /usr/local/bin. Try: jinniectl doctor"
                     : "Adds jinniectl to /usr/local/bin so Terminal can run it (asks for your password if needed).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sources") {
                ForEach(Source.connectors, id: \.self) { s in
                    Toggle(isOn: Binding(get: { agent.agent.isEnabled(s) }, set: { agent.agent.setEnabled(s, $0); agent.objectWillChangeHack += 1 })) {
                        VStack(alignment: .leading) {
                            Text(s.label)
                            Text([agent.agent.connectorAccount(s).map { "Account: \($0)" },
                                  agent.agent.lastRun(s).map { "Last read \($0.formatted(.relative(presentation: .named)))" } ?? "Not read yet"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Outlook (client Microsoft 365, e.g. Umbrella): read through Jinnie's own browser profile — no clicks, nothing marked as read.")
                        .font(.caption).foregroundStyle(.secondary)
                    OutlookSignInButtons()
                    Toggle("Read Teams transcripts of meetings shared with you", isOn: Binding(
                        get: { agent.agent.readsTeamsRecordings },
                        set: { agent.agent.setReadsTeamsRecordings($0); agent.objectWillChangeHack += 1 }))
                    Text("Recordings shared in a Teams chat that Jinnie didn't record itself: Jinnie reads the transcript Teams shows in the player (speaker names included), then learns from it like a recording. Up to two per Outlook read.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Also record their audio and transcribe it on the Mac", isOn: Binding(
                        get: { agent.agent.recordsTeamsAudio },
                        set: { agent.agent.setRecordsTeamsAudio($0); agent.objectWillChangeHack += 1 }))
                    Text("Jinnie plays each recording muted in its hidden browser and records the sound: an hour-long meeting takes an hour, and Outlook reads wait meanwhile. Needs ffmpeg. Any recording can also be done on its own with Record Audio on its card.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("reMarkable: handwritten notebooks are transcribed (Russian and English) within 30 minutes of writing.")
                    Text(RemarkableReader.missing.isEmpty
                         ? (RemarkableReader.isSignedIn ? "rmapi is signed in." : "Sign in once: run ~/.local/bin/rmapi in Terminal and enter the code from my.remarkable.com/device/desktop/connect.")
                         : "Needs \(RemarkableReader.missing.joined(separator: ", ")). See the README → reMarkable.")
                }
                .font(.caption).foregroundStyle(.secondary)
                Picker("On weekends", selection: Binding(get: { agent.agent.weekendInterval }, set: { agent.agent.weekendInterval = $0; agent.objectWillChangeHack += 1 })) {
                    Text("Same as weekdays").tag(TimeInterval(0))
                    Text("Every 4 hours").tag(TimeInterval(4 * 3600))
                    Text("Twice a day").tag(TimeInterval(12 * 3600))
                    Text("Not at all (catch up on Monday)").tag(TimeInterval(72 * 3600))
                }
                Text("Email, Slack and Drive are read hourly, the calendar every 6 hours, through your claude.ai connectors (Settings → Connectors on claude.ai). On Saturdays and Sundays less often, as set above; Monday's first read catches up. Jinnie only ever uses their read tools.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Setup") {
                LabeledContent("Claude CLI", value: agent.agent.claude.executable)
                LabeledContent("Uberdoer", value: Uberdoer.isInstalled ? "Connected" : "Not installed")
                Button("Import projects from Uberdoer") { agent.importProjects() }
                Button("Learn contacts from the last 6 months of mail") { agent.learnContacts() }.disabled(agent.isRunning)
                ContactsFillButton()
                Button("Show agent transcripts") { NSWorkspace.shared.open(agent.agent.claude.tracesDirectory) }
            }
        }
        .formStyle(.grouped)
        .id(agent.objectWillChangeHack)
    }
}

/// Captures the next key combination while `active`.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var active: Bool
    let onRecord: (Shortcut) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        if active, context.coordinator.monitor == nil {
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                if e.keyCode == UInt16(kVK_Escape) { context.coordinator.stop(); return nil }
                if let s = Shortcut(event: e) { context.coordinator.parent.onRecord(s); context.coordinator.stop(); return nil }
                return e
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    final class Coordinator {
        var parent: ShortcutRecorder
        var monitor: Any?
        init(parent: ShortcutRecorder) { self.parent = parent }
        func stop() {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
            DispatchQueue.main.async { self.parent.active = false }
        }
    }
}

struct MeetingSettings: View {
    @State private var mode = RecorderSettings.mode
    @State private var calendarOnly = RecorderSettings.calendarOnly
    @State private var skip = RecorderSettings.skipWords
    @State private var recorderStatus = RecorderService.statusText

    var body: some View {
        LabeledContent("Jinnie Recorder") {
            HStack {
                Text(recorderStatus).foregroundStyle(.secondary)
                if RecorderService.service.status == .requiresApproval {
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                } else if !RecorderService.isRunning {
                    Button("Start") { RecorderService.ensure(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { recorderStatus = RecorderService.statusText } }
                }
            }
        }
        Text("Records calls even when Jinnie is closed (it starts at login); Jinnie transcribes them when it runs.")
            .font(.caption).foregroundStyle(.secondary)
        Picker("When a call starts (Zoom, Teams, Meet, Webex, Slack, FaceTime)", selection: $mode) {
            ForEach(RecorderSettings.Mode.allCases) { Text($0.label).tag($0) }
        }
        .onChange(of: mode) { _, m in RecorderSettings.mode = m }
        Toggle("Only when my calendar shows a meeting", isOn: $calendarOnly)
            .onChange(of: calendarOnly) { _, v in RecorderSettings.calendarOnly = v }
        Picker("Transcription model", selection: Binding(get: { WhisperModel.choice }, set: { WhisperModel.choice = $0; WhisperModel.shared.reset() })) {
            ForEach(WhisperModel.Choice.allCases) { Text($0.label).tag($0) }
        }
        Text("Runs on this Mac. The full Whisper model is a little more accurate and takes 2–3 times longer (about 1.5 GB). GigaAM reads Russian much better (it gets the words and punctuation right where Whisper guesses) and keeps Whisper for English; it downloads about 225 MB the first time it's used.")
            .font(.caption).foregroundStyle(.secondary)
        TextField("Never record meetings whose title contains", text: $skip)
            .onSubmit { RecorderSettings.skipWords = skip }
            .onChange(of: skip) { _, v in RecorderSettings.skipWords = v }
        Text("Recordings include the meeting app's audio, so the other participants are captured clearly (macOS asks once for System Audio Recording). Recording stops 30 s after the call ends. Many places require everyone's consent to be recorded: use “Copy notice for others” to tell them.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// Fills people's missing emails, companies and job titles from Contacts (also done after every sync).
struct ContactsFillButton: View {
    @Environment(AppModel.self) private var model
    @State private var note: String?

    var body: some View {
        HStack {
            Button("Fill in people from Contacts") {
                Task {
                    let ok = ContactsBridge.allowed ? true : await ContactsBridge.requestAccess()
                    guard ok else { note = "Contacts access is off: System Settings → Privacy & Security → Contacts."; return }
                    let n = ContactsBridge.enrichAll(model.store)
                    note = n == 0 ? "Nothing new in Contacts." : "Filled in \(n) \(n == 1 ? "person" : "people")."
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Signs Jinnie in to its own Claude account from the app: `claude auth login` runs in the background with a separate
/// config folder; the browser opens and hands the result back to it on this Mac, so it usually finishes by itself. If
/// Claude's page shows a code instead, it can be pasted here. The new login replaces Jinnie's only once it works.
@MainActor @Observable
final class ClaudeSignIn {
    static let shared = ClaudeSignIn()
    enum State: Equatable { case idle, waiting, done(String), failed(String) }
    private(set) var state: State = .idle
    private var process: Process?
    private var input: Pipe?

    func start() {
        cancel()
        try? FileManager.default.createDirectory(at: Claude.accountDirectory, withIntermediateDirectories: true)
        guard let exe = Claude.locate() else { state = .failed("Claude Code is not installed"); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["auth", "login"] + (OwnerProfile.current.emails.first.map { ["--email", $0] } ?? [])
        var env = Claude.environment()
        env["CLAUDE_CONFIG_DIR"] = Claude.accountDirectory.path  // signs in in place: the login is tied to this path
        p.environment = env
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            Task { @MainActor in ClaudeSignIn.shared.finished() }
        }
        do { try p.run(); process = p; input = pipe; state = .waiting } catch { state = .failed(error.localizedDescription) }
    }

    /// The fallback: a code Claude's page shows when it can't hand the sign-in back by itself.
    func submit(code: String) {
        guard let input else { return }
        input.fileHandleForWriting.write(Data((code.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8))
    }

    func cancel() {
        if let process, process.isRunning { process.terminationHandler = nil; process.terminate() }
        process = nil; input = nil
        if state == .waiting { state = .idle }
    }

    private func finished() {
        process = nil; input = nil
        Task.detached {
            let email = Claude.activateOwnAccount()
            await MainActor.run {
                ClaudeSignIn.shared.state = email.map { .done($0) } ?? .failed("Not signed in; Jinnie still uses Claude Code's account.")
            }
        }
    }
}

/// Which Claude account Jinnie runs on: the one Claude Code uses in Terminal, or its own (claude.ai connectors belong to
/// the account, so Jinnie's must be the one with your Gmail, Slack, Calendar and Drive).
struct ClaudeAccountSettings: View {
    @State private var signIn = ClaudeSignIn.shared
    @State private var own = Claude.usesOwnAccount
    @State private var account: String?
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Jinnie runs as") {
                Text(account.map { own ? "\($0) (its own account)" : "\($0) (same as Claude Code)" } ?? (own ? "its own account" : "the same account as Claude Code"))
            }
            switch signIn.state {
            case .waiting:
                Label("Your browser opened: sign in there. Jinnie finishes by itself.", systemImage: "hourglass").foregroundStyle(.secondary)
                HStack {
                    TextField("If the page shows a code, paste it here", text: $code)
                    Button("Finish") { signIn.submit(code: code); code = "" }.disabled(code.isEmpty)
                    Button("Cancel") { signIn.cancel() }
                }
            case .done(let email):
                Label("Signed in as \(email). Claude Code in Terminal can now use another account.", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            case .idle:
                EmptyView()
            }
            HStack {
                if signIn.state != .waiting {
                    Button(own ? "Sign In Again…" : "Sign In to Its Own Account…") { signIn.start() }
                }
                if own && signIn.state != .waiting {
                    Button("Use Claude Code's Account") {
                        Claude.useSharedAccount()
                        refresh()
                    }
                }
            }
            Text("Claude connectors (Gmail, Slack, Calendar, Drive) belong to the account, so Jinnie's must be the one that has yours.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { refresh() }
        .onChange(of: signIn.state) { _, _ in refresh() }
    }

    private func refresh() {
        own = Claude.usesOwnAccount
        Task.detached {
            let s = Claude.accountStatus(configDirectory: Claude.usesOwnAccount ? Claude.accountDirectory : nil)
            await MainActor.run { account = s.email }
        }
    }
}
