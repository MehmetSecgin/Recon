import AppKit
import SwiftUI

@main
struct ReconApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = TelepresenceController()

    var body: some Scene {
        MenuBarExtra {
            ReconMenuView(controller: controller)
        } label: {
            Text(controller.statusItemTitle)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
        .menuBarExtraStyle(.window)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}
