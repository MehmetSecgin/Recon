import AppKit
import SwiftUI

struct ReconMenuView: View {
    private enum ActiveDropdown: String {
        case kubeconfig
        case namespace
    }

    @Environment(\.openWindow) private var openWindow

    @ObservedObject var controller: TelepresenceController
    @State private var activeDropdown: ActiveDropdown?

    private var appVersionText: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildNumber) {
        case let (shortVersion?, buildNumber?) where shortVersion != buildNumber:
            return "v\(shortVersion) (\(buildNumber))"
        case let (shortVersion?, _):
            return "v\(shortVersion)"
        case let (_, buildNumber?):
            return "build \(buildNumber)"
        default:
            return "version unavailable"
        }
    }

    private var isNamespaceRowInteractive: Bool {
        controller.snapshot.state == .connected &&
        controller.isRunningCommand == false &&
        controller.targetMetadata.context != nil &&
        controller.namespacePickerOptions.isEmpty == false
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            menuContent
        }
        .overlayPreferenceValue(ReconDropdownAnchorPreferenceKey.self) { anchors in
            GeometryReader { proxy in
                menuDropdownOverlay(anchors: anchors, proxy: proxy)
            }
        }
        .background(ReconDismissOnEscape(isEnabled: activeDropdown != nil) {
            activeDropdown = nil
        })
        .background(MenuWindowConfigurator())
        .onAppear {
            controller.refreshNow()
        }
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeaderSection

            if let errorPresentation = controller.errorPresentation {
                ConnectionErrorBanner(
                    presentation: errorPresentation,
                    onCopyStatus: controller.copyStatusCommand,
                    onOpenLogs: controller.openLogs
                )
                .padding(.top, 14)
            }

            metadataSection
                .padding(.top, 16)

            if controller.isProductionConnection {
                ProductionWarningBanner()
                    .padding(.top, 12)
            }

            if controller.isSwitchingKubeconfig {
                switchingHint
                    .padding(.top, 8)
            }

            actionsSection
                .padding(.top, 20)

            preferencesSection
                .padding(.top, 20)

            footerSection
                .padding(.top, 16)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 352, alignment: .leading)
        .background(ReconTheme.windowBackground)
    }

    private var statusHeaderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                statusIndicator

                HStack(spacing: 8) {
                    Text(controller.snapshot.statusText)
                        .font(.system(size: 16, weight: .semibold))

                    if controller.isProductionConnection {
                        ProductionBadge()
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 10) {
                    if controller.shouldShowTimestamp {
                        Text(controller.snapshot.lastUpdated, style: .relative)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(ReconTheme.textMuted)
                    }

                    Button {
                        controller.refreshNow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ReconTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.isRunningCommand)
                    .help("Refresh status")
                }
            }

            if let detailText = controller.headerDetailText, !detailText.isEmpty {
                Text(detailText)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(ReconTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch controller.snapshot.state {
        case .busy:
            ProgressView()
                .controlSize(.small)
                .tint(ReconTheme.warning)
                .frame(width: 10, height: 10)
        case .connected:
            Circle()
                .fill(controller.isProductionConnection ? ReconTheme.danger : ReconTheme.success)
                .frame(width: 8, height: 8)
                .shadow(
                    color: (controller.isProductionConnection ? ReconTheme.danger : ReconTheme.success).opacity(0.3),
                    radius: 2
                )
        case .disconnected, .unavailable:
            Circle()
                .fill(ReconTheme.textMuted)
                .frame(width: 8, height: 8)
        case .error:
            Circle()
                .fill(ReconTheme.danger)
                .frame(width: 8, height: 8)
                .shadow(color: ReconTheme.danger.opacity(0.25), radius: 2)
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MenuSectionHeading(title: "TARGET")

            MenuCard {
                MenuCardRow {
                    KubeconfigPickerMetadataRow(
                        key: "Kubeconfig",
                        value: controller.displayKubeconfig,
                        isInteractive: controller.isKubeconfigRowInteractive,
                        isOpen: activeDropdown == .kubeconfig,
                        onToggle: {
                            toggleDropdown(.kubeconfig)
                        }
                    )
                }

                InsetDivider()

                MenuCardRow {
                    MetadataRow(
                        key: "Context",
                        value: controller.displayContext,
                        dimmed: controller.targetMetadata.isLastKnown,
                        valueColor: controller.isProductionConnection ? ReconTheme.danger : nil
                    )
                }

                InsetDivider()

                MenuCardRow {
                    NamespacePickerMetadataRow(
                        key: "Namespace",
                        value: controller.displayNamespace,
                        dimmed: controller.targetMetadata.isLastKnown,
                        showsOverrideAnnotation: controller.namespaceOverride != nil,
                        isInteractive: isNamespaceRowInteractive,
                        isLoading: controller.isLoadingNamespacePickerOptions,
                        isOpen: activeDropdown == .namespace,
                        onToggle: {
                            toggleDropdown(.namespace)
                        }
                    )
                }
            }
        }
    }

    private var switchingHint: some View {
        Text(controller.snapshot.detailText)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(ReconTheme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.isRunningCommand || controller.snapshot.state == .busy {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .center)
            } else {
                switch controller.snapshot.state {
                case .connected:
                    HStack(spacing: 8) {
                        actionButton("Reconnect", variant: .secondary) {
                            controller.reconnect()
                        }

                        actionButton("Disconnect", variant: .danger) {
                            controller.disconnect()
                        }
                    }
                case .disconnected:
                    actionButton("Connect", variant: .primary) {
                        controller.connect()
                    }
                case .error:
                    actionButton("Reconnect", variant: .primary) {
                        controller.reconnect()
                    }
                case .unavailable:
                    actionButton("Connect", variant: .primary, isDisabled: true) {
                        controller.connect()
                    }
                case .busy:
                    EmptyView()
                }
            }
        }
    }

    private var preferencesSection: some View {
        PreferencesMenuItem {
            openWindow(id: "preferences")
        }
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionDivider()

            HStack(alignment: .center, spacing: 12) {
                Text("Recon \(appVersionText)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(ReconTheme.textMuted)

                Spacer(minLength: 8)

                FooterQuitButton {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
    }

    private func menuDropdownOverlay(
        anchors: [String: Anchor<CGRect>],
        proxy: GeometryProxy
    ) -> some View {
        if let activeDropdown, let anchor = anchors[activeDropdown.rawValue] {
            let rect = proxy[anchor]

            return AnyView(
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            self.activeDropdown = nil
                        }

                    dropdownPanel(for: activeDropdown)
                        .frame(width: dropdownWidth(for: activeDropdown, triggerRect: rect))
                        .offset(
                            x: dropdownOriginX(for: activeDropdown, triggerRect: rect, containerSize: proxy.size),
                            y: dropdownOriginY(for: activeDropdown, triggerRect: rect, containerSize: proxy.size)
                        )
                }
                .zIndex(10)
            )
        }

        return AnyView(EmptyView())
    }

    @ViewBuilder
    private func dropdownPanel(for dropdown: ActiveDropdown) -> some View {
        switch dropdown {
        case .kubeconfig:
            ReconDropdownPanel(
                options: controller.kubeconfigPickerOptions,
                selectedID: controller.selectedKubeconfigPickerOptionID,
                width: 228,
                maxHeight: 220,
                onSelect: { option in
                    activeDropdown = nil

                    switch option.kind {
                    case .path:
                        controller.selectKubeconfigPickerOption(withID: option.id)
                    case .chooseFile:
                        browseForKubeconfig()
                    }
                }
            ) { option, isSelected, _ in
                dropdownRowLabel(
                    title: option.title,
                    isSelected: isSelected
                )
            }
        case .namespace:
            ReconDropdownPanel(
                options: controller.namespacePickerOptions,
                selectedID: controller.selectedNamespacePickerOptionID,
                width: 228,
                maxHeight: 220,
                onSelect: { option in
                    activeDropdown = nil
                    controller.selectNamespacePickerOption(withID: option.id)
                }
            ) { option, isSelected, _ in
                dropdownRowLabel(
                    title: option.title,
                    isSelected: isSelected
                )
            }
        }
    }

    private func dropdownRowLabel(title: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(ReconTheme.textPrimary)
                .lineLimit(1)

            if isSelected {
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ReconTheme.accent)
            }
        }
    }

    private func toggleDropdown(_ dropdown: ActiveDropdown) {
        activeDropdown = activeDropdown == dropdown ? nil : dropdown
    }

    private func dropdownWidth(for dropdown: ActiveDropdown, triggerRect: CGRect) -> CGFloat {
        let minimumWidth: CGFloat

        switch dropdown {
        case .kubeconfig:
            minimumWidth = 228
        case .namespace:
            minimumWidth = 228
        }

        return max(triggerRect.width, minimumWidth)
    }

    private func estimatedDropdownHeight(for dropdown: ActiveDropdown) -> CGFloat {
        let optionCount: Int

        switch dropdown {
        case .kubeconfig:
            optionCount = controller.kubeconfigPickerOptions.count
        case .namespace:
            optionCount = controller.namespacePickerOptions.count
        }

        return min(CGFloat(optionCount) * 38 + 20, 236)
    }

    private func dropdownOriginX(
        for dropdown: ActiveDropdown,
        triggerRect: CGRect,
        containerSize: CGSize
    ) -> CGFloat {
        let width = dropdownWidth(for: dropdown, triggerRect: triggerRect)
        let preferredX = triggerRect.maxX - width
        return min(max(12, preferredX), max(12, containerSize.width - width - 12))
    }

    private func dropdownOriginY(
        for dropdown: ActiveDropdown,
        triggerRect: CGRect,
        containerSize: CGSize
    ) -> CGFloat {
        let height = estimatedDropdownHeight(for: dropdown)
        let belowY = triggerRect.maxY + 8

        if belowY + height <= containerSize.height - 12 {
            return belowY
        }

        return max(12, triggerRect.minY - height - 8)
    }

    private func actionButton(
        _ title: String,
        variant: MenuActionButtonVariant,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(MenuActionButtonStyle(variant: variant))
            .disabled(isDisabled)
            .frame(maxWidth: .infinity)
    }

    private func browseForKubeconfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = preferredKubeconfigDirectoryURL()

        if panel.runModal() == .OK, let url = panel.url {
            controller.addAndSelectKubeconfig(path: url.path)
        }
    }

    private func preferredKubeconfigDirectoryURL() -> URL {
        if let selectedKubeconfigPath = controller.selectedKubeconfigPath {
            return URL(fileURLWithPath: selectedKubeconfigPath).deletingLastPathComponent()
        }

        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kube", isDirectory: true)
    }
}

