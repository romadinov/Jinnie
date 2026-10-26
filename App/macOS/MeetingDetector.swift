import AppKit
import AudioToolbox
import Foundation
import JinnieCore
import Observation
import SwiftUI

/// Notices when a call starts (a meeting app takes the microphone), offers to record it or records it, and stops when the
/// call ends. Recording includes the meeting app's audio, so the other participants are captured cleanly.
@MainActor @Observable
final class MeetingDetector {
    static let shared = MeetingDetector()

    enum Mode: String, CaseIterable, Identifiable {
        case off, ask, automatic
        var id: String { rawValue }
        var label: String {
            switch self { case .off: "Off"; case .ask: "Ask before recording"; case .automatic: "Record automatically" }
        }
    }

    var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: "meetings.mode") ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "meetings.mode") }
    }
    /// Only calls that coincide with a meeting in the calendar (browsers always need one: they use the mic for other things).
    var calendarOnly: Bool {
        get { UserDefaults.standard.object(forKey: "meetings.calendarOnly") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "meetings.calendarOnly") }
    }
    /// Meetings whose title contains any of these words are never recorded.
    var skipWords: String {
        get { UserDefaults.standard.string(forKey: "meetings.skip") ?? "private, personal, doctor, interview, HR, 1:1 personal" }
        set { UserDefaults.standard.set(newValue, forKey: "meetings.skip") }
    }

    struct App {
        let prefix: String; let name: String; let browser: Bool
        /// WhatsApp, Telegram: no calendar; work or private depends on who's calling.
        var messenger = false
    }
    static let apps: [App] = [
        App(prefix: "us.zoom.", name: "Zoom", browser: false),
        App(prefix: "com.microsoft.teams", name: "Teams", browser: false),
        App(prefix: "com.cisco.webex", name: "Webex", browser: false),
        App(prefix: "Cisco-Systems.Spark", name: "Webex", browser: false),
        App(prefix: "com.tinyspeck.slackmacgap", name: "Slack", browser: false),
        App(prefix: "com.apple.FaceTime", name: "FaceTime", browser: false),
        App(prefix: "com.apple.avconferenced", name: "FaceTime", browser: false),  // FaceTime's audio runs here
        App(prefix: "net.whatsapp.", name: "WhatsApp", browser: false, messenger: true),
        App(prefix: "desktop.WhatsApp", name: "WhatsApp", browser: false, messenger: true),
        App(prefix: "ru.keepcoder.Telegram", name: "Telegram", browser: false, messenger: true),
        App(prefix: "org.telegram.desktop", name: "Telegram", browser: false, messenger: true),
        App(prefix: "com.google.Chrome", name: "Chrome", browser: true),
        App(prefix: "com.apple.Safari", name: "Safari", browser: true),
        App(prefix: "com.apple.WebKit", name: "Safari", browser: true),
        App(prefix: "company.thebrowser.", name: "Arc", browser: true),
        App(prefix: "com.microsoft.edgemac", name: "Edge", browser: true),
        App(prefix: "org.mozilla.firefox", name: "Firefox", browser: true),
        App(prefix: "com.brave.Browser", name: "Brave", browser: true),
    ]

    struct Detected {
        let appName: String
        let isBrowser: Bool
        /// The microphone the meeting app uses (AirPods during a call): Jinnie records from the same one.
        let inputDevice: AudioDeviceID?
        /// The app's audio processes (main app and helpers), tapped for the other participants' voices.
        let processIDs: [AudioObjectID]
        let calendarItem: Item?
        /// The app is both listening and playing: a conversation, not just dictation.
        var twoWay = false
        var isMessenger = false
        var callerPID: pid_t = 0
        /// Messenger calls: who's on it, and the work contacts among them.
        var callerLabel: String?
        var participants: [Person] = []
    }

    private var timer: Timer?
    private var activeSince: Date?
    private var twoWaySince: Date?
    private var quietSince: Date?
    /// Asked (or declined) for the current call: don't ask again until it ends.
    private var handledCurrentCall = false
    private var autoStarted = false

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingDetector.shared.poll() }
        }
    }

    private var polling = false

    /// Core Audio is asked off the main thread: each query is a round trip to coreaudiod (tens of milliseconds, longer
    /// when it is busy), which would make the window stutter or freeze.
    private func poll() {
        guard mode != .off, !polling else { return }
        polling = true
        DispatchQueue.global(qos: .utility).async {
            let procs = AudioProcess.all()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MeetingDetector.shared.polling = false
                    MeetingDetector.shared.tick(procs)
                }
            }
        }
    }

    /// The call going on right now, if any (also used when you press Record yourself, to include the other participants).
    func activeMeeting(_ procs: [AudioProcess] = AudioProcess.all()) -> Detected? {
        let me = getpid()
        guard let caller = procs.first(where: { $0.isRunningInput && $0.pid != me && Self.app(for: $0.bundleID) != nil }),
              let app = Self.app(for: caller.bundleID) else { return nil }
        let family = procs.filter { $0.bundleID.hasPrefix(app.prefix) && $0.pid != me }
        var d = Detected(appName: app.name, isBrowser: app.browser, inputDevice: caller.inputDevice, processIDs: family.map(\.objectID),
                         calendarItem: app.messenger ? nil : Self.calendarMeeting(), twoWay: family.contains(where: \.isRunningOutput))
        d.isMessenger = app.messenger
        // The UI process (helpers carry audio): the one whose windows show the caller.
        d.callerPID = NSRunningApplication.runningApplications(withBundleIdentifier: caller.bundleID).first?.processIdentifier
            ?? NSWorkspace.shared.runningApplications.first { ($0.bundleIdentifier ?? "").hasPrefix(app.prefix) }?.processIdentifier ?? caller.pid
        return d
    }

    func tick(_ procs: [AudioProcess]) {
        let recorder = MeetingRecorder.shared
        guard mode != .off else { return }
        guard let call = activeMeeting(procs) else {
            activeSince = nil
            twoWaySince = nil
            if quietSince == nil { quietSince = Date() }
            // The call ended (no app has used the mic for 30 s): stop what detection started, and be ready for the next call.
            if Date().timeIntervalSince(quietSince!) > 30 {
                handledCurrentCall = false
                if autoStarted && recorder.isRecording { recorder.stop() }
                autoStarted = false
            }
            return
        }
        quietSince = nil
        guard !handledCurrentCall, !recorder.isRecording, !recorder.isBusy else { return }
        if call.twoWay { if twoWaySince == nil { twoWaySince = Date() } } else { twoWaySince = nil }
        if call.isMessenger {
            // A voice message also uses the mic: a call is listening and playing for a few seconds.
            guard let since = twoWaySince, Date().timeIntervalSince(since) >= 3 else { return }
            handledCurrentCall = true
            if !CallerID.contactsAllowed { Task { _ = await CallerID.requestContacts() } }
            if !CallerID.accessibilityAllowed { CallerID.requestAccessibility() }
            let who = CallerID.identify(pid: call.callerPID)
            var work = call
            work.callerLabel = who.label
            work.participants = who.people
            guard who.isWork else {
                // Private (or unknown) caller: not recorded unless the user says so.
                MeetingPrompt.shared.show(.privateCall(work)) { [weak self] record in
                    guard record, let self else { return }
                    recorder.start(meeting: work, auto: true)
                    self.autoStarted = true
                }
                return
            }
            recorder.start(meeting: work, auto: true)
            autoStarted = true
            MeetingPrompt.shared.show(.started(work))
            return
        }
        if call.calendarItem == nil {
            // Not in the calendar (or not synced yet): a browser counts once it has been both listening and playing for
            // 15 s (a call, not dictation or a mic test); native call apps only when "calendar only" is off.
            let browserCall = call.isBrowser && (twoWaySince.map { Date().timeIntervalSince($0) >= 15 } ?? false)
            if call.isBrowser ? !browserCall : calendarOnly { return }
        }
        if let title = call.calendarItem?.title, Self.skipped(title, words: skipWords) { handledCurrentCall = true; return }
        if activeSince == nil { activeSince = Date() }
        // Start as soon as the call has held the microphone for 2 s (skips a momentary mic check).
        guard Date().timeIntervalSince(activeSince!) >= 2 else { return }
        handledCurrentCall = true
        switch mode {
        case .automatic:
            recorder.start(meeting: call, auto: true)
            autoStarted = true
            MeetingPrompt.shared.show(.started(call))
        case .ask:
            MeetingPrompt.shared.show(.ask(call)) { [weak self] record in
                guard record, let self else { return }
                recorder.start(meeting: call, auto: true)
                self.autoStarted = true
            }
        case .off: break
        }
    }

    static func app(for bundleID: String) -> App? { apps.first { bundleID.hasPrefix($0.prefix) } }

    static func skipped(_ title: String, words: String) -> Bool {
        words.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .contains { title.localizedCaseInsensitiveContains($0) }
    }

    /// A calendar meeting with other people that is on now (started up to 90 min ago, or starting within 10 min).
    static func calendarMeeting(now: Date = Date()) -> Item? {
        AppModel.shared.items.filter { i in
            (i.source == .calendar || i.sourceRef.hasPrefix("outlook-cal:")) && !i.personIDs.isEmpty
                && i.occurredAt > now.addingTimeInterval(-90 * 60) && i.occurredAt < now.addingTimeInterval(10 * 60)
        }
        .min { abs($0.occurredAt.timeIntervalSince(now)) < abs($1.occurredAt.timeIntervalSince(now)) }
    }

    /// What to tell the others: recording people without telling them is illegal in many places.
    static let notice = "Heads-up: I'm recording this meeting for my own notes; it's transcribed privately on my Mac. Tell me if you'd rather I didn't."
}

