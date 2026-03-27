import AppKit
import SwiftUI

@main
struct ReconApp: App {
    @StateObject private var settingsStore: AppSettingsStore
    @StateObject private var controller: TelepresenceController
    @StateObject private var diagnosticsViewModel: DiagnosticsViewModel

    init() {
        let settingsStore = AppSettingsStore()
        let controller = TelepresenceController(settingsStore: settingsStore)
        _settingsStore = StateObject(wrappedValue: settingsStore)
        _controller = StateObject(wrappedValue: controller)
        _diagnosticsViewModel = StateObject(wrappedValue: DiagnosticsViewModel(controller: controller))
    }

    var body: some Scene {
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
            DiagnosticsWindowView(viewModel: diagnosticsViewModel)
        }
        .defaultSize(width: 560, height: 520)
        .windowResizability(.contentSize)
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
