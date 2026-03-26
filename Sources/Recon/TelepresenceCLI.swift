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
    let lastUpdated: Date

    static func busy(_ detailText: String) -> TelepresenceStatusSnapshot {
        TelepresenceStatusSnapshot(
            state: .busy,
            statusText: "Working",
            detailText: detailText,
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
    }

    private let environmentResolver: CommandEnvironmentResolver

    init(environmentResolver: CommandEnvironmentResolver = CommandEnvironmentResolver()) {
        self.environmentResolver = environmentResolver
    }

    func setKubeconfigPath(_ path: String?) async {
        await environmentResolver.setPinnedKubeconfigPath(path)
    }

    func fetchStatus() async -> TelepresenceStatusSnapshot {
        guard let executable = await resolveExecutable() else {
            return TelepresenceStatusSnapshot(
                state: .unavailable,
                statusText: "Telepresence not found",
                detailText: "Install Telepresence or set TELEPRESENCE_PATH.",
                lastUpdated: .now
            )
        }

        do {
            let result = try await ProcessRunner.run(
                executable: executable,
                arguments: ["status", "--output", "json"],
                environment: await environmentResolver.executionEnvironment()
            )

            guard result.exitCode == 0 else {
                return makeDisconnectedSnapshot(output: result.combinedOutput)
            }

            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stdout.isEmpty else {
                return makeDisconnectedSnapshot(output: result.combinedOutput)
            }

            let response = try JSONDecoder().decode(StatusResponse.self, from: Data(stdout.utf8))
            let stateText = response.user_daemon?.status ?? "Disconnected"
            let normalizedStatus = stateText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isConnected = normalizedStatus == "connected" || normalizedStatus.hasPrefix("connected ")
            let state: TelepresenceStatusSnapshot.State = isConnected ? .connected : .disconnected
            let detailText: String

            if state == .connected {
                detailText = "Connected"
            } else if response.user_daemon?.running == true || response.root_daemon?.running == true {
                detailText = "Daemons are running, but there is no active cluster connection."
            } else {
                detailText = "Telepresence is not connected."
            }

            return TelepresenceStatusSnapshot(
                state: state,
                statusText: stateText,
                detailText: detailText,
                lastUpdated: .now
            )
        } catch {
            return TelepresenceStatusSnapshot(
                state: .error,
                statusText: "Status check failed",
                detailText: error.localizedDescription,
                lastUpdated: .now
            )
        }
    }

    func connect() async -> CommandOutcome {
        let connectArguments = await connectArguments()
        return await runCommand(arguments: connectArguments, successSummary: "Telepresence connected.")
    }

    func reconnect() async -> CommandOutcome {
        guard let executable = await resolveExecutable() else {
            return CommandOutcome(
                success: false,
                summary: "Telepresence executable was not found.",
                details: "Install Telepresence or set TELEPRESENCE_PATH.",
                logPaths: []
            )
        }

        do {
            let environment = await environmentResolver.executionEnvironment()
            let quitResult = try await ProcessRunner.run(
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

            let connectResult = try await ProcessRunner.run(
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
        guard let kubectl = await resolveKubectlExecutable() else {
            return nil
        }

        do {
            let result = try await ProcessRunner.run(
                executable: kubectl,
                arguments: ["config", "current-context"],
                environment: await environmentResolver.executionEnvironment()
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
        guard let executable = await resolveExecutable() else {
            return CommandOutcome(
                success: false,
                summary: "Telepresence executable was not found.",
                details: "Install Telepresence or set TELEPRESENCE_PATH.",
                logPaths: []
            )
        }

        do {
            let result = try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                environment: await environmentResolver.executionEnvironment()
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

    private func makeFailureOutcome(summary: String, fallbackVerb: String, result: ProcessOutput) -> CommandOutcome {
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

    private func resolveExecutable() async -> String? {
        await environmentResolver.resolveExecutable(
            named: "telepresence",
            envKey: "TELEPRESENCE_PATH",
            wellKnownPaths: [
                "/usr/local/bin/telepresence",
                "/opt/homebrew/bin/telepresence",
                "/usr/bin/telepresence"
            ]
        )
    }

    private func resolveKubectlExecutable() async -> String? {
        await environmentResolver.resolveExecutable(
            named: "kubectl",
            envKey: "KUBECTL_PATH",
            wellKnownPaths: [
                "/usr/local/bin/kubectl",
                "/opt/homebrew/bin/kubectl",
                "/usr/bin/kubectl"
            ]
        )
    }

    private func makeDisconnectedSnapshot(output: String) -> TelepresenceStatusSnapshot {
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = normalized.isEmpty ? "Telepresence is not connected." : normalized

        return TelepresenceStatusSnapshot(
            state: .disconnected,
            statusText: "Disconnected",
            detailText: detail,
            lastUpdated: .now
        )
    }
}
