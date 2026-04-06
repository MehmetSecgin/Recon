import Foundation

struct ProcessOutput {
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

enum ProcessRunner {
    struct TimeoutError: LocalizedError {
        let duration: Duration

        var errorDescription: String? {
            "Command timed out after \(duration.components.seconds) seconds."
        }
    }

    private enum WaitOutcome {
        case completed(Int32, Date)
        case timedOut(Date)
    }

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration? = nil,
        metadata: ProcessRunMetadata = ProcessRunMetadata()
    ) async throws -> ProcessOutput {
        let startedAt = Date.now
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

        do {
            try process.run()
        } catch {
            await persistLog(
                executable: executable,
                arguments: arguments,
                metadata: metadata,
                startedAt: startedAt,
                finishedAt: Date.now,
                resultState: .launchFailure,
                exitCode: nil,
                stdout: "",
                stderr: error.localizedDescription
            )
            throw error
        }

        async let stdoutRead = stdoutPipe.fileHandleForReading.readToEnd()
        async let stderrRead = stderrPipe.fileHandleForReading.readToEnd()

        let waitOutcome = await waitForExit(of: process, timeout: timeout)
        let stdoutData = try await stdoutRead ?? Data()
        let stderrData = try await stderrRead ?? Data()
        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)

        switch waitOutcome {
        case .completed(let terminationStatus, let finishedAt):
            await persistLog(
                executable: executable,
                arguments: arguments,
                metadata: metadata,
                startedAt: startedAt,
                finishedAt: finishedAt,
                resultState: terminationStatus == 0 ? .success : .nonZeroExit,
                exitCode: terminationStatus,
                stdout: stdout,
                stderr: stderr
            )

            return ProcessOutput(
                exitCode: terminationStatus,
                stdout: stdout,
                stderr: stderr
            )
        case .timedOut(let finishedAt):
            await persistLog(
                executable: executable,
                arguments: arguments,
                metadata: metadata,
                startedAt: startedAt,
                finishedAt: finishedAt,
                resultState: .timeout,
                exitCode: process.terminationStatus,
                stdout: stdout,
                stderr: stderr
            )
            throw TimeoutError(duration: timeout ?? .zero)
        }
    }

    private static func waitForExit(of process: Process, timeout: Duration?) async -> WaitOutcome {
        guard let timeout else {
            let terminationStatus = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                }
            }
            return .completed(terminationStatus, Date.now)
        }

        return await withTaskGroup(of: WaitOutcome.self) { group in
            group.addTask {
                let status = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        process.waitUntilExit()
                        continuation.resume(returning: process.terminationStatus)
                    }
                }
                return .completed(status, Date.now)
            }

            group.addTask {
                try? await Task.sleep(for: timeout)
                if process.isRunning {
                    let timeoutAt = Date.now
                    process.terminate()
                    return .timedOut(timeoutAt)
                }

                return .completed(process.terminationStatus, Date.now)
            }

            let outcome = await group.next() ?? .completed(process.terminationStatus, Date.now)
            group.cancelAll()
            return outcome
        }
    }

    private static func persistLog(
        executable: String,
        arguments: [String],
        metadata: ProcessRunMetadata,
        startedAt: Date,
        finishedAt: Date,
        resultState: CommandHistoryResultState,
        exitCode: Int32?,
        stdout: String,
        stderr: String
    ) async {
        let durationMs = max(Int64((finishedAt.timeIntervalSince(startedAt) * 1000).rounded()), 0)
        let record = CommandHistoryEntryRecord(
            startedAt: startedAt,
            finishedAt: finishedAt,
            durationMs: durationMs,
            executable: executable,
            arguments: arguments,
            source: metadata.source,
            context: metadata.context,
            namespace: metadata.namespace,
            resultState: resultState,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr
        )

        do {
            try await CommandHistoryStore.shared.insert(record)
        } catch {
            return
        }
    }
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
