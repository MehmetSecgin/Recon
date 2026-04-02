import Foundation

enum ResourceType: String, CaseIterable, Hashable {
    case pods
    case deployments
    case services
    case configMaps

    var title: String {
        switch self {
        case .pods:
            return "Pods"
        case .deployments:
            return "Deployments"
        case .services:
            return "Services"
        case .configMaps:
            return "ConfigMaps"
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
        case .configMaps:
            return "configmap"
        }
    }

    var pluralTitleForStatusBar: String {
        switch self {
        case .pods:
            return "pods"
        case .deployments:
            return "deployments"
        case .services:
            return "services"
        case .configMaps:
            return "configmaps"
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
        case .configMaps:
            return "switch.2"
        }
    }

    var emptyStateTitle: String {
        "No \(pluralTitleForStatusBar)"
    }

    func emptyStateDescription(namespace: String) -> String {
        "No \(pluralTitleForStatusBar) found in namespace `\(namespace)`."
    }
}

enum LoadedResources {
    case none
    case pods([PodResource])
    case deployments([DeploymentResource])
    case services([ServiceResource])
    case configMaps([ConfigMapResource])

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
        case .configMaps(let resources):
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

enum ResourceHealthBucket: Int, Comparable, Hashable {
    case unhealthy = 0
    case transitional = 1
    case healthy = 2
    case neutral = 3

    static func < (lhs: ResourceHealthBucket, rhs: ResourceHealthBucket) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct PodResource: Identifiable, Hashable {
    let id: String
    let name: String
    let namespace: String
    let phase: PodPhase
    let statusReason: String?
    let readyCount: Int
    let totalCount: Int
    let restartCount: Int
    let createdAt: Date?

    var displayStatusText: String {
        statusReason ?? phase.rawValue
    }

    var readyText: String {
        "\(readyCount)/\(totalCount)"
    }

    var healthBucket: ResourceHealthBucket {
        if phase == .succeeded {
            return .neutral
        }

        if phase == .failed || statusReason == "CrashLoopBackOff" || statusReason == "CreateContainerConfigError" {
            return .unhealthy
        }

        if statusReason == "ImagePullBackOff" || phase == .pending || phase == .unknown {
            return .transitional
        }

        if phase == .running, statusReason == nil, totalCount > 0, readyCount == totalCount {
            return .healthy
        }

        if readyCount < totalCount {
            return .transitional
        }

        return .healthy
    }

    var statusSortValue: Int {
        healthBucket.rawValue
    }

    var readySortValue: Double {
        guard totalCount > 0 else {
            return readyCount > 0 ? 1 : 0
        }

        return Double(readyCount) / Double(totalCount)
    }

    var ageSortValue: Date {
        createdAt ?? .distantPast
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

    var healthBucket: ResourceHealthBucket {
        if desiredReplicas == 0 {
            return .neutral
        }

        if availableReplicas == 0 {
            return .unhealthy
        }

        if readyReplicas == desiredReplicas,
           updatedReplicas == desiredReplicas,
           availableReplicas == desiredReplicas {
            return .healthy
        }

        return .transitional
    }

    var defaultHealthSortValue: Int {
        healthBucket.rawValue
    }

    var readySortValue: Double {
        guard desiredReplicas > 0 else {
            return readyReplicas > 0 ? 1 : 0
        }

        return Double(readyReplicas) / Double(desiredReplicas)
    }

    var ageSortValue: Date {
        createdAt ?? .distantPast
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
            return "-"
        }

        return ports.map(\.displayValue).joined(separator: ", ")
    }

    var clusterIPSortValue: String {
        clusterIP ?? ""
    }

    var ageSortValue: Date {
        createdAt ?? .distantPast
    }
}

struct ConfigMapResource: Identifiable, Hashable {
    let id: String
    let name: String
    let namespace: String
    let dataKeyCount: Int
    let isImmutable: Bool
    let createdAt: Date?

    var immutableText: String {
        isImmutable ? "Yes" : "No"
    }

    var immutableSortValue: Int {
        isImmutable ? 1 : 0
    }

    var ageSortValue: Date {
        createdAt ?? .distantPast
    }
}

enum ClusterBrowserInspectCommandBuilder {
    static func pod(name: String, namespace: String) -> String {
        "kubectl get pod \(name) -n \(namespace)"
    }

    static func deployment(name: String, namespace: String) -> String {
        "kubectl get deployment \(name) -n \(namespace)"
    }

    static func service(name: String, namespace: String) -> String {
        "kubectl get service \(name) -n \(namespace)"
    }

    static func configMap(name: String, namespace: String) -> String {
        "kubectl get configmap \(name) -n \(namespace)"
    }
}
