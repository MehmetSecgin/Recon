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
    let text: String
    let timestampText: String?
    let level: DiagnosticsLogLevel

    init(
        id: UUID = UUID(),
        text: String,
        timestampText: String?,
        level: DiagnosticsLogLevel
    ) {
        self.id = id
        self.text = text
        self.timestampText = timestampText
        self.level = level
    }
}

struct DiagnosticsLogFileState: Sendable {
    let source: DiagnosticsLogSource
    let fileURL: URL?
    let exists: Bool
}
