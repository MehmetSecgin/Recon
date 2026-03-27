import AppKit
import Combine
import Foundation
import UserNotifications

struct KubeconfigOption: Identifiable, Hashable {
    let path: String
    let title: String

    var id: String { path }
}

struct KubeconfigPickerOption: Identifiable, Hashable {
    enum Kind: Hashable {
        case path(String)
        case chooseFile
    }

    let kind: Kind
    let title: String

    var id: String {
        switch kind {
        case .path(let path):
            return "kubeconfig:\(path)"
        case .chooseFile:
            return "kubeconfig:choose-file"
        }
    }
}

struct NamespacePickerOption: Identifiable, Hashable {
    enum Kind: Hashable {
        case namespace(String)
        case useKubeconfigDefault
    }

    let kind: Kind
    let title: String

    var id: String {
        switch kind {
        case .namespace(let namespace):
            return "namespace:\(namespace)"
        case .useKubeconfigDefault:
            return "use-kubeconfig-default"
        }
    }
}

@MainActor
final class TelepresenceController: ObservableObject {
    @Published private(set) var snapshot = TelepresenceStatusSnapshot.busy("Checking Recon...")
    @Published private(set) var targetMetadata = TargetMetadata.empty
    @Published private(set) var isRunningCommand = false
    @Published private(set) var isSwitchingKubeconfig = false
    @Published private(set) var kubeconfigOptions: [KubeconfigOption] = []
    @Published private(set) var isProductionConnection = false
    @Published private(set) var errorPresentation: ErrorPresentation?
    @Published private(set) var settingsStatusMessage: String?
    @Published private(set) var isUpdatingLaunchAtLogin = false
    @Published private(set) var isDetectingTelepresencePath = false
    @Published private(set) var isDetectingKubectlPath = false
    @Published private(set) var detectedTelepresencePath: String?
    @Published private(set) var detectedKubectlPath: String?
    @Published private(set) var namespaceOverride: String?
    @Published private(set) var kubeconfigPickerOptions: [KubeconfigPickerOption] = []
    @Published private(set) var namespacePickerOptions: [NamespacePickerOption] = []
    @Published private(set) var isLoadingNamespacePickerOptions = false
    @Published private(set) var appUpdateState: AppUpdateState = .idle
    @Published private(set) var connectedSince: Date?

    let settingsStore: AppSettingsStore

    private let environmentResolver: CommandEnvironmentResolver
    private let cli: TelepresenceCLI
    private let releaseChecker: AppReleaseChecker
    private let appInstaller: AppInstaller
    private let targetResolver: KubeTargetResolver
    private let namespaceDiscoveryService: NamespaceDiscoveryService
    private let logLocator = TelepresenceLogLocator()
    private let fileManager = FileManager.default
    private var pollingTask: Task<Void, Never>?
    private var updatePollingTask: Task<Void, Never>?
    private var hasAttemptedAutoReconnectForCurrentDrop = false
    private var userInitiatedDisconnect = false
    private var lastCommandFailure: CommandOutcome?
    private var lastNamespacePickerContext: String?
    private var lastUpdateCheckAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private var diagnosticsEventContinuations: [UUID: AsyncStream<DiagnosticsEvent>.Continuation] = [:]

    var statusItemTitle: String {
        switch snapshot.state {
        case .connected:
            return "R●"
        case .busy:
            return "R⋯"
        case .disconnected:
            return "R○"
        case .unavailable:
            return "R–"
        case .error:
            return "R!"
        }
    }

    var headerDetailText: String? {
        switch snapshot.state {
        case .connected:
            return nil
        case .busy:
            return snapshot.detailText
        case .disconnected:
            return errorPresentation == nil ? snapshot.detailText : nil
        case .unavailable, .error:
            return errorPresentation == nil ? snapshot.detailText : nil
        }
    }

    var shouldShowTimestamp: Bool {
        snapshot.state != .busy
    }

    var selectedKubeconfigPath: String? {
        settingsStore.selectedKubeconfigPath
    }

    var selectedPollingInterval: PollingIntervalOption {
        settingsStore.pollingInterval
    }

    var displayTelepresencePath: String {
        displayPathText(for: detectedTelepresencePath)
    }

    var displayKubectlPath: String {
        displayPathText(for: detectedKubectlPath)
    }

    var telepresencePathOverride: String? {
        settingsStore.telepresencePathOverride
    }

    var kubectlPathOverride: String? {
        settingsStore.kubectlPathOverride
    }

    var logDirectoryDisplay: String {
        NSString(string: logLocator.logsDirectoryURL.path).abbreviatingWithTildeInPath
    }

    var kubeconfigPickerLabel: String {
        if let selectedKubeconfigPath {
            return URL(fileURLWithPath: selectedKubeconfigPath).lastPathComponent
        }

        switch targetMetadata.kubeconfigMode {
        case .inheritedMultiple(let count):
            return "Inherited (\(count) files)"
        case .inheritedSingle:
            return "Follow $KUBECONFIG"
        case .default:
            return "Default kubeconfig"
        case .pinned:
            return targetMetadata.kubeconfigDisplay
        case .unresolved:
            return "Choose source"
        }
    }