// MARK: - Prompt

/// A small floating panel at the top right: "Record this meeting?" or "Recording started", with a notice to share.
@MainActor
final class MeetingPrompt {
    static let shared = MeetingPrompt()
    enum Kind { case ask(MeetingDetector.Detected), started(MeetingDetector.Detected), privateCall(MeetingDetector.Detected) }
    private var panel: NSPanel?
    private var closeTimer: Timer?

    func show(_ kind: Kind, onAnswer: ((Bool) -> Void)? = nil) {
        close()
        let size = NSSize(width: 380, height: 150)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView, .utilityWindow],
                        backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        let view = MeetingPromptView(kind: kind) { [weak self] answer in
            onAnswer?(answer)
            self?.close()
        }
        let host = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
        host.sizingOptions = []
        p.contentViewController = host
        p.setContentSize(size)
        if let f = NSScreen.main?.visibleFrame { p.setFrameTopLeftPoint(NSPoint(x: f.maxX - size.width - 16, y: f.maxY - 16)) }
        p.orderFrontRegardless()
        panel = p
        // Unanswered questions mean "no"; the "recording started" note just goes away.
        let seconds: TimeInterval
        switch kind { case .ask: seconds = 120; case .started: seconds = 20; case .privateCall: seconds = 25 }
        closeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { onAnswer?(false); MeetingPrompt.shared.close() }
        }
    }

    func close() {
        closeTimer?.invalidate(); closeTimer = nil
        panel?.close(); panel = nil
    }
}