private enum MenuActionButtonVariant {
    case primary
    case secondary
    case danger
}

private struct MetadataRow: View {
    let key: String
    let value: String
    var dimmed = false
    var valueColor: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(ReconTheme.textSecondary)

            Spacer(minLength: 12)

            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(dimmed ? AnyShapeStyle(ReconTheme.textMuted) : AnyShapeStyle(valueColor ?? ReconTheme.textPrimary))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}

private struct NamespacePickerMetadataRow: View {
    let key: String
    let value: String
    let dimmed: Bool
    let showsOverrideAnnotation: Bool
    let isInteractive: Bool
    let isLoading: Bool
    let isOpen: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(ReconTheme.textSecondary)

            Spacer(minLength: 12)

            if isInteractive {
                ReconDropdownTrigger(
                    id: "namespace",
                    isEnabled: true,
                    action: onToggle
                ) {
                    namespaceValueLabel
                }
            } else {
                namespaceValueLabel
            }
        }
    }

    private var namespaceValueLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(dimmed ? AnyShapeStyle(ReconTheme.textMuted) : AnyShapeStyle(ReconTheme.textPrimary))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)

            if showsOverrideAnnotation {
                Text("(override)")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(ReconTheme.textMuted)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(ReconTheme.textMuted)
            } else if isInteractive {
                ReconMenuChevron()
            }
        }
        .padding(.horizontal, isInteractive ? 12 : 0)
        .padding(.vertical, isInteractive ? 6 : 0)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isInteractive ? (isOpen ? ReconTheme.accentSoft : ReconTheme.panelRaised) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isInteractive ? (isOpen ? ReconTheme.selectionBorder : ReconTheme.panelBorder) : Color.clear,
                    lineWidth: 1
                )
        )
    }
}

