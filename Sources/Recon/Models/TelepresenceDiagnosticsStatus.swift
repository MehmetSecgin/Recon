import Foundation

struct TelepresenceDiagnosticsStatus: Decodable, Sendable {
    let userDaemon: UserDaemon?
    let rootDaemon: RootDaemon?
    let trafficManager: TrafficManager?

    private enum CodingKeys: String, CodingKey {
        case userDaemon = "user_daemon"
        case rootDaemon = "root_daemon"
        case trafficManager = "traffic_manager"
    }

    struct UserDaemon: Decodable, Sendable {
        let running: Bool?
        let status: String?
        let version: String?
        let name: String?
        let kubernetesServer: String?
        let kubernetesContext: String?
        let namespace: String?
        let managerNamespace: String?
        let mappedNamespaces: [String]?

        private enum CodingKeys: String, CodingKey {
            case running
            case status
            case version
            case name
            case kubernetesServer = "kubernetes_server"
            case kubernetesContext = "kubernetes_context"
            case namespace
            case managerNamespace = "manager_namespace"
            case mappedNamespaces = "mapped_namespaces"
        }
    }

    struct RootDaemon: Decodable, Sendable {
        let running: Bool?
        let version: String?
        let subnets: [String]?
        let dns: DNS?

        struct DNS: Decodable, Sendable {
            let error: String?
            let localAddresses: [String]?
            let includeSuffixes: [String]?

            private enum CodingKeys: String, CodingKey {
                case error
                case localAddresses = "local_addresses"
                case includeSuffixes = "include_suffixes"
            }
        }
    }

    struct TrafficManager: Decodable, Sendable {
        let name: String?
        let version: String?
    }
}

enum DiagnosticsComponentState: Sendable {
    case healthy
    case warning
    case error
    case inactive
    case unavailable
}

struct DiagnosticsHealthCard: Identifiable, Sendable {
    let id: String
    let title: String
    let value: String
    let state: DiagnosticsComponentState
}

struct DiagnosticsHealthSnapshot: Sendable {
    let status: TelepresenceDiagnosticsStatus?
    let telepresenceUnavailable: Bool
    let unavailableReason: String?
    let connectedSince: Date?
}

struct TelepresenceDiagnosticsFetchResult: Sendable {
    let status: TelepresenceDiagnosticsStatus?
    let telepresenceUnavailable: Bool
    let unavailableReason: String?
}
