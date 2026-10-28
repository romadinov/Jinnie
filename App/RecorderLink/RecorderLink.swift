import Foundation

/// What Jinnie and Jinnie Recorder share. The recorder is its own app (Contents/Library/LoginItems, started at login by
/// launchd and restarted if it crashes): it detects calls and records them even when Jinnie isn't running. Jinnie
/// transcribes finished recordings (status `.processing`) whenever it runs.
enum RecorderLink {
    static let agentLabel = "com.romadinov.jinnie.recorder"
    static let agentPlist = "com.romadinov.jinnie.recorder.plist"
    static let recorderBundleID = "com.romadinov.jinnie.recorder"

    /// Settings live in Jinnie's defaults (its Settings window edits them); the recorder reads them from there.
    static let defaults: UserDefaults = Bundle.main.bundleIdentifier == recorderBundleID
        ? UserDefaults(suiteName: "com.romadinov.jinnie.mac") ?? .standard : .standard

    enum Command: String { case toggle, start, stop, reloadSettings }

    private static let commandName = Notification.Name("com.romadinov.jinnie.recorder.command")
    /// Posted by the recorder when a recording has finished and is ready for Jinnie to transcribe.
    static let finishedName = Notification.Name("com.romadinov.jinnie.recorder.finished")

    static func send(_ command: Command) {
        DistributedNotificationCenter.default().postNotificationName(commandName, object: command.rawValue, userInfo: nil, deliverImmediately: true)
    }

    static func onCommand(_ handler: @escaping @Sendable (Command) -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: commandName, object: nil, queue: .main) { n in
            if let c = (n.object as? String).flatMap(Command.init) { handler(c) }
        }
    }

    static func postFinished() {
        DistributedNotificationCenter.default().postNotificationName(finishedName, object: nil, userInfo: nil, deliverImmediately: true)
    }

    static func onFinished(_ handler: @escaping @Sendable () -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: finishedName, object: nil, queue: .main) { _ in handler() }
    }

    static var deviceName: String { Host.current().localizedName ?? "Mac" }
}

/// When to record calls: Settings → Recordings in Jinnie, read by the recorder.
enum RecorderSettings {
    enum Mode: String, CaseIterable, Identifiable {
        case off, ask, automatic
        var id: String { rawValue }
        var label: String {
            switch self { case .off: "Off"; case .ask: "Ask before recording"; case .automatic: "Record automatically" }
        }
    }

    static var mode: Mode {
        get { Mode(rawValue: RecorderLink.defaults.string(forKey: "meetings.mode") ?? "") ?? .ask }
        set { RecorderLink.defaults.set(newValue.rawValue, forKey: "meetings.mode") }
    }
    /// Only calls that coincide with a meeting in the calendar (browsers always need one: they use the mic for other things).
    static var calendarOnly: Bool {
        get { RecorderLink.defaults.object(forKey: "meetings.calendarOnly") as? Bool ?? true }
        set { RecorderLink.defaults.set(newValue, forKey: "meetings.calendarOnly") }
    }
    /// Meetings whose title contains any of these words are never recorded.
    static var skipWords: String {
        get { RecorderLink.defaults.string(forKey: "meetings.skip") ?? "private, personal, doctor, interview, HR, 1:1 personal" }
        set { RecorderLink.defaults.set(newValue, forKey: "meetings.skip") }
    }
    static let recordKey = "hotkey.record"
}
