import Foundation

struct PersistedAppSettings: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var autoConnectOnLaunchEnabled: Bool
    var autoReconnectEnabled: Bool
    var pollingIntervalSeconds: Int
    var telepresencePathOverride: String?
    var kubectlPathOverride: String?
    var kubeconfigPreferenceModeRawValue: String
    var selectedKubeconfigPath: String?
    var rememberedKubeconfigPaths: [String]
    var namespaceOverridesByContext: [String: String]
    var recentNamespacesByContext: [String: [String]]
    var notificationToggles: [String: Bool]
    var appUpdateSectionDismissed: Bool

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        autoConnectOnLaunchEnabled: Bool = false,
        autoReconnectEnabled: Bool = false,
        pollingIntervalSeconds: Int = PollingIntervalOption.defaultValue.rawValue,
        telepresencePathOverride: String? = nil,
        kubectlPathOverride: String? = nil,
        kubeconfigPreferenceModeRawValue: String = KubeconfigPreferenceMode.pinned.rawValue,
        selectedKubeconfigPath: String? = nil,
        rememberedKubeconfigPaths: [String] = [],
        namespaceOverridesByContext: [String: String] = [:],
        recentNamespacesByContext: [String: [String]] = [:],
        notificationToggles: [String: Bool] = [:],
        appUpdateSectionDismissed: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.autoConnectOnLaunchEnabled = autoConnectOnLaunchEnabled
        self.autoReconnectEnabled = autoReconnectEnabled
        self.pollingIntervalSeconds = pollingIntervalSeconds
        self.telepresencePathOverride = telepresencePathOverride
        self.kubectlPathOverride = kubectlPathOverride
        self.kubeconfigPreferenceModeRawValue = kubeconfigPreferenceModeRawValue
        self.selectedKubeconfigPath = selectedKubeconfigPath
        self.rememberedKubeconfigPaths = rememberedKubeconfigPaths
        self.namespaceOverridesByContext = namespaceOverridesByContext
        self.recentNamespacesByContext = recentNamespacesByContext
        self.notificationToggles = notificationToggles
        self.appUpdateSectionDismissed = appUpdateSectionDismissed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        autoConnectOnLaunchEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoConnectOnLaunchEnabled) ?? false
        autoReconnectEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoReconnectEnabled) ?? false
        pollingIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollingIntervalSeconds) ?? PollingIntervalOption.defaultValue.rawValue
        telepresencePathOverride = try container.decodeIfPresent(String.self, forKey: .telepresencePathOverride)
        kubectlPathOverride = try container.decodeIfPresent(String.self, forKey: .kubectlPathOverride)
        kubeconfigPreferenceModeRawValue = try container.decodeIfPresent(String.self, forKey: .kubeconfigPreferenceModeRawValue) ?? KubeconfigPreferenceMode.pinned.rawValue
        selectedKubeconfigPath = try container.decodeIfPresent(String.self, forKey: .selectedKubeconfigPath)
        rememberedKubeconfigPaths = try container.decodeIfPresent([String].self, forKey: .rememberedKubeconfigPaths) ?? []
        namespaceOverridesByContext = try container.decodeIfPresent([String: String].self, forKey: .namespaceOverridesByContext) ?? [:]
        recentNamespacesByContext = try container.decodeIfPresent([String: [String]].self, forKey: .recentNamespacesByContext) ?? [:]
        notificationToggles = try container.decodeIfPresent([String: Bool].self, forKey: .notificationToggles) ?? [:]
        appUpdateSectionDismissed = try container.decodeIfPresent(Bool.self, forKey: .appUpdateSectionDismissed) ?? false
    }
}

struct AppSettingsFileStore {
    private enum LegacyDefaultsKey {
        static let selectedKubeconfigPath = "Recon.SelectedKubeconfigPath"
        static let rememberedKubeconfigPaths = "Recon.RememberedKubeconfigPaths"
        static let namespaceOverridesByContext = "Recon.NamespaceOverridesByContext"
        static let recentNamespacesByContext = "Recon.RecentNamespacesByContext"
        static let browserKubeconfigPaths = "Recon.BrowserKubeconfigPaths"
        static let browserHasExplicitKubeconfigSources = "Recon.BrowserHasExplicitKubeconfigSources"
        static let browserLastSelectedContextID = "Recon.BrowserLastSelectedContextID"
        static let browserSelectedNamespacesByContextID = "Recon.BrowserSelectedNamespacesByContextID"
        static let browserRecentNamespacesByContextID = "Recon.BrowserRecentNamespacesByContextID"
        static let browserHiddenNamespacesByContextID = "Recon.BrowserHiddenNamespacesByContextID"
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
        static let appUpdateSectionDismissed = "Recon.AppUpdateSectionDismissed"
    }

