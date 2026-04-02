import Foundation

enum ResourceType: String, CaseIterable, Hashable {
    case pods
    case deployments
    case services
    case ingresses

    var title: String {
        switch self {
        case .pods:
            return "Pods"
        case .deployments:
            return "Deployments"
        case .services:
            return "Services"
        case .ingresses:
            return "Ingresses"
        }
    }

    var singularTitle: String {
        switch self {
        case .pods:
            return "pod"
        case .deployments:
            return "deployment"
        case .services:
            return "service"
        case .ingresses:
            return "ingress"
        }
    }

    var systemImage: String {
        switch self {
        case .pods:
            return "shippingbox"
        case .deployments:
            return "square.stack.3d.up"
        case .services:
            return "point.3.connected.trianglepath.dotted"
        case .ingresses:
            return "network"
        }
    }

    var emptyStateTitle: String {
        "No \(title.lowercased())"
    }

    func emptyStateDescription(namespace: String) -> String {
        "No \(title.lowercased()) found in namespace `\(namespace)`."
    }
}

enum LoadedResources {
    case none
    case pods([PodResource])
    case deployments([DeploymentResource])
    case services([ServiceResource])
    case ingresses([IngressResource])

    var isEmpty: Bool {
        switch self {
        case .none:
            return true
        case .pods(let resources):
            return resources.isEmpty
        case .deployments(let resources):
            return resources.isEmpty
        case .services(let resources):
            return resources.isEmpty
        case .ingresses(let resources):
            return resources.isEmpty
        }
    }
}

enum PodPhase: String, Decodable, Hashable {
    case running = "Running"
    case pending = "Pending"
    case succeeded = "Succeeded"
    case failed = "Failed"
    case unknown = "Unknown"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = PodPhase(rawValue: rawValue) ?? .unknown
    }
}

struct PodResource: Identifiable, Hashable {
    let id: String
    let name: String
    let namespace: String
    let phase: PodPhase
    let readyCount: Int
    let totalCount: Int
    let restartCount: Int
    let createdAt: Date?

    var statusText: String {
        phase.rawValue
    }

    var readyText: String {
        "\(readyCount)/\(totalCount)"
    }
}

struct DeploymentResource: Identifiable, Hashable {
    let id: String
    let name: String
    let namespace: String
    let readyReplicas: Int
    let desiredReplicas: Int
    let updatedReplicas: Int
    let availableReplicas: Int
    let createdAt: Date?

    var readyText: String {
        "\(readyReplicas)/\(desiredReplicas)"
    }
}

struct ServicePort: Hashable {
    let name: String?
    let port: UInt16
    let protocolName: String

    var displayValue: String {
        let prefix = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefix, prefix.isEmpty == false {
            return "\(prefix):\(port)/\(protocolName.lowercased())"
        }

        return "\(port)/\(protocolName.lowercased())"
    }
}

struct ServiceResource: Identifiable, Hashable {
    let id: String
    let name: String
    let namespace: String
    let type: String
    let clusterIP: String?
    let ports: [ServicePort]
    let createdAt: Date?

    var portsText: String {
        if ports.isEmpty {
            return "\u{2014}"
        }

        return ports.map(\.displayValue).joined(separator: ", ")
    }
}

struct IngressResource: Identifiable, Hashable {
    let id: String
    let name: String
    let namespace: String
    let hosts: [String]
    let createdAt: Date?

    var hostsText: String {
        if hosts.isEmpty {
            return "\u{2014}"
        }

        return hosts.joined(separator: ", ")
    }
}
