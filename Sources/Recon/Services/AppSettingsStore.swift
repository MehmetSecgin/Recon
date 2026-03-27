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

    private enum DefaultsKey {
        static let selectedKubeconfigPath = "Recon.SelectedKubeconfigPath"
        static let rememberedKubeconfigPaths = "Recon.RememberedKubeconfigPaths"
        static let hasExplicitKubeconfigSelection = "Recon.HasExplicitKubeconfigSelection"
        static let pollingIntervalSeconds = "Recon.PollingIntervalSeconds"
        static let autoReconnectEnabled = "Recon.AutoReconnectEnabled"
        static let notificationsEnabled = "Recon.NotificationsEnabled"
        static let autoConnectOnLaunchEnabled = "Recon.AutoConnectOnLaunchEnabled"
        static let telepresencePathOverride = "Recon.TelepresencePathOverride"
        static let kubectlPathOverride = "Recon.KubectlPathOverride"
        static let kubeconfigPreferenceMode = "Recon.KubeconfigPreferenceMode"
        static let notifyConnectionEstablished = "Recon.Notify.ConnectionEstablished"
        static let notifyConnectionDropped = "Recon.Notify.ConnectionDropped"
        static let notifyAutoReconnectFailed = "Recon.Notify.AutoReconnectFailed"
        static let notifyAutoConnectFailed = "Recon.Notify.AutoConnectFailed"
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
    @Published private(set) var notificationToggles: [AppNotificationEvent: Bool]

    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        launchAtLoginEnabled: Bool = LaunchAtLoginManager.isEnabled
    ) {
        self.defaults = defaults
        self.launchAtLoginEnabled = launchAtLoginEnabled
        autoConnectOnLaunchEnabled = defaults.object(forKey: DefaultsKey.autoConnectOnLaunchEnabled) as? Bool ?? false
        autoReconnectEnabled = defaults.object(forKey: DefaultsKey.autoReconnectEnabled) as? Bool ?? false
        pollingInterval = PollingIntervalOption.restored(
            from: defaults.object(forKey: DefaultsKey.pollingIntervalSeconds) as? Int
        )
        telepresencePathOverride = Self.normalize(path: defaults.string(forKey: DefaultsKey.telepresencePathOverride))
        kubectlPathOverride = Self.normalize(path: defaults.string(forKey: DefaultsKey.kubectlPathOverride))

        let storedMode = defaults.string(forKey: DefaultsKey.kubeconfigPreferenceMode)
            .flatMap(KubeconfigPreferenceMode.init(rawValue:))
        let hadExplicitSelection = defaults.object(forKey: DefaultsKey.hasExplicitKubeconfigSelection) as? Bool ?? false
        let legacySelectedPath = hadExplicitSelection
            ? Self.normalize(path: defaults.string(forKey: DefaultsKey.selectedKubeconfigPath))
            : nil
        kubeconfigPreferenceMode = storedMode ?? .pinned
        selectedKubeconfigPath = legacySelectedPath

        rememberedKubeconfigPaths = Self.normalize(paths: defaults.stringArray(forKey: DefaultsKey.rememberedKubeconfigPaths) ?? [])
        notificationToggles = Self.loadNotificationToggles(from: defaults)

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
        defaults.set(enabled, forKey: DefaultsKey.autoConnectOnLaunchEnabled)
    }

    func setAutoReconnectEnabled(_ enabled: Bool) {
        guard autoReconnectEnabled != enabled else { return }
        autoReconnectEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.autoReconnectEnabled)
    }

    func setPollingInterval(_ option: PollingIntervalOption) {
        guard pollingInterval != option else { return }
        pollingInterval = option
        defaults.set(option.rawValue, forKey: DefaultsKey.pollingIntervalSeconds)
    }

    func setNotificationEnabled(_ enabled: Bool, for event: AppNotificationEvent) {
        guard isNotificationEnabled(for: event) != enabled else { return }
        notificationToggles[event] = enabled
        defaults.set(enabled, forKey: defaultsKey(for: event))
    }

    func setTelepresencePathOverride(_ path: String?) {
        let normalizedPath = Self.normalize(path: path)
        guard telepresencePathOverride != normalizedPath else { return }
        telepresencePathOverride = normalizedPath
        persist(path: normalizedPath, key: DefaultsKey.telepresencePathOverride)
    }

    func setKubectlPathOverride(_ path: String?) {
        let normalizedPath = Self.normalize(path: path)
        guard kubectlPathOverride != normalizedPath else { return }
        kubectlPathOverride = normalizedPath
        persist(path: normalizedPath, key: DefaultsKey.kubectlPathOverride)
    }

    func setKubeconfigPreferenceMode(_ mode: KubeconfigPreferenceMode) {
        guard kubeconfigPreferenceMode != mode else { return }
        kubeconfigPreferenceMode = mode
        defaults.set(mode.rawValue, forKey: DefaultsKey.kubeconfigPreferenceMode)
    }

    func setPinnedKubeconfigPath(_ path: String?) {
        let normalizedPath = Self.normalize(path: path)
        guard selectedKubeconfigPath != normalizedPath || kubeconfigPreferenceMode != .pinned else {
            return
        }

        selectedKubeconfigPath = normalizedPath
        kubeconfigPreferenceMode = .pinned
        persist(path: normalizedPath, key: DefaultsKey.selectedKubeconfigPath)
        defaults.set(normalizedPath != nil, forKey: DefaultsKey.hasExplicitKubeconfigSelection)
        defaults.set(KubeconfigPreferenceMode.pinned.rawValue, forKey: DefaultsKey.kubeconfigPreferenceMode)
    }

    func followEnvironmentForKubeconfig() {
        guard kubeconfigPreferenceMode != .followEnvironment || selectedKubeconfigPath != nil else {
            return
        }

        kubeconfigPreferenceMode = .followEnvironment
        selectedKubeconfigPath = nil
        defaults.set(KubeconfigPreferenceMode.followEnvironment.rawValue, forKey: DefaultsKey.kubeconfigPreferenceMode)
        defaults.removeObject(forKey: DefaultsKey.selectedKubeconfigPath)
        defaults.set(false, forKey: DefaultsKey.hasExplicitKubeconfigSelection)
    }

    func setRememberedKubeconfigPaths(_ paths: [String]) {
        let normalizedPaths = Self.normalize(paths: paths)
        guard rememberedKubeconfigPaths != normalizedPaths else { return }
        rememberedKubeconfigPaths = normalizedPaths
        defaults.set(normalizedPaths, forKey: DefaultsKey.rememberedKubeconfigPaths)
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
        defaults.set(pollingInterval.rawValue, forKey: DefaultsKey.pollingIntervalSeconds)
        defaults.set(kubeconfigPreferenceMode.rawValue, forKey: DefaultsKey.kubeconfigPreferenceMode)
        defaults.set(rememberedKubeconfigPaths, forKey: DefaultsKey.rememberedKubeconfigPaths)
        persist(path: telepresencePathOverride, key: DefaultsKey.telepresencePathOverride)
        persist(path: kubectlPathOverride, key: DefaultsKey.kubectlPathOverride)
        persist(path: selectedKubeconfigPath, key: DefaultsKey.selectedKubeconfigPath)
        defaults.set(selectedKubeconfigPath != nil, forKey: DefaultsKey.hasExplicitKubeconfigSelection)

        for event in AppNotificationEvent.allCases {
            defaults.set(isNotificationEnabled(for: event), forKey: defaultsKey(for: event))
        }
    }

    private func persist(path: String?, key: String) {
        if let path {
            defaults.set(path, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func defaultsKey(for event: AppNotificationEvent) -> String {
        switch event {
        case .connectionEstablished:
            return DefaultsKey.notifyConnectionEstablished
        case .connectionDropped:
            return DefaultsKey.notifyConnectionDropped
        case .autoReconnectFailed:
            return DefaultsKey.notifyAutoReconnectFailed
        case .autoConnectFailed:
            return DefaultsKey.notifyAutoConnectFailed
        }
    }

    private static func loadNotificationToggles(from defaults: UserDefaults) -> [AppNotificationEvent: Bool] {
        let perEventValues = AppNotificationEvent.allCases.reduce(into: [AppNotificationEvent: Bool]()) { result, event in
            let key = defaultsKey(for: event)
            if let storedValue = defaults.object(forKey: key) as? Bool {
                result[event] = storedValue
            }
        }

        if perEventValues.count == AppNotificationEvent.allCases.count {
            return perEventValues
        }

        let legacyValue = defaults.object(forKey: DefaultsKey.notificationsEnabled) as? Bool ?? false
        return AppNotificationEvent.allCases.reduce(into: [AppNotificationEvent: Bool]()) { result, event in
            result[event] = perEventValues[event] ?? legacyValue
        }
    }

    private static func defaultsKey(for event: AppNotificationEvent) -> String {
        switch event {
        case .connectionEstablished:
            return DefaultsKey.notifyConnectionEstablished
        case .connectionDropped:
            return DefaultsKey.notifyConnectionDropped
        case .autoReconnectFailed:
            return DefaultsKey.notifyAutoReconnectFailed
        case .autoConnectFailed:
            return DefaultsKey.notifyAutoConnectFailed
        }
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
}
