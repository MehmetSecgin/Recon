import Foundation

enum DiagnosticsLogSource: String, CaseIterable, Identifiable, Sendable {
    case connector
    case cli
    case daemon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connector:
            return "Connector"
        case .cli:
            return "CLI"
        case .daemon:
            return "Daemon"
        }
    }

    var filename: String {
        switch self {
        case .connector:
            return "connector.log"
        case .cli:
            return "cli.log"
        case .daemon:
            return "daemon.log"
        }
    }
}

enum DiagnosticsLogLevel: String, CaseIterable, Identifiable, Sendable {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
    case unknown = "UNKNOWN"

    var id: String { rawValue }
}

struct DiagnosticsLogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let rawLine: String
    let timestampText: String?
    let level: DiagnosticsLogLevel
    let messageText: String

    init(
        id: UUID = UUID(),
        rawLine: String,
        timestampText: String?,
        level: DiagnosticsLogLevel,
        messageText: String
    ) {
        self.id = id
        self.rawLine = rawLine
        self.timestampText = timestampText
        self.level = level
        self.messageText = messageText
    }
}

struct DiagnosticsLogFileState: Sendable {
    let source: DiagnosticsLogSource
    let fileURL: URL?
    let exists: Bool
}
