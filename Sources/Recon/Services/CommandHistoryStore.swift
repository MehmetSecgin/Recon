import Foundation
import SQLite3

private let COMMAND_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor CommandHistoryStore {
    private struct StreamSanitizationResult {
        let text: String
        let truncated: Bool
    }

    private struct SanitizationInput {
        let text: String
        let truncated: Bool
    }

    private struct SanitizedOutputPair {
        let stdout: StreamSanitizationResult
        let stderr: StreamSanitizationResult
    }

    private struct JSONRedactionOptions {
        let redactConfigMapPayloads: Bool
    }

    private static let maxStoredStreamBytes = 128 * 1024
    private static let maxSanitizationInputBytes = 512 * 1024
    private static let pruneInsertThreshold = 50
    nonisolated(unsafe) static var shared = CommandHistoryStore()

    private let databaseURL: URL
    private let fileManager: FileManager
    private let nowProvider: @Sendable () -> Date
    private let retentionWindow: TimeInterval
    private var db: OpaquePointer?
    private var hasPreparedSchema = false
    private var insertsSincePrune = 0

    init(
        fileManager: FileManager = .default,
        databaseURL: URL? = nil,
        retentionWindow: TimeInterval = 24 * 60 * 60,
        nowProvider: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fileManager = fileManager
        self.nowProvider = nowProvider
        self.retentionWindow = retentionWindow
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
        try ensureReady()
        try pruneExpiredRows()
    }

    func insert(_ record: CommandHistoryEntryRecord) throws {
        try ensureReady()

        let sanitized = Self.sanitizeOutputs(
            stdout: record.stdout,
            stderr: record.stderr,
            executable: record.executable,
            arguments: record.arguments
        )

        try execute(
            """
            INSERT INTO command_history (
                started_at,
                finished_at,
                duration_ms,
                executable,
                arguments_json,
                source,
                context,
                namespace,
                result_state,
                exit_code,
                stdout,
                stderr,
                stdout_truncated,
                stderr_truncated
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .double(record.startedAt.timeIntervalSince1970),
                .double(record.finishedAt.timeIntervalSince1970),
                .int64(record.durationMs),
                .text(record.executable),
                .text(Self.serializeArguments(record.arguments)),
                .text(record.source.rawValue),
                .text(record.context),
                .text(record.namespace),
                .text(record.resultState.rawValue),
                .int32(record.exitCode),
                .text(sanitized.stdout.text),
                .text(sanitized.stderr.text),
                .int32(sanitized.stdout.truncated ? 1 : 0),
                .int32(sanitized.stderr.truncated ? 1 : 0)
            ]
        )

        insertsSincePrune += 1
        if insertsSincePrune >= Self.pruneInsertThreshold {
            try pruneExpiredRows()
            insertsSincePrune = 0
        }
    }

    func recentSummaries(limit: Int = 500) throws -> [CommandHistorySummaryItem] {
        try ensureReady()
        try pruneExpiredRows()

        return try query(
            """
            SELECT
                id,
                started_at,
                finished_at,
                duration_ms,
                executable,
                arguments_json,
                source,
                context,
                namespace,
                result_state,
                exit_code,
                stdout_truncated,
                stderr_truncated
            FROM command_history
            WHERE started_at >= ?
            ORDER BY started_at DESC
            LIMIT ?;
            """,
            bindings: [
                .double(retentionCutoff.timeIntervalSince1970),
                .int32(Int32(limit))
            ]
        ) { statement in
            CommandHistorySummaryItem(
                id: sqlite3_column_int64(statement, 0),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                finishedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                durationMs: sqlite3_column_int64(statement, 3),
                executable: Self.columnText(statement, index: 4) ?? "",
                arguments: Self.deserializeArguments(Self.columnText(statement, index: 5)),
                source: CommandHistorySource(rawValue: Self.columnText(statement, index: 6) ?? "") ?? .other,
                context: Self.columnText(statement, index: 7),
                namespace: Self.columnText(statement, index: 8),
                resultState: CommandHistoryResultState(rawValue: Self.columnText(statement, index: 9) ?? "") ?? .launchFailure,
                exitCode: Self.columnInt32(statement, index: 10),
                stdoutTruncated: sqlite3_column_int(statement, 11) != 0,
                stderrTruncated: sqlite3_column_int(statement, 12) != 0
            )
        }
    }

    func detail(id: Int64) throws -> CommandHistoryDetailItem? {
        try ensureReady()

        return try query(
            """
            SELECT
                id,
                started_at,
                finished_at,
                duration_ms,
                executable,
                arguments_json,
                source,
                context,
                namespace,
                result_state,
                exit_code,
                stdout,
                stderr,
                stdout_truncated,
                stderr_truncated
            FROM command_history
            WHERE id = ?
            LIMIT 1;
            """,
            bindings: [.int64(id)]
        ) { statement in
            CommandHistoryDetailItem(
                id: sqlite3_column_int64(statement, 0),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                finishedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                durationMs: sqlite3_column_int64(statement, 3),
                executable: Self.columnText(statement, index: 4) ?? "",
                arguments: Self.deserializeArguments(Self.columnText(statement, index: 5)),
                source: CommandHistorySource(rawValue: Self.columnText(statement, index: 6) ?? "") ?? .other,
                context: Self.columnText(statement, index: 7),
                namespace: Self.columnText(statement, index: 8),
                resultState: CommandHistoryResultState(rawValue: Self.columnText(statement, index: 9) ?? "") ?? .launchFailure,
                exitCode: Self.columnInt32(statement, index: 10),
                stdout: Self.columnText(statement, index: 11) ?? "",
                stderr: Self.columnText(statement, index: 12) ?? "",
                stdoutTruncated: sqlite3_column_int(statement, 13) != 0,
                stderrTruncated: sqlite3_column_int(statement, 14) != 0
            )
        }.first
    }

    private func ensureReady() throws {
        try openIfNeeded()
        guard hasPreparedSchema == false else { return }

        try execute(
            """
            CREATE TABLE IF NOT EXISTS command_history (
                id INTEGER PRIMARY KEY,
                started_at REAL NOT NULL,
                finished_at REAL NOT NULL,
                duration_ms INTEGER NOT NULL,
                executable TEXT NOT NULL,
                arguments_json TEXT NOT NULL,
                source TEXT NOT NULL,
                context TEXT NULL,
                namespace TEXT NULL,
                result_state TEXT NOT NULL,
                exit_code INTEGER NULL,
                stdout TEXT NOT NULL DEFAULT '',
                stderr TEXT NOT NULL DEFAULT '',
                stdout_truncated INTEGER NOT NULL DEFAULT 0,
                stderr_truncated INTEGER NOT NULL DEFAULT 0
            );
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS idx_command_history_started_at
            ON command_history(started_at DESC);
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS idx_command_history_source_started_at
            ON command_history(source, started_at DESC);
            """
        )

        hasPreparedSchema = true
    }

    private func pruneExpiredRows() throws {
        try execute(
            "DELETE FROM command_history WHERE started_at < ?;",
            bindings: [.double(retentionCutoff.timeIntervalSince1970)]
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
            throw CommandHistoryStoreError.openFailed(message)
        }

        db = handle
    }

    private func execute(_ sql: String, bindings: [CommandSQLiteBinding] = []) throws {
        _ = try query(sql, bindings: bindings) { _ in () }
    }

    private func query<T>(
        _ sql: String,
        bindings: [CommandSQLiteBinding] = [],
        row: (OpaquePointer) throws -> T
    ) throws -> [T] {
        guard let db else {
            throw CommandHistoryStoreError.openFailed("SQLite database is not available.")
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CommandHistoryStoreError.queryFailed(Self.errorMessage(for: db))
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
                throw CommandHistoryStoreError.queryFailed(Self.errorMessage(for: db))
            }
        }
    }

    private func bind(_ bindings: [CommandSQLiteBinding], to statement: OpaquePointer) throws {
        for (index, binding) in bindings.enumerated() {
            let sqliteIndex = Int32(index + 1)
            let result: Int32

            switch binding {
            case .null:
                result = sqlite3_bind_null(statement, sqliteIndex)
            case .int32(let value):
                if let value {
                    result = sqlite3_bind_int(statement, sqliteIndex, value)
                } else {
                    result = sqlite3_bind_null(statement, sqliteIndex)
                }
            case .int64(let value):
                result = sqlite3_bind_int64(statement, sqliteIndex, value)
            case .double(let value):
                result = sqlite3_bind_double(statement, sqliteIndex, value)
            case .text(let value):
                if let value {
                    result = sqlite3_bind_text(statement, sqliteIndex, value, -1, COMMAND_SQLITE_TRANSIENT)
                } else {
                    result = sqlite3_bind_null(statement, sqliteIndex)
                }
            }

            guard result == SQLITE_OK else {
                throw CommandHistoryStoreError.queryFailed(Self.errorMessage(for: db))
            }
        }
    }

    private var retentionCutoff: Date {
        nowProvider().addingTimeInterval(-retentionWindow)
    }

    private static func sanitizeOutputs(
        stdout: String,
        stderr: String,
        executable: String,
        arguments: [String]
    ) -> SanitizedOutputPair {
        let intent = redactionIntent(for: executable, arguments: arguments)
        return SanitizedOutputPair(
            stdout: sanitizeStream(stdout, intent: intent),
            stderr: sanitizeStream(stderr, intent: intent)
        )
    }

    private static func sanitizeStream(_ text: String, intent: RedactionIntent) -> StreamSanitizationResult {
        let boundedInput = boundInputForSanitization(text, intent: intent)
        let redacted: String
        switch intent {
        case .configView:
            redacted = configViewSummary(for: boundedInput.text)
        case .configMaps:
            redacted = redact(boundedInput.text, options: JSONRedactionOptions(redactConfigMapPayloads: true))
        case .generic:
            redacted = redact(boundedInput.text, options: JSONRedactionOptions(redactConfigMapPayloads: false))
        }

        let truncated = truncateUTF8(redacted, maxBytes: maxStoredStreamBytes)
        return StreamSanitizationResult(
            text: truncated.text,
            truncated: boundedInput.truncated || truncated.truncated
        )
    }

    private static func boundInputForSanitization(_ text: String, intent: RedactionIntent) -> SanitizationInput {
        let byteCount = text.lengthOfBytes(using: .utf8)
        guard byteCount > maxSanitizationInputBytes else {
            return SanitizationInput(text: text, truncated: false)
        }

        switch intent {
        case .configView:
            return SanitizationInput(
                text: largeOutputSummary(
                    label: "kubectl config view output",
                    byteCount: byteCount,
                    lineCount: lineCount(in: text)
                ),
                truncated: true
            )
        case .configMaps:
            return SanitizationInput(
                text: largeOutputSummary(
                    label: "kubectl configmaps output",
                    byteCount: byteCount,
                    lineCount: lineCount(in: text)
                ),
                truncated: true
            )
        case .generic:
            if looksLikeStructuredJSON(text) {
                return SanitizationInput(
                    text: largeOutputSummary(
                        label: "large JSON output",
                        byteCount: byteCount,
                        lineCount: lineCount(in: text)
                    ),
                    truncated: true
                )
            }

            let truncated = truncateUTF8(text, maxBytes: maxSanitizationInputBytes)
            return SanitizationInput(
                text: """
                [output truncated before redaction due to size]
                original-bytes: \(byteCount)
                original-lines: \(lineCount(in: text))

                \(truncated.text)
                """,
                truncated: true
            )
        }
    }

    private static func redact(_ text: String, options: JSONRedactionOptions) -> String {
        guard text.isEmpty == false else {
            return ""
        }

        if let structured = redactStructuredText(text, options: options) {
            return structured
        }

        return redactPlainText(text)
    }

    private static func redactStructuredText(_ text: String, options: JSONRedactionOptions) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object) else {
            return nil
        }

        let redacted = redactJSONObject(object, options: options)
        guard JSONSerialization.isValidJSONObject(redacted),
              let serialized = try? JSONSerialization.data(
                  withJSONObject: redacted,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let text = String(data: serialized, encoding: .utf8) else {
            return nil
        }

        return text
    }

    private static func redactJSONObject(_ value: Any, options: JSONRedactionOptions) -> Any {
        if var dictionary = value as? [String: Any] {
            if let name = dictionary["name"] as? String, isSensitiveKey(name) {
                if dictionary["value"] != nil {
                    dictionary["value"] = redactedPlaceholder
                }
                if dictionary["valueFrom"] != nil {
                    dictionary["valueFrom"] = redactedPlaceholder
                }
            }

            for key in dictionary.keys {
                if options.redactConfigMapPayloads && isConfigMapPayloadKey(key) {
                    dictionary[key] = redactedCollectionPlaceholder(for: dictionary[key])
                    continue
                }

                if isSensitiveKey(key) {
                    dictionary[key] = redactedPlaceholder
                    continue
                }

                if let nestedValue = dictionary[key] {
                    dictionary[key] = redactJSONObject(nestedValue, options: options)
                }
            }

            return dictionary
        }

        if let array = value as? [Any] {
            return array.map { redactJSONObject($0, options: options) }
        }

        return value
    }

    private static func redactPlainText(_ text: String) -> String {
        let patterns = [
            #"(?im)(["']?(?:token|password|secret|client-key-data|client-certificate-data|certificate-authority-data)["']?\s*[:=]\s*)(["'][^"'\n]*["']|[^\s,\n]+)"#,
            #"(?im)(\b[A-Z0-9_]*(?:TOKEN|PASSWORD|SECRET)[A-Z0-9_]*\b\s*[:=]\s*)(["'][^"'\n]*["']|[^\s,\n]+)"#
        ]

        return patterns.reduce(text) { partialResult, pattern in
            partialResult.replacingOccurrences(
                of: pattern,
                with: "$1<redacted>",
                options: .regularExpression
            )
        }
    }

    private static func configViewSummary(for text: String) -> String {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return ""
        }

        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let currentContext = (object["current-context"] as? String)?.nilIfEmpty ?? "unknown"
            let contextCount = (object["contexts"] as? [Any])?.count ?? 0
            let clusterCount = (object["clusters"] as? [Any])?.count ?? 0
            let userCount = (object["users"] as? [Any])?.count ?? 0

            return """
            [redacted kubectl config view output]
            current-context: \(currentContext)
            contexts: \(contextCount)
            clusters: \(clusterCount)
            users: \(userCount)
            """
        }

        let compactFields = KubectlConfigOutputParsing.parseTargetFields(from: text)
        if compactFields.context != nil || compactFields.namespace != nil {
            let context = compactFields.context ?? "unknown"
            let namespace = compactFields.namespace ?? "default"

            return """
            [redacted kubectl config view output]
            current-context: \(context)
            current-namespace: \(namespace)
            """
        }

        let lineCount = text.components(separatedBy: .newlines).filter { $0.isEmpty == false }.count
        return """
        [redacted kubectl config view output]
        omitted-lines: \(lineCount)
        """
    }

    private static func largeOutputSummary(label: String, byteCount: Int, lineCount: Int) -> String {
        """
        [output summarized due to size]
        label: \(label)
        original-bytes: \(byteCount)
        original-lines: \(lineCount)
        """
    }

    private static func redactedCollectionPlaceholder(for value: Any?) -> String {
        if let dictionary = value as? [String: Any] {
            return "<redacted \(dictionary.count) entries>"
        }

        if let array = value as? [Any] {
            return "<redacted \(array.count) entries>"
        }

        return redactedPlaceholder
    }

    private static var redactedPlaceholder: String {
        "<redacted>"
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }

        let fragments = [
            "token",
            "password",
            "secret",
            "clientkeydata",
            "clientcertificatedata",
            "certificateauthoritydata"
        ]

        return fragments.contains { normalized.contains($0) }
    }

    private static func isConfigMapPayloadKey(_ key: String) -> Bool {
        ["data", "binarydata", "stringdata"].contains(
            key.lowercased().filter { $0.isLetter || $0.isNumber }
        )
    }

    private static func looksLikeStructuredJSON(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }) else {
            return false
        }

        return first == "{" || first == "["
    }

    private static func lineCount(in text: String) -> Int {
        if text.isEmpty {
            return 0
        }

        return text.reduce(into: 1) { count, character in
            if character == "\n" {
                count += 1
            }
        }
    }

    private enum RedactionIntent {
        case generic
        case configView
        case configMaps
    }

    private static func redactionIntent(for executable: String, arguments: [String]) -> RedactionIntent {
        let searchable = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).map { $0.lowercased() }
        let containsConfig = searchable.contains { $0.contains("config") }
        let containsView = searchable.contains { $0.contains("view") }
        if containsConfig && containsView {
            return .configView
        }

        let containsGet = searchable.contains { $0 == "get" || $0.contains("get") }
        let containsConfigMaps = searchable.contains { $0.contains("configmap") }
        if containsGet && containsConfigMaps {
            return .configMaps
        }

        return .generic
    }

    private static func truncateUTF8(_ text: String, maxBytes: Int) -> (text: String, truncated: Bool) {
        guard text.lengthOfBytes(using: .utf8) > maxBytes else {
            return (text, false)
        }

        var byteCount = 0
        var endIndex = text.startIndex

        for index in text.indices {
            let nextIndex = text.index(after: index)
            let scalar = String(text[index..<nextIndex])
            let scalarBytes = scalar.lengthOfBytes(using: .utf8)
            if byteCount + scalarBytes > maxBytes {
                break
            }
            byteCount += scalarBytes
            endIndex = nextIndex
        }

        return (String(text[..<endIndex]), true)
    }

    private static func serializeArguments(_ arguments: [String]) -> String {
        guard let data = try? JSONEncoder().encode(arguments),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private static func deserializeArguments(_ json: String?) -> [String] {
        guard let json,
              let data = json.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return arguments
    }

    private static func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private static func columnInt32(_ statement: OpaquePointer, index: Int32) -> Int32? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_int(statement, index)
    }

    private static func errorMessage(for db: OpaquePointer?) -> String {
        guard let db, let message = sqlite3_errmsg(db) else {
            return "Unknown SQLite error"
        }
        return String(cString: message)
    }
}

enum CommandHistoryStoreError: LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "Couldn't open command history: \(message)"
        case .queryFailed(let message):
            return "Couldn't update command history: \(message)"
        }
    }
}

private enum CommandSQLiteBinding {
    case null
    case int32(Int32?)
    case int64(Int64)
    case double(Double)
    case text(String?)
}
