import Foundation

@main
@MainActor
struct AppSettingsStoreHarness {
    static func main() throws {
        try testLegacyDefaultsMigrateIntoSettingsFile()
        try testSettingsFileWinsOverLegacyDefaults()
        try testCorruptSettingsFileFallsBackSafely()

        print("App settings harness passed")
    }

    private enum LegacyDefaultsKey {
        static let selectedKubeconfigPath = "Recon.SelectedKubeconfigPath"
        static let rememberedKubeconfigPaths = "Recon.RememberedKubeconfigPaths"
        static let browserKubeconfigPaths = "Recon.BrowserKubeconfigPaths"
        static let browserHasExplicitKubeconfigSources = "Recon.BrowserHasExplicitKubeconfigSources"
        static let browserLastSelectedContextID = "Recon.BrowserLastSelectedContextID"
        static let browserSelectedNamespacesByContextID = "Recon.BrowserSelectedNamespacesByContextID"
        static let browserRecentNamespacesByContextID = "Recon.BrowserRecentNamespacesByContextID"
        static let browserHiddenNamespacesByContextID = "Recon.BrowserHiddenNamespacesByContextID"
        static let hasExplicitKubeconfigSelection = "Recon.HasExplicitKubeconfigSelection"
        static let pollingIntervalSeconds = "Recon.PollingIntervalSeconds"
        static let autoReconnectEnabled = "Recon.AutoReconnectEnabled"
        static let autoConnectOnLaunchEnabled = "Recon.AutoConnectOnLaunchEnabled"
        static let telepresencePathOverride = "Recon.TelepresencePathOverride"
        static let kubeconfigPreferenceMode = "Recon.KubeconfigPreferenceMode"
        static let notifyConnectionDropped = "Recon.Notify.ConnectionDropped"
    }

    private static func testLegacyDefaultsMigrateIntoSettingsFile() throws {
        let (defaults, suiteName) = makeDefaults()
        let settingsURL = try makeSettingsURL()
        defer { cleanup(settingsURL: settingsURL, defaults: defaults, suiteName: suiteName) }

        defaults.set(true, forKey: LegacyDefaultsKey.autoConnectOnLaunchEnabled)
        defaults.set(true, forKey: LegacyDefaultsKey.autoReconnectEnabled)
        defaults.set(PollingIntervalOption.thirtySeconds.rawValue, forKey: LegacyDefaultsKey.pollingIntervalSeconds)
        defaults.set("/tmp/../tmp/telepresence", forKey: LegacyDefaultsKey.telepresencePathOverride)
        defaults.set(KubeconfigPreferenceMode.pinned.rawValue, forKey: LegacyDefaultsKey.kubeconfigPreferenceMode)
        defaults.set(true, forKey: LegacyDefaultsKey.hasExplicitKubeconfigSelection)
        defaults.set("/tmp/../tmp/config-a", forKey: LegacyDefaultsKey.selectedKubeconfigPath)
        defaults.set(["/tmp/../tmp/config-b", "/tmp/../tmp/config-a"], forKey: LegacyDefaultsKey.rememberedKubeconfigPaths)
        defaults.set(["/tmp/../tmp/browser-a"], forKey: LegacyDefaultsKey.browserKubeconfigPaths)
        defaults.set(true, forKey: LegacyDefaultsKey.browserHasExplicitKubeconfigSources)
        defaults.set("source-a#qa", forKey: LegacyDefaultsKey.browserLastSelectedContextID)
        defaults.set(["source-a#qa": "payments"], forKey: LegacyDefaultsKey.browserSelectedNamespacesByContextID)
        defaults.set(["source-a#qa": ["payments", "default", "payments"]], forKey: LegacyDefaultsKey.browserRecentNamespacesByContextID)
        defaults.set(["source-a#qa": ["hidden-a", "hidden-a", "hidden-b"]], forKey: LegacyDefaultsKey.browserHiddenNamespacesByContextID)
        defaults.set(true, forKey: LegacyDefaultsKey.notifyConnectionDropped)

        let store = makeStore(settingsURL: settingsURL, defaults: defaults)

        try expect(FileManager.default.fileExists(atPath: settingsURL.path), "Migration should create a durable settings file")
        try expect(store.autoConnectOnLaunchEnabled, "Auto-connect should migrate from legacy defaults")
        try expect(store.autoReconnectEnabled, "Auto-reconnect should migrate from legacy defaults")
        try expect(store.pollingInterval == .thirtySeconds, "Polling interval should migrate from legacy defaults")
        try expect(store.telepresencePathOverride == standardizedPath("/tmp/../tmp/telepresence"), "Migrated paths should be normalized")
        try expect(store.selectedKubeconfigPath == standardizedPath("/tmp/../tmp/config-a"), "Pinned kubeconfig should migrate")
        try expect(store.isNotificationEnabled(for: .connectionDropped), "Per-event notification settings should migrate")
        try expect(defaults.object(forKey: LegacyDefaultsKey.browserHiddenNamespacesByContextID) == nil, "Legacy defaults should be cleared after migration")
        try expect(defaults.object(forKey: LegacyDefaultsKey.autoReconnectEnabled) == nil, "Legacy scalar defaults should be cleared after migration")

        let (reloadedDefaults, reloadedSuiteName) = makeDefaults()
        defer { cleanupDefaults(reloadedDefaults, suiteName: reloadedSuiteName) }
        let reloaded = makeStore(settingsURL: settingsURL, defaults: reloadedDefaults)
        try expect(reloaded.autoReconnectEnabled, "Reloaded state should come from the settings file")
    }

