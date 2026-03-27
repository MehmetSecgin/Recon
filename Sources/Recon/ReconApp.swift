import AppKit
import SwiftUI

@main
struct ReconApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settingsStore: AppSettingsStore
    @StateObject private var controller: TelepresenceController

    init() {
        let settingsStore = AppSettingsStore()
        _settingsStore = StateObject(wrappedValue: settingsStore)
        _controller = StateObject(wrappedValue: TelepresenceController(settingsStore: settingsStore))
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

        Window("Recon — Preferences", id: "preferences") {
            PreferencesWindowView(controller: controller, settingsStore: settingsStore)
        }
        .defaultSize(width: 500, height: 400)
        .windowResizability(.contentSize)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

private struct PreferencesCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Preferences…") {
                openWindow(id: "preferences")
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }
}