private struct KubeconfigPickerMetadataRow: View {
    let key: String
    let value: String
    let isInteractive: Bool
    let isOpen: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(ReconTheme.textSecondary)

            Spacer(minLength: 12)

            if isInteractive {
                ReconDropdownTrigger(
                    id: "kubeconfig",
                    isEnabled: true,
                    action: onToggle
                ) {
                    kubeconfigValueLabel
                }
            } else {
                kubeconfigValueLabel
            }
        }
    }

    private var kubeconfigValueLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(ReconTheme.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)

            if isInteractive {
                ReconMenuChevron()
            }
        }
        .padding(.horizontal, isInteractive ? 12 : 0)
        .padding(.vertical, isInteractive ? 6 : 0)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isInteractive ? (isOpen ? ReconTheme.accentSoft : ReconTheme.panelRaised) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isInteractive ? (isOpen ? ReconTheme.selectionBorder : ReconTheme.panelBorder) : Color.clear,
                    lineWidth: 1
                )
        )
    }
}

private struct MenuSectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ReconTheme.textMuted)
            .tracking(0.5)
    }
}

private struct MenuCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(ReconTheme.panelBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(ReconTheme.panelBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: ReconTheme.shadow, radius: 10, y: 6)
    }
}

private struct MenuCardRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PreferencesMenuItem: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(ReconTheme.textSecondary)

                Text("Preferences…")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(ReconTheme.textPrimary)

                Spacer(minLength: 8)

                Text("⌘,")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(ReconTheme.textMuted)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? ReconTheme.panelRaised : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct FooterQuitButton: View {
    let action: () -> Void

    var body: some View {
        Button("Quit", action: action)
            .buttonStyle(MenuActionButtonStyle(variant: .danger))
            .frame(width: 88)
    }
}

