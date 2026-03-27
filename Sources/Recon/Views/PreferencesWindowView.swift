import AppKit
import SwiftUI

struct PreferencesWindowView: View {
    private enum ActiveDropdown: String {
        case pollingInterval
        case kubeconfigMode
    }

    enum Tab: Hashable, CaseIterable {
        case general
        case notifications
        case paths

        var title: String {
            switch self {
            case .general:
                return "General"
            case .notifications:
                return "Notifications"
            case .paths:
                return "Paths"
            }
        }

        var systemImage: String {
            switch self {
            case .general:
                return "gearshape"
            case .notifications:
                return "bell"
            case .paths:
                return "folder"
            }
        }
    }

    @ObservedObject var controller: TelepresenceController
    @ObservedObject var settingsStore: AppSettingsStore
    @State private var selectedTab: Tab = .general
    @State private var activeDropdown: ActiveDropdown?
    @State private var window: NSWindow?

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                windowHeader
                tabBar

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        currentTabContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
            }
        }
        .overlayPreferenceValue(ReconDropdownAnchorPreferenceKey.self) { anchors in
            GeometryReader { proxy in
                preferencesDropdownOverlay(anchors: anchors, proxy: proxy)
            }
        }
        .background(ReconDismissOnEscape(isEnabled: activeDropdown != nil) {
            activeDropdown = nil
        })
        .frame(width: 500, height: 400)
        .background(ReconTheme.windowBackground)
        .background(PreferencesWindowConfigurator(window: $window))
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 12, weight: selectedTab == tab ? .medium : .regular))

                            Text(tab.title)
                                .font(.system(size: 12, weight: selectedTab == tab ? .medium : .regular))
                        }
                        .foregroundStyle(selectedTab == tab ? ReconTheme.textPrimary : ReconTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selectedTab == tab ? ReconTheme.panelRaised : Color.clear)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(selectedTab == tab ? ReconTheme.panelBorder : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)

            Rectangle()
                .fill(ReconTheme.divider)
                .frame(height: 0.5)
        }
    }

    private var windowHeader: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                ReconWindowControlButton(kind: .close) {
                    window?.performClose(nil)
                }

                ReconWindowControlButton(kind: .minimize) {
                    window?.miniaturize(nil)
                }
            }
            .frame(width: 54, alignment: .leading)

            Spacer(minLength: 0)

            Text("Recon Preferences")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ReconTheme.textPrimary)

            Spacer(minLength: 0)

            Rectangle()
                .fill(Color.clear)
                .frame(width: 54, height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(ReconTheme.titlebarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ReconTheme.divider)
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var currentTabContent: some View {
        switch selectedTab {
        case .general:
            generalTab
        case .notifications:
            notificationsTab
        case .paths:
            pathsTab
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreferencesSection(title: "STARTUP", topPadding: 0) {
                PreferencesCard {
                    PreferenceControlRow(title: "Launch at login") {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { settingsStore.launchAtLoginEnabled },
                                set: { controller.setLaunchAtLoginEnabled($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(ReconToggleStyle())
                        .disabled(controller.isUpdatingLaunchAtLogin)
                    }

                    PreferencesInsetDivider()

                    PreferenceControlRow(title: "Auto-connect on launch") {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { settingsStore.autoConnectOnLaunchEnabled },
                                set: { settingsStore.setAutoConnectOnLaunchEnabled($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(ReconToggleStyle())
                    }
                }
            }

            if controller.isUpdatingLaunchAtLogin {
                Text("Updating launch at login...")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ReconTheme.textMuted)
                    .padding(.top, 8)
            }

            PreferencesSection(
                title: "CONNECTION",
                topPadding: 20,
                hintText: settingsStore.pollingInterval.helpText
            ) {
                PreferencesCard {
                    PreferenceControlRow(title: "Auto-reconnect on failure") {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { settingsStore.autoReconnectEnabled },
                                set: { settingsStore.setAutoReconnectEnabled($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(ReconToggleStyle())
                    }

                    PreferencesInsetDivider()

                    PreferenceControlRow(title: "Polling interval") {
                        ReconDropdownTrigger(
                            id: ActiveDropdown.pollingInterval.rawValue,
                            isEnabled: true,
                            action: { toggleDropdown(.pollingInterval) }
                        ) {
                            ReconSettingsMenuLabel(
                                title: settingsStore.pollingInterval.title,
                                width: 160,
                                isOpen: activeDropdown == .pollingInterval
                            )
                        }
                    }
                }
            }

            settingsMessage
                .padding(.top, 12)
        }
    }

    private var notificationsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreferencesSection(title: "NOTIFY ME WHEN", topPadding: 0) {
                PreferencesCard {
                    ForEach(Array(AppNotificationEvent.allCases.enumerated()), id: \.element.id) { index, event in
                        NotificationToggleRow(
                            title: event.title,
                            detail: event.detail,
                            isOn: Binding(
                                get: { settingsStore.isNotificationEnabled(for: event) },
                                set: { controller.setNotificationEnabled($0, for: event) }
                            )
                        )

                        if index < AppNotificationEvent.allCases.count - 1 {
                            PreferencesInsetDivider()
                        }
                    }
                }
            }

            PreferencesSection(title: "ALWAYS SUPPRESSED", topPadding: 20) {
                PreferencesCard {
                    AlwaysSuppressedRow(title: "Manual connect or reconnect")

                    PreferencesInsetDivider()

                    AlwaysSuppressedRow(title: "Manual disconnect")

                    PreferencesInsetDivider()

                    AlwaysSuppressedRow(title: "Refreshes with no state change")
                }
            }

            settingsMessage
                .padding(.top, 12)
        }
    }

    private var pathsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreferencesSection(title: "TOOL PATHS", topPadding: 0) {
                PreferencesCard {
                    PathPreferenceRow(
                        title: "Telepresence",
                        value: controller.displayTelepresencePath,
                        buttonTitle: controller.isDetectingTelepresencePath ? "Detecting..." : "Detect",
                        isButtonDisabled: controller.isDetectingTelepresencePath,
                        action: controller.detectTelepresencePath
                    )

                    PreferencesInsetDivider()

                    PathPreferenceRow(
                        title: "kubectl",
                        value: controller.displayKubectlPath,
                        buttonTitle: controller.isDetectingKubectlPath ? "Detecting..." : "Detect",
                        isButtonDisabled: controller.isDetectingKubectlPath,
                        action: controller.detectKubectlPath
                    )
                }
            }

            PreferencesSection(
                title: "KUBECONFIG",
                topPadding: 20,
                hintText: "Changing the kubeconfig mode reconnects Telepresence. Use the popover picker to choose a pinned file in this phase."
            ) {
                PreferencesCard {
                    PreferenceControlRow(title: "Kubeconfig mode") {
                        ReconDropdownTrigger(
                            id: ActiveDropdown.kubeconfigMode.rawValue,
                            isEnabled: true,
                            action: { toggleDropdown(.kubeconfigMode) }
                        ) {
                            ReconSettingsMenuLabel(
                                title: settingsStore.kubeconfigPreferenceMode.title,
                                width: 180,
                                isOpen: activeDropdown == .kubeconfigMode
                            )
                        }
                    }

                    PreferencesInsetDivider()

                    PreferenceValueRow(
                        title: "Current source",
                        value: controller.displayKubeconfig
                    )

                    PreferencesInsetDivider()

                    PreferenceValueRow(
                        title: "Pinned file",
                        value: controller.selectedKubeconfigPath.map {
                            NSString(string: $0).abbreviatingWithTildeInPath
                        } ?? "None"
                    )
                }
            }

            PreferencesSection(title: "LOGS", topPadding: 20) {
                PreferencesCard {
                    LogDirectoryRow(
                        value: controller.logDirectoryDisplay,
                        action: controller.revealLogDirectory
                    )
                }
            }

            settingsMessage
                .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var settingsMessage: some View {
        if let settingsStatusMessage = controller.settingsStatusMessage, !settingsStatusMessage.isEmpty {
            Text(settingsStatusMessage)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(ReconTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func preferencesDropdownOverlay(
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
        case .pollingInterval:
            ReconDropdownPanel(
                options: PollingIntervalOption.displayChoices(including: settingsStore.pollingInterval),
                selectedID: settingsStore.pollingInterval.id,
                width: 180,
                maxHeight: 220,
                onSelect: { option in
                    activeDropdown = nil
                    settingsStore.setPollingInterval(option)
                }
            ) { option, isSelected, _ in
                preferencesDropdownRow(title: option.title, isSelected: isSelected)
            }
        case .kubeconfigMode:
            ReconDropdownPanel(
                options: KubeconfigPreferenceMode.allCases,
                selectedID: settingsStore.kubeconfigPreferenceMode.id,
                width: 210,
                maxHeight: 180,
                onSelect: { option in
                    activeDropdown = nil
                    controller.changeKubeconfigPreferenceMode(to: option)
                }
            ) { option, isSelected, _ in
                preferencesDropdownRow(title: option.title, isSelected: isSelected)
            }
        }
    }

    private func preferencesDropdownRow(title: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(ReconTheme.textPrimary)

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
        switch dropdown {
        case .pollingInterval:
            return max(triggerRect.width, 180)
        case .kubeconfigMode:
            return max(triggerRect.width, 210)
        }
    }

    private func estimatedDropdownHeight(for dropdown: ActiveDropdown) -> CGFloat {
        let optionCount: Int

        switch dropdown {
        case .pollingInterval:
            optionCount = PollingIntervalOption.displayChoices(including: settingsStore.pollingInterval).count
        case .kubeconfigMode:
            optionCount = KubeconfigPreferenceMode.allCases.count
        }

        return min(CGFloat(optionCount) * 38 + 20, 220)
    }

    private func dropdownOriginX(
        for dropdown: ActiveDropdown,
        triggerRect: CGRect,
        containerSize: CGSize
    ) -> CGFloat {
        let width = dropdownWidth(for: dropdown, triggerRect: triggerRect)
        let preferredX = triggerRect.maxX - width
        return min(max(16, preferredX), max(16, containerSize.width - width - 16))
    }

    private func dropdownOriginY(
        for dropdown: ActiveDropdown,
        triggerRect: CGRect,
        containerSize: CGSize
    ) -> CGFloat {
        let height = estimatedDropdownHeight(for: dropdown)
        let belowY = triggerRect.maxY + 8

        if belowY + height <= containerSize.height - 16 {
            return belowY
        }

        return max(16, triggerRect.minY - height - 8)
    }
}

private struct PreferencesSection<Content: View>: View {
    let title: String
    let topPadding: CGFloat
    let hintText: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        topPadding: CGFloat,
        hintText: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.topPadding = topPadding
        self.hintText = hintText
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreferencesSectionHeading(title: title)
                .padding(.top, topPadding)

            content
                .padding(.top, 6)

            if let hintText, !hintText.isEmpty {
                Text(hintText)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ReconTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }
}

private struct PreferencesSectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ReconTheme.textMuted)
            .tracking(0.5)
    }
}

private struct PreferencesCard<Content: View>: View {
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
    }
}

private struct PreferencesInsetDivider: View {
    var body: some View {
        Rectangle()
            .fill(ReconTheme.divider)
            .frame(height: 0.5)
            .padding(.leading, 12)
    }
}

private struct PreferenceControlRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(ReconTheme.textPrimary)

            Spacer(minLength: 12)

            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }
}