    private let fileManager: FileManager
    private let defaults: UserDefaults
    let settingsURL: URL

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        settingsURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        if let settingsURL {
            self.settingsURL = settingsURL
        } else {
            let appSupport = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.settingsURL = (appSupport ?? fileManager.homeDirectoryForCurrentUser)
                .appendingPathComponent("Recon", isDirectory: true)
                .appendingPathComponent("settings.json")
        }
    }

    func load() -> PersistedAppSettings {
        if fileManager.fileExists(atPath: settingsURL.path) {
            return loadFromFile() ?? PersistedAppSettings()
        }

        let migrated = loadLegacyDefaults()
        do {
            try save(migrated)
            clearLegacyDefaults()
        } catch {
            reportPersistenceIssue("Failed to save migrated app settings: \(error.localizedDescription)")
        }
        return migrated
    }

    func save(_ settings: PersistedAppSettings) throws {
        try fileManager.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: .atomic)
    }

    private func loadFromFile() -> PersistedAppSettings? {
        do {
            let data = try Data(contentsOf: settingsURL)
            return try JSONDecoder().decode(PersistedAppSettings.self, from: data)
        } catch {
            reportPersistenceIssue("Failed to load app settings file: \(error.localizedDescription)")
            return nil
        }
    }

    private func loadLegacyDefaults() -> PersistedAppSettings {
        let storedMode = defaults.string(forKey: LegacyDefaultsKey.kubeconfigPreferenceMode)
            ?? KubeconfigPreferenceMode.pinned.rawValue
        let hadExplicitSelection = defaults.object(forKey: LegacyDefaultsKey.hasExplicitKubeconfigSelection) as? Bool ?? false
        let selectedPath = hadExplicitSelection
            ? defaults.string(forKey: LegacyDefaultsKey.selectedKubeconfigPath)
            : nil

        return PersistedAppSettings(
            autoConnectOnLaunchEnabled: defaults.object(forKey: LegacyDefaultsKey.autoConnectOnLaunchEnabled) as? Bool ?? false,
            autoReconnectEnabled: defaults.object(forKey: LegacyDefaultsKey.autoReconnectEnabled) as? Bool ?? false,
            pollingIntervalSeconds: defaults.object(forKey: LegacyDefaultsKey.pollingIntervalSeconds) as? Int ?? PollingIntervalOption.defaultValue.rawValue,
            telepresencePathOverride: defaults.string(forKey: LegacyDefaultsKey.telepresencePathOverride),
            kubectlPathOverride: defaults.string(forKey: LegacyDefaultsKey.kubectlPathOverride),
            kubeconfigPreferenceModeRawValue: storedMode,
            selectedKubeconfigPath: selectedPath,
            rememberedKubeconfigPaths: defaults.stringArray(forKey: LegacyDefaultsKey.rememberedKubeconfigPaths) ?? [],
            namespaceOverridesByContext: defaults.dictionary(forKey: LegacyDefaultsKey.namespaceOverridesByContext) as? [String: String] ?? [:],
            recentNamespacesByContext: defaults.dictionary(forKey: LegacyDefaultsKey.recentNamespacesByContext) as? [String: [String]] ?? [:],
            notificationToggles: loadLegacyNotificationToggles(),
            appUpdateSectionDismissed: defaults.object(forKey: LegacyDefaultsKey.appUpdateSectionDismissed) as? Bool ?? false
        )
    }

    private func loadLegacyNotificationToggles() -> [String: Bool] {
        let keysByEvent: [AppNotificationEvent: String] = [
            .connectionEstablished: LegacyDefaultsKey.notifyConnectionEstablished,
            .connectionDropped: LegacyDefaultsKey.notifyConnectionDropped,
            .autoReconnectFailed: LegacyDefaultsKey.notifyAutoReconnectFailed,
            .autoConnectFailed: LegacyDefaultsKey.notifyAutoConnectFailed
        ]

        let perEventValues = AppNotificationEvent.allCases.reduce(into: [String: Bool]()) { result, event in
            guard let key = keysByEvent[event],
                  let storedValue = defaults.object(forKey: key) as? Bool else {
                return
            }

            result[event.rawValue] = storedValue
        }

        if perEventValues.count == AppNotificationEvent.allCases.count {
            return perEventValues
        }

        let legacyValue = defaults.object(forKey: LegacyDefaultsKey.notificationsEnabled) as? Bool ?? false
        return AppNotificationEvent.allCases.reduce(into: [String: Bool]()) { result, event in
            result[event.rawValue] = perEventValues[event.rawValue] ?? legacyValue
        }
    }

    private func clearLegacyDefaults() {
        let keys = [
            LegacyDefaultsKey.selectedKubeconfigPath,
            LegacyDefaultsKey.rememberedKubeconfigPaths,
            LegacyDefaultsKey.namespaceOverridesByContext,
            LegacyDefaultsKey.recentNamespacesByContext,
            LegacyDefaultsKey.browserKubeconfigPaths,
            LegacyDefaultsKey.browserHasExplicitKubeconfigSources,
            LegacyDefaultsKey.browserLastSelectedContextID,
            LegacyDefaultsKey.browserSelectedNamespacesByContextID,
            LegacyDefaultsKey.browserRecentNamespacesByContextID,
            LegacyDefaultsKey.browserHiddenNamespacesByContextID,
            LegacyDefaultsKey.hasExplicitKubeconfigSelection,
            LegacyDefaultsKey.pollingIntervalSeconds,
            LegacyDefaultsKey.autoReconnectEnabled,
            LegacyDefaultsKey.notificationsEnabled,
            LegacyDefaultsKey.autoConnectOnLaunchEnabled,
            LegacyDefaultsKey.telepresencePathOverride,
            LegacyDefaultsKey.kubectlPathOverride,
            LegacyDefaultsKey.kubeconfigPreferenceMode,
            LegacyDefaultsKey.notifyConnectionEstablished,
            LegacyDefaultsKey.notifyConnectionDropped,
            LegacyDefaultsKey.notifyAutoReconnectFailed,
            LegacyDefaultsKey.notifyAutoConnectFailed,
            LegacyDefaultsKey.appUpdateSectionDismissed
        ]

        for key in keys {
            defaults.removeObject(forKey: key)
        }
    }
}

func reportPersistenceIssue(_ message: String) {
    fputs("Recon settings warning: \(message)\n", stderr)
}
