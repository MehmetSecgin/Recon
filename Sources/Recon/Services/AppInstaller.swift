import AppKit
import Foundation

struct AppInstaller {
    enum InstallError: LocalizedError {
        case invalidInstallerURL
        case installerFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidInstallerURL:
                return "The installer script URL is invalid."
            case .installerFailed(let output):
                return output
            }
        }
    }

    private let repository: String
    private let installerScriptURL: URL
    private let installDirectoryURL: URL
    private let processLauncher: (Process) throws -> Void
    private let appOpener: (URL) -> Void

    init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        processLauncher: @escaping (Process) throws -> Void = { process in
            try process.run()
        },
        appOpener: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.open(url)
        }
    ) {
        repository = (bundle.object(forInfoDictionaryKey: "ReconGitHubRepository") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "mehmetsecgin/Recon"

        if let configuredURL = (bundle.object(forInfoDictionaryKey: "ReconInstallerScriptURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty,
           let url = URL(string: configuredURL) {
            installerScriptURL = url
        } else {
            installerScriptURL = URL(string: "https://raw.githubusercontent.com/\(repository)/main/install.sh")!
        }

        installDirectoryURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        self.processLauncher = processLauncher
        self.appOpener = appOpener
    }

    var installedAppURL: URL {
        installDirectoryURL.appendingPathComponent("Recon.app", isDirectory: true)
    }

    func installLatestRelease() async throws {
        guard installerScriptURL.scheme?.hasPrefix("http") == true else {
            throw InstallError.invalidInstallerURL
        }

        let command = "curl -fsSL \(shellQuoted(installerScriptURL.absoluteString)) | bash"
        let environment = ProcessInfo.processInfo.environment.merging(["RECON_REPO": repository]) { _, newValue in
            newValue
        }

        let result = try await ProcessRunner.run(
            executable: "/bin/bash",
            arguments: ["-lc", command],
            environment: environment,
            timeout: .seconds(10 * 60),
            metadata: ProcessRunMetadata(source: .appInstall)
        )

        guard result.exitCode == 0 else {
            throw InstallError.installerFailed(result.combinedOutput.nilIfEmpty ?? "The installer exited with code \(result.exitCode).")
        }
    }

    func relaunchInstalledAppAfterCurrentProcessExits() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-lc",
            "sleep 1; open \(shellQuoted(installedAppURL.path))"
        ]

        do {
            try processLauncher(process)
        } catch {
            appOpener(installedAppURL)
        }
    }
}

private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
