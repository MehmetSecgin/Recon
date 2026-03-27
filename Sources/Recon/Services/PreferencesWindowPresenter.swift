import AppKit
import SwiftUI

enum AppWindowID {
    static let preferences = "preferences"
}

@MainActor
enum PreferencesWindowPresenter {
    static func present(using openWindow: OpenWindowAction) {
        if let window = preferencesWindow {
            bringToFront(window)
            return
        }

        openWindow(id: AppWindowID.preferences)

        Task { @MainActor in
            for _ in 0..<10 {
                if let window = preferencesWindow {
                    bringToFront(window)
                    return
                }

                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    static func configure(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier(AppWindowID.preferences)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    private static var preferencesWindow: NSWindow? {
        NSApp.windows.first { window in
            window.identifier?.rawValue == AppWindowID.preferences
        }
    }

    private static func bringToFront(_ window: NSWindow) {
        configure(window)

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