struct MeetingPromptView: View {
    let kind: MeetingPrompt.Kind
    let answer: (Bool) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isPrivate ? "lock.fill" : (isAsk ? "waveform.badge.mic" : "record.circle.fill"))
                    .foregroundStyle(isPrivate ? Color.secondary : (isAsk ? Color.accentColor : Color.red))
                Text(isPrivate ? "Private call: not recording" : (isAsk ? "Record this meeting?" : "Jinnie is recording")).font(.headline)
            }
            Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                if !isPrivate { Button(copied ? "Copied" : "Copy notice for others") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MeetingDetector.notice, forType: .string)
                    copied = true
                }
                .controlSize(.small)
                .help("Paste it in the meeting chat so everyone knows they're being recorded") }
                Spacer()
                if isPrivate {
                    Button("Record anyway") { answer(true) }.controlSize(.small)
                    Button("OK") { answer(false) }.buttonStyle(.borderedProminent).controlSize(.small)
                } else if isAsk {
                    Button("Not this one") { answer(false) }.controlSize(.small)
                    Button("Record") { answer(true) }.buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    Button("Stop") { MeetingRecorder.shared.stop(); answer(false) }.controlSize(.small)
                    Button("OK") { answer(false) }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
        .padding(14)
        .padding(.top, 6)
    }

    var isAsk: Bool { if case .ask = kind { return true }; return false }
    var isPrivate: Bool { if case .privateCall = kind { return true }; return false }
    var call: MeetingDetector.Detected { switch kind { case .ask(let c), .started(let c), .privateCall(let c): c } }
    var subtitle: String {
        if isPrivate { return "\(call.appName) call with \(call.callerLabel ?? "someone not in your work contacts"): private, so Jinnie isn't recording it." }
        let what = call.calendarItem?.title ?? call.callerLabel.map { "\(call.appName) call with \($0)" } ?? "A call"
        return "\(what) · \(call.appName). Includes the other participants' audio; transcribed on this Mac."
    }
}
