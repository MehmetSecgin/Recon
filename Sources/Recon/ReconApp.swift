import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

private struct ReconMenuView: View {
    @AppStorage("Recon.PollingIntervalSeconds") private var pollingIntervalSeconds = TelepresenceController.PollingIntervalOption.fiveMinutes.rawValue
    @AppStorage("Recon.AutoReconnectEnabled") private var autoReconnectEnabled = false
    @AppStorage("Recon.NotificationsEnabled") private var notificationsEnabled = false
    @AppStorage("Recon.AutoConnectOnLaunchEnabled") private var autoConnectOnLaunchEnabled = false
    @State private var preferencesExpanded = false

    @ObservedObject var controller: TelepresenceController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusHeaderSection

            Divider()

            kubeconfigSection

            if controller.hasMetadata {
                Divider()
                metadataSection
            }

            Divider()

            actionsSection

            Divider()

            preferencesSection

            if let lastErrorText = controller.lastErrorText, !lastErrorText.isEmpty {
                Divider()
                errorSection(lastErrorText)
            }

            Divider()

            footerSection
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .tint(.gray)
        .background(MenuWindowConfigurator())
        .preferredColorScheme(.dark)
        .onAppear {
            controller.refreshNow()
        }
        .onReceive(controller.$notificationsEnabled) { notificationsEnabled = $0 }
        .onReceive(controller.$autoConnectOnLaunchEnabled) { autoConnectOnLaunchEnabled = $0 }
    }

    private var statusHeaderSection: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIndicator
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(controller.snapshot.statusText)
                    .font(.system(size: 17, weight: .semibold))

                Text(controller.snapshot.detailText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Updated \(controller.snapshot.lastUpdated.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch controller.snapshot.state {
        case .busy:
            ProgressView()
                .tint(Color(hex: 0xFFD60A))
                .controlSize(.small)
                .frame(width: 8, height: 8)
        case .connected:
            Circle()
                .fill(Color(hex: 0x32D74B))
                .frame(width: 8, height: 8)
        case .disconnected, .error:
            Circle()
                .fill(Color(hex: 0xFF453A))
                .frame(width: 8, height: 8)
        case .unavailable:
            Circle()
                .fill(.quaternary)
                .frame(width: 8, height: 8)
        }
    }

    private var kubeconfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("KUBECONFIG")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.tertiary)

            Picker(
                selection: Binding<String?>(
                    get: { controller.selectedKubeconfigPath },
                    set: { newValue in
                        guard let newValue else { return }
                        controller.addAndSelectKubeconfig(path: newValue)
                    }
                )
            ) {
                ForEach(controller.kubeconfigOptions) { option in
                    Text(option.displayName).tag(Optional(option.path))
                }
            } label: {
                Text(controller.selectedKubeconfigDisplayName)
                    .font(.system(size: 13, weight: .regular))
            }
            .pickerStyle(.menu)
            .disabled(controller.isSwitchingKubeconfig || controller.kubeconfigOptions.isEmpty)

            Button("Browse for file...") {
                browseForKubeconfig()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(.secondary)

            if controller.isSwitchingKubeconfig {
                Text("switching config -> reconnecting...")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
        }
        .disabled(controller.isSwitchingKubeconfig)
        .opacity(controller.isSwitchingKubeconfig ? 0.6 : 1)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(controller.metadataRows, id: \.key) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.key)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 12)

                    Text(row.value)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Connect") {
                controller.connect()
            }
            .disabled(controller.isRunningCommand || controller.snapshot.state == .connected)

            Button("Disconnect") {
                controller.disconnect()
            }
            .disabled(
                controller.isRunningCommand ||
                controller.snapshot.state == .disconnected ||
                controller.snapshot.state == .unavailable
            )

            Button("Reconnect") {
                controller.reconnect()
            }
            .disabled(controller.isRunningCommand)

            Button("Refresh Now") {
                controller.refreshNow()
            }
            .disabled(controller.isRunningCommand)
        }
        .buttonStyle(.bordered)
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    preferencesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: preferencesExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))

                    Text("Preferences...")
                        .font(.system(size: 13, weight: .regular))

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)

            if preferencesExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("POLLING")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.tertiary)

                        Picker(
                            selection: Binding<Int>(
                                get: { pollingIntervalSeconds },
                                set: { newValue in
                                    pollingIntervalSeconds = newValue
                                    controller.setPollingInterval(seconds: newValue)
                                }
                            )
                        ) {
                            ForEach(TelepresenceController.PollingIntervalOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        } label: {
                            Text(controller.selectedPollingInterval.title)
                                .font(.system(size: 13, weight: .regular))
                        }
                        .pickerStyle(.menu)
                    }

                    Toggle(
                        "Launch at login",
                        isOn: Binding<Bool>(
                            get: { controller.isLaunchAtLoginEnabled },
                            set: { newValue in
                                controller.setLaunchAtLoginEnabled(newValue)
                            }
                        )
                    )
                    .disabled(controller.isUpdatingLaunchAtLogin)

                    Toggle(
                        "Auto-reconnect on disconnect",
                        isOn: Binding<Bool>(
                            get: { autoReconnectEnabled },
                            set: { newValue in
                                autoReconnectEnabled = newValue
                                controller.setAutoReconnectEnabled(newValue)
                            }
                        )
                    )

                    Toggle(
                        "Notify on state changes",
                        isOn: Binding<Bool>(
                            get: { notificationsEnabled },
                            set: { newValue in
                                notificationsEnabled = newValue
                                controller.setNotificationsEnabled(newValue)
                            }
                        )
                    )

                    Toggle(
                        "Auto-connect on launch",
                        isOn: Binding<Bool>(
                            get: { autoConnectOnLaunchEnabled },
                            set: { newValue in
                                autoConnectOnLaunchEnabled = newValue
                                controller.setAutoConnectOnLaunchEnabled(newValue)
                            }
                        )
                    )

                    if controller.isUpdatingLaunchAtLogin {
                        Text("updating launch at login...")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .accentColor(.primary)
    }

    private func errorSection(_ errorText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LAST ERROR")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color(hex: 0xFF453A))

            Text(errorText)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var footerSection: some View {
        Button("Quit Recon") {
            NSApplication.shared.terminate(nil)
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .regular))
        .foregroundColor(.red)
    }

    private func browseForKubeconfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = preferredKubeconfigDirectoryURL()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "yaml"),
            UTType(filenameExtension: "kubeconfig")
        ].compactMap { $0 }

        if panel.runModal() == .OK, let url = panel.url {
            controller.addAndSelectKubeconfig(path: url.path)
        }
    }

    private func preferredKubeconfigDirectoryURL() -> URL {
        if let selectedKubeconfigPath = controller.selectedKubeconfigPath {
            let selectedURL = URL(fileURLWithPath: selectedKubeconfigPath)
            return selectedURL.deletingLastPathComponent()
        }

        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kube", isDirectory: true)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
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
            window.appearance = NSAppearance(named: .darkAqua)
            window.isOpaque = false
            window.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.98)
        }
    }
}