    var displayKubeconfig: String {
        targetMetadata.kubeconfigDisplay
    }

    var isKubeconfigRowInteractive: Bool {
        isSwitchingKubeconfig == false && kubeconfigPickerOptions.isEmpty == false
    }

    var displayContext: String {
        targetMetadata.context ?? "\u{2014}"
    }

    var displayNamespace: String {
        targetMetadata.namespace ?? "\u{2014}"
    }

    var selectedNamespacePickerOptionID: String? {
        if namespaceOverride != nil {
            guard let namespace = targetMetadata.namespace else {
                return nil
            }
            return NamespacePickerOption(kind: .namespace(namespace), title: namespace).id
        }

        guard let namespace = targetMetadata.kubeconfigDefaultNamespace ?? targetMetadata.namespace else {
            return nil
        }

        return NamespacePickerOption(kind: .namespace(namespace), title: namespace).id
    }

    var selectedKubeconfigPickerOptionID: String? {
        guard let selectedKubeconfigPath else {
            return nil
        }

        return KubeconfigPickerOption(kind: .path(selectedKubeconfigPath), title: "").id
    }

    var appUpdateTitle: String {
        switch appUpdateState {
        case .idle:
            return "Check for Updates"
        case .checking:
            return "Checking for updates"
        case .upToDate:
            return "Recon is up to date"
        case .available:
            return "Update available"
        case .installing:
            return "Installing update"
        case .checkFailed:
            return "Couldn't check for updates"
        case .installFailed:
            return "Update failed"
        }
    }

    var appUpdateDetail: String {
        switch appUpdateState {
        case .idle:
            return "Look for the latest published Recon release."
        case .checking:
            return "Looking for the latest published Recon release."
        case .upToDate(let currentVersion, let latestVersion):
            if let latestVersion, latestVersion != currentVersion {
                return "Installed: v\(currentVersion). Latest seen: v\(latestVersion)."
            }
            return "Installed: v\(currentVersion)."
        case .available(let release):
            return "\(release.displayVersion) is ready to install."
        case .installing(let release):
            return "Downloading and installing \(release.displayVersion)..."
        case .checkFailed(let currentVersion):
            return "Installed: v\(currentVersion). Try again."
        case .installFailed(let currentVersion, let release):
            return "Couldn't install \(release.displayVersion). Installed: v\(currentVersion)."
        }
    }

    var appUpdateActionTitle: String? {
        switch appUpdateState {
        case .checking, .installing:
            return nil
        case .available, .installFailed:
            return "Update"
        default:
            return "Check"
        }
    }

    var isPerformingUpdateAction: Bool {
        if case .checking = appUpdateState {
            return true
        }

        if case .installing = appUpdateState {
            return true
        }

        return false
    }

    init(
        settingsStore: AppSettingsStore,
        environmentResolver: CommandEnvironmentResolver = CommandEnvironmentResolver(),
        releaseChecker: AppReleaseChecker = AppReleaseChecker(),
        appInstaller: AppInstaller = AppInstaller()
    ) {
        self.settingsStore = settingsStore
        self.environmentResolver = environmentResolver
        self.releaseChecker = releaseChecker
        self.appInstaller = appInstaller
        cli = TelepresenceCLI(environmentResolver: environmentResolver)
        targetResolver = KubeTargetResolver(environmentResolver: environmentResolver)
        namespaceDiscoveryService = NamespaceDiscoveryService(
            environmentResolver: environmentResolver,
            targetResolver: targetResolver,
            settingsStore: settingsStore
        )

        bindSettings()

        Task { [weak self] in
            guard let self else { return }
            self.refreshLaunchAtLoginState()
            await self.syncEnvironmentSettings()
            await self.refreshDetectedExecutables()
            await self.loadKubeconfigOptions()
            await self.checkForUpdates(force: true)
            await self.performAutoConnectOnLaunchIfNeeded()
            self.startPolling()
            self.startUpdatePolling()
        }
    }

    deinit {
        pollingTask?.cancel()
        updatePollingTask?.cancel()
    }

    func connect() {
        userInitiatedDisconnect = false
        let namespace = activeNamespaceOverride
        runCommand(busyMessage: "Connecting to Telepresence...") { cli in
            await cli.connect(namespace: namespace)
        }
    }