    private static func testSettingsFileWinsOverLegacyDefaults() throws {
        let (initialDefaults, initialSuiteName) = makeDefaults()
        let settingsURL = try makeSettingsURL()
        defer { cleanup(settingsURL: settingsURL, defaults: initialDefaults, suiteName: initialSuiteName) }

        let initialStore = makeStore(settingsURL: settingsURL, defaults: initialDefaults)
        initialStore.setAutoReconnectEnabled(true)

        let (conflictingDefaults, conflictingSuiteName) = makeDefaults()
        conflictingDefaults.set(false, forKey: LegacyDefaultsKey.autoReconnectEnabled)
        defer { cleanupDefaults(conflictingDefaults, suiteName: conflictingSuiteName) }

        let reloaded = makeStore(settingsURL: settingsURL, defaults: conflictingDefaults)
        try expect(reloaded.autoReconnectEnabled, "Existing settings file should take precedence over legacy defaults")
    }

    private static func testCorruptSettingsFileFallsBackSafely() throws {
        let (defaults, suiteName) = makeDefaults()
        let settingsURL = try makeSettingsURL()
        defer { cleanup(settingsURL: settingsURL, defaults: defaults, suiteName: suiteName) }

        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data("{not-json".utf8).write(to: settingsURL, options: .atomic)
        defaults.set(true, forKey: LegacyDefaultsKey.autoReconnectEnabled)

        let store = makeStore(settingsURL: settingsURL, defaults: defaults)
        try expect(store.autoReconnectEnabled == false, "Corrupt settings files should not silently fall back to legacy defaults")
    }

    private static func makeStore(settingsURL: URL, defaults: UserDefaults) -> AppSettingsStore {
        AppSettingsStore(
            defaults: defaults,
            fileStore: AppSettingsFileStore(defaults: defaults, settingsURL: settingsURL),
            launchAtLoginEnabled: false
        )
    }

    private static func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "Recon.AppSettingsHarness.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private static func makeSettingsURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recon-app-settings-\(UUID().uuidString)", isDirectory: true)
        return directory.appendingPathComponent("settings.json")
    }

    private static func cleanup(settingsURL: URL, defaults: UserDefaults, suiteName: String) {
        try? FileManager.default.removeItem(at: settingsURL.deletingLastPathComponent())
        cleanupDefaults(defaults, suiteName: suiteName)
    }

    private static func cleanupDefaults(_ defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if condition() == false {
            throw HarnessError(message: message)
        }
    }
}

private struct HarnessError: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}