private struct NotificationToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ReconTheme.textPrimary)

                Text(detail)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ReconTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(ReconToggleStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }
}

private struct AlwaysSuppressedRow: View {
    let title: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(ReconTheme.textPrimary)

            Spacer(minLength: 12)

            Text("Never")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(ReconTheme.textMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }
}

private struct PreferenceValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(ReconTheme.textPrimary)

            Spacer(minLength: 12)

            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(ReconTheme.textSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }
}

private struct PathPreferenceRow: View {
    let title: String
    let value: String
    let buttonTitle: String
    let isButtonDisabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ReconTheme.textPrimary)

                Text(value)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(ReconTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button(buttonTitle, action: action)
                .buttonStyle(ReconSecondaryButtonStyle())
                .disabled(isButtonDisabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }
}

private struct LogDirectoryRow: View {
    let value: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Log directory")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(ReconTheme.textPrimary)

                Text(value)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(ReconTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button("Reveal", action: action)
                .buttonStyle(ReconSecondaryButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }
}

private struct ReconSettingsMenuLabel: View {
    let title: String
    let width: CGFloat
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ReconTheme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ReconTheme.accent)
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isOpen ? ReconTheme.accentSoft : ReconTheme.panelRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isOpen ? ReconTheme.selectionBorder : ReconTheme.panelBorder, lineWidth: 1)
        )
    }
}

private struct PreferencesWindowConfigurator: NSViewRepresentable {
    @Binding var window: NSWindow?

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
            self.window = window
            window.isOpaque = false
            window.backgroundColor = ReconTheme.windowBackgroundNSColor
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.level = .floating
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
}