    func reconnect() {
        userInitiatedDisconnect = false
        let namespace = activeNamespaceOverride
        runCommand(busyMessage: "Restarting Telepresence...") { cli in
            await cli.reconnect(namespace: namespace)
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        Task {
            await namespaceDiscoveryService.clearSessionCache()
        }
        runCommand(busyMessage: "Disconnecting Telepresence...") { cli in
            await cli.disconnect()
        }
    }

    func switchNamespace(to namespace: String) {
        guard let context = targetMetadata.context else { return }

        settingsStore.setOverride(namespace, for: context)
        namespaceOverride = settingsStore.override(for: context)
        targetMetadata = targetMetadata.applying(
            context: targetMetadata.context,
            namespace: namespaceOverride ?? targetMetadata.kubeconfigDefaultNamespace,
            kubeconfigDefaultNamespace: targetMetadata.kubeconfigDefaultNamespace,
            isLastKnown: true,
            resolutionError: nil
        )
        userInitiatedDisconnect = false

        runCommand(busyMessage: "Reconnecting to \(namespace)...") { cli in
            await self.namespaceDiscoveryService.clearSessionCache()
            return await cli.reconnect(namespace: namespace)
        }
    }

    func clearNamespaceOverride() {
        guard let context = targetMetadata.context else { return }

        settingsStore.clearOverride(for: context)
        namespaceOverride = nil
        targetMetadata = targetMetadata.applying(
            context: targetMetadata.context,
            namespace: targetMetadata.kubeconfigDefaultNamespace,
            kubeconfigDefaultNamespace: targetMetadata.kubeconfigDefaultNamespace,
            isLastKnown: true,
            resolutionError: nil
        )
        userInitiatedDisconnect = false

        runCommand(busyMessage: "Reconnecting with kubeconfig default namespace...") { cli in
            await self.namespaceDiscoveryService.clearSessionCache()
            return await cli.reconnect(namespace: nil)
        }
    }

    func selectNamespacePickerOption(withID optionID: String) {
        guard let option = namespacePickerOptions.first(where: { $0.id == optionID }) else {
            return
        }

        switch option.kind {
        case .namespace(let namespace):
            guard namespace != targetMetadata.namespace else { return }
            switchNamespace(to: namespace)
        case .useKubeconfigDefault:
            guard namespaceOverride != nil else { return }
            clearNamespaceOverride()
        }
    }

    func selectKubeconfigPickerOption(withID optionID: String) {
        guard let option = kubeconfigPickerOptions.first(where: { $0.id == optionID }) else {
            return
        }

        switch option.kind {
        case .path(let path):
            guard path != selectedKubeconfigPath else { return }
            addAndSelectKubeconfig(path: path)
        case .chooseFile:
            break
        }
    }

    func refreshNow() {
        Task {
            await refreshStatus()
        }
    }

    func refreshUpdateStatusIfNeeded() {
        Task {
            await checkForUpdates(force: false)
        }
    }

    func handleAppUpdateAction() {
        switch appUpdateState {
        case .available(let release), .installFailed(_, let release):
            Task {
                await installUpdate(release)
            }
        case .checking, .installing:
            return
        default:
            Task {
                await checkForUpdates(force: true)
            }
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        guard !isUpdatingLaunchAtLogin else { return }

        isUpdatingLaunchAtLogin = true

        Task {
            do {
                try LaunchAtLoginManager.setEnabled(enabled)
                refreshLaunchAtLoginState()
                settingsStatusMessage = nil
            } catch {
                settingsStatusMessage = "Couldn't update launch at login: \(error.localizedDescription)"
                refreshLaunchAtLoginState()
            }

            isUpdatingLaunchAtLogin = false
        }
    }

    func setNotificationEnabled(_ enabled: Bool, for event: AppNotificationEvent) {
        if enabled {
            requestNotificationPermission { [weak self] granted in
                guard let self else { return }

                if granted {
                    self.settingsStore.setNotificationEnabled(true, for: event)
                    self.settingsStatusMessage = nil
                } else {
                    self.settingsStore.setNotificationEnabled(false, for: event)
                    self.settingsStatusMessage = "Notifications weren't enabled because macOS denied permission."
                }
            }
            return
        }

        settingsStore.setNotificationEnabled(false, for: event)
        settingsStatusMessage = nil
    }

    func addAndSelectKubeconfig(path: String) {
        let normalizedPath = normalizePath(path)
        guard fileManager.fileExists(atPath: normalizedPath) else { return }

        let siblingPaths = scanKubeconfigFiles(in: URL(fileURLWithPath: normalizedPath).deletingLastPathComponent())
        mergeKubeconfigOptions(with: siblingPaths + [normalizedPath])
        settingsStore.setRememberedKubeconfigPaths(kubeconfigOptions.map(\.path))
        settingsStore.setPinnedKubeconfigPath(normalizedPath)

        targetMetadata = TargetMetadata(
            kubeconfigDisplay: NSString(string: normalizedPath).abbreviatingWithTildeInPath,
            kubeconfigMode: .pinned,
            context: targetMetadata.context,
            namespace: targetMetadata.namespace,
            kubeconfigDefaultNamespace: targetMetadata.kubeconfigDefaultNamespace,
            isLastKnown: true,
            resolutionError: nil
        )

        emitDiagnosticsEvent(
            DiagnosticsEvent(
                kind: .kubeconfigChanged,
                context: targetMetadata.context,
                namespace: targetMetadata.namespace,
                message: "Kubeconfig changed to \(NSString(string: normalizedPath).abbreviatingWithTildeInPath)."
            )
        )

        userInitiatedDisconnect = false
        runCommand(
            busyMessage: "Switching kubeconfig and reconnecting...",
            switchingKubeconfig: true
        ) { cli in
            await self.namespaceDiscoveryService.clearSessionCache()
            await self.syncEnvironmentSettings()
            await self.loadKubeconfigOptions()
            await self.refreshTargetMetadata()
            return await cli.reconnect(namespace: self.activeNamespaceOverride)
        }
    }

    func changeKubeconfigPreferenceMode(to mode: KubeconfigPreferenceMode) {
        let isAlreadySelected = settingsStore.kubeconfigPreferenceMode == mode
        if isAlreadySelected, mode != .followEnvironment || settingsStore.selectedKubeconfigPath == nil {
            return
        }

        let eventMessage: String
        switch mode {
        case .pinned:
            let pinnedPath = settingsStore.selectedKubeconfigPath.map {
                NSString(string: $0).abbreviatingWithTildeInPath
            } ?? "the pinned kubeconfig"
            eventMessage = "Kubeconfig source changed to \(pinnedPath)."
        case .followEnvironment:
            eventMessage = "Kubeconfig source changed to follow $KUBECONFIG."
        }

        emitDiagnosticsEvent(
            DiagnosticsEvent(
                kind: .kubeconfigChanged,
                context: targetMetadata.context,
                namespace: targetMetadata.namespace,
                message: eventMessage
            )
        )

        userInitiatedDisconnect = false
        runCommand(
            busyMessage: "Reconnecting after kubeconfig mode change...",
            switchingKubeconfig: true
        ) { cli in
            await self.namespaceDiscoveryService.clearSessionCache()
            switch mode {
            case .pinned:
                self.settingsStore.setKubeconfigPreferenceMode(.pinned)
            case .followEnvironment:
                self.settingsStore.followEnvironmentForKubeconfig()
            }

            await self.syncEnvironmentSettings()
            await self.loadKubeconfigOptions()
            await self.refreshTargetMetadata()
            return await cli.reconnect(namespace: self.activeNamespaceOverride)
        }
    }

    func detectTelepresencePath() {
        guard !isDetectingTelepresencePath else { return }
        isDetectingTelepresencePath = true
        settingsStatusMessage = nil

        Task {
            let detectedPath = await environmentResolver.detectExecutable(
                named: "telepresence",
                envKey: "TELEPRESENCE_PATH",
                wellKnownPaths: [
                    "/usr/local/bin/telepresence",
                    "/opt/homebrew/bin/telepresence",
                    "/usr/bin/telepresence"
                ]
            )

            if let detectedPath {
                settingsStore.setTelepresencePathOverride(detectedPath)
                await syncEnvironmentSettings()
                await refreshDetectedExecutables()
                await refreshStatus()
                settingsStatusMessage = nil
            } else {
                settingsStatusMessage = "Couldn't detect telepresence from TELEPRESENCE_PATH or PATH."
            }

            isDetectingTelepresencePath = false
        }
    }

    func detectKubectlPath() {
        guard !isDetectingKubectlPath else { return }
        isDetectingKubectlPath = true
        settingsStatusMessage = nil

        Task {
            let detectedPath = await environmentResolver.detectExecutable(
                named: "kubectl",
                envKey: "KUBECTL_PATH",
                wellKnownPaths: [
                    "/usr/local/bin/kubectl",
                    "/opt/homebrew/bin/kubectl",
                    "/usr/bin/kubectl"
                ]
            )

            if let detectedPath {
                settingsStore.setKubectlPathOverride(detectedPath)
                await syncEnvironmentSettings()
                await refreshDetectedExecutables()
                await refreshTargetMetadata()
                settingsStatusMessage = nil
            } else {
                settingsStatusMessage = "Couldn't detect kubectl from KUBECTL_PATH or PATH."
            }

            isDetectingKubectlPath = false
        }
    }

    func copyStatusCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("telepresence status", forType: .string)
    }

    func diagnosticsEventStream() -> AsyncStream<DiagnosticsEvent> {
        let streamID = UUID()
        return AsyncStream { continuation in
            diagnosticsEventContinuations[streamID] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.diagnosticsEventContinuations.removeValue(forKey: streamID)
                }
            }
        }
    }

    func fetchDiagnosticsHealthSnapshot() async -> DiagnosticsHealthSnapshot {
        do {
            let baseSnapshot = try await cli.fetchDiagnosticsStatus()
            return DiagnosticsHealthSnapshot(
                status: baseSnapshot.status,
                telepresenceUnavailable: baseSnapshot.telepresenceUnavailable,
                unavailableReason: baseSnapshot.unavailableReason,
                connectedSince: connectedSince
            )
        } catch {
            return DiagnosticsHealthSnapshot(
                status: nil,
                telepresenceUnavailable: snapshot.state == .unavailable,
                unavailableReason: error.localizedDescription,
                connectedSince: connectedSince
            )
        }
    }

    func exportDiagnosticBundle() async -> DiagnosticExportOutcome {
        await cli.exportDiagnosticBundle()
    }

    func openLogs() {
        guard let url = logLocator.preferredLogURL() else { return }
        NSWorkspace.shared.open(url)
    }

    func revealLogDirectory() {
        let url = logLocator.logsDirectoryURL

        if fileManager.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
            return
        }

        NSWorkspace.shared.open(url.deletingLastPathComponent())
    }

    private func bindSettings() {
        settingsStore.$pollingInterval
            .dropFirst()
            .sink { [weak self] _ in
                self?.restartPolling()
            }
            .store(in: &cancellables)
    }

    private func syncEnvironmentSettings() async {
        await environmentResolver.apply(settings: settingsStore.makeEnvironmentSnapshot())
    }

    private func refreshDetectedExecutables() async {
        detectedTelepresencePath = await environmentResolver.resolveExecutable(
            named: "telepresence",
            envKey: "TELEPRESENCE_PATH",
            wellKnownPaths: [
                "/usr/local/bin/telepresence",
                "/opt/homebrew/bin/telepresence",
                "/usr/bin/telepresence"
            ]
        )

        detectedKubectlPath = await environmentResolver.resolveExecutable(
            named: "kubectl",
            envKey: "KUBECTL_PATH",
            wellKnownPaths: [
                "/usr/local/bin/kubectl",
                "/opt/homebrew/bin/kubectl",
                "/usr/bin/kubectl"
            ]
        )
    }

    private func loadKubeconfigOptions() async {
        let discoveredPaths = scanDefaultKubeconfigDirectory()
        let rememberedPaths = settingsStore.rememberedKubeconfigPaths.filter { fileManager.fileExists(atPath: $0) }
        let resolvedPaths = await environmentResolver.resolvedKubeconfigPaths()

        mergeKubeconfigOptions(with: discoveredPaths + rememberedPaths + resolvedPaths)
        settingsStore.setRememberedKubeconfigPaths(kubeconfigOptions.map(\.path))
        rebuildKubeconfigPickerOptions()

        if settingsStore.kubeconfigPreferenceMode == .pinned,
           let selectedKubeconfigPath = settingsStore.selectedKubeconfigPath,
           existingOptionPath(matching: selectedKubeconfigPath) == nil {
            settingsStore.setPinnedKubeconfigPath(nil)
            await syncEnvironmentSettings()
        }
    }

    private func startPolling() {
        restartPolling()
    }

    private func startUpdatePolling() {
        restartUpdatePolling()
    }

    private func restartPolling() {
        pollingTask?.cancel()

        pollingTask = Task {
            await refreshStatus()

            guard let interval = settingsStore.pollingInterval.duration else {
                return
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await refreshStatus()
            }
        }
    }

    private func restartUpdatePolling() {
        updatePollingTask?.cancel()

        updatePollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
                guard !Task.isCancelled else { return }
                await checkForUpdates(force: false)
            }
        }
    }

    private func runCommand(
        busyMessage: String,
        switchingKubeconfig: Bool = false,
        isAutoReconnect: Bool = false,
        operation: @escaping (TelepresenceCLI) async -> CommandOutcome
    ) {
        guard !isRunningCommand else { return }

        isRunningCommand = true
        isSwitchingKubeconfig = switchingKubeconfig
        snapshot = .busy(busyMessage)
        errorPresentation = nil

        Task {
            let outcome = await operation(cli)
            isRunningCommand = false
            isSwitchingKubeconfig = false

            if outcome.success == false {
                lastCommandFailure = outcome
                if isAutoReconnect {
                    emitDiagnosticsEvent(
                        DiagnosticsEvent(
                            kind: .autoReconnectFailed,
                            context: targetMetadata.context,
                            namespace: targetMetadata.namespace,
                            message: "Auto-reconnect failed for \(connectionSummaryText())."
                        )
                    )
                    await postNotification(
                        event: .autoReconnectFailed,
                        title: "Auto-reconnect failed",
                        body: outcome.summary
                    )
                }
            } else {
                lastCommandFailure = nil
            }

            await refreshStatus()
        }
    }

    private func refreshStatus() async {
        guard !isRunningCommand else { return }

        let previousState = snapshot.state
        let updatedSnapshot = await cli.fetchStatus()
        let recoveredFromAutoReconnect = hasAttemptedAutoReconnectForCurrentDrop &&
            updatedSnapshot.state == .connected &&
            previousState != .connected
        snapshot = updatedSnapshot
        updateConnectedSince(previousState: previousState, nextState: updatedSnapshot.state)
        await refreshTargetMetadata()
        await refreshDetectedExecutables()
        updateDerivedPresentation(for: updatedSnapshot)

        if updatedSnapshot.state == .connected {
            hasAttemptedAutoReconnectForCurrentDrop = false
            userInitiatedDisconnect = false
            lastCommandFailure = nil
            recordRecentNamespaceIfNeeded()
            Task { @MainActor [weak self] in
                await self?.refreshNamespacePickerOptions(force: previousState != .connected)
            }
            if recoveredFromAutoReconnect {
                emitDiagnosticsEvent(
                    DiagnosticsEvent(
                        kind: .autoReconnectSucceeded,
                        context: targetMetadata.context,
                        namespace: targetMetadata.namespace,
                        message: "Auto-reconnect succeeded for \(connectionSummaryText())."
                    )
                )
            } else if previousState != .connected {
                emitDiagnosticsEvent(
                    DiagnosticsEvent(
                        kind: .connected,
                        context: targetMetadata.context,
                        namespace: targetMetadata.namespace,
                        message: "Connected to \(connectionSummaryText())."
                    )
                )
            }
        } else if updatedSnapshot.state == .disconnected {
            await namespaceDiscoveryService.clearSessionCache()
            clearNamespacePickerOptions()

            if previousState == .connected {
                let eventKind: DiagnosticsEvent.Kind = userInitiatedDisconnect ? .disconnectedUser : .disconnectedUnexpected
                let message: String
                if userInitiatedDisconnect {
                    message = "Disconnected from \(connectionSummaryText())."
                } else {
                    message = "Connection dropped from \(connectionSummaryText())."
                }

                emitDiagnosticsEvent(
                    DiagnosticsEvent(
                        kind: eventKind,
                        context: targetMetadata.context,
                        namespace: targetMetadata.namespace,
                        message: message
                    )
                )
            }
        }

        if previousState == .connected && updatedSnapshot.state == .disconnected {
            await postNotification(
                event: .connectionDropped,
                title: "Telepresence disconnected",
                body: updatedSnapshot.detailText
            )
        } else if (previousState == .disconnected || previousState == .error) && updatedSnapshot.state == .connected {
            await postNotification(
                event: .connectionEstablished,
                title: "Telepresence connected",
                body: updatedSnapshot.detailText
            )
        }

        guard shouldAttemptAutoReconnect(from: previousState, to: updatedSnapshot.state) else {
            return
        }

        hasAttemptedAutoReconnectForCurrentDrop = true
        runCommand(busyMessage: "Connection dropped. Reconnecting...", isAutoReconnect: true) { cli in
            await self.namespaceDiscoveryService.clearSessionCache()
            return await cli.reconnect(namespace: self.activeNamespaceOverride)
        }
    }

    private func refreshTargetMetadata() async {
        let previousContext = targetMetadata.context
        let resolvedMetadata = await targetResolver.resolveTargetMetadata()
        let shouldDimMetadata = snapshot.state != .connected || resolvedMetadata.resolutionError != nil
        let resolvedContext = resolvedMetadata.context ?? targetMetadata.context
        let resolvedOverride = resolvedContext.flatMap { settingsStore.override(for: $0) }
        let resolvedDefaultNamespace = resolvedMetadata.kubeconfigDefaultNamespace ?? targetMetadata.kubeconfigDefaultNamespace
        let effectiveNamespace = resolvedOverride ?? resolvedDefaultNamespace ?? targetMetadata.namespace

        namespaceOverride = resolvedOverride
        if previousContext != resolvedContext {
            await namespaceDiscoveryService.clearSessionCache()
            clearNamespacePickerOptions()
        }

        targetMetadata = resolvedMetadata.applying(
            context: resolvedContext,
            namespace: effectiveNamespace,
            kubeconfigDefaultNamespace: resolvedDefaultNamespace,
            isLastKnown: shouldDimMetadata,
            resolutionError: resolvedMetadata.resolutionError
        )
        isProductionConnection = snapshot.state == .connected && ProductionDetector.isProduction(context: targetMetadata.context)
    }

    private func performAutoConnectOnLaunchIfNeeded() async {
        guard settingsStore.autoConnectOnLaunchEnabled else { return }

        let initialSnapshot = await cli.fetchStatus()
        snapshot = initialSnapshot
        await refreshTargetMetadata()

        guard initialSnapshot.state == .disconnected || initialSnapshot.state == .error else {
            return
        }

        snapshot = .busy("Auto-connecting on launch...")
        errorPresentation = nil

        let outcome = await cli.connect(namespace: activeNamespaceOverride)
        if outcome.success {
            await postNotification(
                event: .connectionEstablished,
                title: "Telepresence connected",
                body: outcome.summary
            )
            lastCommandFailure = nil
        } else {
            lastCommandFailure = outcome
            await postNotification(
                event: .autoConnectFailed,
                title: "Auto-connect failed",
                body: outcome.summary
            )
        }

        await refreshStatus()
    }

    private func checkForUpdates(force: Bool) async {
        if isPerformingUpdateAction {
            return
        }

        if !force,
           let lastUpdateCheckAt,
           Date.now.timeIntervalSince(lastUpdateCheckAt) < 6 * 60 * 60 {
            return
        }

        let currentVersion = Self.currentAppVersion()
        appUpdateState = .checking

        do {
            let release = try await releaseChecker.fetchLatestRelease()
            lastUpdateCheckAt = .now

            if AppReleaseChecker.isVersion(release.version, newerThan: currentVersion) {
                appUpdateState = .available(release)
            } else {
                appUpdateState = .upToDate(currentVersion: currentVersion, latestVersion: release.version)
            }
        } catch {
            lastUpdateCheckAt = .now
            appUpdateState = .checkFailed(currentVersion: currentVersion)
        }
    }

    private func installUpdate(_ release: AppRelease) async {
        guard !isPerformingUpdateAction else {
            return
        }

        appUpdateState = .installing(release)

        do {
            try await appInstaller.installLatestRelease()
            appInstaller.relaunchInstalledAppAfterCurrentProcessExits()
            NSApplication.shared.terminate(nil)
        } catch {
            appUpdateState = .installFailed(
                currentVersion: Self.currentAppVersion(),
                release: release
            )
        }
    }

    private func scanDefaultKubeconfigDirectory() -> [String] {
        let kubeDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".kube")
        return scanKubeconfigFiles(in: kubeDirectory)
    }

    private func scanKubeconfigFiles(in directoryURL: URL) -> [String] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.compactMap { fileURL in
            guard isEligibleKubeconfigFile(fileURL) else {
                return nil
            }
            return normalizePath(fileURL.path)
        }
    }

    private func isEligibleKubeconfigFile(_ fileURL: URL) -> Bool {
        let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
        guard resourceValues?.isRegularFile == true else {
            return false
        }

        let pathExtension = fileURL.pathExtension.lowercased()
        if pathExtension == "yaml" || pathExtension == "yml" || pathExtension == "kubeconfig" {
            return true
        }

        let filename = fileURL.lastPathComponent.lowercased()
        if filename == "config" || filename.hasPrefix("config-") || filename.hasPrefix("config_") {
            return true
        }

        if filename.contains("kubeconfig") {
            return true
        }

        return false
    }

    private func mergeKubeconfigOptions(with paths: [String]) {
        let validPaths = paths
            .map(normalizePath)
            .filter { fileManager.fileExists(atPath: $0) }

        let mergedPaths = Array(Set(kubeconfigOptions.map(\.path) + validPaths))
            .sorted {
                URL(fileURLWithPath: $0).lastPathComponent.localizedCaseInsensitiveCompare(
                    URL(fileURLWithPath: $1).lastPathComponent
                ) == .orderedAscending
            }

        let duplicateBasenames = Dictionary(grouping: mergedPaths, by: {
            URL(fileURLWithPath: $0).lastPathComponent
        })
        .filter { $0.value.count > 1 }

        kubeconfigOptions = mergedPaths.map { path in
            KubeconfigOption(
                path: path,
                title: formatKubeconfigOptionTitle(
                    path: path,
                    hasDuplicateBasename: duplicateBasenames[URL(fileURLWithPath: path).lastPathComponent] != nil
                )
            )
        }
    }

    private func existingOptionPath(matching path: String) -> String? {
        kubeconfigOptions.first(where: { $0.path == path })?.path
    }

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func refreshLaunchAtLoginState() {
        settingsStore.setLaunchAtLoginEnabledState(LaunchAtLoginManager.isEnabled)
    }

    private func requestNotificationPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                completion(granted)
            }
        }
    }

    private func postNotification(event: AppNotificationEvent, title: String, body: String) async {
        guard settingsStore.isNotificationEnabled(for: event) else { return }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        try? await center.add(request)
    }

    private func shouldAttemptAutoReconnect(
        from previousState: TelepresenceStatusSnapshot.State,
        to nextState: TelepresenceStatusSnapshot.State
    ) -> Bool {
        settingsStore.autoReconnectEnabled &&
        !userInitiatedDisconnect &&
        !hasAttemptedAutoReconnectForCurrentDrop &&
        previousState == .connected &&
        nextState == .disconnected
    }

    private func updateDerivedPresentation(for snapshot: TelepresenceStatusSnapshot) {
        let canOpenLogs = logLocator.hasOpenableTarget()

        if let statusPresentation = ErrorPresentationMapper.makeStatusPresentation(
            snapshot: snapshot,
            canOpenLogs: canOpenLogs
        ) {
            errorPresentation = statusPresentation
            return
        }

        if snapshot.state != .connected, let lastCommandFailure {
            errorPresentation = ErrorPresentationMapper.makeCommandFailurePresentation(
                outcome: lastCommandFailure,
                canOpenLogs: canOpenLogs
            )
            return
        }

        errorPresentation = nil
    }

    private func updateConnectedSince(
        previousState: TelepresenceStatusSnapshot.State,
        nextState: TelepresenceStatusSnapshot.State
    ) {
        if nextState == .connected && previousState != .connected {
            connectedSince = .now
        } else if nextState != .connected {
            connectedSince = nil
        }
    }

    private func emitDiagnosticsEvent(_ event: DiagnosticsEvent) {
        for continuation in diagnosticsEventContinuations.values {
            continuation.yield(event)
        }
    }

    private func connectionSummaryText() -> String {
        let context = targetMetadata.context ?? "unknown context"
        let namespace = targetMetadata.namespace ?? "unknown namespace"
        return "\(context) / \(namespace)"
    }

    private var activeNamespaceOverride: String? {
        guard let context = targetMetadata.context else {
            return nil
        }

        return settingsStore.override(for: context)
    }

    private func recordRecentNamespaceIfNeeded() {
        guard let context = targetMetadata.context,
              let namespace = targetMetadata.namespace else {
            return
        }

        settingsStore.recordRecentNamespace(namespace, for: context)
    }

    private func rebuildKubeconfigPickerOptions() {
        kubeconfigPickerOptions = kubeconfigOptions.map {
            KubeconfigPickerOption(kind: .path($0.path), title: $0.title)
        } + [
            KubeconfigPickerOption(kind: .chooseFile, title: "Choose file…")
        ]
    }

    private func formatKubeconfigOptionTitle(path: String, hasDuplicateBasename: Bool) -> String {
        let fileURL = URL(fileURLWithPath: path)
        let basename = fileURL.lastPathComponent
        guard hasDuplicateBasename else {
            return basename
        }

        let parentPath = NSString(string: fileURL.deletingLastPathComponent().path).abbreviatingWithTildeInPath
        return "\(basename) (\(parentPath))"
    }

    private func refreshNamespacePickerOptions(force: Bool = false) async {
        guard snapshot.state == .connected,
              let context = targetMetadata.context else {
            clearNamespacePickerOptions()
            return
        }

        guard force || lastNamespacePickerContext != context || namespacePickerOptions.isEmpty else {
            return
        }

        guard isLoadingNamespacePickerOptions == false else {
            return
        }

        isLoadingNamespacePickerOptions = true
        defer { isLoadingNamespacePickerOptions = false }

        let result = await namespaceDiscoveryService.fetchAvailable(for: context)
        namespacePickerOptions = makeNamespacePickerOptions(from: result)
        lastNamespacePickerContext = context
    }

    private func makeNamespacePickerOptions(from result: NamespaceListResult) -> [NamespacePickerOption] {
        let currentNamespace = targetMetadata.namespace
        let orderedNamespaces = result.available + result.recentlyUsed + [result.kubeconfigDefault] + [currentNamespace].compactMap { $0 }

        var options: [NamespacePickerOption] = []
        var seen = Set<String>()

        if result.currentOverride != nil {
            options.append(
                NamespacePickerOption(
                    kind: .useKubeconfigDefault,
                    title: formatNamespaceOptionTitle(result.kubeconfigDefault, suffix: "kubeconfig default")
                )
            )
        }

        for namespace in orderedNamespaces {
            let trimmedNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedNamespace.isEmpty == false,
                  seen.insert(trimmedNamespace).inserted else {
                continue
            }

            let suffix = result.currentOverride != nil && trimmedNamespace == result.kubeconfigDefault
                ? "kubeconfig default"
                : nil
            options.append(
                NamespacePickerOption(
                    kind: .namespace(trimmedNamespace),
                    title: formatNamespaceOptionTitle(trimmedNamespace, suffix: suffix)
                )
            )
        }

        return options
    }

    private func formatNamespaceOptionTitle(_ namespace: String, suffix: String?) -> String {
        var components = [namespace]
        if let suffix, suffix.isEmpty == false {
            components.append("(\(suffix))")
        }
        if ProductionDetector.isProductionNamespace(namespace) {
            components.append("[PROD]")
        }
        return components.joined(separator: " ")
    }

    private func clearNamespacePickerOptions() {
        namespacePickerOptions = []
        isLoadingNamespacePickerOptions = false
        lastNamespacePickerContext = nil
    }

    private func displayPathText(for path: String?) -> String {
        guard let path else {
            return "Not found"
        }

        return NSString(string: path).abbreviatingWithTildeInPath
    }

    private static func currentAppVersion(bundle: Bundle = .main) -> String {
        if let shortVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !shortVersion.isEmpty {
            return shortVersion
        }

        if let buildNumber = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !buildNumber.isEmpty {
            return buildNumber
        }

        return "0.0.0"
    }
}
