import AppKit
import SwiftUI

@MainActor
enum ClusterBrowserWindowPresenter {
    static func present(
        using openWindow: OpenWindowAction,
        appActivationPolicyController: AppActivationPolicyController
    ) {
        appActivationPolicyController.prepareForDeckPresentation()

        if let window = mostRecentClusterWindow {
            bringToFront(window)
            return
        }

        openWindow(id: AppWindowID.cluster)
        focusMostRecentClusterWindow()
    }

    static func configure(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier(AppWindowID.cluster)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.collectionBehavior.remove(.moveToActiveSpace)
        window.setFrameAutosaveName(AppWindowID.cluster)
    }

    private static func focusMostRecentClusterWindow() {
        Task { @MainActor in
            for _ in 0..<10 {
                if let window = mostRecentClusterWindow {
                    bringToFront(window)
                    return
                }

                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private static var mostRecentClusterWindow: NSWindow? {
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
