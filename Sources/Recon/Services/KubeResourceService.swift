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
    private let browserConfigService: BrowserConfigService

    init(browserConfigService: BrowserConfigService) {
        self.browserConfigService = browserConfigService
    }

    func fetchPods(target: BrowserTarget) async throws -> [PodResource] {
        try await fetchList(
            resource: "pods",
            target: target,
            parser: { try KubectlTableParser.parsePods(from: $0, namespace: target.namespace) }
        )
    }

    func fetchDeployments(target: BrowserTarget) async throws -> [DeploymentResource] {
        try await fetchList(
            resource: "deployments",
            target: target,
            parser: { try KubectlTableParser.parseDeployments(from: $0, namespace: target.namespace) }
        )
    }

    func fetchServices(target: BrowserTarget) async throws -> [ServiceResource] {
        try await fetchList(
            resource: "services",
            target: target,
            parser: { try KubectlTableParser.parseServices(from: $0, namespace: target.namespace) }
        )
    }

    func fetchConfigMaps(target: BrowserTarget) async throws -> [ConfigMapResource] {
        try await fetchList(
            resource: "configmaps",
            target: target,
            parser: { try KubectlTableParser.parseConfigMaps(from: $0, namespace: target.namespace) }
        )
    }

    private func fetchList<T>(
        resource: String,
        target: BrowserTarget,
        parser: (String) throws -> [T]
    ) async throws -> [T] {
        do {
            let result = try await browserConfigService.executeBrowserKubectl(
                for: target.context,
                command: [
                    "--request-timeout=5s",
                    "get",
                    resource,
                    "-n",
                    target.namespace,
                    "--chunk-size=200",
                    "--no-headers"
                ],
                timeout: .seconds(5)
            )

            guard result.exitCode == 0 else {
                throw KubeResourceReadError.commandFailed(
                    summarizeFailure(result.combinedOutput, fallback: "Couldn't load \(resource).")
                )
            }

            do {
                return try parser(result.stdout)
            } catch {
                throw KubeResourceReadError.invalidResponse("Couldn't decode the cluster response.")
            }
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
