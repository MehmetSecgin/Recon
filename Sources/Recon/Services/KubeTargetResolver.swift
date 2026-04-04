import Foundation

actor KubeTargetResolver {
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
                kubeconfigDefaultNamespace: nil,
                isLastKnown: false,
                resolutionError: "kubectl was not found."
            )
        }

        let environment = await environmentResolver.executionEnvironment()
        var context: String?
        var namespace: String?
        var resolutionError: String?

        do {
            let configViewResult = try await ProcessRunner.run(
                executable: kubectl,
                arguments: [
                    "config",
                    "view",
                    "--minify",
                    "-o",
                    #"jsonpath={.current-context}{"\t"}{.contexts[0].context.namespace}"#
                ],
                environment: environment,
                metadata: ProcessRunMetadata(source: .kubeTargetResolution)
            )

            if configViewResult.exitCode == 0 {
                let fields = KubectlConfigOutputParsing.parseTargetFields(from: configViewResult.stdout)
                context = fields.context
                namespace = fields.namespace?.nilIfEmpty
            } else {
                resolutionError = summarize(output: configViewResult.combinedOutput, fallback: "Couldn't read kubeconfig details.")
            }
        } catch {
            resolutionError = error.localizedDescription
        }

        if context != nil, namespace == nil {
            namespace = "default"
        }

        return TargetMetadata(
            kubeconfigDisplay: source.display,
            kubeconfigMode: source.mode,
            context: context,
            namespace: namespace,
            kubeconfigDefaultNamespace: namespace,
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
