import AppKit
import AVFoundation
import CloudKit
import JinnieAgent
import JinnieCore
import SwiftUI

/// "Set Up Jinnie": who you are, and every integration Jinnie needs, checked live with step-by-step fixes.
/// Opens by itself until the required parts are done; later from Settings → Setup and the menu bar.
struct SetupView: View {
    @Environment(AgentController.self) private var agent
    @State private var profile = OwnerProfile.current
    @State private var emails = OwnerProfile.current.emails.joined(separator: ", ")
    @State private var nicknames = OwnerProfile.current.nicknames.joined(separator: ", ")
    @State private var checks: [SetupCheck] = []
    @State private var connectors: [SetupCheck] = []
    @State private var checkingConnectors = false
    @State private var icloud: SetupCheck?
    @State private var savedFlash = false
    var onDone: (() -> Void)? = nil

    var body: some View {
        Form {
            Section {
                Text("Jinnie reads your mail, calendar, Slack and notes with your own Claude subscription, on this Mac. Everything it learns stays in your iCloud.")
                    .foregroundStyle(.secondary)
            }
            Section("About you") {
                TextField("Full name", text: $profile.name)
                TextField("Your email addresses (comma-separated: work and personal)", text: $emails)
                TextField("Organization", text: $profile.organization)
                TextField("Role (e.g. sales engineer)", text: $profile.role)
                TextField("Languages you write in (e.g. English and Russian)", text: $profile.languages)
                TextField("Other names people use for you (comma-separated)", text: $nicknames)
                TextField("Uberdoer folder for work projects", text: $profile.uberdoerFolder)
                HStack {
                    if savedFlash { Text("Saved").foregroundStyle(.green) }
                    Spacer()
                    Button("Save") { saveProfile() }.buttonStyle(.borderedProminent).disabled(profile.name.isEmpty || emails.isEmpty)
                }
            }
            Section("Required") {
                ForEach(checks.filter { $0.level == .required && $0.id != "profile" }) { SetupCheckRow(check: $0) }
                if let icloud { SetupCheckRow(check: icloud) }
            }
            Section {
                if connectors.isEmpty {
                    Text("Gmail and Google Calendar are recommended; Slack and Drive are optional. They're connected in your claude.ai account, and Jinnie only uses their read tools.")
                        .foregroundStyle(.secondary)
                }
                ForEach(connectors) { c in
                    SetupCheckRow(check: c, toggle: source(for: c))
                }
                HStack {
                    Button { Opener.open(Setup.connectorsURL) } label: { Label("Open claude.ai Connectors", systemImage: "arrow.up.right.square") }
                    Spacer()
                    if checkingConnectors { ProgressView().controlSize(.small); Text("Asking Claude…").foregroundStyle(.secondary) }
                    Button(connectors.isEmpty ? "Check connectors" : "Check again") { checkConnectors() }.disabled(checkingConnectors)
                }
            } header: { Text("Sources (claude.ai connectors)") }
            Section("Optional") {
                ForEach(checks.filter { $0.level == .optional }) { c in
                    SetupCheckRow(check: c, toggle: source(for: c))
                    if c.id == "outlook" && OutlookReader.isInstalled && agent.agent.isEnabled(.outlook) {
                        OutlookSignInButtons { refresh() }.padding(.leading, 22)
                    }
                }
                VoiceSetupRow()
                MessengerSetupRow()
            }
            Section {
                HStack {
                    Button("Check again") { refresh() }
                    Spacer()
                    if let onDone {
                        Button(ready ? "Start using Jinnie" : "Finish later") { saveProfile(); onDone() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh(); if connectors.isEmpty && OwnerProfile.exists { checkConnectors(refresh: false) } }
    }

    var ready: Bool { OwnerProfile.exists && checks.first { $0.id == "claude" }?.status == .ok }

    func source(for c: SetupCheck) -> Source? {
        switch c.id {
        case "outlook": .outlook
        case "remarkable": .remarkable
        case let id where id.hasPrefix("connector."): Source(rawValue: String(id.dropFirst("connector.".count)))
        default: nil
        }
    }

    func saveProfile() {
        profile.emails = emails.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { $0.contains("@") }
        profile.nicknames = nicknames.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        if profile.uberdoerFolder.trimmingCharacters(in: .whitespaces).isEmpty { profile.uberdoerFolder = "Work" }
        try? profile.save()
        savedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedFlash = false }
        refresh()
        agent.runNow(force: false)
    }

    func refresh() {
        let a = agent.agent
        Task.detached {
            let c = Setup.quickChecks(a)
            await MainActor.run { checks = c }
        }
        CKContainer(identifier: JinnieConfig.cloudContainer).accountStatus { status, _ in
            let ok = status == .available
            let c = SetupCheck(id: "icloud", title: "iCloud", level: .required, status: ok ? .ok : .missing,
                               detail: ok ? "Signed in: Jinnie syncs with your iPhone" : "Not signed in to iCloud: nothing syncs to the iPhone",
                               steps: ok ? [] : [.init("Sign in: System Settings → your name (Apple Account) → iCloud, and keep iCloud Drive on.")])
            Task { @MainActor in icloud = c }
        }
    }

    func checkConnectors(refresh: Bool = true) {
        checkingConnectors = true
        let a = agent.agent
        Task.detached {
            let c = await Setup.connectors(a, refresh: refresh)
            await MainActor.run { connectors = c; checkingConnectors = false }
        }
    }
}

struct SetupCheckRow: View {
    @Environment(AgentController.self) private var agent
    let check: SetupCheck
    var toggle: Source? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon).foregroundStyle(color)
                Text(check.title).font(.body.weight(.semibold))
                if check.level == .recommended { Text("recommended").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let toggle {
                    Toggle("", isOn: Binding(get: { agent.agent.isEnabled(toggle) },
                                             set: { agent.agent.setEnabled(toggle, $0); agent.objectWillChangeHack += 1 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            Text(check.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(check.steps, id: \.self) { step in
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.text).font(.callout)
                    if let cmd = step.command { CommandLine_(command: cmd) }
                    if let url = step.url { Button(url) { Opener.open(url) }.buttonStyle(.link).font(.caption) }
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 2)
    }

    var icon: String {
        switch check.status {
        case .ok: "checkmark.circle.fill"
        case .missing: check.level == .required ? "xmark.circle.fill" : "circle.dashed"
        case .warning: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
    var color: Color {
        switch check.status {
        case .ok: .green
        case .missing: check.level == .required ? .red : .secondary
        case .warning: .orange
        case .unknown: .secondary
        }
    }
}

/// A Terminal command with Copy and Run-in-Terminal buttons.
struct CommandLine_: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text(command).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
                .padding(6).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .controlSize(.small)
            Button("Copy & Open Terminal") { Opener.openTerminal(with: command) }.controlSize(.small)
                .help("Copies the command and opens Terminal: paste with ⌘V and press Return")
        }
    }
}

/// Voice notes and recordings: the Whisper model and microphone access.
struct VoiceSetupRow: View {
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        let whisper = WhisperModel.shared
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: whisper.isDownloaded && mic == .authorized ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(whisper.isDownloaded && mic == .authorized ? .green : .secondary)
                Text("Voice notes and meeting recordings").font(.body.weight(.semibold))
            }
            Text("Transcribed on this Mac (Whisper); recordings are also separated by speaker.").font(.callout).foregroundStyle(.secondary)
            HStack {
                switch whisper.status {
                case .downloading(let p): ProgressView(value: p).frame(width: 140); Text("Downloading the speech model…").font(.caption)
                case .ready: Text("Speech model ready").font(.caption).foregroundStyle(.secondary)
                case .failed(let m): Text(m).font(.caption).foregroundStyle(.orange)
                default:
                    if whisper.isDownloaded { Text("Speech model downloaded").font(.caption).foregroundStyle(.secondary) }
                    else { Button("Download speech model (~630 MB)") { Task { await whisper.prepare() } }.controlSize(.small) }
                }
                Spacer()
                switch mic {
                case .authorized: Text("Microphone allowed").font(.caption).foregroundStyle(.secondary)
                case .notDetermined: Button("Allow microphone") { Task { _ = await AVCaptureDevice.requestAccess(for: .audio); mic = AVCaptureDevice.authorizationStatus(for: .audio) } }.controlSize(.small)
                default: Button("Open Microphone settings") { Opener.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }.controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

enum Opener {
    static func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

    /// Copies the command and opens Terminal: paste (⌘V) and press Return. (No Apple Events: nothing runs unseen.)
    static func openTerminal(with command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }
}

/// The setup window: shown at launch until Jinnie has an owner and a signed-in Claude Code.
@MainActor
final class SetupWindow {
    static let shared = SetupWindow()
    private var window: NSWindow?

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let view = SetupView(onDone: { [weak self] in self?.window?.close() })
            .environment(AgentController.shared)
            .environment(AppModel.shared)
            .frame(minWidth: 620, minHeight: 640)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Set Up Jinnie"
        w.setContentSize(NSSize(width: 680, height: 760))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// First launch, or something required is missing.
    func showIfNeeded() {
        if !OwnerProfile.exists || Claude.locate() == nil { show() }
    }
}

/// WhatsApp and Telegram calls: work calls are recorded, private ones aren't. Needs Contacts (who is a work contact) and
/// Accessibility (the caller's name in the call window).
struct MessengerSetupRow: View {
    @State private var contacts = CallerID.contactsAllowed
    @State private var ax = CallerID.accessibilityAllowed

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: contacts && ax ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(contacts && ax ? .green : .secondary)
                Text("WhatsApp and Telegram calls").font(.body.weight(.semibold))
            }
            Text("Calls with work contacts are recorded like meetings; private calls are not. Jinnie reads the caller's name in the call window and looks it up in your Contacts and its people.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                if contacts { Text("Contacts allowed").font(.caption).foregroundStyle(.secondary) }
                else { Button("Allow Contacts") { Task { contacts = await CallerID.requestContacts() } }.controlSize(.small) }
                if ax { Text("Accessibility allowed").font(.caption).foregroundStyle(.secondary) }
                else {
                    Button("Allow Accessibility") { CallerID.requestAccessibility() }.controlSize(.small)
                    Button("Check") { ax = CallerID.accessibilityAllowed }.controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Signs in to Outlook on the web: opens Jinnie's browser window, then checks the sign-in once the user says it's done
/// and reads Outlook straight away, so the warning clears.
struct OutlookSignInButtons: View {
    @Environment(AgentController.self) private var agent
    var onSignedIn: () -> Void = {}
    @State private var state = Phase.idle
    enum Phase: Equatable { case idle, waiting, checking, done(Bool), failed(String) }

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .waiting:
                Text("Sign in in the browser window and choose \"Stay signed in\".").font(.callout)
                Spacer()
                Button("Cancel") { state = .idle }
                Button("I've Signed In") { check() }.buttonStyle(.borderedProminent)
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking Outlook…").font(.callout).foregroundStyle(.secondary)
                Spacer()
            default:
                if case .done(let ok) = state {
                    Label(ok ? "Signed in. Reading Outlook now." : "Still not signed in. Try again.",
                          systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(ok ? .green : .orange)
                }
                if case .failed(let message) = state { Text(message).font(.callout).foregroundStyle(.red) }
                Spacer()
                Button("Sign In to Outlook…") { open() }
            }
        }
    }

    func open() {
        state = .waiting
        Task.detached {
            do { try OutlookReader().login() }
            catch { await MainActor.run { state = .failed("\(error)") } }
        }
    }

    func check() {
        state = .checking
        Task.detached {
            let result: Phase
            do { result = .done(try OutlookReader().finishLogin()) } catch { result = .failed("\(error)") }
            await MainActor.run {
                state = result
                if result == .done(true) {
                    agent.agent.store.setMeta("outlook.signedInAt", String(Date().timeIntervalSince1970))
                    AppModel.shared.reload(); agent.runNow(force: true); onSignedIn()
                }
            }
        }
    }
}
