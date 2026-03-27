import Foundation

struct DiagnosticsEvent: Sendable {
    enum Kind: String, Sendable {
        case connected
        case disconnectedUser = "disconnected-user"
        case disconnectedUnexpected = "disconnected-unexpected"
        case sessionTimeout = "session-timeout"
        case autoReconnectSucceeded = "auto-reconnect-succeeded"
        case autoReconnectFailed = "auto-reconnect-failed"
        case rootDaemonRestarted = "root-daemon-restarted"
        case kubeconfigChanged = "kubeconfig-changed"
    }

    let occurredAt: Date
    let kind: Kind
    let context: String?
    let namespace: String?
    let message: String
    let metadataJSON: String?

    init(
        occurredAt: Date = .now,
        kind: Kind,
        context: String? = nil,
        namespace: String? = nil,
        message: String,
        metadataJSON: String? = nil
    ) {
        self.occurredAt = occurredAt
        self.kind = kind
        self.context = context
        self.namespace = namespace
        self.message = message
        self.metadataJSON = metadataJSON
    }
}

struct DiagnosticsHistoryItem: Identifiable, Equatable, Sendable {
    let id: Int64
    let occurredAt: Date
    let kind: DiagnosticsEvent.Kind
    let message: String
    let context: String?
    let namespace: String?

    var tint: DiagnosticsHistoryTint {
        switch kind {
        case .connected, .autoReconnectSucceeded:
            return .green
        case .disconnectedUser:
            return .gray
        case .disconnectedUnexpected, .sessionTimeout:
            return .red
        case .autoReconnectFailed, .rootDaemonRestarted:
            return .orange
        case .kubeconfigChanged:
            return .blue
        }
    }
}

enum DiagnosticsHistoryTint: Sendable {
    case green
    case gray
    case red
    case orange
    case blue
}
