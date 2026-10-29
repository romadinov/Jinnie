import AppKit
import Carbon.HIToolbox
import JinnieCore
import SwiftUI

/// Jinnie Recorder: started at login by launchd (and again if it crashes), so calls are recorded even when Jinnie is
/// closed. It only records; Jinnie transcribes. Menu bar: Record / Stop, and what it's doing.
@main
struct JinnieRecorderApp: App {
    @NSApplicationDelegateAdaptor(RecorderDelegate.self) private var delegate
    @State private var recorder = CallRecorder.shared

    var body: some Scene {
        MenuBarExtra {
            RecorderMenu().environment(recorder)
        } label: {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "waveform.circle")
        }
    }
}

@MainActor
final class RecorderDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // launchd starts exactly one; an extra copy (opened by hand) leaves.
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: RecorderLink.recorderBundleID).contains(where: { $0.processIdentifier != me }) {
            exit(0)
        }
        CallRecorder.shared.finishOrphans()
        MeetingDetector.shared.start()
        RecorderHotKey.apply()
        RecorderLink.onCommand { command in
            Task { @MainActor in
                let r = CallRecorder.shared
                switch command {
                case .toggle: r.toggle()
                case .start: if !r.isRecording { r.start(meeting: MeetingDetector.shared.activeMeeting()) }
                case .stop: r.stop()
                case .reloadSettings: RecorderHotKey.apply()
                }
            }
        }
    }

    /// Quitting (or logging out) mid-call keeps what was recorded: it goes to Jinnie like a stopped recording.
    func applicationWillTerminate(_ notification: Notification) {
        CallRecorder.shared.stop()
    }
}

enum RecorderHotKey {
    static let defaultShortcut = Shortcut(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥R")
    /// ⌃⌥R (or the shortcut set in Jinnie's Settings): start or stop a recording.
    @MainActor static func apply() {
        let saved = RecorderLink.defaults.data(forKey: RecorderSettings.recordKey).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
        HotKeyCenter.shared.register(id: 3, saved ?? defaultShortcut) { Task { @MainActor in CallRecorder.shared.toggle() } }
    }
}

struct RecorderMenu: View {
    @Environment(CallRecorder.self) private var recorder

    var body: some View {
        switch recorder.state {
        case .recording(let started):
            Text("Recording since \(started.formatted(date: .omitted, time: .shortened))")
            if let t = recorder.title { Text(t) }
            Button("Stop Recording") { recorder.stop() }
        case .failed(let m):
            Text(m)
            Button("Record a Meeting") { recorder.toggle() }
        case .idle:
            Text(RecorderSettings.mode == .off ? "Not watching for calls" : "Watching for calls: \(RecorderSettings.mode.label.lowercased())")
            Button("Record a Meeting") { recorder.toggle() }
        }
        Divider()
        Button("Open Jinnie") {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.romadinov.jinnie.mac") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        Button("Quit Recorder") { NSApp.terminate(nil) }
    }
}
