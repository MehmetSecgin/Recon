import AppKit
import Combine
import Foundation
import UserNotifications

struct KubeconfigOption: Identifiable, Hashable {
    let path: String

    var id: String { path }
    var displayName: String { URL(fileURLWithPath: path).lastPathComponent }
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

    let settingsStore: AppSettingsStore

    private let environmentResolver: CommandEnvironmentResolver
    private let cli: TelepresenceCLI
    private let targetResolver: KubeTargetResolver
    private let logLocator = TelepresenceLogLocator()
    private let fileManager = FileManager.default
    private var pollingTask: Task<Void, Never>?
    private var hasAttemptedAutoReconnectForCurrentDrop = false
    private var userInitiatedDisconnect = false
    private var lastCommandFailure: CommandOutcome?
    private var cancellables = Set<AnyCancellable>()

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

    var displayContext: String {
        targetMetadata.context ?? "\u{2014}"
    }

    var displayNamespace: String {
        targetMetadata.namespace ?? "\u{2014}"
    }

    init(
        settingsStore: AppSettingsStore,
        environmentResolver: CommandEnvironmentResolver = CommandEnvironmentResolver()
    ) {
        self.settingsStore = settingsStore
        self.environmentResolver = environmentResolver
        cli = TelepresenceCLI(environmentResolver: environmentResolver)
        targetResolver = KubeTargetResolver(environmentResolver: environmentResolver)

        bindSettings()

        Task { [weak self] in
            guard let self else { return }
            self.refreshLaunchAtLoginState()
            await self.syncEnvironmentSettings()
            await self.refreshDetectedExecutables()
            await self.loadKubeconfigOptions()
            await self.performAutoConnectOnLaunchIfNeeded()
            self.startPolling()
        }
    }

    deinit {
        pollingTask?.cancel()
    }

    func connect() {
        userInitiatedDisconnect = false
        runCommand(busyMessage: "Connecting to Telepresence...") { cli in
            await cli.connect()
        }
    }

    func reconnect() {
        userInitiatedDisconnect = false
        runCommand(busyMessage: "Restarting Telepresence...") { cli in
            await cli.reconnect()
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        runCommand(busyMessage: "Disconnecting Telepresence...") { cli in
            await cli.disconnect()
        }
    }

    func refreshNow() {
        Task {
            await refreshStatus()
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
            isLastKnown: true,
            resolutionError: nil
        )

        userInitiatedDisconnect = false
        runCommand(
            busyMessage: "Switching kubeconfig and reconnecting...",
            switchingKubeconfig: true
        ) { cli in
            await self.syncEnvironmentSettings()
            await self.loadKubeconfigOptions()
            await self.refreshTargetMetadata()
            return await cli.reconnect()
        }
    }

    func changeKubeconfigPreferenceMode(to mode: KubeconfigPreferenceMode) {
        let isAlreadySelected = settingsStore.kubeconfigPreferenceMode == mode
        if isAlreadySelected, mode != .followEnvironment || settingsStore.selectedKubeconfigPath == nil {
            return
        }

        userInitiatedDisconnect = false
        runCommand(
            busyMessage: "Reconnecting after kubeconfig mode change...",
            switchingKubeconfig: true
        ) { cli in
            switch mode {
            case .pinned:
                self.settingsStore.setKubeconfigPreferenceMode(.pinned)
            case .followEnvironment:
                self.settingsStore.followEnvironmentForKubeconfig()
            }

            await self.syncEnvironmentSettings()
            await self.loadKubeconfigOptions()
            await self.refreshTargetMetadata()
            return await cli.reconnect()
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
        snapshot = updatedSnapshot
        await refreshTargetMetadata()
        await refreshDetectedExecutables()
        updateDerivedPresentation(for: updatedSnapshot)

        if updatedSnapshot.state == .connected {
            hasAttemptedAutoReconnectForCurrentDrop = false
            userInitiatedDisconnect = false
            lastCommandFailure = nil
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
            await cli.reconnect()
        }
    }

    private func refreshTargetMetadata() async {
        let resolvedMetadata = await targetResolver.resolveTargetMetadata()
        let shouldDimMetadata = snapshot.state != .connected || resolvedMetadata.resolutionError != nil

        let mergedContext = resolvedMetadata.context ?? targetMetadata.context
        let mergedNamespace = resolvedMetadata.namespace ?? targetMetadata.namespace

        targetMetadata = resolvedMetadata.applying(
            context: mergedContext,
            namespace: mergedNamespace,
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

        let outcome = await cli.connect()
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

        kubeconfigOptions = mergedPaths.map(KubeconfigOption.init(path:))
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

    private func displayPathText(for path: String?) -> String {
        guard let path else {
            return "Not found"
        }

        return NSString(string: path).abbreviatingWithTildeInPath
    }
}
