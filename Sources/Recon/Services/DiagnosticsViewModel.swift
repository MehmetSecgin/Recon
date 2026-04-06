import AppKit
import Foundation

@MainActor
final class DiagnosticsViewModel: ObservableObject {
    enum Tab: Hashable, CaseIterable {
        case health
        case logs
        case history
        case commands

        var title: String {
            switch self {
            case .health:
                return "Health"
            case .logs:
                return "Logs"
            case .history:
                return "History"
            case .commands:
                return "Commands"
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
            case .commands:
                return "terminal"
            }
        }
    }

    @Published var selectedTab: Tab = .health
    @Published var selectedLogSource: DiagnosticsLogSource?
    @Published var filterText = ""
    @Published var showStatusPollCommands = false
    @Published private(set) var includedLogLevels: Set<DiagnosticsLogLevel> = [.info, .warn, .error]
    @Published private(set) var healthSnapshot: DiagnosticsHealthSnapshot?
    @Published private(set) var healthErrorMessage: String?
    @Published private(set) var sourceStates: [DiagnosticsLogFileState] = []
    @Published private(set) var logEntries: [DiagnosticsLogEntry] = []
    @Published private(set) var logsDirectoryExists = false
    @Published private(set) var historyItems: [DiagnosticsHistoryItem] = []
    @Published private(set) var historyErrorMessage: String?
    @Published private(set) var commandItems: [CommandHistorySummaryItem] = []
    @Published private(set) var expandedCommandIDs = Set<Int64>()
    @Published private(set) var loadingCommandDetailIDs = Set<Int64>()
    @Published private(set) var commandDetailItems: [Int64: CommandHistoryDetailItem] = [:]
    @Published private(set) var commandErrorMessage: String?
    @Published private(set) var exportStatusMessage: String?
    @Published private(set) var isLoadingHealth = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var isLoadingCommands = false
    @Published private(set) var isExportingBundle = false

    private let controller: DiagnosticsControllerClient
    private let historyStore: DiagnosticsHistoryStoreClient
    private let commandHistoryStore: DiagnosticsCommandHistoryStoreClient
    private let logService: DiagnosticsLogServiceClient
    private var logPollingTask: Task<Void, Never>?
    private var isWindowActive = false
    private var lastBackfillAt: Date?

    private static let defaultIncludedLogLevels: Set<DiagnosticsLogLevel> = [.info, .warn, .error]

    convenience init(controller: TelepresenceController) {
        self.init(
            controller: .live(controller),
            historyStore: .live(EventHistoryStore()),
            commandHistoryStore: .live(CommandHistoryStore.shared),
            logService: .live(DiagnosticsLogService())
        )
    }

    init(
        controller: DiagnosticsControllerClient,
        historyStore: DiagnosticsHistoryStoreClient,
        commandHistoryStore: DiagnosticsCommandHistoryStoreClient,
        logService: DiagnosticsLogServiceClient
    ) {
        self.controller = controller
        self.historyStore = historyStore
        self.commandHistoryStore = commandHistoryStore
        self.logService = logService
    }

    deinit {
        logPollingTask?.cancel()
    }

    var filteredLogEntries: [DiagnosticsLogEntry] {
        logEntries.filter { entry in
            let levelIncluded = entry.level == .unknown || includedLogLevels.contains(entry.level)
            let matchesFilter = filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                entryMatchesFilter(entry)
            return levelIncluded && matchesFilter
        }
    }

    var visibleCommandItems: [CommandHistorySummaryItem] {
        commandItems.filter { item in
            showStatusPollCommands || item.source.isStatusPoll == false
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
            await self.refreshSelectedTab(forceReload: true)
        }
    }

    func deactivateWindow() {
        isWindowActive = false
        stopLogPolling()
        Task {
            await logService.reset()
        }
        clearRetainedState()
    }

    func selectTab(_ tab: Tab) {
        guard selectedTab != tab else { return }

        let previousTab = selectedTab
        selectedTab = tab

        if previousTab == .commands && tab != .commands {
            clearCommandHistoryState()
        }

        guard isWindowActive else { return }

        Task { [weak self] in
            await self?.refreshSelectedTab(forceReload: true)
        }
    }

    func refreshSelectedTab() {
        guard isWindowActive else { return }

        Task { [weak self] in
            await self?.refreshSelectedTab(forceReload: true)
        }
    }

