import Foundation

enum KubeResourceReadError: LocalizedError {
    case kubectlNotFound
    case timedOut
    case commandFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .kubectlNotFound:
            return "kubectl was not found."
        case .timedOut:
            return "Request timed out. The cluster may be unreachable."
        case .commandFailed(let message):
            return message
        case .invalidResponse(let message):
            return message
        }
    }
}

actor KubeResourceService {
    private struct ResourceListResponse<Item: Decodable>: Decodable {
        let items: [Item]
    }

    private struct PodListItem: Decodable {
        struct Metadata: Decodable {
            let name: String
            let namespace: String?
            let creationTimestamp: Date?
        }

        struct Status: Decodable {
            struct ContainerStatus: Decodable {
                struct ContainerState: Decodable {
                    struct WaitingState: Decodable {
                        let reason: String?
                    }

                    let waiting: WaitingState?
                }

                let ready: Bool?
                let restartCount: Int?
                let state: ContainerState?
            }

            let phase: PodPhase?
            let containerStatuses: [ContainerStatus]?
        }

        let metadata: Metadata
        let status: Status?
    }

    private struct DeploymentListItem: Decodable {
        struct Metadata: Decodable {
            let name: String
            let namespace: String?
            let creationTimestamp: Date?
        }

        struct Spec: Decodable {
            let replicas: Int?
        }

        struct Status: Decodable {
            let readyReplicas: Int?
            let updatedReplicas: Int?
            let availableReplicas: Int?
        }

        let metadata: Metadata
        let spec: Spec?
        let status: Status?
    }

    private struct ServiceListItem: Decodable {
        struct Metadata: Decodable {
            let name: String
            let namespace: String?
            let creationTimestamp: Date?
        }

        struct Spec: Decodable {
            struct Port: Decodable {
                let name: String?
                let port: UInt16
                let `protocol`: String?
            }

            let type: String?
            let clusterIP: String?
            let ports: [Port]?
        }

        let metadata: Metadata
        let spec: Spec?
    }

    private let browserConfigService: BrowserConfigService
    private let decoder: JSONDecoder

    init(browserConfigService: BrowserConfigService) {
        self.browserConfigService = browserConfigService

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)

            if let date = KubernetesTimestampParser.parse(rawValue) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Kubernetes timestamp: \(rawValue)"
            )
        }
        self.decoder = decoder
    }

    func fetchPods(target: BrowserTarget) async throws -> [PodResource] {
        let items: [PodListItem] = try await fetchItems(resource: "pods", target: target)

        return mapPods(items, namespace: target.namespace)
    }

    func fetchDeployments(target: BrowserTarget) async throws -> [DeploymentResource] {
        let items: [DeploymentListItem] = try await fetchItems(resource: "deployments", target: target)

        return mapDeployments(items, namespace: target.namespace)
    }

    func fetchServices(target: BrowserTarget) async throws -> [ServiceResource] {
        let items: [ServiceListItem] = try await fetchItems(resource: "services", target: target)

        return mapServices(items, namespace: target.namespace)
    }

    func fetchConfigMaps(target: BrowserTarget) async throws -> [ConfigMapResource] {
        let data = try await fetchJSON(resource: "configmaps", target: target)
        return try ConfigMapResourceDecoder.decode(from: data, defaultNamespace: target.namespace)
    }

    func decodeConfigMaps(from data: Data, namespace: String) throws -> [ConfigMapResource] {
        try ConfigMapResourceDecoder.decode(from: data, defaultNamespace: namespace)
    }

    private func mapPods(_ items: [PodListItem], namespace: String) -> [PodResource] {
        items.map { item in
            let namespaceName = item.metadata.namespace ?? namespace
            let containerStatuses = item.status?.containerStatuses ?? []
            let waitingReasons = containerStatuses.map { $0.state?.waiting?.reason }

            return PodResource(
                id: "pod:\(namespaceName):\(item.metadata.name)",
                name: item.metadata.name,
                namespace: namespaceName,
                phase: item.status?.phase ?? .unknown,
                statusReason: PodStatusReasonDeriver.derive(from: waitingReasons),
                readyCount: containerStatuses.reduce(0) { count, status in
                    count + ((status.ready ?? false) ? 1 : 0)
                },
                totalCount: containerStatuses.count,
                restartCount: containerStatuses.reduce(0) { count, status in
                    count + (status.restartCount ?? 0)
                },
                createdAt: item.metadata.creationTimestamp
            )
        }
    }

    private func mapDeployments(_ items: [DeploymentListItem], namespace: String) -> [DeploymentResource] {
        items.map { item in
            let namespaceName = item.metadata.namespace ?? namespace

            return DeploymentResource(
                id: "deployment:\(namespaceName):\(item.metadata.name)",
                name: item.metadata.name,
                namespace: namespaceName,
                readyReplicas: item.status?.readyReplicas ?? 0,
                desiredReplicas: item.spec?.replicas ?? 0,
                updatedReplicas: item.status?.updatedReplicas ?? 0,
                availableReplicas: item.status?.availableReplicas ?? 0,
                createdAt: item.metadata.creationTimestamp
            )
        }
    }

    private func mapServices(_ items: [ServiceListItem], namespace: String) -> [ServiceResource] {
        items.map { item in
            let namespaceName = item.metadata.namespace ?? namespace

            return ServiceResource(
                id: "service:\(namespaceName):\(item.metadata.name)",
                name: item.metadata.name,
                namespace: namespaceName,
                type: item.spec?.type ?? "ClusterIP",
                clusterIP: item.spec?.clusterIP,
                ports: (item.spec?.ports ?? []).map { port in
                    ServicePort(
                        name: port.name,
                        port: port.port,
                        protocolName: port.protocol ?? "TCP"
                    )
                },
                createdAt: item.metadata.creationTimestamp
            )
        }
    }

    private func fetchItems<Item: Decodable>(resource: String, target: BrowserTarget) async throws -> [Item] {
        let data = try await fetchJSON(resource: resource, target: target)
        do {
            return try decoder.decode(ResourceListResponse<Item>.self, from: data).items
        } catch {
            throw KubeResourceReadError.invalidResponse("Couldn't decode the cluster response.")
        }
    }

    private func fetchJSON(resource: String, target: BrowserTarget) async throws -> Data {
        do {
            let result = try await browserConfigService.executeBrowserKubectl(
                for: target.context,
                command: ["get", resource, "-n", target.namespace, "-o", "json"],
                timeout: .seconds(5)
            )

            guard result.exitCode == 0 else {
                throw KubeResourceReadError.commandFailed(
                    summarizeFailure(result.combinedOutput, fallback: "Couldn't load \(resource).")
                )
            }

            return Data(result.stdout.utf8)
        } catch let error as BrowserConfigError {
            switch error {
            case .kubectlNotFound:
                throw KubeResourceReadError.kubectlNotFound
            case .timedOut:
                throw KubeResourceReadError.timedOut
            case .commandFailed(let message):
                throw KubeResourceReadError.commandFailed(message)
            }
        } catch is ProcessRunner.TimeoutError {
            throw KubeResourceReadError.timedOut
        } catch let error as KubeResourceReadError {
            throw error
        } catch {
            throw KubeResourceReadError.commandFailed(error.localizedDescription)
        }
    }

    private func summarizeFailure(_ output: String, fallback: String) -> String {
        let firstLine = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.isEmpty == false })

        return firstLine ?? fallback
    }
}
