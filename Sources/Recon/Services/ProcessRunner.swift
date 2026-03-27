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

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration? = nil
    ) async throws -> ProcessOutput {
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

        let terminationStatus: Int32
        if let timeout {
            terminationStatus = try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            process.waitUntilExit()
                            continuation.resume(returning: process.terminationStatus)
                        }
                    }
                }

                group.addTask {
                    try await Task.sleep(for: timeout)
                    if process.isRunning {
                        process.terminate()
                    }
                    throw TimeoutError(duration: timeout)
                }

                let status = try await group.next() ?? process.terminationStatus
                group.cancelAll()
                return status
            }
        } else {
            terminationStatus = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                }
            }
        }

        let stdoutData = try await stdoutRead ?? Data()
        let stderrData = try await stderrRead ?? Data()

        return ProcessOutput(
            exitCode: terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
