import Foundation
import JinnieCore

/// Reads Outlook on the web (a client's Microsoft 365, e.g. Umbrella) through Jinnie's own signed-in browser
/// profile, for tenants where the Microsoft 365 connector can't be approved and New Outlook can't be scripted.
///
/// Read-only by construction: this type only opens URLs, takes accessibility snapshots and scrolls. It never
/// clicks or types, so it can't send, delete or even mark anything as read. The model never drives the browser;
/// it only sees the text collected here.
public struct OutlookReader: Sendable {
    public static let session = "jinnie-outlook"
    public var executable: String

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        executable = ["/opt/homebrew/bin/agent-browser", "/usr/local/bin/agent-browser", "\(home)/.local/bin/agent-browser"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "agent-browser"
    }

    public static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: OutlookReader().executable) }

    @discardableResult
    func browser(_ args: [String], timeout: TimeInterval = 90) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        // A persistent Chrome profile, not --session-name: that only saves cookies when the browser is closed, so a
        // sign-in in a window left open was lost, and Microsoft's "stay signed in" cookies need a real profile anyway.
        try? FileManager.default.createDirectory(at: Self.profileDirectory, withIntermediateDirectories: true)
        p.arguments = ["--session", Self.session, "--profile", Self.profileDirectory.path] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        // A file, not a pipe: the first call starts agent-browser's daemon, which would keep a pipe open forever.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("jinnie-ab-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: file) }
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        p.waitUntilExit()
        timer.cancel()
        if p.terminationReason == .uncaughtSignal { throw ClaudeError(message: "agent-browser timed out: \(args.first ?? "")") }
        let data = (try? Data(contentsOf: file)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Opens a page and fails clearly if the session needs a new sign-in.
    func open(_ url: String) throws {
        try browser(["open", url])
        try browser(["wait", "4000"])
        let current = try browser(["get", "url"])
        if current.contains("login.microsoftonline.com") || current.contains("login.live.com") {
            throw ClaudeError(message: "Outlook sign-in expired. Sign in again: Settings → Setup → Outlook → Sign in…, or run \(SetupCheck.jinniectl) outlook-login")
        }
    }

    public static var profileDirectory: URL { JinnieConfig.supportDirectory().appendingPathComponent("outlook-browser") }

    /// Opens a visible browser window so the user can sign in (MFA, "stay signed in"). Finish with `finishLogin()`.
    public func login() throws {
        try? browser(["close"])
        try browser(["--headed", "open", "https://outlook.office.com/mail/"])
    }

    /// After the user signed in: closes the window (Jinnie reads without one) and checks the sign-in stuck.
    public func finishLogin() throws -> Bool {
        try? browser(["close"])
        return try isSignedIn()
    }

    /// Opens the mailbox without a window; false when Microsoft asks for a sign-in.
    public func isSignedIn() throws -> Bool {
        do { try open("https://outlook.office.com/mail/"); return true }
        catch let e as ClaudeError where e.message.hasPrefix("Outlook sign-in expired") { return false }
    }

    /// One line per conversation in a mail folder, as Outlook lists it: flags, senders, subject, time, preview.
    /// Scrolls the virtualised list `pages` times to load older conversations.
    public func conversations(folder: String = "inbox", pages: Int = 3) throws -> [String] {
        try open("https://outlook.office.com/mail/\(folder)")
        var seen: [String] = []
        var seenSet = Set<String>()
        for _ in 0..<max(1, pages) {
            let snap = try browser(["snapshot"])
            var lastRef: String?
            for line in snap.split(separator: "\n") where line.contains("- option \"") {
                guard let text = OutlookReader.quoted(String(line)) else { continue }
                let clean = OutlookReader.tidy(text)
                if seenSet.insert(clean).inserted { seen.append(clean) }
                lastRef = OutlookReader.ref(String(line))
            }
            guard let lastRef else { break }
            let before = seen.count
            try browser(["scrollintoview", "@\(lastRef)"])
            try browser(["wait", "1500"])
            if seen.count == before && pages > 1 { continue }
        }
        return seen
    }

    /// Calendar events as Outlook describes them ("Title, 11:00 AM to 12:00 PM, Tuesday, October 20, 2026, By Organiser,
    /// Busy, Recurring event"). Outlook on the web ignores dates in calendar URLs, so this reads the month view (the
    /// whole current month, plus the days of neighbouring months in its grid) and this week's view, without clicking.
    public func events() throws -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let dated = #"(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), [A-Z][a-z]+ \d{1,2}, \d{4}"#
        for view in ["month", "week"] {
            try open("https://outlook.office.com/calendar/view/\(view)")
            let snap = try browser(["snapshot"])
            for line in snap.split(separator: "\n") where line.contains("- button \"") {
                guard let text = OutlookReader.quoted(String(line)),
                      text.range(of: dated, options: .regularExpression) != nil,
                      !text.hasPrefix("Go to") else { continue }
                if seen.insert(text).inserted { out.append(text) }
            }
        }
        // Outlook shows times in the mailbox's time zone (a client's, e.g. New Zealand), not this Mac's. The calendar labels
        // itself "current time: Wed 1:39 PM"; the difference from now is the shift to undo, so every event reads in local time.
        let shift = (try? browser(["eval", "document.querySelector('[aria-label^=\"calendar view, current time\"]')?.getAttribute('aria-label')||''"])).flatMap { OutlookReader.calendarShift($0) } ?? 0
        if shift != 0 { out = out.map { OutlookReader.shifted($0, by: -shift) } }
        try? open("https://outlook.office.com/mail/")
        return out
    }

    /// Seconds Outlook's displayed clock is ahead of this Mac ("…current time: Wed 1:39 PM" at 11:39 here → +7200),
    /// rounded to 15 minutes; nil if the label can't be read.
    static func calendarShift(_ label: String, now: Date = Date()) -> TimeInterval? {
        guard let r = label.range(of: #"(\d{1,2}):(\d{2}) ?([AP]M)"#, options: .regularExpression) else { return nil }
        let parts = label[r].replacingOccurrences(of: " ", with: "")
        let digits = parts.dropLast(2).split(separator: ":").compactMap { Int($0) }
        guard digits.count == 2 else { return nil }
        var h = digits[0] % 12
        if parts.hasSuffix("PM") { h += 12 }
        let shown = h * 60 + digits[1]
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        var diff = shown - ((c.hour ?? 0) * 60 + (c.minute ?? 0))
        if diff > 12 * 60 { diff -= 24 * 60 }
        if diff < -12 * 60 { diff += 24 * 60 }
        let rounded = Int((Double(diff) / 15).rounded()) * 15
        return TimeInterval(rounded * 60)
    }

    /// An event line with its "h:mm AM to h:mm PM, Weekday, Month d, yyyy" moved by `seconds` (day and date follow).
    static func shifted(_ line: String, by seconds: TimeInterval) -> String {
        let pattern = #"(\d{1,2}:\d{2} [AP]M) to (\d{1,2}:\d{2} [AP]M), (Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), ([A-Z][a-z]+ \d{1,2}, \d{4})"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r1 = Range(m.range(at: 1), in: line), let r2 = Range(m.range(at: 2), in: line), let r4 = Range(m.range(at: 4), in: line) else { return line }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM d, yyyy h:mm a"
        let day = String(line[r4])
        guard let start = f.date(from: "\(day) \(line[r1])"), var end = f.date(from: "\(day) \(line[r2])") else { return line }
        if end < start { end = end.addingTimeInterval(86400) }
        let s = start.addingTimeInterval(seconds), e = end.addingTimeInterval(seconds)
        let time = DateFormatter(); time.locale = f.locale; time.dateFormat = "h:mm a"
        let date = DateFormatter(); date.locale = f.locale; date.dateFormat = "EEEE, MMMM d, yyyy"
        let whole = Range(m.range, in: line)!
        return line.replacingCharacters(in: whole, with: "\(time.string(from: s)) to \(time.string(from: e)), \(date.string(from: s))")
    }

    static func quoted(_ line: String) -> String? {
        guard let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b else { return nil }
        return String(line[line.index(after: a)..<b])
    }

    static func ref(_ line: String) -> String? {
        guard let r = line.range(of: #"ref=(e\d+)"#, options: .regularExpression) else { return nil }
        return String(line[r].dropFirst(4))
    }

    /// Drops Outlook's invisible padding characters and trailing selection text.
    static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: "͏", with: "")
            .replacingOccurrences(of: "No conversations selected", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
