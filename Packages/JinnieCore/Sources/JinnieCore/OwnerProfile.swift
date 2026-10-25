import Foundation

/// Who Jinnie works for: set in the Mac's setup assistant, stored in `profile.json` next to the database (shared by the
/// app and `jinniectl`). Nothing about the owner is built into the code.
public struct OwnerProfile: Codable, Equatable, Sendable {
    public var name: String = ""
    /// Every address the owner sends from (work and personal): their own messages and commitments are told apart by these.
    public var emails: [String] = []
    public var organization: String = ""
    /// "sales engineer", "Product manager"…
    public var role: String = ""
    /// Languages the owner writes and speaks ("English and Russian").
    public var languages: String = "English"
    /// Other names the owner goes by in notes and messages ("Alex", "Саша").
    public var nicknames: [String] = []
    /// Uberdoer folder for work projects.
    public var uberdoerFolder: String = "Work"

    public init() {}

    public var isComplete: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !emails.isEmpty }
    public var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }

    /// "a sales engineer at Northwind Traders" (or less, as filled in).
    public var description: String {
        switch (role.isEmpty, organization.isEmpty) {
        case (false, false): "\(role) at \(organization)"
        case (false, true): role
        case (true, false): "someone at \(organization)"
        case (true, true): "a professional"
        }
    }

    // MARK: Storage

    public static var url: URL { JinnieConfig.supportDirectory().appendingPathComponent("profile.json") }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: OwnerProfile?

    public static var current: OwnerProfile {
        lock.withLock {
            if let cached { return cached }
            let p = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(OwnerProfile.self, from: $0) } ?? OwnerProfile()
            cached = p
            return p
        }
    }

    public static var exists: Bool { FileManager.default.fileExists(atPath: url.path) && current.isComplete }

    public func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url, options: .atomic)
        Self.lock.withLock { Self.cached = self }
    }

    /// Re-read from disk (another process saved it).
    public static func reload() { lock.withLock { cached = nil } }
}
