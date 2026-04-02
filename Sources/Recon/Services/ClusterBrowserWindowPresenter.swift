import AppKit
import SwiftUI

@MainActor
enum ClusterBrowserWindowPresenter {
    static func present(using openWindow: OpenWindowAction) {
        if let window = clusterWindow {
            bringToFront(window)
            return
        }

        openWindow(id: AppWindowID.cluster)

        Task { @MainActor in
            for _ in 0..<10 {
                if let window = clusterWindow {
                    bringToFront(window)
                    return
                }

                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    static func configure(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier(AppWindowID.cluster)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    private static var clusterWindow: NSWindow? {
        NSApp.windows.first { window in
            window.identifier?.rawValue == AppWindowID.cluster
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
