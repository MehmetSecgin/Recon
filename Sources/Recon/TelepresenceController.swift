import Combine
import Foundation
import ServiceManagement
import UserNotifications

struct KubeconfigOption: Identifiable, Hashable {
    let path: String

    var id: String { path }
    var displayName: String { URL(fileURLWithPath: path).lastPathComponent }
}

@MainActor
final class TelepresenceController: ObservableObject {
    private enum DefaultsKey {
        static let selectedKubeconfigPath = "Recon.SelectedKubeconfigPath"
        static let rememberedKubeconfigPaths = "Recon.RememberedKubeconfigPaths"
        static let hasExplicitKubeconfigSelection = "Recon.HasExplicitKubeconfigSelection"
        static let pollingIntervalSeconds = "Recon.PollingIntervalSeconds"
        static let autoReconnectEnabled = "Recon.AutoReconnectEnabled"
        static let notificationsEnabled = "Recon.NotificationsEnabled"
        static let autoConnectOnLaunchEnabled = "Recon.AutoConnectOnLaunchEnabled"
    }

    enum PollingIntervalOption: Int, CaseIterable, Identifiable {
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900
        case thirtyMinutes = 1800

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .oneMinute:
                return "1 minute"
            case .fiveMinutes:
                return "5 minutes"
            case .fifteenMinutes:
                return "15 minutes"
            case .thirtyMinutes:
                return "30 minutes"
            }
        }

        var duration: Duration {
            .seconds(rawValue)
        }
    }

    @Published private(set) var snapshot = TelepresenceStatusSnapshot.busy("Checking Recon...")
    @Published private(set) var targetMetadata = TargetMetadata.empty
    @Published private(set) var isRunningCommand = false
    @Published private(set) var isSwitchingKubeconfig = false
    @Published private(set) var kubeconfigOptions: [KubeconfigOption] = []
    @Published private(set) var selectedPollingInterval: PollingIntervalOption
    @Published private(set) var autoReconnectEnabled: Bool
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var autoConnectOnLaunchEnabled: Bool
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var isUpdatingLaunchAtLogin = false
    @Published var selectedKubeconfigPath: String?
    @Published private(set) var lastErrorText: String?

    private let environmentResolver: CommandEnvironmentResolver
    private let cli: TelepresenceCLI
    private let targetResolver: KubeTargetResolver
    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private var pollingTask: Task<Void, Never>?
    private var hasAttemptedAutoReconnectForCurrentDrop = false
    private var userInitiatedDisconnect = false

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
        case .disconnected, .unavailable, .error:
            return lastErrorText ?? snapshot.detailText
        }
    }

    var shouldShowTimestamp: Bool {
        snapshot.state != .busy
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

    init() {
        let environmentResolver = CommandEnvironmentResolver()
        self.environmentResolver = environmentResolver
        cli = TelepresenceCLI(environmentResolver: environmentResolver)
        targetResolver = KubeTargetResolver(environmentResolver: environmentResolver)

        let storedInterval = defaults.object(forKey: DefaultsKey.pollingIntervalSeconds) as? Int
        selectedPollingInterval = PollingIntervalOption(rawValue: storedInterval ?? PollingIntervalOption.fiveMinutes.rawValue)
            ?? .fiveMinutes
        autoReconnectEnabled = defaults.object(forKey: DefaultsKey.autoReconnectEnabled) as? Bool ?? false
        notificationsEnabled = defaults.object(forKey: DefaultsKey.notificationsEnabled) as? Bool ?? false
        autoConnectOnLaunchEnabled = defaults.object(forKey: DefaultsKey.autoConnectOnLaunchEnabled) as? Bool ?? false

        Task { [weak self] in
            guard let self else { return }
            self.refreshLaunchAtLoginState()
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

    func setPollingInterval(seconds: Int) {
        let nextInterval = PollingIntervalOption(rawValue: seconds) ?? .fiveMinutes
        guard selectedPollingInterval != nextInterval else { return }

        selectedPollingInterval = nextInterval
        defaults.set(nextInterval.rawValue, forKey: DefaultsKey.pollingIntervalSeconds)
        restartPolling()
    }

    func setAutoReconnectEnabled(_ enabled: Bool) {
        guard autoReconnectEnabled != enabled else { return }
        autoReconnectEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.autoReconnectEnabled)
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard notificationsEnabled != enabled else { return }

        if enabled {
            requestNotificationPermission { [weak self] granted in
                guard let self else { return }

                if granted {
                    self.notificationsEnabled = true
                    self.defaults.set(true, forKey: DefaultsKey.notificationsEnabled)
                    self.lastErrorText = nil
                } else {
                    self.notificationsEnabled = false
                    self.defaults.set(false, forKey: DefaultsKey.notificationsEnabled)
                    self.lastErrorText = "Notifications were not enabled because permission was denied."
                }
            }
            return
        }

        notificationsEnabled = false
        defaults.set(false, forKey: DefaultsKey.notificationsEnabled)
    }

    func setAutoConnectOnLaunchEnabled(_ enabled: Bool) {
        guard autoConnectOnLaunchEnabled != enabled else { return }
        autoConnectOnLaunchEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.autoConnectOnLaunchEnabled)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        guard !isUpdatingLaunchAtLogin else { return }

        isUpdatingLaunchAtLogin = true

        Task {
            do {
                try LaunchAtLoginManager.setEnabled(enabled)
                refreshLaunchAtLoginState()
            } catch {
                lastErrorText = "Could not update launch at login: \(error.localizedDescription)"
                refreshLaunchAtLoginState()
            }

            isUpdatingLaunchAtLogin = false
        }
    }

    func addAndSelectKubeconfig(path: String) {
        let normalizedPath = normalizePath(path)
        guard fileManager.fileExists(atPath: normalizedPath) else { return }

        let siblingPaths = scanKubeconfigFiles(in: URL(fileURLWithPath: normalizedPath).deletingLastPathComponent())
        mergeKubeconfigOptions(with: siblingPaths + [normalizedPath])
        persistKubeconfigOptions()

        selectedKubeconfigPath = normalizedPath
        persistSelectedKubeconfigPath()
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
            await self.environmentResolver.setPinnedKubeconfigPath(normalizedPath)
            return await cli.reconnect()
        }
    }

    private func loadKubeconfigOptions() async {
        let discoveredPaths = scanDefaultKubeconfigDirectory()
        let rememberedPaths = loadRememberedKubeconfigPaths()
        let resolvedPaths = await environmentResolver.resolvedKubeconfigPaths()

        mergeKubeconfigOptions(with: discoveredPaths + rememberedPaths + resolvedPaths)

        let savedSelection = defaults.string(forKey: DefaultsKey.selectedKubeconfigPath).map(normalizePath)
        let hasExplicitSelection = defaults.object(forKey: DefaultsKey.hasExplicitKubeconfigSelection) as? Bool ?? false

        let shouldTreatSavedSelectionAsPinned: Bool
        if hasExplicitSelection {
            shouldTreatSavedSelectionAsPinned = true
        } else if let savedSelection {
            shouldTreatSavedSelectionAsPinned = resolvedPaths.contains(savedSelection) == false
        } else {
            shouldTreatSavedSelectionAsPinned = false
        }

        selectedKubeconfigPath = shouldTreatSavedSelectionAsPinned
            ? savedSelection.flatMap(existingOptionPath(matching:))
            : nil

        await environmentResolver.setPinnedKubeconfigPath(selectedKubeconfigPath)
        persistSelectedKubeconfigPath()
        persistKubeconfigOptions()
        await refreshTargetMetadata()
    }

    private func startPolling() {
        restartPolling()
    }

    private func restartPolling() {
        pollingTask?.cancel()

        pollingTask = Task {
            await refreshStatus()

            while !Task.isCancelled {
                try? await Task.sleep(for: selectedPollingInterval.duration)
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
        lastErrorText = nil

        Task {
            let outcome = await operation(cli)
            isRunningCommand = false
            isSwitchingKubeconfig = false

            if outcome.success == false {
                lastErrorText = outcome.details ?? outcome.summary
                if isAutoReconnect {
                    await postNotification(title: "Auto-reconnect failed", body: outcome.summary)
                }
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

        if updatedSnapshot.state == .connected {
            hasAttemptedAutoReconnectForCurrentDrop = false
            userInitiatedDisconnect = false
        }

        if updatedSnapshot.state == .error {
            lastErrorText = updatedSnapshot.detailText
        }

        if previousState == .connected && updatedSnapshot.state == .disconnected {
            await postNotification(title: "Telepresence disconnected", body: updatedSnapshot.detailText)
        } else if (previousState == .disconnected || previousState == .error) && updatedSnapshot.state == .connected {
            await postNotification(title: "Telepresence connected", body: updatedSnapshot.detailText)
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
    }

    private func performAutoConnectOnLaunchIfNeeded() async {
        guard autoConnectOnLaunchEnabled else { return }

        let initialSnapshot = await cli.fetchStatus()
        snapshot = initialSnapshot
        await refreshTargetMetadata()

        guard initialSnapshot.state == .disconnected || initialSnapshot.state == .error else {
            return
        }

        snapshot = .busy("Auto-connecting on launch...")
        lastErrorText = nil

        let outcome = await cli.connect()
        if outcome.success {
            await postNotification(title: "Telepresence connected", body: outcome.summary)
        } else {
            lastErrorText = outcome.details ?? outcome.summary
            await postNotification(title: "Auto-connect failed", body: outcome.summary)
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

    private func loadRememberedKubeconfigPaths() -> [String] {
        let storedPaths = defaults.stringArray(forKey: DefaultsKey.rememberedKubeconfigPaths) ?? []
        return storedPaths
            .map(normalizePath)
            .filter { fileManager.fileExists(atPath: $0) }
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

    private func persistKubeconfigOptions() {
        defaults.set(kubeconfigOptions.map(\.path), forKey: DefaultsKey.rememberedKubeconfigPaths)
    }

    private func persistSelectedKubeconfigPath() {
        if let selectedKubeconfigPath {
            defaults.set(selectedKubeconfigPath, forKey: DefaultsKey.selectedKubeconfigPath)
            defaults.set(true, forKey: DefaultsKey.hasExplicitKubeconfigSelection)
        } else {
            defaults.removeObject(forKey: DefaultsKey.selectedKubeconfigPath)
            defaults.set(false, forKey: DefaultsKey.hasExplicitKubeconfigSelection)
        }
    }

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func refreshLaunchAtLoginState() {
        isLaunchAtLoginEnabled = LaunchAtLoginManager.isEnabled
    }

    private func requestNotificationPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                completion(granted)
            }
        }
    }

    private func postNotification(title: String, body: String) async {
        guard notificationsEnabled else { return }

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
        autoReconnectEnabled &&
        !userInitiatedDisconnect &&
        !hasAttemptedAutoReconnectForCurrentDrop &&
        previousState == .connected &&
        nextState == .disconnected
    }
}

private enum LaunchAtLoginManager {
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
