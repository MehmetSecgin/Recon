import Foundation

actor BrowserConfigService {
    private let settingsStore: AppSettingsStore
    private let environmentResolver: CommandEnvironmentResolver
    private let fileManager = FileManager.default
    private let kubectlFallbackPaths = [
        "/usr/local/bin/kubectl",
        "/opt/homebrew/bin/kubectl",
        "/usr/bin/kubectl"
    ]

    init(settingsStore: AppSettingsStore, environmentResolver: CommandEnvironmentResolver) {
        self.settingsStore = settingsStore
        self.environmentResolver = environmentResolver
    }

    func loadContextCatalog() async -> BrowserContextCatalog {
        await bootstrapBrowserSourcesIfNeeded()

        let sourcePaths = await MainActor.run { settingsStore.browserKubeconfigPaths }
        guard sourcePaths.isEmpty == false else {
            return BrowserContextCatalog(contexts: [], sourceStatuses: [])
        }

        guard let kubectl = await resolveKubectl() else {
            let statuses = sourcePaths.map { path in
                BrowserSourceStatus(
                    path: path,
                    statusText: "kubectl unavailable",
                    errorMessage: "kubectl was not found.",
                    contextCount: nil
                )
            }
            return BrowserContextCatalog(contexts: [], sourceStatuses: statuses)
        }

        var descriptorsByPath: [String: [BrowserContextDescriptor]] = [:]
        var sourceStatuses: [BrowserSourceStatus] = []

        for path in sourcePaths {
            guard fileManager.fileExists(atPath: path) else {
                sourceStatuses.append(
                    BrowserSourceStatus(
                        path: path,
                        statusText: "Missing",
                        errorMessage: "The kubeconfig file could not be found.",
                        contextCount: nil
                    )
                )
                continue
            }

            do {
                let result = try await runKubectl(
                    executable: kubectl,
                    arguments: [
                        "config",
                        "view",
                        "--kubeconfig",
                        path,
                        "-o",
                        #"jsonpath={range .contexts[*]}{.name}{"\t"}{.context.namespace}{"\n"}{end}"#
                    ],
                    timeout: .seconds(5),
                    metadata: ProcessRunMetadata(source: .clusterBrowser)
                )

                guard result.exitCode == 0 else {
                    sourceStatuses.append(
                        BrowserSourceStatus(
                            path: path,
                            statusText: "Invalid",
                            errorMessage: summarize(result.combinedOutput, fallback: "Couldn't read contexts from this kubeconfig."),
                            contextCount: nil
                        )
                    )
                    continue
                }

                let descriptors = KubectlConfigOutputParsing.parseContextEntries(from: result.stdout).map { entry in
                    BrowserContextDescriptor(
                        id: BrowserContextIdentity.makeID(contextName: entry.name, sourcePath: path),
                        name: entry.name,
                        sourcePath: path,
                        sourceBadge: nil,
                        defaultNamespace: entry.namespace?.nilIfEmpty,
                        isProductionLike: ProductionDetector.isProduction(context: entry.name)
                    )
                }

                descriptorsByPath[path] = descriptors
                let contextCount = descriptors.count
                sourceStatuses.append(
                    BrowserSourceStatus(
                        path: path,
                        statusText: contextCount == 1 ? "1 context" : "\(contextCount) contexts",
                        errorMessage: nil,
                        contextCount: contextCount
                    )
                )
            } catch {
                sourceStatuses.append(
                    BrowserSourceStatus(
                        path: path,
                        statusText: "Invalid",
                        errorMessage: error.localizedDescription,
                        contextCount: nil
                    )
                )
            }
        }

        let contexts = makeContexts(from: descriptorsByPath)
        return BrowserContextCatalog(
            contexts: contexts,
            sourceStatuses: sourceStatuses.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        )
    }

    func fetchNamespaces(for context: BrowserContextDescriptor) async throws -> [String] {
        guard let kubectl = await resolveKubectl() else {
            throw BrowserConfigError.kubectlNotFound
        }

        let result = try await runKubectl(
            executable: kubectl,
            arguments: browserScopedArguments(
                for: context,
                command: ["--request-timeout=5s", "get", "namespaces", "-o", "jsonpath={.items[*].metadata.name}"]
            ),
            timeout: .seconds(5),
            metadata: ProcessRunMetadata(source: .clusterBrowser, context: context.name)
        )

        guard result.exitCode == 0 else {
            throw BrowserConfigError.commandFailed(
                summarize(result.combinedOutput, fallback: "Couldn't load namespaces for \(context.name).")
            )
        }

        let available = result.stdout
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { $0.isEmpty == false }

        let combined = available + [context.defaultNamespace ?? "default"]
        return combined.reduce(into: [String]()) { result, namespace in
            let trimmedNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedNamespace.isEmpty == false,
                  result.contains(trimmedNamespace) == false else {
                return
            }

            result.append(trimmedNamespace)
        }
    }

    func executeBrowserKubectl(
        for context: BrowserContextDescriptor,
        command: [String],
        timeout: Duration = .seconds(5)
    ) async throws -> ProcessOutput {
        guard let kubectl = await resolveKubectl() else {
            throw BrowserConfigError.kubectlNotFound
        }

        return try await runKubectl(
            executable: kubectl,
            arguments: browserScopedArguments(for: context, command: command),
            timeout: timeout,
            metadata: ProcessRunMetadata(
                source: .clusterBrowser,
                context: context.name,
                namespace: commandNamespace(in: command) ?? context.defaultNamespace
            )
        )
    }

    private func bootstrapBrowserSourcesIfNeeded() async {
        let shouldBootstrap = await MainActor.run {
            settingsStore.hasExplicitBrowserKubeconfigSources == false &&
            settingsStore.browserKubeconfigPaths.isEmpty
        }

        guard shouldBootstrap else { return }
        let resolvedPaths = await environmentResolver.resolvedKubeconfigPaths()
        await MainActor.run {
            settingsStore.bootstrapBrowserKubeconfigPaths(resolvedPaths)
        }
    }

    private func resolveKubectl() async -> String? {
        await environmentResolver.resolveExecutable(
            named: "kubectl",
            envKey: "KUBECTL_PATH",
            wellKnownPaths: kubectlFallbackPaths
        )
    }

    private func runKubectl(
        executable: String,
        arguments: [String],
        timeout: Duration,
        metadata: ProcessRunMetadata
    ) async throws -> ProcessOutput {
        do {
            var environment = await environmentResolver.executionEnvironment()
            environment.removeValue(forKey: "KUBECONFIG")

            return try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: timeout,
                metadata: metadata
            )
        } catch is ProcessRunner.TimeoutError {
            throw BrowserConfigError.timedOut
        } catch let error as BrowserConfigError {
            throw error
        } catch {
            throw BrowserConfigError.commandFailed(error.localizedDescription)
        }
    }

    private func browserScopedArguments(for context: BrowserContextDescriptor, command: [String]) -> [String] {
        ["--kubeconfig", context.sourcePath, "--context", context.name] + command
    }

    private func commandNamespace(in command: [String]) -> String? {
        if let namespaceIndex = command.firstIndex(of: "--namespace"),
           command.indices.contains(namespaceIndex + 1) {
            return command[namespaceIndex + 1].nilIfEmpty
        }

        if let namespaceIndex = command.firstIndex(of: "-n"),
           command.indices.contains(namespaceIndex + 1) {
            return command[namespaceIndex + 1].nilIfEmpty
        }

        return nil
    }

    private func makeContexts(from descriptorsByPath: [String: [BrowserContextDescriptor]]) -> [BrowserContextDescriptor] {
        let allDescriptors = descriptorsByPath.values.flatMap { $0 }
        let groupedByName = Dictionary(grouping: allDescriptors, by: \.name)

        return allDescriptors
            .map { descriptor in
                let sameNameDescriptors = groupedByName[descriptor.name] ?? [descriptor]
                guard sameNameDescriptors.count > 1 else {
                    return descriptor
                }

                let baseName = URL(fileURLWithPath: descriptor.sourcePath).lastPathComponent
                let baseNameCollision = sameNameDescriptors
                    .map { URL(fileURLWithPath: $0.sourcePath).lastPathComponent }
                    .filter { $0 == baseName }
                    .count > 1

                return BrowserContextDescriptor(
                    id: descriptor.id,
                    name: descriptor.name,
                    sourcePath: descriptor.sourcePath,
                    sourceBadge: baseNameCollision ? NSString(string: descriptor.sourcePath).abbreviatingWithTildeInPath : baseName,
                    defaultNamespace: descriptor.defaultNamespace,
                    isProductionLike: descriptor.isProductionLike
                )
            }
            .sorted { lhs, rhs in
                let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }

                return lhs.sourcePath.localizedStandardCompare(rhs.sourcePath) == .orderedAscending
            }
    }

    private func summarize(_ output: String, fallback: String) -> String {
        let summary = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.isEmpty == false })

        return summary ?? fallback
    }
}

enum BrowserConfigError: LocalizedError {
    case kubectlNotFound
    case timedOut
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .kubectlNotFound:
            return "kubectl was not found."
        case .timedOut:
            return "Request timed out. The cluster may be unreachable."
        case .commandFailed(let message):
            return message
        }
    }
}
