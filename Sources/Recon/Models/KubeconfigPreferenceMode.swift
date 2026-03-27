import Foundation

enum KubeconfigPreferenceMode: String, CaseIterable, Identifiable, Sendable {
    case pinned
    case followEnvironment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned:
            return "Pinned to file"
        case .followEnvironment:
            return "Follow $KUBECONFIG"
        }
    }
}
