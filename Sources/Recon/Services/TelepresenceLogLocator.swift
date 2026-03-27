import Foundation

struct TelepresenceLogLocator {
    private let fileManager = FileManager.default

    func preferredLogURL() -> URL? {
        let directory = logsDirectoryURL
        let preferredFiles = ["cli.log", "connector.log", "daemon.log"]

        for filename in preferredFiles {
            let candidate = directory.appendingPathComponent(filename)
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
}
