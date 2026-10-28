import Foundation
import SQLite3

/// Just enough of SQLite for the search index: open, run, prepare, bind, step.
/// Not thread-safe; the owning actor serialises every call.
final class SQLiteDatabase {
    struct Error: Swift.Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite \(code): \(message)" }
    }

    private var handle: OpaquePointer?

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            handle = nil
            throw Error(code: rc, message: message)
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        guard rc == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? lastMessage
            sqlite3_free(err)
            throw Error(code: rc, message: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw Error(code: rc, message: lastMessage) }
        return Statement(stmt, db: self)
    }

    /// Runs `body` in a transaction; rolls back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastMessage: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed" }

    final class Statement {
        private let stmt: OpaquePointer
        private let db: SQLiteDatabase

        fileprivate init(_ stmt: OpaquePointer, db: SQLiteDatabase) {
            self.stmt = stmt
            self.db = db
        }

        deinit { sqlite3_finalize(stmt) }

        /// Binds values to `?` placeholders in order (1-based in SQLite).
        @discardableResult
        func bind(_ values: [SQLValue]) throws -> Statement {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            for (i, value) in values.enumerated() {
                let index = Int32(i + 1)
                let rc: Int32
                switch value {
                case .null: rc = sqlite3_bind_null(stmt, index)
                case .int(let v): rc = sqlite3_bind_int64(stmt, index, Int64(v))
                case .double(let v): rc = sqlite3_bind_double(stmt, index, v)
                case .text(let v): rc = sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
                }
                guard rc == SQLITE_OK else { throw Error(code: rc, message: db.lastMessage) }
            }
            return self
        }

        /// Runs a statement that returns no rows.
        func run(_ values: [SQLValue] = []) throws {
            try bind(values)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw Error(code: rc, message: db.lastMessage) }
            sqlite3_reset(stmt)
        }

        /// Every row, mapped by `row`.
        func rows<T>(_ values: [SQLValue] = [], _ row: (Row) throws -> T) throws -> [T] {
            try bind(values)
            var out: [T] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw Error(code: rc, message: db.lastMessage) }
                out.append(try row(Row(stmt: stmt)))
            }
            sqlite3_reset(stmt)
            return out
        }
    }

    struct Row {
        fileprivate let stmt: OpaquePointer

        func text(_ i: Int32) -> String? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func double(_ i: Int32) -> Double? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
        }
        func int(_ i: Int32) -> Int? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i))
        }
    }
}

enum SQLValue {
    case null
    case int(Int)
    case double(Double)
    case text(String)

    static func optional(_ s: String?) -> SQLValue { s.map(SQLValue.text) ?? .null }
    static func optional(_ d: Double?) -> SQLValue { d.map(SQLValue.double) ?? .null }
}

/// SQLite copies the bound string (`SQLITE_TRANSIENT` isn't imported into Swift).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
