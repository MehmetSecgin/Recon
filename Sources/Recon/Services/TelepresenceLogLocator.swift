import Foundation

struct TelepresenceLogLocator {
    private let fileManager = FileManager.default

    func logURL(for source: DiagnosticsLogSource) -> URL {
        logsDirectoryURL.appendingPathComponent(source.filename)
    }

    func logState(for source: DiagnosticsLogSource) -> DiagnosticsLogFileState {
        let fileURL = logURL(for: source)
        return DiagnosticsLogFileState(
            source: source,
            fileURL: fileURL,
            exists: fileManager.fileExists(atPath: fileURL.path)
        )
    }

    func availableSources() -> [DiagnosticsLogSource] {
        DiagnosticsLogSource.allCases.filter { logState(for: $0).exists }
    }

    func preferredLogURL() -> URL? {
        for source in [DiagnosticsLogSource.cli, .connector, .daemon] {
            let candidate = logURL(for: source)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        if fileManager.fileExists(atPath: directory.path) {
            return directory
        }

        return nil
    }

    func hasOpenableTarget() -> Bool {
        preferredLogURL() != nil
    }

    var logsDirectoryURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/telepresence", isDirectory: true)
    }

    private var directory: URL {
        logsDirectoryURL
    }
}
