import AppKit
import SwiftUI

struct PreferencesWindowView: View {
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

    var body: some View {
        VStack(spacing: 0) {
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
        .frame(width: 500, height: 400)
        .background(PreferencesWindowConfigurator())
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
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selectedTab == tab ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
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
                    }
                }
            }

            if controller.isUpdatingLaunchAtLogin {
                Text("Updating launch at login...")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
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
                    }

                    PreferencesInsetDivider()

                    PreferenceControlRow(title: "Polling interval") {
                        Picker(
                            "Polling interval",
                            selection: Binding(
                                get: { settingsStore.pollingInterval },
                                set: { settingsStore.setPollingInterval($0) }
                            )
                        ) {
                            ForEach(PollingIntervalOption.displayChoices(including: settingsStore.pollingInterval)) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 160, alignment: .trailing)
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
                        Picker(
                            "Kubeconfig mode",
                            selection: Binding(
                                get: { settingsStore.kubeconfigPreferenceMode },
                                set: { controller.changeKubeconfigPreferenceMode(to: $0) }
                            )
                        ) {
                            ForEach(KubeconfigPreferenceMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180, alignment: .trailing)
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
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
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
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            .tracking(0.5)
    }
}

private struct PreferencesCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PreferencesInsetDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
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
                .foregroundStyle(Color(nsColor: .labelColor))

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
                    .foregroundStyle(Color(nsColor: .labelColor))

                Text(detail)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $isOn)
                .labelsHidden()
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
                .foregroundStyle(Color(nsColor: .labelColor))

            Spacer(minLength: 12)

            Text("Never")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
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
                .foregroundStyle(Color(nsColor: .labelColor))

            Spacer(minLength: 12)

            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
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
                    .foregroundStyle(Color(nsColor: .labelColor))

                Text(value)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
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
                    .foregroundStyle(Color(nsColor: .labelColor))

                Text(value)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button("Reveal", action: action)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }
}
private struct PreferencesWindowConfigurator: NSViewRepresentable {
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
            PreferencesWindowPresenter.configure(window)
            window.isOpaque = false
            window.backgroundColor = NSColor.windowBackgroundColor
            window.level = .floating
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
}
