import Foundation
import SQLite3

public enum SQLValue: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    public init(_ value: Int) { self = .int(Int64(value)) }
    public init(_ value: Bool) { self = .int(value ? 1 : 0) }
    public init(_ value: Data) { self = .blob(value) }

    public var string: String? { if case .text(let v) = self { v } else { nil } }
    public var int: Int? { if case .int(let v) = self { Int(v) } else { nil } }
    public var data: Data? {
        switch self {
        case .blob(let v): v
        case .text(let v): Data(v.utf8)
        default: nil
        }
    }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
    public var isConstraint: Bool { code & 0xff == SQLITE_CONSTRAINT }
}

extension Error {
    /// Maps any failure to a user-facing error without leaking SQL or file paths.
    public var cueError: CueError { self as? CueError ?? .storage(self) }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A single SQLite connection. Not thread-safe: own it from one actor.
public final class SQLite {
    private var handle: OpaquePointer?
    public let url: URL?

    public init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        url = path
        try open(path.path)
    }

    /// An in-memory database for tests.
    public init() throws {
        url = nil
        try open(":memory:")
    }

    private func open(_ path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let error = lastError()
            sqlite3_close(handle)
            handle = nil
            throw error
        }
        sqlite3_busy_timeout(handle, 3000)
        try executeScript("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close_v2(handle) }

    private func lastError() -> SQLiteError {
        SQLiteError(code: sqlite3_extended_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Runs one or more statements without parameters.
    public func executeScript(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    public func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        _ = try query(sql, params)
    }

    @discardableResult
    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in params.enumerated() {
            let position = Int32(index + 1)
            let status: Int32 = switch value {
            case .null: sqlite3_bind_null(statement, position)
            case .int(let v): sqlite3_bind_int64(statement, position, v)
            case .double(let v): sqlite3_bind_double(statement, position, v)
            case .text(let v): sqlite3_bind_text(statement, position, v, -1, SQLITE_TRANSIENT)
            case .blob(let v): v.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            }
            guard status == SQLITE_OK else { throw lastError() }
        }
        var rows: [[SQLValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw lastError() }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: .double(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    .blob(Data(bytes: sqlite3_column_blob(statement, column), count: Int(sqlite3_column_bytes(statement, column))))
                default: .null
                }
            })
        }
        return rows
    }

    public func scalar(_ sql: String, _ params: [SQLValue] = []) throws -> SQLValue? {
        try query(sql, params).first?.first
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }

    public func userVersion() throws -> Int { try scalar("PRAGMA user_version")?.int ?? 0 }

    /// Runs `body` in an immediate transaction. Any thrown error rolls back every change.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try executeScript("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try executeScript("COMMIT")
            return result
        } catch {
            try? executeScript("ROLLBACK")
            throw error
        }
    }

    /// Copies a consistent snapshot with SQLite's online backup API and keeps the newest `retain` files.
    @discardableResult
    public func backup(into directory: URL, prefix: String, retain: Int = 5) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Timestamp.sortable(Date())
        let target = directory.appendingPathComponent("\(prefix)-\(stamp)-\(UUID().uuidString.lowercased()).sqlite3")
        var destination: OpaquePointer?
        defer { sqlite3_close_v2(destination) }
        guard sqlite3_open(target.path, &destination) == SQLITE_OK,
              let backup = sqlite3_backup_init(destination, "main", handle, "main") else {
            try? FileManager.default.removeItem(at: target)
            throw lastError()
        }
        let step = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE else {
            try? FileManager.default.removeItem(at: target)
            throw SQLiteError(code: step, message: "Backup did not complete.")
        }
        // Names start with a sortable timestamp, so lexical order is chronological.
        let existing = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("\(prefix)-") && $0.hasSuffix(".sqlite3") }
            .sorted()
        for name in existing.dropLast(retain) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        return target
    }
}
