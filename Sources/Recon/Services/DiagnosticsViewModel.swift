import AppKit
import Foundation

@MainActor
final class DiagnosticsViewModel: ObservableObject {
    enum Tab: Hashable, CaseIterable {
        case health
        case logs
        case history

        var title: String {
            switch self {
            case .health:
                return "Health"
            case .logs:
                return "Logs"
            case .history:
                return "History"
            }
        }

        var systemImage: String {
            switch self {
            case .health:
                return "heart.text.square"
            case .logs:
                return "doc.text.magnifyingglass"
            case .history:
                return "clock.arrow.circlepath"
            }
        }
    }

    @Published var selectedTab: Tab = .health
    @Published var selectedLogSource: DiagnosticsLogSource?
    @Published var filterText = ""
    @Published private(set) var includedLogLevels: Set<DiagnosticsLogLevel> = [.info, .warn, .error]
    @Published private(set) var healthSnapshot: DiagnosticsHealthSnapshot?
    @Published private(set) var healthErrorMessage: String?
    @Published private(set) var sourceStates: [DiagnosticsLogFileState] = []
    @Published private(set) var logEntries: [DiagnosticsLogEntry] = []
    @Published private(set) var logsDirectoryExists = false
    @Published private(set) var historyItems: [DiagnosticsHistoryItem] = []
    @Published private(set) var historyErrorMessage: String?
    @Published private(set) var exportStatusMessage: String?
    @Published private(set) var isLoadingHealth = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var isExportingBundle = false

    private let controller: TelepresenceController
    private let historyStore: EventHistoryStore
    private let logService: DiagnosticsLogService
    private var eventSubscriptionTask: Task<Void, Never>?
    private var logPollingTask: Task<Void, Never>?
    private var isWindowActive = false
    private var lastBackfillAt: Date?

    init(
        controller: TelepresenceController,
        historyStore: EventHistoryStore = EventHistoryStore(),
        logService: DiagnosticsLogService = DiagnosticsLogService()
    ) {
        self.controller = controller
        self.historyStore = historyStore
        self.logService = logService

        eventSubscriptionTask = Task { [weak self] in
            guard let self else { return }
            await self.prepareHistoryStore()
            let stream = self.controller.diagnosticsEventStream()
            for await event in stream {
                await self.persist(event: event)
            }
        }
    }

    deinit {
        eventSubscriptionTask?.cancel()
        logPollingTask?.cancel()
    }

    var filteredLogEntries: [DiagnosticsLogEntry] {
        logEntries.filter { entry in
            let levelIncluded = entry.level == .unknown || includedLogLevels.contains(entry.level)
            let matchesFilter = filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                entry.rawLine.localizedCaseInsensitiveContains(filterText)
            return levelIncluded && matchesFilter
        }
    }

    var canOpenSelectedLog: Bool {
        selectedSourceState?.exists == true
    }

    var selectedSourceState: DiagnosticsLogFileState? {
        guard let selectedLogSource else { return nil }
        return sourceStates.first { $0.source == selectedLogSource }
    }

    func activateWindow() {
        guard isWindowActive == false else { return }
        isWindowActive = true

        Task { [weak self] in
            guard let self else { return }
            await self.refreshAll()
            await self.startLogPolling()
        }
    }

    func deactivateWindow() {
        isWindowActive = false
        logPollingTask?.cancel()
        logPollingTask = nil
    }

    func selectTab(_ tab: Tab) {
        selectedTab = tab
        if tab == .logs, isWindowActive {
            Task { [weak self] in
                await self?.reloadLogs(reset: true)
            }
        }
    }

    func selectLogSource(_ source: DiagnosticsLogSource?) {
        guard selectedLogSource != source else { return }
        selectedLogSource = source
        Task { [weak self] in
            await self?.reloadLogs(reset: true)
        }
    }

    func toggleLogLevel(_ level: DiagnosticsLogLevel) {
        if includedLogLevels.contains(level) {
            if includedLogLevels.count > 1 {
                includedLogLevels.remove(level)
            }
        } else {
            includedLogLevels.insert(level)
        }
    }

    func refreshAll() async {
        await refreshHealth()
        await backfillHistoryFromLogs()
        await refreshHistory()
        await reloadLogs(reset: true)
    }

    func refreshHealth() async {
        isLoadingHealth = true
        let snapshot = await controller.fetchDiagnosticsHealthSnapshot()
        healthSnapshot = snapshot
        healthErrorMessage = snapshot.telepresenceUnavailable ? snapshot.unavailableReason : nil
        isLoadingHealth = false
    }

    func refreshHistory() async {
        isLoadingHistory = true
        do {
            historyItems = try await historyStore.recentHistory()
            historyErrorMessage = nil
        } catch {
            historyErrorMessage = error.localizedDescription
        }
        isLoadingHistory = false
    }

    func reloadLogs(reset: Bool) async {
        let snapshot = await (reset ? logService.snapshot(for: selectedLogSource) : logService.poll(for: selectedLogSource))
        sourceStates = snapshot.sourceStates
        logsDirectoryExists = snapshot.logsDirectoryExists

        if selectedLogSource == nil {
            selectedLogSource = snapshot.selectedSourceState?.source
        }

        if snapshot.replacesEntries {
            logEntries = snapshot.entries
        } else if !snapshot.entries.isEmpty {
            logEntries.append(contentsOf: snapshot.entries)
            if logEntries.count > 1500 {
                logEntries = Array(logEntries.suffix(1500))
            }
        }
    }

