import AppKit
import SwiftUI

struct PreferencesWindowView: View {
    enum Tab: Hashable {
        case general
        case notifications
        case paths
    }

    @ObservedObject var controller: TelepresenceController
    @ObservedObject var settingsStore: AppSettingsStore
    @State private var selectedTab: Tab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(Tab.general)

            notificationsTab
                .tabItem {
                    Label("Notifications", systemImage: "bell")
                }
                .tag(Tab.notifications)

            pathsTab
                .tabItem {
                    Label("Paths", systemImage: "folder")
                }
                .tag(Tab.paths)
        }
        .padding(18)
        .frame(width: 500, height: 400)
        .background(PreferencesWindowConfigurator())
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { settingsStore.launchAtLoginEnabled },
                        set: { controller.setLaunchAtLoginEnabled($0) }
                    )
                )
                .disabled(controller.isUpdatingLaunchAtLogin)

                Toggle(
                    "Auto-connect on launch",
                    isOn: Binding(
                        get: { settingsStore.autoConnectOnLaunchEnabled },
                        set: { settingsStore.setAutoConnectOnLaunchEnabled($0) }
                    )
                )

                Toggle(
                    "Auto-reconnect on failure",
                    isOn: Binding(
                        get: { settingsStore.autoReconnectEnabled },
                        set: { settingsStore.setAutoReconnectEnabled($0) }
                    )
                )

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
                .pickerStyle(.menu)
            }
            .formStyle(.grouped)

            Text(settingsStore.pollingInterval.helpText)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)

            if controller.isUpdatingLaunchAtLogin {
                Text("Updating launch at login...")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            settingsMessage

            Spacer()
        }
    }

    private var notificationsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                ForEach(AppNotificationEvent.allCases) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(
                            event.title,
                            isOn: Binding(
                                get: { settingsStore.isNotificationEnabled(for: event) },
                                set: { controller.setNotificationEnabled($0, for: event) }
                            )
                        )

                        Text(event.detail)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 8) {
                Text("Always off in this phase")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                NeverNotifyRow(title: "Manual connect or reconnect")
                NeverNotifyRow(title: "Manual disconnect")
                NeverNotifyRow(title: "Refreshes with no state change")
            }

            settingsMessage

            Spacer()
        }
    }

    private var pathsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                PathRow(
                    title: "Telepresence",
                    value: controller.displayTelepresencePath,
                    detail: overrideText(for: controller.telepresencePathOverride),
                    buttonTitle: controller.isDetectingTelepresencePath ? "Detecting..." : "Detect",
                    isButtonDisabled: controller.isDetectingTelepresencePath,
                    action: controller.detectTelepresencePath
                )

                PathRow(
                    title: "kubectl",
                    value: controller.displayKubectlPath,
                    detail: overrideText(for: controller.kubectlPathOverride),
                    buttonTitle: controller.isDetectingKubectlPath ? "Detecting..." : "Detect",
                    isButtonDisabled: controller.isDetectingKubectlPath,
                    action: controller.detectKubectlPath
                )

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center) {
                        Text("Kubeconfig mode")
                        Spacer(minLength: 12)
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
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 180, alignment: .trailing)
                    }

                    Text("Changing the kubeconfig mode reconnects Telepresence. Use the popover picker to choose a pinned file in this phase.")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)

                ReadOnlyRow(
                    title: "Current source",
                    value: controller.displayKubeconfig
                )

                ReadOnlyRow(
                    title: "Pinned file",
                    value: controller.selectedKubeconfigPath.map {
                        NSString(string: $0).abbreviatingWithTildeInPath
                    } ?? "None"
                )

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Log directory")
                        Text(controller.logDirectoryDisplay)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 12)

                    Button("Reveal") {
                        controller.revealLogDirectory()
                    }
                }
                .padding(.vertical, 2)
            }
            .formStyle(.grouped)

            settingsMessage

            Spacer()
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

    private func overrideText(for path: String?) -> String {
        guard let path else {
            return "No saved override"
        }

        return "Saved override: \(NSString(string: path).abbreviatingWithTildeInPath)"
    }
}

private struct PathRow: View {
    let title: String
    let value: String
    let detail: String
    let buttonTitle: String
    let isButtonDisabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(value)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(detail)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button(buttonTitle, action: action)
                .disabled(isButtonDisabled)
        }
        .padding(.vertical, 2)
    }
}

private struct ReadOnlyRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

private struct NeverNotifyRow: View {
    let title: String

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
            Spacer(minLength: 12)
            Text("Never notify")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.tertiary)
        }
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
            window.appearance = NSAppearance(named: .darkAqua)
            window.isOpaque = false
            window.backgroundColor = NSColor.windowBackgroundColor
            window.level = .floating
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
}
