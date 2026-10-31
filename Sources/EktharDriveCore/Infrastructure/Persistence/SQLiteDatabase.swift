import Foundation
import SQLite3

public enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    public var string: String? { if case .text(let s) = self { s } else { nil } }
    public var int: Int64? {
        switch self {
        case .integer(let i): i
        case .real(let d): Int64(d)
        default: nil
        }
    }
    public var double: Double? {
        switch self {
        case .real(let d): d
        case .integer(let i): Double(i)
        default: nil
        }
    }
}

public typealias SQLiteRow = [String: SQLiteValue]

public enum DatabaseError: Error, Sendable, Equatable {
    case open(String)
    case prepare(String)
    case step(String)
    case corrupt(String)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Small thread-safe SQLite wrapper. All access is serialized through one lock; the DB is tiny (metadata only).
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let url: URL

    public init(url: URL) throws(DatabaseError) {
        self.url = url
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw .open(msg)
        }
        handle = db
        sqlite3_busy_timeout(db, 3000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        chmod(url.path, 0o600)
    }

    deinit { sqlite3_close(handle) }

    public func execute(_ sql: String, _ params: [SQLiteValue] = []) throws(DatabaseError) {
        _ = try query(sql, params)
    }

    @discardableResult
    public func query(_ sql: String, _ params: [SQLiteValue] = []) throws(DatabaseError) -> [SQLiteRow] {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw .prepare(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, idx)
            case .integer(let v): sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            }
        }
        var rows: [SQLiteRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                let msg = String(cString: sqlite3_errmsg(handle))
                if rc == SQLITE_CORRUPT || rc == SQLITE_NOTADB { throw .corrupt(msg) }
                throw .step(msg)
            }
            var row: SQLiteRow = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var userVersion: Int {
        (try? query("PRAGMA user_version").first?["user_version"]?.int).flatMap { $0 }.map(Int.init) ?? 0
    }

    public func integrityCheck() -> Bool {
        (try? query("PRAGMA integrity_check").first?.values.first?.string) == "ok"
    }
}
