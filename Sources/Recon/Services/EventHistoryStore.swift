import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor EventHistoryStore {
    private let databaseURL: URL
    private let fileManager: FileManager
    private var db: OpaquePointer?

    init(
        fileManager: FileManager = .default,
        databaseURL: URL? = nil
    ) {
        self.fileManager = fileManager
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let appSupport = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.databaseURL = (appSupport ?? fileManager.homeDirectoryForCurrentUser)
                .appendingPathComponent("Recon", isDirectory: true)
                .appendingPathComponent("diagnostics.sqlite3")
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func prepare() throws {
        try openIfNeeded()
        try execute(
            """
            CREATE TABLE IF NOT EXISTS diagnostics_history (
                id INTEGER PRIMARY KEY,
                occurred_at REAL NOT NULL,
                kind TEXT NOT NULL,
                context TEXT NULL,
                namespace TEXT NULL,
                message TEXT NOT NULL,
                metadata_json TEXT NULL,
                UNIQUE(kind, occurred_at, message) ON CONFLICT IGNORE
            );
            """
        )
        try pruneExpiredRows()
    }

    func insert(_ event: DiagnosticsEvent) throws {
        try prepare()
        try execute(
            """
            INSERT INTO diagnostics_history (
                occurred_at,
                kind,
                context,
                namespace,
                message,
                metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .double(event.occurredAt.timeIntervalSince1970),
                .text(event.kind.rawValue),
                .text(event.context),
                .text(event.namespace),
                .text(event.message),
                .text(event.metadataJSON)
            ]
        )
    }

    func recentHistory(limit: Int = 300) throws -> [DiagnosticsHistoryItem] {
        try prepare()

        return try query(
            """
            SELECT id, occurred_at, kind, message, context, namespace
            FROM diagnostics_history
            WHERE occurred_at >= ?
            ORDER BY occurred_at DESC
            LIMIT ?;
            """,
            bindings: [
                .double(Self.retentionCutoff.timeIntervalSince1970),
                .int(Int32(limit))
            ]
        ) { statement in
            let id = sqlite3_column_int64(statement, 0)
            let occurredAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let kindText = Self.columnText(statement, index: 2) ?? DiagnosticsEvent.Kind.connected.rawValue
            let kind = DiagnosticsEvent.Kind(rawValue: kindText) ?? .connected
            let message = Self.columnText(statement, index: 3) ?? ""
            let context = Self.columnText(statement, index: 4)
            let namespace = Self.columnText(statement, index: 5)

            return DiagnosticsHistoryItem(
                id: id,
                occurredAt: occurredAt,
                kind: kind,
                message: message,
                context: context,
                namespace: namespace
            )
        }
    }

    private func pruneExpiredRows() throws {
        try execute(
            "DELETE FROM diagnostics_history WHERE occurred_at < ?;",
            bindings: [.double(Self.retentionCutoff.timeIntervalSince1970)]
        )
    }

    private func openIfNeeded() throws {
        if db != nil {
            return
        }

        let directoryURL = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            let message = handle.flatMap { sqlite3_errmsg($0).map { String(cString: $0) } } ?? "Unknown SQLite error"
            if let handle {
                sqlite3_close(handle)
            }
            throw EventHistoryStoreError.openFailed(message)
        }

        db = handle
    }

    private func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        _ = try query(sql, bindings: bindings) { _ in () }
    }

    private func query<T>(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        row: (OpaquePointer) throws -> T
    ) throws -> [T] {
        guard let db else {
            throw EventHistoryStoreError.openFailed("SQLite database is not available.")
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw EventHistoryStoreError.queryFailed(Self.errorMessage(for: db))
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        var results: [T] = []
        while true {
            let code = sqlite3_step(statement)
            switch code {
            case SQLITE_ROW:
                results.append(try row(statement))
            case SQLITE_DONE:
                return results
            default:
                throw EventHistoryStoreError.queryFailed(Self.errorMessage(for: db))
            }
        }
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer) throws {
        for (index, binding) in bindings.enumerated() {
            let sqliteIndex = Int32(index + 1)
            let result: Int32

            switch binding {
            case .null:
                result = sqlite3_bind_null(statement, sqliteIndex)
            case .int(let value):
                result = sqlite3_bind_int(statement, sqliteIndex, value)
            case .double(let value):
                result = sqlite3_bind_double(statement, sqliteIndex, value)
            case .text(let value):
                if let value {
                    result = sqlite3_bind_text(statement, sqliteIndex, value, -1, SQLITE_TRANSIENT)
                } else {
                    result = sqlite3_bind_null(statement, sqliteIndex)
                }
            }

            guard result == SQLITE_OK else {
                throw EventHistoryStoreError.queryFailed(Self.errorMessage(for: db))
            }
        }
    }

    private static func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private static func errorMessage(for db: OpaquePointer?) -> String {
        guard let db, let message = sqlite3_errmsg(db) else {
            return "Unknown SQLite error"
        }
        return String(cString: message)
    }

    private static var retentionCutoff: Date {
        Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
    }
}

enum EventHistoryStoreError: LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "Couldn't open diagnostics history: \(message)"
        case .queryFailed(let message):
            return "Couldn't update diagnostics history: \(message)"
        }
    }
}

private enum SQLiteBinding {
    case null
    case int(Int32)
    case double(Double)
    case text(String?)
}
