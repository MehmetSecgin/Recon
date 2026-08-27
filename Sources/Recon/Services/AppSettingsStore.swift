import Combine
import Foundation

@MainActor
final class AppSettingsStore: ObservableObject {
    struct EnvironmentSettingsSnapshot: Sendable {
        let kubeconfigPreferenceMode: KubeconfigPreferenceMode
        let selectedKubeconfigPath: String?
        let telepresencePathOverride: String?
        let kubectlPathOverride: String?
    }

    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var autoConnectOnLaunchEnabled: Bool
    @Published private(set) var autoReconnectEnabled: Bool
    @Published private(set) var pollingInterval: PollingIntervalOption
    @Published private(set) var telepresencePathOverride: String?
    @Published private(set) var kubectlPathOverride: String?
    @Published private(set) var kubeconfigPreferenceMode: KubeconfigPreferenceMode
    @Published private(set) var selectedKubeconfigPath: String?
    @Published private(set) var rememberedKubeconfigPaths: [String]
    @Published private(set) var namespaceOverridesByContext: [String: String]
    @Published private(set) var recentNamespacesByContext: [String: [String]]
    @Published private(set) var notificationToggles: [AppNotificationEvent: Bool]
    @Published private(set) var appUpdateSectionDismissed: Bool

    private let fileStore: AppSettingsFileStore

    init(
        defaults: UserDefaults = .standard,
        fileStore: AppSettingsFileStore? = nil,
        launchAtLoginEnabled: Bool = LaunchAtLoginManager.isEnabled
    ) {
        self.fileStore = fileStore ?? AppSettingsFileStore(defaults: defaults)
        let persisted = self.fileStore.load()
        self.launchAtLoginEnabled = launchAtLoginEnabled
        autoConnectOnLaunchEnabled = persisted.autoConnectOnLaunchEnabled
        autoReconnectEnabled = persisted.autoReconnectEnabled
        pollingInterval = PollingIntervalOption.restored(
            from: persisted.pollingIntervalSeconds
        )
        telepresencePathOverride = Self.normalize(path: persisted.telepresencePathOverride)
        kubectlPathOverride = Self.normalize(path: persisted.kubectlPathOverride)

        kubeconfigPreferenceMode = KubeconfigPreferenceMode(rawValue: persisted.kubeconfigPreferenceModeRawValue) ?? .pinned
        selectedKubeconfigPath = Self.normalize(path: persisted.selectedKubeconfigPath)

        rememberedKubeconfigPaths = Self.normalize(paths: persisted.rememberedKubeconfigPaths)
        namespaceOverridesByContext = Self.normalize(namespaceOverrides: persisted.namespaceOverridesByContext)
        recentNamespacesByContext = Self.normalize(recentNamespacesByContext: persisted.recentNamespacesByContext)
        notificationToggles = Self.normalize(notificationToggles: persisted.notificationToggles)
        appUpdateSectionDismissed = persisted.appUpdateSectionDismissed

        persistCanonicalState()
    }

    var hasAnyNotificationsEnabled: Bool {
        AppNotificationEvent.allCases.contains { isNotificationEnabled(for: $0) }
    }

    func isNotificationEnabled(for event: AppNotificationEvent) -> Bool {
        notificationToggles[event] ?? false
    }

    func setLaunchAtLoginEnabledState(_ enabled: Bool) {
        guard launchAtLoginEnabled != enabled else { return }
        launchAtLoginEnabled = enabled
    }

    func setAutoConnectOnLaunchEnabled(_ enabled: Bool) {
        guard autoConnectOnLaunchEnabled != enabled else { return }
        autoConnectOnLaunchEnabled = enabled
        persistCanonicalState()
    }

    func setAutoReconnectEnabled(_ enabled: Bool) {
        guard autoReconnectEnabled != enabled else { return }
        autoReconnectEnabled = enabled
        persistCanonicalState()
    }

    func setPollingInterval(_ option: PollingIntervalOption) {
        guard pollingInterval != option else { return }
        pollingInterval = option
        persistCanonicalState()
    }

    func setNotificationEnabled(_ enabled: Bool, for event: AppNotificationEvent) {
        guard isNotificationEnabled(for: event) != enabled else { return }
        notificationToggles[event] = enabled
        persistCanonicalState()
    }

    func setTelepresencePathOverride(_ path: String?) {
        let normalizedPath = Self.normalize(path: path)
        guard telepresencePathOverride != normalizedPath else { return }
        telepresencePathOverride = normalizedPath
        persistCanonicalState()
    }

    func setKubectlPathOverride(_ path: String?) {
        let normalizedPath = Self.normalize(path: path)
        guard kubectlPathOverride != normalizedPath else { return }
        kubectlPathOverride = normalizedPath
        persistCanonicalState()
    }

    func setKubeconfigPreferenceMode(_ mode: KubeconfigPreferenceMode) {
        guard kubeconfigPreferenceMode != mode else { return }
        kubeconfigPreferenceMode = mode
        persistCanonicalState()
    }

    func setPinnedKubeconfigPath(_ path: String?) {
        let normalizedPath = Self.normalize(path: path)
        guard selectedKubeconfigPath != normalizedPath || kubeconfigPreferenceMode != .pinned else {
            return
        }

        selectedKubeconfigPath = normalizedPath
        kubeconfigPreferenceMode = .pinned
        persistCanonicalState()
    }

    func followEnvironmentForKubeconfig() {
        guard kubeconfigPreferenceMode != .followEnvironment || selectedKubeconfigPath != nil else {
            return
        }

        kubeconfigPreferenceMode = .followEnvironment
        selectedKubeconfigPath = nil
        persistCanonicalState()
    }

