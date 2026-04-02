import AppKit
import SwiftUI

@main
struct ReconApp: App {
    @StateObject private var settingsStore: AppSettingsStore
    @StateObject private var controller: TelepresenceController
    private let diagnosticsEventRecorder: DiagnosticsEventRecorder

    init() {
        let settingsStore = AppSettingsStore()
        let environmentResolver = CommandEnvironmentResolver()
        let controller = TelepresenceController(
            settingsStore: settingsStore,
            environmentResolver: environmentResolver
        )
        _settingsStore = StateObject(wrappedValue: settingsStore)
        _controller = StateObject(wrappedValue: controller)
        diagnosticsEventRecorder = DiagnosticsEventRecorder(controller: controller)
    }

    var body: some Scene {
        let _ = diagnosticsEventRecorder

        MenuBarExtra {
            ReconMenuView(controller: controller)
        } label: {
            Text(controller.statusItemTitle)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
        .menuBarExtraStyle(.window)
        .commands {
            PreferencesCommands()
        }

        Window("Recon — Preferences", id: AppWindowID.preferences) {
            PreferencesWindowView(controller: controller, settingsStore: settingsStore)
        }
        .defaultSize(width: 500, height: 400)
        .windowResizability(.contentSize)

        Window("Recon — Diagnostics", id: AppWindowID.diagnostics) {
            DiagnosticsWindowSceneView(controller: controller)
        }
        .defaultSize(width: 560, height: 520)
        .windowResizability(.contentSize)

        Window("Recon — Cluster", id: AppWindowID.cluster) {
            ClusterBrowserWindowSceneView(settingsStore: settingsStore)
        }
        .defaultSize(width: 960, height: 700)
        .windowResizability(.contentMinSize)
    }
}

private struct PreferencesCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Preferences…") {
                Task { @MainActor in
                    PreferencesWindowPresenter.present(using: openWindow)
                }
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }
}
