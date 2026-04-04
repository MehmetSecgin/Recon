import AppKit
import Foundation

@MainActor
final class AppActivationPolicyController {
    private var deckWindowObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var isRegularAppModeEnabled = false

    func prepareForDeckPresentation() {
        promoteForDeck()
    }

    func registerDeckWindow(_ window: NSWindow) {
        let windowID = ObjectIdentifier(window)

        if deckWindowObservers[windowID] == nil {
            let observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleDeckWindowWillClose(windowID)
                }
            }

            deckWindowObservers[windowID] = observer
        }

        promoteForDeck()
    }

    private func handleDeckWindowWillClose(_ windowID: ObjectIdentifier) {
        removeObserver(for: windowID)

        guard deckWindowObservers.isEmpty else {
            return
        }

        demoteAfterDeckClose()
    }

    private func promoteForDeck() {
        guard isRegularAppModeEnabled == false else {
            return
        }

        isRegularAppModeEnabled = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func demoteAfterDeckClose() {
        guard isRegularAppModeEnabled else {
            return
        }

        isRegularAppModeEnabled = false
        NSApp.setActivationPolicy(.accessory)
    }

    private func removeObserver(for windowID: ObjectIdentifier) {
        guard let observer = deckWindowObservers.removeValue(forKey: windowID) else {
            return
        }

        NotificationCenter.default.removeObserver(observer)
    }

    deinit {
        for observer in deckWindowObservers.values {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
