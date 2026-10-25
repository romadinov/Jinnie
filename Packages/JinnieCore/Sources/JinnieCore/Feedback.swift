import Foundation

/// The shared agent-feedback convention (~/Dev/agent-feedback): the app appends improvement notes and saves crash reports
/// in its iCloud container's Documents/, where the Claude session working on the repo picks them up. Jinnie is the only
/// writer of "Improvement notes.md"; the feedback tool writes the status files. Adapted from Scriptorium.
public enum Feedback {
    public static let containerIdentifier = JinnieConfig.cloudContainer

    /// iCloud Drive › Jinnie (the container's Documents), or the local Documents folder when iCloud is unavailable.
    /// Call off the main thread: the first lookup can block.
    public static func documentsDirectory() -> URL {
        FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier)?.appendingPathComponent("Documents")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Jinnie")
    }

    public static var notesFile: URL { documentsDirectory().appendingPathComponent("Improvement notes.md") }
    public static var crashFolder: URL { documentsDirectory().appendingPathComponent("Crash reports") }

    /// "0.1.0 (3)"
    public static var build: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// Minimal TaskPaper: `Project:` lines and tab-indented `- item @tag(value)` lines.
public enum TaskPaper {
    public static func project(_ name: String) -> String { oneLine(name).replacingOccurrences(of: ":", with: " –") + ":" }

    public static func item(_ text: String, tags: [(String, String?)], indent: Int = 1) -> String {
        let tagText = tags.map { name, value in value.map { "@\(name)(\(tagValue($0)))" } ?? "@\(name)" }.joined(separator: " ")
        return String(repeating: "\t", count: indent) + "- " + oneLine(text) + (tagText.isEmpty ? "" : " " + tagText)
    }

    public static func note(_ text: String, indent: Int = 2) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(repeating: "\t", count: indent) + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Tag values can't contain parentheses or line breaks.
    static func tagValue(_ value: String) -> String {
        oneLine(value).replacingOccurrences(of: "(", with: "[").replacingOccurrences(of: ")", with: "]")
    }

    public static func date(_ date: Date) -> String { date.formatted(.iso8601.year().month().day()) }
}

/// "Improvement notes.md": problems and ideas noted while using the app, with where, build, device and an optional
/// screenshot. Append-only and coordinated, so another device's notes are never overwritten.
public struct ImprovementNotes: Sendable {
    public static let projectName = "Improvement notes"
    public let file: URL

    public init(file: URL = Feedback.notesFile) { self.file = file }

    public var attachmentsDirectory: URL { file.deletingLastPathComponent().appendingPathComponent("Improvement notes") }

    /// Appends a note; returns the screenshot's file name if one was saved.
    @discardableResult
    public func add(_ text: String, context: String, build: String = Feedback.build, device: String,
                    screenshot: Data? = nil, date: Date = Date()) throws -> String? {
        var attachment: String?
        if let screenshot {
            try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HHmmss"
            let name = "Screenshot \(f.string(from: date)).png"
            try screenshot.write(to: attachmentsDirectory.appendingPathComponent(name))
            attachment = name
        }
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        var tags: [(String, String?)] = [("date", TaskPaper.date(date)), ("where", context), ("build", build), ("device", device)]
        if let attachment { tags.append(("screenshot", "Improvement notes/\(attachment)")) }
        var entry = TaskPaper.item(lines.first ?? "", tags: tags)
        let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { entry += "\n" + TaskPaper.note(rest) }

        var inner: Error?
        var coordinationError: NSError?
        SharedTextFile.waitUntilCurrent(file)
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forMerging, error: &coordinationError) { url in
            do {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                var content = SharedTextFile.currentText(at: url)
                if content.isEmpty { content = TaskPaper.project(Self.projectName) + "\n" }
                if !content.hasSuffix("\n") { content += "\n" }
                content += entry + "\n"
                try Data(content.utf8).write(to: url, options: .atomic)
            } catch { inner = error }
        }
        if let error = coordinationError ?? inner { throw error }
        return attachment
    }
}

/// Text files written on several devices through iCloud Drive: wait for the latest version before appending, and fold
/// any conflict versions back in, line by line.
enum SharedTextFile {
    static func waitUntilCurrent(_ url: URL, timeout: TimeInterval = 8) {
        guard (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var copy = url
            copy.removeAllCachedResourceValues()
            if (try? copy.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus == .current { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    static func currentText(at url: URL) -> String {
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        for version in conflicts {
            if let other = try? String(contentsOf: version.url, encoding: .utf8) { text = merge(text, other) }
            version.isResolved = true
        }
        if !conflicts.isEmpty { try? NSFileVersion.removeOtherVersionsOfItem(at: url) }
        return text
    }

    /// Lines of `b` missing from `a` are inserted after the line they followed in `b`.
    static func merge(_ a: String, _ b: String) -> String {
        var lines = a.components(separatedBy: "\n")
        var previous: Int?
        for line in b.components(separatedBy: "\n") {
            if let i = lines.firstIndex(of: line) { previous = i; continue }
            guard !line.isEmpty else { continue }
            let at = previous.map { $0 + 1 } ?? lines.count
            lines.insert(line, at: at)
            previous = at
        }
        return lines.joined(separator: "\n")
    }
}
