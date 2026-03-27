import AppKit
import SwiftUI

@MainActor
enum DiagnosticsWindowPresenter {
    static func present(using openWindow: OpenWindowAction) {
        if let window = diagnosticsWindow {
            bringToFront(window)
            return
        }

        openWindow(id: AppWindowID.diagnostics)

        Task { @MainActor in
            for _ in 0..<10 {
                if let window = diagnosticsWindow {
                    bringToFront(window)
                    return
                }

                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    static func configure(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier(AppWindowID.diagnostics)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    private static var diagnosticsWindow: NSWindow? {
        NSApp.windows.first { window in
            window.identifier?.rawValue == AppWindowID.diagnostics
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
