import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite wrapper. Not thread-safe by itself; `Store` serialises access.
final class SQLiteDB {
    private(set) var handle: OpaquePointer?
    private var cache: [String: OpaquePointer] = [:]

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            throw SQLiteError(code: -1, message: msg)
        }
        // WAL lets the share extension and the app use the database at the same time.
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA foreign_keys=OFF")
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit {
        for (_, s) in cache { sqlite3_finalize(s) }
        sqlite3_close_v2(handle)
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: sqlite3_errcode(handle), message: msg)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        if let s = cache[sql] {
            sqlite3_reset(s); sqlite3_clear_bindings(s)
            return Statement(stmt: s, db: self)
        }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &s, nil) == SQLITE_OK, let s else {
            throw SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
        }
        cache[sql] = s
        return Statement(stmt: s, db: self)
    }

    var changes: Int { Int(sqlite3_changes(handle)) }
    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }
}

struct Statement {
    let stmt: OpaquePointer
    unowned let db: SQLiteDB

    @discardableResult
    func bind(_ values: Any?...) -> Statement { bind(array: values) }

    @discardableResult
    func bind(array values: [Any?]) -> Statement {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case nil: sqlite3_bind_null(stmt, idx)
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
            case let n as Int32: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let b as Bool: sqlite3_bind_int64(stmt, idx, b ? 1 : 0)
            case let data as Data:
                _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(data.count), SQLITE_TRANSIENT) }
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return self
    }

    func run() throws {
        let rc = sqlite3_step(stmt)
        defer { sqlite3_reset(stmt) }
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError(code: rc, message: db.errorMessage)
        }
    }

    /// Iterates rows; the row accessor is only valid inside the closure.
    func forEach(_ body: (Row) throws -> Void) throws {
        defer { sqlite3_reset(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(code: rc, message: db.errorMessage) }
            try body(Row(stmt: stmt))
        }
    }

    func first<T>(_ map: (Row) -> T) throws -> T? {
        var out: T?
        try forEach { row in if out == nil { out = map(row) } }
        return out
    }
}

struct Row {
    let stmt: OpaquePointer
    func string(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    func optionalString(_ i: Int32) -> String? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : string(i)
    }
    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func data(_ i: Int32) -> Data {
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: n)
    }
}
