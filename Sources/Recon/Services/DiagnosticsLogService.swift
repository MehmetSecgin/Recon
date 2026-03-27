import AppKit
import Foundation

struct DiagnosticsLogSnapshot: Sendable {
    let sourceStates: [DiagnosticsLogFileState]
    let selectedSourceState: DiagnosticsLogFileState?
    let entries: [DiagnosticsLogEntry]
    let logsDirectoryExists: Bool
    let replacesEntries: Bool
}

struct DiagnosticsBackfillResult: Sendable {
    let events: [DiagnosticsEvent]
}

actor DiagnosticsLogService {
    private enum BackfillConstants {
        static let maxLines = 1200
        static let timeoutFollowupWindow = 12
        static let chunkSize = 64 * 1024
    }

    private struct ReaderState: Sendable {
        let fileURL: URL
        let fileIdentifier: String?
        let offset: UInt64
    }

    private let logLocator: TelepresenceLogLocator
    private let fileManager: FileManager
    private var readerStates: [DiagnosticsLogSource: ReaderState] = [:]

    init(
        logLocator: TelepresenceLogLocator = TelepresenceLogLocator(),
        fileManager: FileManager = .default
    ) {
        self.logLocator = logLocator
        self.fileManager = fileManager
    }

    func defaultSource() -> DiagnosticsLogSource? {
        for source in [DiagnosticsLogSource.connector, .cli, .daemon] {
            if logLocator.logState(for: source).exists {
                return source
            }
        }

        return nil
    }

    func snapshot(for source: DiagnosticsLogSource?) -> DiagnosticsLogSnapshot {
        let sourceStates = DiagnosticsLogSource.allCases.map { logLocator.logState(for: $0) }
        let selected = source ?? defaultSource()
        let selectedState = selected.map { logLocator.logState(for: $0) }
        let logsDirectoryExists = fileManager.fileExists(atPath: logLocator.logsDirectoryURL.path)
        let entries = selected.flatMap { loadInitialEntries(for: $0) } ?? []

        return DiagnosticsLogSnapshot(
            sourceStates: sourceStates,
            selectedSourceState: selectedState,
            entries: entries,
            logsDirectoryExists: logsDirectoryExists,
            replacesEntries: true
        )
    }

    func poll(for source: DiagnosticsLogSource?) -> DiagnosticsLogSnapshot {
        let sourceStates = DiagnosticsLogSource.allCases.map { logLocator.logState(for: $0) }
        let selected = source ?? defaultSource()
        let selectedState = selected.map { logLocator.logState(for: $0) }
        let logsDirectoryExists = fileManager.fileExists(atPath: logLocator.logsDirectoryURL.path)
        let result = selected.map { loadIncrementalEntries(for: $0) }

        return DiagnosticsLogSnapshot(
            sourceStates: sourceStates,
            selectedSourceState: selectedState,
            entries: result?.entries ?? [],
            logsDirectoryExists: logsDirectoryExists,
            replacesEntries: result?.replacesEntries ?? true
        )
    }

    func openInConsole(source: DiagnosticsLogSource?) {
        guard let source else { return }
        let fileURL = logLocator.logURL(for: source)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }

        let consoleURL = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: consoleURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func reveal(source: DiagnosticsLogSource?) {
        guard let source else { return }
        let fileURL = logLocator.logURL(for: source)

        if fileManager.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else if fileManager.fileExists(atPath: logLocator.logsDirectoryURL.path) {
            NSWorkspace.shared.open(logLocator.logsDirectoryURL)
        }
    }

    func backfillEvents() -> DiagnosticsBackfillResult {
        var events: [DiagnosticsEvent] = []

        if let daemonURL = existingLogURL(for: .daemon) {
            events.append(contentsOf: parseBackfillEvents(in: daemonURL, source: .daemon))
        }

        if let connectorURL = existingLogURL(for: .connector) {
            events.append(contentsOf: parseBackfillEvents(in: connectorURL, source: .connector))
        }

        return DiagnosticsBackfillResult(events: events)
    }

    private func existingLogURL(for source: DiagnosticsLogSource) -> URL? {
        let url = logLocator.logURL(for: source)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func loadInitialEntries(for source: DiagnosticsLogSource) -> [DiagnosticsLogEntry] {
        let fileURL = logLocator.logURL(for: source)
        guard fileManager.fileExists(atPath: fileURL.path),
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            readerStates[source] = nil
            return []
        }

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let entries = lines.suffix(1000).map(parseLogEntry(from:))
        let identifier = fileIdentifier(for: fileURL)
        let offset: UInt64
        if let handle = try? FileHandle(forReadingFrom: fileURL) {
            defer { try? handle.close() }
            offset = (try? handle.seekToEnd()) ?? UInt64(content.utf8.count)
        } else {
            offset = UInt64(content.utf8.count)
        }
        readerStates[source] = ReaderState(fileURL: fileURL, fileIdentifier: identifier, offset: offset)
        return entries
    }

    private func loadIncrementalEntries(for source: DiagnosticsLogSource) -> (entries: [DiagnosticsLogEntry], replacesEntries: Bool) {
        let fileURL = logLocator.logURL(for: source)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            readerStates[source] = nil
            return ([], true)
        }

        let fileIdentifier = fileIdentifier(for: fileURL)
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0

        guard let previousState = readerStates[source],
              previousState.fileURL == fileURL,
              previousState.fileIdentifier == fileIdentifier,
              previousState.offset <= fileSize else {
            return (loadInitialEntries(for: source), true)
        }

        guard fileSize > previousState.offset else {
            return ([], false)
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return (loadInitialEntries(for: source), true)
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: previousState.offset)
            let data = try handle.readToEnd() ?? Data()
            readerStates[source] = ReaderState(
                fileURL: fileURL,
                fileIdentifier: fileIdentifier,
                offset: previousState.offset + UInt64(data.count)
            )

            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                return ([], false)
            }

            let entries = text
                .components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .map(parseLogEntry(from:))
            return (entries, false)
        } catch {
            return (loadInitialEntries(for: source), true)
        }
    }

    private func fileIdentifier(for fileURL: URL) -> String? {
        guard let values = try? fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey]),
              let identifier = values.fileResourceIdentifier else {
            return nil
        }

        return String(describing: identifier)
    }

    private func parseBackfillEvents(in fileURL: URL, source: DiagnosticsLogSource) -> [DiagnosticsEvent] {
        let lines = tailLines(in: fileURL, maxLines: BackfillConstants.maxLines)
        guard !lines.isEmpty else {
            return []
        }

        var events: [DiagnosticsEvent] = []

        if source == .daemon {
            for (index, line) in lines.enumerated() {
                let lowered = line.lowercased()

                if isRootDaemonRestartLine(lowered) {
                    events.append(
                        DiagnosticsEvent(
                            occurredAt: parseTimestamp(from: line) ?? .now,
                            kind: .rootDaemonRestarted,
                            message: "The Telepresence root daemon restarted."
                        )
                    )
                }

                guard isTimeoutCandidateLine(lowered) else {
                    continue
                }

                let upperBound = min(lines.count, index + BackfillConstants.timeoutFollowupWindow + 1)
                let followupLines = lines[(index + 1)..<upperBound]
                if followupLines.contains(where: isSessionEndedLine(_:)) {
                    events.append(
                        DiagnosticsEvent(
                            occurredAt: parseTimestamp(from: line) ?? .now,
                            kind: .sessionTimeout,
                            message: "Telepresence session hit a timeout."
                        )
                    )
                }
            }
        }

        return events
    }

    private func tailLines(in fileURL: URL, maxLines: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return []
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize > 0 else {
            return []
        }

        var offset = fileSize
        var collected = Data()

        while offset > 0 {
            let readSize = min(UInt64(BackfillConstants.chunkSize), offset)
            offset -= readSize

            do {
                try handle.seek(toOffset: offset)
                let chunk = try handle.read(upToCount: Int(readSize)) ?? Data()
                collected.insert(contentsOf: chunk, at: 0)
            } catch {
                break
            }

            if let text = String(data: collected, encoding: .utf8) {
                let lines = text
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                if lines.count >= maxLines || offset == 0 {
                    return Array(lines.suffix(maxLines))
                }
            }
        }

        guard let text = String(data: collected, encoding: .utf8) else {
            return []
        }

        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(maxLines)
            .map { $0 }
    }

    private func isTimeoutCandidateLine(_ lowered: String) -> Bool {
        let isDaemonSessionLine = lowered.contains("daemon/session")
        let mentionsTimeout = lowered.contains("context deadline exceeded") || lowered.contains("watchclusterinfo")
        return isDaemonSessionLine && mentionsTimeout
    }

    private func isSessionEndedLine(_ line: String) -> Bool {
        line.lowercased().contains("daemon/session") && line.contains("-- Session ended")
    }

    private func isRootDaemonRestartLine(_ lowered: String) -> Bool {
        lowered.contains("telepresence daemon") && lowered.contains("starting...")
    }

    private func parseLogEntry(from line: String) -> DiagnosticsLogEntry {
        let pattern = #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)\s+([A-Za-z]+)\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return DiagnosticsLogEntry(rawLine: line, timestampText: nil, level: .unknown, messageText: line)
        }

        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges == 4 else {
            return DiagnosticsLogEntry(rawLine: line, timestampText: nil, level: .unknown, messageText: line)
        }

        let nsLine = line as NSString
        let timestampText = nsLine.substring(with: match.range(at: 1))
        let levelText = nsLine.substring(with: match.range(at: 2)).uppercased()
        let messageText = nsLine.substring(with: match.range(at: 3))

        let level: DiagnosticsLogLevel
        switch levelText {
        case "INFO":
            level = .info
        case "WARN", "WARNING":
            level = .warn
        case "ERR", "ERROR":
            level = .error
        default:
            level = .unknown
        }

        return DiagnosticsLogEntry(
            rawLine: line,
            timestampText: timestampText,
            level: level,
            messageText: messageText
        )
    }

    private func parseTimestamp(from line: String) -> Date? {
        let prefix = String(line.prefix(24))
        return Self.timestampFormatter.date(from: prefix)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS"
        return formatter
    }()
}