    func selectLogSource(_ source: DiagnosticsLogSource?) {
        guard selectedLogSource != source else { return }
        selectedLogSource = source
        guard isWindowActive, selectedTab == .logs else { return }

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

    func toggleCommandExpansion(_ item: CommandHistorySummaryItem) {
        if expandedCommandIDs.contains(item.id) {
            expandedCommandIDs.remove(item.id)
            return
        }

        expandedCommandIDs.insert(item.id)

        guard commandDetailItems[item.id] == nil,
              loadingCommandDetailIDs.contains(item.id) == false else {
            return
        }

        loadingCommandDetailIDs.insert(item.id)
        Task { [weak self] in
            guard let self else { return }

            do {
                let detail = try await self.commandHistoryStore.detail(item.id)
                guard self.isWindowActive,
                      self.selectedTab == .commands,
                      self.expandedCommandIDs.contains(item.id) else {
                    self.loadingCommandDetailIDs.remove(item.id)
                    return
                }

                if let detail {
                    self.commandDetailItems[item.id] = detail
                    self.commandErrorMessage = nil
                }
            } catch {
                if self.selectedTab == .commands {
                    self.commandErrorMessage = error.localizedDescription
                }
            }

            self.loadingCommandDetailIDs.remove(item.id)
        }
    }

    func commandDetail(for id: Int64) -> CommandHistoryDetailItem? {
        commandDetailItems[id]
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
            try await historyStore.prepare()
            historyItems = try await historyStore.recentHistory(300)
            historyErrorMessage = nil
        } catch {
            historyErrorMessage = error.localizedDescription
        }
        isLoadingHistory = false
    }

    func refreshCommands() async {
        isLoadingCommands = true
        clearCommandHistoryState(retainingItems: false)

        do {
            try await commandHistoryStore.prepare()
            commandItems = try await commandHistoryStore.recentSummaries(500)
            commandErrorMessage = nil
        } catch {
            commandErrorMessage = error.localizedDescription
        }

        isLoadingCommands = false
    }

    func reloadLogs(reset: Bool) async {
        let snapshot = await (reset ? logService.snapshot(selectedLogSource) : logService.poll(selectedLogSource))
        sourceStates = snapshot.sourceStates
        logsDirectoryExists = snapshot.logsDirectoryExists

        if selectedLogSource == nil {
            selectedLogSource = snapshot.selectedSourceState?.source
        }

        if snapshot.replacesEntries {
            logEntries = snapshot.entries
        } else if !snapshot.entries.isEmpty {
            logEntries.append(contentsOf: snapshot.entries)
            if logEntries.count > DiagnosticsLogService.retainedEntryLimit {
                logEntries = Array(logEntries.suffix(DiagnosticsLogService.retainedEntryLimit))
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
            await logService.openInConsole(selectedLogSource)
        }
    }

    func revealSelectedLog() {
        Task {
            await logService.reveal(selectedLogSource)
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

    private func backfillHistoryFromLogs() async {
        if let lastBackfillAt,
           Date.now.timeIntervalSince(lastBackfillAt) < 5 * 60 {
            return
        }

        do {
            try await historyStore.prepare()
        } catch {
            historyErrorMessage = error.localizedDescription
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
        stopLogPolling()
        logPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.isWindowActive, self.selectedTab == .logs else { return }
                await self.reloadLogs(reset: false)
            }
        }
    }

    private func stopLogPolling() {
        logPollingTask?.cancel()
        logPollingTask = nil
    }

    private func refreshSelectedTab(forceReload: Bool) async {
        switch selectedTab {
        case .health:
            stopLogPolling()
            await refreshHealth()
        case .logs:
            await reloadLogs(reset: forceReload)
            await startLogPolling()
        case .history:
            stopLogPolling()
            await backfillHistoryFromLogs()
            await refreshHistory()
        case .commands:
            stopLogPolling()
            await refreshCommands()
        }
    }

    private func clearRetainedState() {
        selectedTab = .health
        selectedLogSource = nil
        filterText = ""
        showStatusPollCommands = false
        includedLogLevels = Self.defaultIncludedLogLevels
        healthSnapshot = nil
        healthErrorMessage = nil
        sourceStates = []
        logEntries = []
        logsDirectoryExists = false
        historyItems = []
        historyErrorMessage = nil
        clearCommandHistoryState()
        exportStatusMessage = nil
        isLoadingHealth = false
        isLoadingHistory = false
        isLoadingCommands = false
        isExportingBundle = false
        lastBackfillAt = nil
    }

    private func clearCommandHistoryState(retainingItems: Bool = false) {
        if retainingItems == false {
            commandItems = []
        }
        expandedCommandIDs = []
        loadingCommandDetailIDs = []
        commandDetailItems = [:]
        commandErrorMessage = nil
    }

    private func entryMatchesFilter(_ entry: DiagnosticsLogEntry) -> Bool {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        if entry.text.localizedCaseInsensitiveContains(query) {
            return true
        }

        if let timestampText = entry.timestampText,
           timestampText.localizedCaseInsensitiveContains(query) {
            return true
        }

        return entry.level.rawValue.localizedCaseInsensitiveContains(query)
    }

    private static let connectedSinceFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
