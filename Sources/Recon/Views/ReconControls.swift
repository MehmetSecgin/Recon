import AppKit
import SwiftUI

struct ReconDropdownTrigger<Label: View>: View {
    let id: String
    let isEnabled: Bool
    let action: () -> Void
    let label: () -> Label

    init(
        id: String,
        isEnabled: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false)
        .anchorPreference(key: ReconDropdownAnchorPreferenceKey.self, value: .bounds) {
            [id: $0]
        }
    }
}

struct ReconDropdownPanel<Option: Identifiable, Content: View>: View where Option.ID: Hashable {
    let options: [Option]
    let selectedID: Option.ID?
    let width: CGFloat
    let maxHeight: CGFloat
    let onSelect: (Option) -> Void
    let content: (Option, Bool, Bool) -> Content

    @State private var hoveredID: Option.ID?

    init(
        options: [Option],
        selectedID: Option.ID?,
        width: CGFloat,
        maxHeight: CGFloat,
        onSelect: @escaping (Option) -> Void,
        @ViewBuilder content: @escaping (Option, Bool, Bool) -> Content
    ) {
        self.options = options
        self.selectedID = selectedID
        self.width = width
        self.maxHeight = maxHeight
        self.onSelect = onSelect
        self.content = content
    }

    var body: some View {
        dropdownBody
            .frame(width: width)
            .padding(8)
            .background(ReconTheme.floatingPanelBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(ReconTheme.panelBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: ReconTheme.shadow.opacity(1), radius: 22, y: 12)
    }

    @ViewBuilder
    private var dropdownBody: some View {
        if options.count > 6 {
            ScrollView {
                LazyVStack(spacing: 4) {
                    optionRows
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: maxHeight)
            .scrollIndicators(.hidden)
        } else {
            VStack(spacing: 4) {
                optionRows
            }
            .padding(.vertical, 2)
        }
    }

    private var optionRows: some View {
        ForEach(options) { option in
            let isSelected = selectedID == option.id
            let isHovered = hoveredID == option.id

            Button {
                onSelect(option)
            } label: {
                HStack(spacing: 0) {
                    content(option, isSelected, isHovered)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(backgroundColor(isSelected: isSelected, isHovered: isHovered))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isSelected ? ReconTheme.selectionBorder : Color.clear,
                            lineWidth: 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                hoveredID = hovering ? option.id : nil
            }
        }
    }

    private func backgroundColor(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return ReconTheme.selectionBackground
        }

        if isHovered {
            return ReconTheme.panelRaised
        }

        return Color.clear
    }
}

struct ReconWindowControlButton: View {
    enum Kind {
        case close
        case minimize

        var fill: Color {
            switch self {
            case .close:
                return Color(hex: 0xFF5F57)
            case .minimize:
                return Color(hex: 0xFEBC2E)
            }
        }

        var icon: String {
            switch self {
            case .close:
                return "xmark"
            case .minimize:
                return "minus"
            }
        }
    }

    let kind: Kind
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(kind.fill)
                .frame(width: 12, height: 12)
                .overlay {
                    if isHovering {
                        Image(systemName: kind.icon)
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.7))
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct ReconDismissOnEscape: NSViewRepresentable {
    let isEnabled: Bool
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.setEnabled(isEnabled)
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
        context.coordinator.setEnabled(isEnabled)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.setEnabled(false)
    }

    final class Coordinator {
        var onEscape: () -> Void
        private var monitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        deinit {
            setEnabled(false)
        }

        func setEnabled(_ enabled: Bool) {
            if enabled {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard event.keyCode == 53 else { return event }
                    self?.onEscape()
                    return nil
                }
                return
            }

            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

struct ReconDropdownAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