private struct MenuActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let variant: MenuActionButtonVariant

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(backgroundColor(configuration: configuration))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(configuration.isPressed ? 0.92 : 1)
            .saturation(isEnabled ? 1 : 0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.55)
    }

    private var foregroundColor: Color {
        guard isEnabled else {
            return ReconTheme.textMuted
        }

        switch variant {
        case .primary:
            return ReconTheme.textPrimary
        case .secondary:
            return ReconTheme.textPrimary
        case .danger:
            return ReconTheme.danger
        }
    }

    private func backgroundColor(configuration: Configuration) -> Color {
        let opacityAdjustment = configuration.isPressed ? 0.88 : 1

        switch variant {
        case .primary:
            return ReconTheme.accent.opacity(opacityAdjustment)
        case .secondary:
            return ReconTheme.panelBackground.opacity(opacityAdjustment)
        case .danger:
            return ReconTheme.dangerBackground.opacity(opacityAdjustment)
        }
    }
}

private struct ReconMenuChevron: View {
    var body: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(ReconTheme.accent)
    }
}

private struct ProductionBadge: View {
    var label = "PRODUCTION"

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ReconTheme.danger)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(ReconTheme.dangerBackground, in: Capsule())
    }
}

private struct ProductionWarningBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ReconTheme.danger)
                .padding(.top, 1)

            Text("You are connected to a production cluster. Actions here affect live traffic.")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(ReconTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(ReconTheme.dangerBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ReconTheme.danger.opacity(0.25), lineWidth: 0.5)
        )
    }
}

private struct ConnectionErrorBanner: View {
    let presentation: ErrorPresentation
    let onCopyStatus: () -> Void
    let onOpenLogs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ReconTheme.danger)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ReconTheme.textPrimary)

                    Text(presentation.message)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(ReconTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let suggestion = presentation.suggestion, !suggestion.isEmpty {
                        Text(suggestion)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(ReconTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let rawDetailPreview = presentation.rawDetailPreview, !rawDetailPreview.isEmpty {
                Text(rawDetailPreview)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(ReconTheme.textSecondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ReconTheme.panelRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 10) {
                if presentation.canCopyStatus {
                    Button("Copy 'telepresence status'") {
                        onCopyStatus()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ReconTheme.textSecondary)
                }

                if presentation.canOpenLogs {
                    Button("Open logs…") {
                        onOpenLogs()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ReconTheme.textSecondary)
                }
            }
        }
        .padding(10)
        .background(ReconTheme.dangerBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ReconTheme.danger.opacity(0.25), lineWidth: 0.5)
        )
    }
}

private struct InsetDivider: View {
    var body: some View {
        Rectangle()
            .fill(ReconTheme.divider)
            .frame(height: 0.5)
            .padding(.leading, 12)
    }
}

private struct SectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(ReconTheme.divider)
            .frame(height: 0.5)
    }
}

private struct MenuWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(for: nsView)
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = ReconTheme.windowBackgroundNSColor
        }
    }
}
