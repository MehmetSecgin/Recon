import Foundation

enum CommandHistorySource: String, CaseIterable, Sendable {
    case other
    case statusPoll = "status-poll"
    case statusCheck = "status-check"
    case diagnostics
    case telepresenceAction = "telepresence-action"
    case kubeTargetResolution = "kube-target-resolution"
    case clusterBrowser = "cluster-browser"
    case namespaceDiscovery = "namespace-discovery"
    case environmentProbe = "environment-probe"
    case appInstall = "app-install"

    var title: String {
        switch self {
        case .other:
            return "Other"
        case .statusPoll:
            return "Status Poll"
        case .statusCheck:
            return "Status Check"
        case .diagnostics:
            return "Diagnostics"
        case .telepresenceAction:
            return "Telepresence"
        case .kubeTargetResolution:
            return "Kube Target"
        case .clusterBrowser:
            return "Deck"
        case .namespaceDiscovery:
            return "Namespace Discovery"
        case .environmentProbe:
            return "Environment Probe"
        case .appInstall:
            return "App Install"
        }
    }

    var isStatusPoll: Bool {
        self == .statusPoll
    }
}

enum CommandHistoryResultState: String, Sendable {
    case success
    case nonZeroExit = "non-zero-exit"
    case timeout
    case launchFailure = "launch-failure"

    var title: String {
        switch self {
        case .success:
            return "Success"
        case .nonZeroExit:
            return "Non-zero exit"
        case .timeout:
            return "Timed out"
        case .launchFailure:
            return "Launch failed"
        }
    }
}

struct ProcessRunMetadata: Sendable {
    let source: CommandHistorySource
    let context: String?
    let namespace: String?

    init(
        source: CommandHistorySource = .other,
        context: String? = nil,
        namespace: String? = nil
    ) {
        self.source = source
        self.context = context
        self.namespace = namespace
    }
}

struct CommandHistoryEntryRecord: Sendable {
    let startedAt: Date
    let finishedAt: Date
    let durationMs: Int64
    let executable: String
    let arguments: [String]
    let source: CommandHistorySource
    let context: String?
    let namespace: String?
    let resultState: CommandHistoryResultState
    let exitCode: Int32?
    let stdout: String
    let stderr: String
}

struct CommandHistorySummaryItem: Identifiable, Equatable, Sendable {
    let id: Int64
    let startedAt: Date
    let finishedAt: Date
    let durationMs: Int64
    let executable: String
    let arguments: [String]
    let source: CommandHistorySource
    let context: String?
    let namespace: String?
    let resultState: CommandHistoryResultState
    let exitCode: Int32?
    let stdoutTruncated: Bool
    let stderrTruncated: Bool

    var commandText: String {
        Self.renderCommand(executable: executable, arguments: arguments)
    }

    var abbreviatedCommandText: String {
        Self.renderCommand(
            executable: URL(fileURLWithPath: executable).lastPathComponent,
            arguments: arguments
        )
    }

    var resultText: String {
        switch resultState {
        case .success:
            return "Success"
        case .nonZeroExit:
            if let exitCode {
                return "Exit \(exitCode)"
            }
            return "Non-zero exit"
        case .timeout:
            return "Timed out"
        case .launchFailure:
            return "Launch failed"
        }
    }

    var hasTruncatedOutput: Bool {
        stdoutTruncated || stderrTruncated
    }

    private static func renderCommand(executable: String, arguments: [String]) -> String {
        ([executable] + arguments)
            .map(commandFragment)
            .joined(separator: " ")
    }

    private static func commandFragment(_ value: String) -> String {
        if value.isEmpty {
            return "\"\""
        }

        let needsQuotes = value.contains { character in
            character.isWhitespace || "\"'\\$`".contains(character)
        }

        guard needsQuotes else {
            return value
        }

        return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

struct CommandHistoryDetailItem: Identifiable, Equatable, Sendable {
    let id: Int64
    let startedAt: Date
    let finishedAt: Date
    let durationMs: Int64
    let executable: String
    let arguments: [String]
    let source: CommandHistorySource
    let context: String?
    let namespace: String?
    let resultState: CommandHistoryResultState
    let exitCode: Int32?
    let stdout: String
    let stderr: String
    let stdoutTruncated: Bool
    let stderrTruncated: Bool

    var summary: CommandHistorySummaryItem {
        CommandHistorySummaryItem(
            id: id,
            startedAt: startedAt,
            finishedAt: finishedAt,
            durationMs: durationMs,
            executable: executable,
            arguments: arguments,
            source: source,
            context: context,
            namespace: namespace,
            resultState: resultState,
            exitCode: exitCode,
            stdoutTruncated: stdoutTruncated,
            stderrTruncated: stderrTruncated
        )
    }
}
