import Foundation

struct CommandOutcome {
    let success: Bool
    let summary: String
    let details: String?
    let logPaths: [String]
}

struct TelepresenceStatusSnapshot {
    enum State: String {
        case connected
        case disconnected
        case unavailable
        case busy
        case error
    }

    let state: State
    let statusText: String
    let detailText: String
    let context: String?
    let connectionName: String?
    let namespace: String?
    let lastUpdated: Date

    static func busy(_ detailText: String) -> TelepresenceStatusSnapshot {
        TelepresenceStatusSnapshot(
            state: .busy,
            statusText: "Working",
            detailText: detailText,
            context: nil,
            connectionName: nil,
            namespace: nil,
            lastUpdated: .now
        )
    }
}

actor TelepresenceCLI {
    private struct StatusResponse: Decodable {
        let root_daemon: DaemonStatus?
        let user_daemon: UserDaemonStatus?
    }

    private struct DaemonStatus: Decodable {
        let running: Bool?
        let version: String?
    }

    private struct UserDaemonStatus: Decodable {
        let running: Bool?
        let status: String?
        let kubernetes_context: String?
        let connection_name: String?
        let namespace: String?
    }

    private struct CommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var combinedOutput: String {
            [stdout, stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    private enum ShellCommand {
        case loginEnvironment
    }

    private var cachedKubeconfig: String?
    private var cachedShellPath: String?

    func currentKubeconfigPath() async -> String? {
        await resolvedKubeconfig()
    }

    func setKubeconfigPath(_ path: String?) {
        let normalizedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedKubeconfig = normalizedPath?.isEmpty == false ? normalizedPath : nil

        if let cachedKubeconfig {
            setenv("KUBECONFIG", cachedKubeconfig, 1)
        } else {
            unsetenv("KUBECONFIG")
        }
    }

    func fetchStatus() async -> TelepresenceStatusSnapshot {
        guard let executable = resolveExecutable() else {
            return TelepresenceStatusSnapshot(
                state: .unavailable,
                statusText: "Telepresence not found",
                detailText: "Install Telepresence or set TELEPRESENCE_PATH.",
                context: nil,
                connectionName: nil,
                namespace: nil,
                lastUpdated: .now
            )
        }

        do {
            let result = try await runProcess(
                executable: executable,
                arguments: ["status", "--output", "json"],
                environment: await executionEnvironment()
            )
            guard result.exitCode == 0 else {
                return makeDisconnectedSnapshot(output: result.combinedOutput)
            }

            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stdout.isEmpty else {
                return makeDisconnectedSnapshot(output: result.combinedOutput)
            }

            let data = Data(stdout.utf8)
            let response = try JSONDecoder().decode(StatusResponse.self, from: data)
            let userDaemon = response.user_daemon
            let stateText = userDaemon?.status ?? "Disconnected"
            let normalizedStatus = stateText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isConnected = normalizedStatus == "connected" || normalizedStatus.hasPrefix("connected ")
            let state: TelepresenceStatusSnapshot.State = isConnected ? .connected : .disconnected
            let detailText: String

            if state == .connected {
                detailText = "Connected"
            } else if userDaemon?.running == true || response.root_daemon?.running == true {
                detailText = "Daemons are running, but there is no active cluster connection."
            } else {
                detailText = "Telepresence is not connected."
            }

            return TelepresenceStatusSnapshot(
                state: state,
                statusText: stateText,
                detailText: detailText,
                context: userDaemon?.kubernetes_context,
                connectionName: userDaemon?.connection_name,
                namespace: userDaemon?.namespace,
                lastUpdated: .now
            )
        } catch {
            return TelepresenceStatusSnapshot(
                state: .error,
                statusText: "Status check failed",
                detailText: error.localizedDescription,
                context: nil,
                connectionName: nil,
                namespace: nil,
                lastUpdated: .now
            )
        }
    }

    func connect() async -> CommandOutcome {
        let connectArguments = await connectArguments()
        return await runCommand(arguments: connectArguments, successSummary: "Telepresence connected.")
    }

    func reconnect() async -> CommandOutcome {
        guard let executable = resolveExecutable() else {
            return CommandOutcome(
                success: false,
                summary: "Telepresence executable was not found.",
                details: "Install Telepresence or set TELEPRESENCE_PATH.",
                logPaths: []
            )
        }

        do {
            let environment = await executionEnvironment()
            let quitResult = try await runProcess(
                executable: executable,
                arguments: ["quit", "--stop-daemons"],
                environment: environment
            )
            if quitResult.exitCode != 0 {
                let output = quitResult.combinedOutput
                if !output.lowercased().contains("not") {
                    return CommandOutcome(
                        success: false,
                        summary: "Telepresence quit failed.",
                        details: output.isEmpty ? "The quit command exited with code \(quitResult.exitCode)." : output,
                        logPaths: extractLogPaths(from: output)
                    )
                }
            }

            let connectResult = try await runProcess(
                executable: executable,
                arguments: await connectArguments(),
                environment: environment
            )
            guard connectResult.exitCode == 0 else {
                return makeFailureOutcome(
                    summary: "Reconnect failed.",
                    fallbackVerb: "connect",
                    result: connectResult
                )
            }

            return CommandOutcome(
                success: true,
                summary: "Telepresence reconnected.",
                details: connectResult.combinedOutput.nilIfEmpty,
                logPaths: []
            )
        } catch {
            return CommandOutcome(
                success: false,
                summary: "Reconnect failed.",
                details: error.localizedDescription,
                logPaths: []
            )
        }
    }

    func disconnect() async -> CommandOutcome {
        await runCommand(arguments: ["quit"], successSummary: "Telepresence disconnected.")
    }

    private func connectArguments() async -> [String] {
        var arguments = ["connect"]
        if let context = await currentKubernetesContext() {
            arguments.append(contentsOf: ["--context", context])
        }
        return arguments
    }

    private func currentKubernetesContext() async -> String? {
        guard let kubectl = resolveKubectlExecutable() else {
            return nil
        }

        do {
            let result = try await runProcess(
                executable: kubectl,
                arguments: ["config", "current-context"],
                environment: await executionEnvironment()
            )
            guard result.exitCode == 0 else {
                return nil
            }

            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        } catch {
            return nil
        }
    }

    private func runCommand(arguments: [String], successSummary: String) async -> CommandOutcome {
        guard let executable = resolveExecutable() else {
            return CommandOutcome(
                success: false,
                summary: "Telepresence executable was not found.",
                details: "Install Telepresence or set TELEPRESENCE_PATH.",
                logPaths: []
            )
        }

        do {
            let result = try await runProcess(
                executable: executable,
                arguments: arguments,
                environment: await executionEnvironment()
            )
            guard result.exitCode == 0 else {
                return makeFailureOutcome(
                    summary: "Telepresence \(arguments.joined(separator: " ")) failed.",
                    fallbackVerb: arguments.joined(separator: " "),
                    result: result
                )
            }

            return CommandOutcome(
                success: true,
                summary: successSummary,
                details: result.combinedOutput.nilIfEmpty,
                logPaths: []
            )
        } catch {
            return CommandOutcome(
                success: false,
                summary: "Telepresence \(arguments.joined(separator: " ")) failed.",
                details: error.localizedDescription,
                logPaths: []
            )
        }
    }

    private func makeFailureOutcome(summary: String, fallbackVerb: String, result: CommandResult) -> CommandOutcome {
        let output = result.combinedOutput
        let details = summarizeFailureOutput(output).nilIfEmpty ?? "The \(fallbackVerb) command exited with code \(result.exitCode)."
        return CommandOutcome(
            success: false,
            summary: summary,
            details: details,
            logPaths: extractLogPaths(from: output)
        )
    }

    private func summarizeFailureOutput(_ output: String) -> String {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let meaningfulLines = lines.filter { line in
            !line.hasPrefix("Launching Telepresence User Daemon") &&
            !line.hasPrefix("See logs for details") &&
            !line.hasPrefix("If you think you have encountered a bug")
        }

        if let rpcLine = meaningfulLines.first(where: { $0.localizedCaseInsensitiveContains("rpc error") }) {
            return cleanupErrorLine(rpcLine)
        }

        if let errorLine = meaningfulLines.first(where: { $0.localizedCaseInsensitiveContains("error") }) {
            return cleanupErrorLine(errorLine)
        }

        return meaningfulLines.prefix(2).joined(separator: "\n")
    }

    private func cleanupErrorLine(_ line: String) -> String {
        let prefixes = [
            "telepresence connect: error:",
            "telepresence quit: error:",
            "telepresence reconnect: error:"
        ]

        for prefix in prefixes where line.lowercased().hasPrefix(prefix) {
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return line
    }

    private func extractLogPaths(from output: String) -> [String] {
        let pattern = #""(/[^"]+\.log)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsOutput = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: nsOutput.length))
        var seen = Set<String>()

        return matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let path = nsOutput.substring(with: match.range(at: 1))
            guard seen.insert(path).inserted else { return nil }
            return path
        }
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        async let stdoutRead = stdoutPipe.fileHandleForReading.readToEnd()
        async let stderrRead = stderrPipe.fileHandleForReading.readToEnd()
        try process.run()
        let terminationStatus = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
        let stdoutData = try await stdoutRead ?? Data()
        let stderrData = try await stderrRead ?? Data()
        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)

        return CommandResult(
            exitCode: terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    private func executionEnvironment() async -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        if let shellPath = await resolvedShellPath() {
            environment["PATH"] = shellPath
        }

        if let kubeconfig = await resolvedKubeconfig() {
            environment["KUBECONFIG"] = kubeconfig
        }

        return environment
    }

    private func resolvedKubeconfig() async -> String? {
        if let cachedKubeconfig {
            return cachedKubeconfig
        }

        if let kubeconfig = ProcessInfo.processInfo.environment["KUBECONFIG"]?.nilIfEmpty {
            cachedKubeconfig = kubeconfig
            return kubeconfig
        }

        if let shellKubeconfig = await loginShellEnvironmentValue(named: "KUBECONFIG")?.nilIfEmpty {
            cachedKubeconfig = shellKubeconfig
            return shellKubeconfig
        }

        let defaultKubeconfig = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kube/config")
            .path

        if FileManager.default.fileExists(atPath: defaultKubeconfig) {
            cachedKubeconfig = defaultKubeconfig
            return defaultKubeconfig
        }

        return nil
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
            let result = try await runProcess(
                executable: shell,
                arguments: shellCommandArguments(for: .loginEnvironment)
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

    private func resolveExecutable() -> String? {
        resolveExecutable(
            named: "telepresence",
            envKey: "TELEPRESENCE_PATH",
            wellKnownPaths: [
                "/usr/local/bin/telepresence",
                "/opt/homebrew/bin/telepresence",
                "/usr/bin/telepresence"
            ]
        )
    }

    private func resolveKubectlExecutable() -> String? {
        resolveExecutable(
            named: "kubectl",
            envKey: "KUBECTL_PATH",
            wellKnownPaths: [
                "/usr/local/bin/kubectl",
                "/opt/homebrew/bin/kubectl",
                "/usr/bin/kubectl"
            ]
        )
    }

    private func resolveExecutable(named name: String, envKey: String, wellKnownPaths: [String]) -> String? {
        let fileManager = FileManager.default
        let candidates = ([ProcessInfo.processInfo.environment[envKey]] + wellKnownPaths)
            .compactMap { $0 }

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for directory in pathEntries {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private func shellCommandArguments(for command: ShellCommand) -> [String] {
        switch command {
        case .loginEnvironment:
            return ["-lc", "env"]
        }
    }

    private func makeDisconnectedSnapshot(output: String) -> TelepresenceStatusSnapshot {
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = normalized.isEmpty ? "Telepresence is not connected." : normalized

        return TelepresenceStatusSnapshot(
            state: .disconnected,
            statusText: "Disconnected",
            detailText: detail,
            context: nil,
            connectionName: nil,
            namespace: nil,
            lastUpdated: .now
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
