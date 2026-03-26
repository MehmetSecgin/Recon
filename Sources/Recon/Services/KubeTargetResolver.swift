import Foundation

actor KubeTargetResolver {
    private struct KubectlConfigView: Decodable {
        struct ContextEntry: Decodable {
            struct ContextDetails: Decodable {
                let namespace: String?
            }

            let name: String
            let context: ContextDetails
        }

        let contexts: [ContextEntry]
    }

    private let environmentResolver: CommandEnvironmentResolver

    init(environmentResolver: CommandEnvironmentResolver) {
        self.environmentResolver = environmentResolver
    }

    func resolveTargetMetadata() async -> TargetMetadata {
        let source = await environmentResolver.resolvedKubeconfigSource()

        guard let kubectl = await environmentResolver.resolveExecutable(
            named: "kubectl",
            envKey: "KUBECTL_PATH",
            wellKnownPaths: [
                "/usr/local/bin/kubectl",
                "/opt/homebrew/bin/kubectl",
                "/usr/bin/kubectl"
            ]
        ) else {
            return TargetMetadata(
                kubeconfigDisplay: source.display,
                kubeconfigMode: source.mode,
                context: nil,
                namespace: nil,
                isLastKnown: false,
                resolutionError: "kubectl was not found."
            )
        }

        let environment = await environmentResolver.executionEnvironment()
        var context: String?
        var namespace: String?
        var resolutionError: String?

        do {
            let contextResult = try await ProcessRunner.run(
                executable: kubectl,
                arguments: ["config", "current-context"],
                environment: environment
            )

            if contextResult.exitCode == 0 {
                context = contextResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            } else {
                resolutionError = summarize(output: contextResult.combinedOutput, fallback: "Couldn't read the current context.")
            }
        } catch {
            resolutionError = error.localizedDescription
        }

        do {
            let configViewResult = try await ProcessRunner.run(
                executable: kubectl,
                arguments: ["config", "view", "--minify", "-o", "json"],
                environment: environment
            )

            if configViewResult.exitCode == 0 {
                let data = Data(configViewResult.stdout.utf8)
                let config = try JSONDecoder().decode(KubectlConfigView.self, from: data)
                if let context {
                    let activeNamespace = config.contexts
                        .first(where: { $0.name == context })?
                        .context.namespace
                    namespace = activeNamespace?.nilIfEmpty ?? "default"
                }
            } else if resolutionError == nil {
                resolutionError = summarize(output: configViewResult.combinedOutput, fallback: "Couldn't read kubeconfig details.")
            }
        } catch {
            if resolutionError == nil {
                resolutionError = error.localizedDescription
            }
        }

        if context != nil, namespace == nil {
            namespace = "default"
        }

        return TargetMetadata(
            kubeconfigDisplay: source.display,
            kubeconfigMode: source.mode,
            context: context,
            namespace: namespace,
            isLastKnown: false,
            resolutionError: resolutionError
        )
    }

    private func summarize(output: String, fallback: String) -> String {
        let summary = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })

        return summary ?? fallback
    }
}
