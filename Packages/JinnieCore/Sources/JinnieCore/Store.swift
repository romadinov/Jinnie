import Foundation

/// Local database: one JSON row per entity, a full-text index, an outbox of rows CloudKit still has
/// to upload, and a key/value table for device-local state (sync cursors, engine state).
///
/// Safe to share between the app, the CLI and the MCP server (SQLite WAL). Writers in other
/// processes post `JinnieConfig.externalChangeNotification`; the app then uploads their outbox rows.
public final class Store: @unchecked Sendable {
    let db: SQLiteDB
    private let lock = NSRecursiveLock()
    public let url: URL

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Fractional seconds: updatedAt decides which copy wins, so it must round-trip exactly enough.
        e.dateEncodingStrategy = .custom { date, enc in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = enc.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let s = try? c.decode(String.self), let date = parseISODate(s) { return date }
            return Date(timeIntervalSinceReferenceDate: try c.decode(Double.self))
        }
        return d
    }()

    /// Posted on the main queue after any local write in this process.
    public static let didChange = Notification.Name("JinnieStoreDidChange")

    public init(url: URL = JinnieConfig.databaseURL()) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDB(path: url.path)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS records(
          type TEXT NOT NULL, id TEXT NOT NULL, updated_at REAL NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
          nkey TEXT, json TEXT NOT NULL, PRIMARY KEY(type, id));
        CREATE INDEX IF NOT EXISTS records_nkey ON records(type, nkey);
        CREATE TABLE IF NOT EXISTS outbox(type TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY(type, id));
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(type UNINDEXED, id UNINDEXED, body, tokenize='unicode61 remove_diacritics 2');
        """)
    }

    // MARK: Meta

    public func meta(_ key: String) -> String? {
        lock.withLock { try? db.prepare("SELECT value FROM meta WHERE key=?").bind(key).first { $0.optionalString(0) } ?? nil }
    }

    public func setMeta(_ key: String, _ value: String?) {
        lock.withLock {
            if let value { try? db.prepare("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)").bind(key, value).run() }
            else { try? db.prepare("DELETE FROM meta WHERE key=?").bind(key).run() }
        }
    }

    // MARK: Read

    public func all<T: Entity>(_ type: T.Type, includeDeleted: Bool = false) -> [T] {
        lock.withLock {
            var out: [T] = []
            let sql = includeDeleted ? "SELECT json FROM records WHERE type=?" : "SELECT json FROM records WHERE type=? AND deleted=0"
            try? db.prepare(sql).bind(T.type).forEach { row in
                if let v = try? Store.decoder.decode(T.self, from: Data(row.string(0).utf8)) { out.append(v) }
            }
            return out
        }
    }

    public func get<T: Entity>(_ type: T.Type, _ id: String) -> T? {
        lock.withLock {
            let json = try? db.prepare("SELECT json FROM records WHERE type=? AND id=?").bind(T.type, id).first { $0.string(0) }
            return json.flatMap { try? Store.decoder.decode(T.self, from: Data($0.utf8)) }
        }
    }

    public func find<T: Entity>(_ type: T.Type, key: String) -> T? {
        lock.withLock {
            let json = try? db.prepare("SELECT json FROM records WHERE type=? AND nkey=? AND deleted=0 LIMIT 1").bind(T.type, key).first { $0.string(0) }
            return json.flatMap { try? Store.decoder.decode(T.self, from: Data($0.utf8)) }
        }
    }

    /// Full-text search across all entity types. Returns (type, id) pairs, best match first.
    public func search(_ query: String, types: [String]? = nil, limit: Int = 30) -> [(type: String, id: String)] {
        let terms = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
        guard !terms.isEmpty else { return [] }
        // Prefix match on every word, OR-combined, ranked by bm25 so items matching more words come first.
        let match = terms.map { "\"\($0)\"*" }.joined(separator: " OR ")
        return lock.withLock {
            var out: [(String, String)] = []
            try? db.prepare("SELECT type, id FROM fts WHERE fts MATCH ? ORDER BY bm25(fts) LIMIT ?").bind(match, limit * 3).forEach { row in
                let t = row.string(0)
                if types == nil || types!.contains(t) { out.append((t, row.string(1))) }
            }
            return Array(out.prefix(limit)).map { (type: $0.0, id: $0.1) }
        }
    }

    // MARK: Write

    /// Saves an entity (stamping `updatedAt`) and queues it for upload.
    @discardableResult
    public func save<T: Entity>(_ value: T) -> T {
        var v = value
        v.updatedAt = Date()
        lock.withLock {
            try? db.transaction { try write(v, enqueue: true) }
        }
        changed()
        return v
    }

    public func saveAll<T: Entity>(_ values: [T]) {
        guard !values.isEmpty else { return }
        lock.withLock {
            try? db.transaction {
                for var v in values { v.updatedAt = Date(); try write(v, enqueue: true) }
            }
        }
        changed()
    }

    public func delete<T: Entity>(_ value: T) {
        var v = value
        v.deleted = true
        save(v)
    }

    func write<T: Entity>(_ v: T, enqueue: Bool) throws {
        let json = String(decoding: try Store.encoder.encode(v), as: UTF8.self)
        try db.prepare("INSERT OR REPLACE INTO records(type,id,updated_at,deleted,nkey,json) VALUES(?,?,?,?,?,?)")
            .bind(T.type, v.id, v.updatedAt.timeIntervalSince1970, v.deleted, v.naturalKey, json).run()
        try db.prepare("DELETE FROM fts WHERE type=? AND id=?").bind(T.type, v.id).run()
        if !v.deleted {
            try db.prepare("INSERT INTO fts(type,id,body) VALUES(?,?,?)").bind(T.type, v.id, v.searchText).run()
        }
        if enqueue { try db.prepare("INSERT OR IGNORE INTO outbox(type,id) VALUES(?,?)").bind(T.type, v.id).run() }
    }

    private func changed() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Store.didChange, object: nil) }
    }

    // MARK: Sync support

    /// Raw JSON of a record, for upload.
    public func rawRecord(type: String, id: String) -> (json: String, updatedAt: Double)? {
        lock.withLock {
            try? db.prepare("SELECT json, updated_at FROM records WHERE type=? AND id=?").bind(type, id).first { ($0.string(0), $0.double(1)) }
        }
    }

    /// Applies a record received from iCloud if it is newer than the local copy. Returns true if applied.
    @discardableResult
    public func applyRemote(type: String, json: String) -> Bool {
        guard let entityType = EntityRegistry.type(named: type) else { return false }
        return applyRemote(entityType, json: json)
    }

    private func applyRemote<T: Entity>(_ t: T.Type, json: String) -> Bool {
        guard let incoming = try? Store.decoder.decode(T.self, from: Data(json.utf8)) else { return false }
        let applied: Bool = lock.withLock {
            let local = try? db.prepare("SELECT updated_at FROM records WHERE type=? AND id=?").bind(T.type, incoming.id).first { $0.double(0) }
            if let local, local >= incoming.updatedAt.timeIntervalSince1970 { return false }
            try? db.transaction { try write(incoming, enqueue: false) }
            return true
        }
        if applied { changed() }
        return applied
    }

    public func outbox(limit: Int = 400) -> [(type: String, id: String)] {
        lock.withLock {
            var out: [(String, String)] = []
            try? db.prepare("SELECT type, id FROM outbox LIMIT ?").bind(limit).forEach { out.append(($0.string(0), $0.string(1))) }
            return out.map { (type: $0.0, id: $0.1) }
        }
    }

    public func removeFromOutbox(type: String, id: String) {
        lock.withLock { try? db.prepare("DELETE FROM outbox WHERE type=? AND id=?").bind(type, id).run() }
    }

    public func enqueueAll() {
        lock.withLock { try? db.exec("INSERT OR IGNORE INTO outbox(type,id) SELECT type,id FROM records") }
    }

    public var outboxCount: Int {
        lock.withLock { Int((try? db.prepare("SELECT COUNT(*) FROM outbox").first { $0.int64(0) }) ?? 0) }
    }
}

public func parseISODate(_ s: String) -> Date? {
    ISODateParsers.fractional.date(from: s) ?? ISODateParsers.plain.date(from: s) ?? ISODateParsers.day.date(from: s)
}

/// Made once: creating an ISO8601DateFormatter per date made decoding the store (every person, project and run) slow
/// enough to keep a core busy and the UI lagging. ISO8601DateFormatter is thread-safe.
private enum ISODateParsers {
    nonisolated(unsafe) static let fractional = make([.withInternetDateTime, .withFractionalSeconds])
    nonisolated(unsafe) static let plain = make([.withInternetDateTime])
    nonisolated(unsafe) static let day: ISO8601DateFormatter = {
        let f = make([.withFullDate])
        f.timeZone = .current
        return f
    }()
    static func make(_ options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = options
        return f
    }
}
