import Foundation

struct ResolvedKubeconfigSource: Equatable {
    let display: String
    let mode: KubeconfigMode
    let paths: [String]
}

actor CommandEnvironmentResolver {
    private let fileManager = FileManager.default
    private var kubeconfigPreferenceMode: KubeconfigPreferenceMode = .pinned
    private var pinnedKubeconfigPath: String?
    private var telepresencePathOverride: String?
    private var kubectlPathOverride: String?
    private var cachedShellPath: String?

    func apply(settings: AppSettingsStore.EnvironmentSettingsSnapshot) {
        kubeconfigPreferenceMode = settings.kubeconfigPreferenceMode
        pinnedKubeconfigPath = settings.selectedKubeconfigPath
        telepresencePathOverride = settings.telepresencePathOverride
        kubectlPathOverride = settings.kubectlPathOverride
    }

    func executionEnvironment() async -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        if let shellPath = await resolvedShellPath() {
            environment["PATH"] = shellPath
        }

        let source = await resolvedKubeconfigSource()
        if let kubeconfig = source.paths.joined(separator: ":").nilIfEmpty {
            environment["KUBECONFIG"] = kubeconfig
        } else {
            environment.removeValue(forKey: "KUBECONFIG")
        }

        return environment
    }

    func resolvedKubeconfigPaths() async -> [String] {
        await resolvedKubeconfigSource().paths
    }

    func resolvedKubeconfigSource() async -> ResolvedKubeconfigSource {
        if kubeconfigPreferenceMode == .pinned, let pinnedKubeconfigPath {
            return ResolvedKubeconfigSource(
                display: abbreviate(path: pinnedKubeconfigPath),
                mode: .pinned,
                paths: [pinnedKubeconfigPath]
            )
        }

        let inheritedPaths = await inheritedKubeconfigPaths()
        if inheritedPaths.count == 1, let path = inheritedPaths.first {
            return ResolvedKubeconfigSource(
                display: abbreviate(path: path),
                mode: .inheritedSingle,
                paths: inheritedPaths
            )
        }

        if inheritedPaths.count > 1 {
            return ResolvedKubeconfigSource(
                display: "Inherited (\(inheritedPaths.count) files)",
                mode: .inheritedMultiple(count: inheritedPaths.count),
                paths: inheritedPaths
            )
        }

        let defaultPath = defaultKubeconfigPath()
        if fileManager.fileExists(atPath: defaultPath) {
            return ResolvedKubeconfigSource(
                display: "\(abbreviate(path: defaultPath)) (default)",
                mode: .default,
                paths: [defaultPath]
            )
        }

        return ResolvedKubeconfigSource(
            display: "\u{2014}",
            mode: .unresolved,
            paths: []
        )
    }

    func resolveExecutable(named name: String, envKey: String, wellKnownPaths: [String]) async -> String? {
        let candidates = ([overridePath(for: name)] + [ProcessInfo.processInfo.environment[envKey]] + wellKnownPaths)
            .compactMap { $0?.nilIfEmpty }

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let pathEntries = await executableSearchPaths()
        for directory in pathEntries {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    func detectExecutable(named name: String, envKey: String, wellKnownPaths: [String]) async -> String? {
        let candidates = ([ProcessInfo.processInfo.environment[envKey]] + wellKnownPaths)
            .compactMap { $0?.nilIfEmpty }

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return normalize(path: candidate)
        }

        let pathEntries = await executableSearchPaths()
        for directory in pathEntries {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return normalize(path: candidate)
            }
        }

        return nil
    }

    private func inheritedKubeconfigPaths() async -> [String] {
        let processValue = ProcessInfo.processInfo.environment["KUBECONFIG"]?.nilIfEmpty
        let shellValue = await loginShellEnvironmentValue(named: "KUBECONFIG")?.nilIfEmpty

        let rawValue = processValue ?? shellValue
        guard let rawValue else {
            return []
        }

        let separator = CharacterSet(charactersIn: ":")
        return rawValue
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { $0.nilIfEmpty }
            .map { normalize(path: $0) }
            .filter { fileManager.fileExists(atPath: $0) }
    }

    private func executableSearchPaths() async -> [String] {
        let pathValue = await resolvedShellPath() ?? ProcessInfo.processInfo.environment["PATH"]?.nilIfEmpty ?? ""
        return pathValue
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func resolvedShellPath() async -> String? {
        if let cachedShellPath {
            return cachedShellPath
        }

        if let shellPath = await loginShellEnvironmentValue(named: "PATH")?.nilIfEmpty {
            cachedShellPath = shellPath
            return shellPath
        }

        return ProcessInfo.processInfo.environment["PATH"]?.nilIfEmpty
    }

    private func loginShellEnvironmentValue(named name: String) async -> String? {
        do {
            let shell = ProcessInfo.processInfo.environment["SHELL"]?.nilIfEmpty ?? "/bin/zsh"
            let result = try await ProcessRunner.run(
                executable: shell,
                arguments: ["-lc", "env"]
            )

            guard result.exitCode == 0 else {
                return nil
            }

            return result.stdout
                .components(separatedBy: .newlines)
                .first(where: { $0.hasPrefix("\(name)=") })?
                .dropFirst(name.count + 1)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func defaultKubeconfigPath() -> String {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".kube/config")
            .path
    }

    private func abbreviate(path: String) -> String {
        NSString(string: path).abbreviatingWithTildeInPath
    }

    private func overridePath(for name: String) -> String? {
        switch name {
        case "telepresence":
            return telepresencePathOverride
        case "kubectl":
            return kubectlPathOverride
        default:
            return nil
        }
    }

    private func normalize(path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