    func setRememberedKubeconfigPaths(_ paths: [String]) {
        let normalizedPaths = Self.normalize(paths: paths)
        guard rememberedKubeconfigPaths != normalizedPaths else { return }
        rememberedKubeconfigPaths = normalizedPaths
        persistCanonicalState()
    }

    func override(for context: String) -> String? {
        guard let normalizedContext = Self.normalize(contextKey: context) else {
            return nil
        }

        return namespaceOverridesByContext[normalizedContext]
    }

    func setOverride(_ namespace: String, for context: String) {
        guard let normalizedContext = Self.normalize(contextKey: context),
              let normalizedNamespace = Self.normalize(namespace: namespace) else {
            return
        }

        guard namespaceOverridesByContext[normalizedContext] != normalizedNamespace else { return }
        namespaceOverridesByContext[normalizedContext] = normalizedNamespace
        persistCanonicalState()
    }

    func clearOverride(for context: String) {
        guard let normalizedContext = Self.normalize(contextKey: context),
              namespaceOverridesByContext.removeValue(forKey: normalizedContext) != nil else {
            return
        }

        persistCanonicalState()
    }

    func recentNamespaces(for context: String) -> [String] {
        guard let normalizedContext = Self.normalize(contextKey: context) else {
            return []
        }

        return recentNamespacesByContext[normalizedContext] ?? []
    }

    func recordRecentNamespace(_ namespace: String, for context: String) {
        guard let normalizedContext = Self.normalize(contextKey: context),
              let normalizedNamespace = Self.normalize(namespace: namespace) else {
            return
        }

        var updated = recentNamespacesByContext[normalizedContext] ?? []
        updated.removeAll { $0 == normalizedNamespace }
        updated.insert(normalizedNamespace, at: 0)
        if updated.count > 10 {
            updated = Array(updated.prefix(10))
        }

        guard recentNamespacesByContext[normalizedContext] != updated else { return }
        recentNamespacesByContext[normalizedContext] = updated
        persistCanonicalState()
    }

    func setAppUpdateSectionDismissed(_ dismissed: Bool) {
        guard appUpdateSectionDismissed != dismissed else { return }
        appUpdateSectionDismissed = dismissed
        persistCanonicalState()
    }

    func makeEnvironmentSnapshot() -> EnvironmentSettingsSnapshot {
        EnvironmentSettingsSnapshot(
            kubeconfigPreferenceMode: kubeconfigPreferenceMode,
            selectedKubeconfigPath: selectedKubeconfigPath,
            telepresencePathOverride: telepresencePathOverride,
            kubectlPathOverride: kubectlPathOverride
        )
    }

    private func persistCanonicalState() {
        do {
            try fileStore.save(makePersistedSettings())
        } catch {
            reportPersistenceIssue("Failed to save app settings: \(error.localizedDescription)")
        }
    }

    private func makePersistedSettings() -> PersistedAppSettings {
        PersistedAppSettings(
            autoConnectOnLaunchEnabled: autoConnectOnLaunchEnabled,
            autoReconnectEnabled: autoReconnectEnabled,
            pollingIntervalSeconds: pollingInterval.rawValue,
            telepresencePathOverride: telepresencePathOverride,
            kubectlPathOverride: kubectlPathOverride,
            kubeconfigPreferenceModeRawValue: kubeconfigPreferenceMode.rawValue,
            selectedKubeconfigPath: selectedKubeconfigPath,
            rememberedKubeconfigPaths: rememberedKubeconfigPaths,
            namespaceOverridesByContext: namespaceOverridesByContext,
            recentNamespacesByContext: recentNamespacesByContext,
            notificationToggles: Self.serialize(notificationToggles: notificationToggles),
            appUpdateSectionDismissed: appUpdateSectionDismissed
        )
    }

    private static func normalize(path: String?) -> String? {
        guard let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: trimmedPath).standardizedFileURL.path
    }

    private static func normalize(paths: [String]) -> [String] {
        Array(Set(paths.compactMap(normalize(path:)))).sorted()
    }

    private static func normalize(contextKey: String?) -> String? {
        let trimmed = contextKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalize(namespace: String?) -> String? {
        let trimmed = namespace?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private static func normalize(namespaceOverrides: [String: String]) -> [String: String] {
        namespaceOverrides.reduce(into: [String: String]()) { result, element in
            guard let context = normalize(contextKey: element.key),
                  let namespace = normalize(namespace: element.value) else {
                return
            }

            result[context] = namespace
        }
    }

    private static func normalize(recentNamespacesByContext: [String: [String]]) -> [String: [String]] {
        recentNamespacesByContext.reduce(into: [String: [String]]()) { result, element in
            guard let context = normalize(contextKey: element.key) else {
                return
            }

            let namespaces = element.value
                .compactMap { normalize(namespace: $0) }
                .reduce(into: [String]()) { seenNamespaces, namespace in
                    if seenNamespaces.contains(namespace) == false {
                        seenNamespaces.append(namespace)
                    }
                }

            guard namespaces.isEmpty == false else { return }
            result[context] = Array(namespaces.prefix(10))
        }
    }

    private static func normalize(notificationToggles: [String: Bool]) -> [AppNotificationEvent: Bool] {
        AppNotificationEvent.allCases.reduce(into: [AppNotificationEvent: Bool]()) { result, event in
            result[event] = notificationToggles[event.rawValue] ?? false
        }
    }

    private static func serialize(notificationToggles: [AppNotificationEvent: Bool]) -> [String: Bool] {
        notificationToggles.reduce(into: [String: Bool]()) { result, element in
            result[element.key.rawValue] = element.value
        }
    }
}
