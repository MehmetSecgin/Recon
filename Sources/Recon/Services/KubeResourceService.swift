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

    private struct IngressListItem: Decodable {
        struct Metadata: Decodable {
            let name: String
            let namespace: String?
            let creationTimestamp: Date?
        }

        struct Spec: Decodable {
            struct Rule: Decodable {
                let host: String?
            }

            let rules: [Rule]?
        }

        let metadata: Metadata
        let spec: Spec?
    }

    private let environmentResolver: CommandEnvironmentResolver
    private let decoder: JSONDecoder
    private let kubectlFallbackPaths = [
        "/usr/local/bin/kubectl",
        "/opt/homebrew/bin/kubectl",
        "/usr/bin/kubectl"
    ]

    init(environmentResolver: CommandEnvironmentResolver) {
        self.environmentResolver = environmentResolver

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)

            if let date = Self.parseKubernetesTimestamp(rawValue) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Kubernetes timestamp: \(rawValue)"
            )
        }
        self.decoder = decoder
    }

    func fetchPods(namespace: String) async throws -> [PodResource] {
        let items: [PodListItem] = try await fetchItems(resource: "pods", namespace: namespace)

        return items.map { item in
            let namespaceName = item.metadata.namespace ?? namespace
            let containerStatuses = item.status?.containerStatuses ?? []

            return PodResource(
                id: "pod:\(namespaceName):\(item.metadata.name)",
                name: item.metadata.name,
                namespace: namespaceName,
                phase: item.status?.phase ?? .unknown,
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

    func fetchDeployments(namespace: String) async throws -> [DeploymentResource] {
        let items: [DeploymentListItem] = try await fetchItems(resource: "deployments", namespace: namespace)

        return items.map { item in
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

    func fetchServices(namespace: String) async throws -> [ServiceResource] {
        let items: [ServiceListItem] = try await fetchItems(resource: "services", namespace: namespace)

        return items.map { item in
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

    func fetchIngresses(namespace: String) async throws -> [IngressResource] {
        let items: [IngressListItem] = try await fetchItems(resource: "ingresses", namespace: namespace)

        return items.map { item in
            let namespaceName = item.metadata.namespace ?? namespace
            let hosts = (item.spec?.rules ?? [])
                .compactMap(\.host)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }

            return IngressResource(
                id: "ingress:\(namespaceName):\(item.metadata.name)",
                name: item.metadata.name,
                namespace: namespaceName,
                hosts: hosts,
                createdAt: item.metadata.creationTimestamp
            )
        }
    }

    private func fetchItems<Item: Decodable>(resource: String, namespace: String) async throws -> [Item] {
        let kubectl = await environmentResolver.resolveExecutable(
            named: "kubectl",
            envKey: "KUBECTL_PATH",
            wellKnownPaths: kubectlFallbackPaths
        )

        guard let kubectl else {
            throw KubeResourceReadError.kubectlNotFound
        }

        do {
            let result = try await ProcessRunner.run(
                executable: kubectl,
                arguments: ["get", resource, "-n", namespace, "-o", "json"],
                environment: await environmentResolver.executionEnvironment(),
                timeout: .seconds(5)
            )

            guard result.exitCode == 0 else {
                throw KubeResourceReadError.commandFailed(
                    summarizeFailure(result.combinedOutput, fallback: "Couldn't load \(resource).")
                )
            }

            let data = Data(result.stdout.utf8)
            do {
                return try decoder.decode(ResourceListResponse<Item>.self, from: data).items
            } catch {
                throw KubeResourceReadError.invalidResponse("Couldn't decode the cluster response.")
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

    private static func parseKubernetesTimestamp(_ rawValue: String) -> Date? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]

        let withoutFractionalSeconds = ISO8601DateFormatter()
        withoutFractionalSeconds.formatOptions = [.withInternetDateTime]

        return withFractionalSeconds.date(from: rawValue) ?? withoutFractionalSeconds.date(from: rawValue)
    }
}
