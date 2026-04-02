import AppKit
import SwiftUI

struct KeyboardFilterField: View {
    let prompt: String
    @Binding var text: String

    @State private var isCapturing = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isCapturing = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(isCapturing ? Color.accentColor : .secondary)

                    Text(displayText)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .lineLimit(1)

                    if isCapturing {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 1, height: 14)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isCapturing ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: [.command])

            if !text.isEmpty {
                Button {
                    text = ""
                    isCapturing = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .background(
            KeyboardInputMonitor(isActive: isCapturing) { event in
                handleKeyDown(event)
            }
        )
        .onDisappear {
            isCapturing = false
        }
    }

    private var displayText: String {
        if text.isEmpty {
            return isCapturing ? "\(prompt) (type to filter)" : prompt
        }

        return text
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76, 53:
            isCapturing = false
            return true
        case 51, 117:
            if !text.isEmpty {
                text.removeLast()
            }
            return true
        default:
            break
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) {
            return false
        }

        guard let characters = event.characters, !characters.isEmpty else {
            return false
        }

        let scalars = characters.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        guard !scalars.isEmpty else {
            return false
        }

        text.append(String(String.UnicodeScalarView(scalars)))
        return true
    }
}

private struct KeyboardInputMonitor: NSViewRepresentable {
    let isActive: Bool
    let onKeyDown: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.isActive = isActive
        context.coordinator.onKeyDown = onKeyDown
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.isActive = isActive
        context.coordinator.onKeyDown = onKeyDown
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        weak var view: NSView?
        var isActive = false
        var onKeyDown: ((NSEvent) -> Bool)?
        private var monitor: Any?

        func startMonitoring() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.isActive,
                      let view = self.view,
                      view.window?.isKeyWindow == true,
                      self.onKeyDown?(event) == true else {
                    return event
                }

                return nil
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            stopMonitoring()
        }
    }
}
