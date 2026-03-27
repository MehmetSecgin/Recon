import Foundation

actor NamespaceDiscoveryService {
    private let environmentResolver: CommandEnvironmentResolver
    private let targetResolver: KubeTargetResolver
    private let settingsStore: AppSettingsStore
    private var cachedAvailableNamespacesByContext: [String: [String]] = [:]

    init(
        environmentResolver: CommandEnvironmentResolver,
        targetResolver: KubeTargetResolver,
        settingsStore: AppSettingsStore
    ) {
        self.environmentResolver = environmentResolver
        self.targetResolver = targetResolver
        self.settingsStore = settingsStore
    }

    func fetchAvailable(for context: String) async -> NamespaceListResult {
        let resolvedMetadata = await targetResolver.resolveTargetMetadata()
        let kubeconfigDefault = resolvedMetadata.kubeconfigDefaultNamespace ?? "default"
        let currentOverride = await MainActor.run { settingsStore.override(for: context) }
        let recentlyUsed = await MainActor.run { settingsStore.recentNamespaces(for: context) }

        if let cachedAvailable = cachedAvailableNamespacesByContext[context] {
            return NamespaceListResult(
                available: cachedAvailable,
                recentlyUsed: recentlyUsed,
                kubeconfigDefault: kubeconfigDefault,
                currentOverride: currentOverride,
                clusterQueryFailed: false
            )
        }

        guard let kubectl = await environmentResolver.resolveExecutable(
            named: "kubectl",
            envKey: "KUBECTL_PATH",
            wellKnownPaths: [
                "/usr/local/bin/kubectl",
                "/opt/homebrew/bin/kubectl",
                "/usr/bin/kubectl"
            ]
        ) else {
            return NamespaceListResult(
                available: [],
                recentlyUsed: recentlyUsed,
                kubeconfigDefault: kubeconfigDefault,
                currentOverride: currentOverride,
                clusterQueryFailed: true
            )
        }

        do {
            let result = try await ProcessRunner.run(
                executable: kubectl,
                arguments: ["get", "namespaces", "-o", "jsonpath={.items[*].metadata.name}"],
                environment: await environmentResolver.executionEnvironment(),
                timeout: .seconds(5)
            )

            guard result.exitCode == 0 else {
                return NamespaceListResult(
                    available: [],
                    recentlyUsed: recentlyUsed,
                    kubeconfigDefault: kubeconfigDefault,
                    currentOverride: currentOverride,
                    clusterQueryFailed: true
                )
            }

            let available = result.stdout
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter { $0.isEmpty == false }

            let deduplicatedAvailable = deduplicated(namespaces: available + [kubeconfigDefault])
            cachedAvailableNamespacesByContext[context] = deduplicatedAvailable

            return NamespaceListResult(
                available: deduplicatedAvailable,
                recentlyUsed: recentlyUsed,
                kubeconfigDefault: kubeconfigDefault,
                currentOverride: currentOverride,
                clusterQueryFailed: false
            )
        } catch {
            return NamespaceListResult(
                available: [],
                recentlyUsed: recentlyUsed,
                kubeconfigDefault: kubeconfigDefault,
                currentOverride: currentOverride,
                clusterQueryFailed: true
            )
        }
    }

    func recentNamespaces(for context: String) async -> [String] {
        await MainActor.run {
            settingsStore.recentNamespaces(for: context)
        }
    }

    func clearSessionCache() {
        cachedAvailableNamespacesByContext.removeAll()
    }

    private func deduplicated(namespaces: [String]) -> [String] {
        namespaces.reduce(into: [String]()) { result, namespace in
            let trimmedNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedNamespace.isEmpty == false, result.contains(trimmedNamespace) == false else {
                return
            }

            result.append(trimmedNamespace)
        }
    }
}
