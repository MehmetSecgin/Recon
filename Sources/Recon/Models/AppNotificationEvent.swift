import Foundation

enum AppNotificationEvent: String, CaseIterable, Hashable, Identifiable, Sendable {
    case connectionEstablished
    case connectionDropped
    case autoReconnectFailed
    case autoConnectFailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connectionEstablished:
            return "Connection restored"
        case .connectionDropped:
            return "Unexpected disconnect"
        case .autoReconnectFailed:
            return "Auto-reconnect failed"
        case .autoConnectFailed:
            return "Auto-connect on launch failed"
        }
    }

    var detail: String {
        switch self {
        case .connectionEstablished:
            return "Notify when Recon notices Telepresence is connected again."
        case .connectionDropped:
            return "Notify when a previously connected session drops unexpectedly."
        case .autoReconnectFailed:
            return "Notify when the automatic recovery attempt does not succeed."
        case .autoConnectFailed:
            return "Notify when launch-time auto-connect does not succeed."
        }
    }
}