    func exportDiagnosticBundle() {
        guard !isExportingBundle else { return }
        isExportingBundle = true
        exportStatusMessage = nil

        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.controller.exportDiagnosticBundle()
            self.isExportingBundle = false

            if outcome.success, let bundleURL = outcome.bundleURL {
                NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
                self.exportStatusMessage = "Exported diagnostic bundle to \(bundleURL.lastPathComponent)."
            } else {
                self.exportStatusMessage = outcome.details ?? outcome.summary
            }
        }
    }

    func copyStatusCommand() {
        controller.copyStatusCommand()
    }

    func openSelectedLogInConsole() {
        Task {
            await logService.openInConsole(source: selectedLogSource)
        }
    }

    func revealSelectedLog() {
        Task {
            await logService.reveal(source: selectedLogSource)
        }
    }

    func healthCards() -> [DiagnosticsHealthCard] {
        guard let snapshot = healthSnapshot else { return [] }

        if snapshot.telepresenceUnavailable {
            return [
                DiagnosticsHealthCard(id: "user-daemon", title: "User daemon", value: "Unavailable", state: .unavailable),
                DiagnosticsHealthCard(id: "root-daemon", title: "Root daemon", value: "Unavailable", state: .unavailable),
                DiagnosticsHealthCard(id: "traffic-manager", title: "Traffic Manager", value: "Unavailable", state: .unavailable),
                DiagnosticsHealthCard(id: "dns", title: "DNS resolution", value: "Unavailable", state: .unavailable)
            ]
        }

        let userDaemon = snapshot.status?.userDaemon
        let rootDaemon = snapshot.status?.rootDaemon
        let trafficManager = snapshot.status?.trafficManager
        let dns = rootDaemon?.dns

        let userState: DiagnosticsComponentState = {
            if userDaemon?.running == true {
                return .healthy
            }
            if let status = userDaemon?.status?.lowercased(), status.contains("error") {
                return .error
            }
            return .inactive
        }()

        let rootState: DiagnosticsComponentState = {
            if rootDaemon?.running == true {
                return .healthy
            }
            return .inactive
        }()

        let trafficManagerState: DiagnosticsComponentState = trafficManager?.version?.nilIfEmpty == nil ? .warning : .healthy
        let dnsState: DiagnosticsComponentState = {
            if let error = dns?.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                return .error
            }
            if dns?.localAddresses?.isEmpty == false {
                return .healthy
            }
            return .inactive
        }()

        return [
            DiagnosticsHealthCard(
                id: "user-daemon",
                title: "User daemon",
                value: userDaemon?.running == true ? "running" : (userDaemon?.status ?? "stopped"),
                state: userState
            ),
            DiagnosticsHealthCard(
                id: "root-daemon",
                title: "Root daemon",
                value: rootDaemon?.running == true ? "running" : "stopped",
                state: rootState
            ),
            DiagnosticsHealthCard(
                id: "traffic-manager",
                title: "Traffic Manager",
                value: trafficManager?.version ?? "unreachable",
                state: trafficManagerState
            ),
            DiagnosticsHealthCard(
                id: "dns",
                title: "DNS resolution",
                value: dnsState == .healthy ? "active" : (dnsState == .error ? "error" : "inactive"),
                state: dnsState
            )
        ]
    }

    func sessionDetails() -> [(String, String)] {
        let snapshot = healthSnapshot
        let status = snapshot?.status
        let userDaemon = status?.userDaemon
        let rootDaemon = status?.rootDaemon
        let dnsSuffix = rootDaemon?.dns?.includeSuffixes?.first?.nilIfEmpty ?? "\u{2014}"
        let subnets = (rootDaemon?.subnets ?? []).joined(separator: ", ").nilIfEmpty ?? "\u{2014}"

        return [
            ("Session", userDaemon?.name ?? "\u{2014}"),
            ("Telepresence", userDaemon?.version ?? rootDaemon?.version ?? "\u{2014}"),
            ("Cluster", userDaemon?.kubernetesServer ?? "\u{2014}"),
            ("Mapped subnets", subnets),
            ("DNS suffix", dnsSuffix),
            ("Connected since", snapshot?.connectedSince.map(Self.connectedSinceFormatter.string(from:)) ?? "\u{2014}")
        ]
    }

    private func prepareHistoryStore() async {
        do {
            try await historyStore.prepare()
            historyItems = try await historyStore.recentHistory()
            historyErrorMessage = nil
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    private func persist(event: DiagnosticsEvent) async {
        do {
            try await historyStore.insert(event)
            historyItems = try await historyStore.recentHistory()
            historyErrorMessage = nil
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    private func backfillHistoryFromLogs() async {
        if let lastBackfillAt,
           Date.now.timeIntervalSince(lastBackfillAt) < 5 * 60 {
            return
        }

        let result = await logService.backfillEvents()
        for event in result.events {
            do {
                try await historyStore.insert(event)
            } catch {
                historyErrorMessage = error.localizedDescription
                return
            }
        }
        lastBackfillAt = .now
    }

    private func startLogPolling() async {
        logPollingTask?.cancel()
        logPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.isWindowActive else { return }
                await self.reloadLogs(reset: false)
            }
        }
    }

    private static let connectedSinceFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
