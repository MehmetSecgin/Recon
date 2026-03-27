import AppKit
import SwiftUI

struct ReconMenuView: View {
    @Environment(\.openWindow) private var openWindow

    @ObservedObject var controller: TelepresenceController

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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusHeaderSection

            if let errorPresentation = controller.errorPresentation {
                ConnectionErrorBanner(
                    presentation: errorPresentation,
                    onCopyStatus: controller.copyStatusCommand,
                    onOpenLogs: controller.openLogs
                )
            }

            SectionDivider()

            metadataSection

            if controller.isProductionConnection {
                ProductionWarningBanner()
            }

            if controller.isSwitchingKubeconfig {
                switchingHint
            }

            SectionDivider()

            kubeconfigSection

            SectionDivider()

            actionsSection

            SectionDivider()

            preferencesSection

            SectionDivider()

            footerSection
        }
        .padding(14)
        .frame(width: 352, alignment: .leading)
        .background(MenuWindowConfigurator())
        .preferredColorScheme(.dark)
        .onAppear {
            controller.refreshNow()
        }
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
                            .foregroundStyle(.tertiary)
                    }

                    Button {
                        controller.refreshNow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.isRunningCommand)
                    .help("Refresh status")
                }
            }

            if let detailText = controller.headerDetailText, !detailText.isEmpty {
                Text(detailText)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
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
                .tint(.orange)
                .frame(width: 10, height: 10)
        case .connected:
            Circle()
                .fill(controller.isProductionConnection ? Color.red : Color.green)
                .frame(width: 8, height: 8)
                .shadow(color: (controller.isProductionConnection ? Color.red : Color.green).opacity(0.3), radius: 2)
        case .disconnected, .unavailable:
            Circle()
                .fill(Color.secondary)
                .frame(width: 8, height: 8)
        case .error:
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .shadow(color: Color.red.opacity(0.25), radius: 2)
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TARGET")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            MetadataRow(key: "Kubeconfig", value: controller.displayKubeconfig)

            MetadataRow(
                key: "Context",
                value: controller.displayContext,
                dimmed: controller.targetMetadata.isLastKnown,
                valueColor: controller.isProductionConnection ? .red : nil
            )

            MetadataRow(
                key: "Namespace",
                value: controller.displayNamespace,
                dimmed: controller.targetMetadata.isLastKnown
            )
        }
    }

    private var switchingHint: some View {
        Text(controller.snapshot.detailText)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.tertiary)
    }

    private var kubeconfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SWITCH KUBECONFIG")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            HStack(alignment: .center, spacing: 10) {
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
                    Text(controller.kubeconfigPickerLabel)
                        .font(.system(size: 12, weight: .regular))
                }
                .pickerStyle(.menu)
                .disabled(controller.isSwitchingKubeconfig || controller.kubeconfigOptions.isEmpty)

                Button("Choose…") {
                    browseForKubeconfig()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
            }
        }
        .disabled(controller.isSwitchingKubeconfig)
        .opacity(controller.isSwitchingKubeconfig ? 0.6 : 1)
    }

    @ViewBuilder
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controller.isRunningCommand || controller.snapshot.state == .busy {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                switch controller.snapshot.state {
                case .connected:
                    HStack(spacing: 10) {
                        actionButton("Reconnect", prominent: false) {
                            controller.reconnect()
                        }

                        actionButton(
                            "Disconnect",
                            prominent: controller.isProductionConnection,
                            tint: .red
                        ) {
                            controller.disconnect()
                        }
                    }
                case .disconnected:
                    actionButton("Connect", prominent: true) {
                        controller.connect()
                    }
                case .error:
                    actionButton("Reconnect", prominent: true) {
                        controller.reconnect()
                    }
                case .unavailable:
                    actionButton("Connect", prominent: true) {
                        controller.connect()
                    }
                    .disabled(true)
                case .busy:
                    EmptyView()
                }
            }
        }
    }

    private var preferencesSection: some View {
        Button {
            openWindow(id: "preferences")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))

                Text("Preferences…")
                    .font(.system(size: 13, weight: .regular))

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private var footerSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Recon \(appVersionText)")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.tertiary)

            Spacer(minLength: 8)

            Button("Quit Recon") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(.red)
        }
    }

    private func actionButton(
        _ title: String,
        prominent: Bool,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Group {
            if prominent {
                Button(title, action: action)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(title, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .tint(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct MetadataRow: View {
    let key: String
    let value: String
    var dimmed = false
    var valueColor: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(valueColor ?? .primary))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}

private struct ProductionBadge: View {
    var body: some View {
        Text("PRODUCTION")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.red.opacity(0.12), in: Capsule())
    }
}

private struct ProductionWarningBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
                .padding(.top, 1)

            Text("You are connected to a production cluster. Actions here affect live traffic.")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.red.opacity(0.2), lineWidth: 0.5)
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
                    .foregroundStyle(.red)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(presentation.message)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let suggestion = presentation.suggestion, !suggestion.isEmpty {
                        Text(suggestion)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let rawDetailPreview = presentation.rawDetailPreview, !rawDetailPreview.isEmpty {
                Text(rawDetailPreview)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 10) {
                if presentation.canCopyStatus {
                    Button("Copy 'telepresence status'") {
                        onCopyStatus()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                }

                if presentation.canOpenLogs {
                    Button("Open logs…") {
                        onOpenLogs()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.red.opacity(0.2), lineWidth: 0.5)
        )
    }
}

private struct SectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
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
            window.appearance = NSAppearance(named: .darkAqua)
            window.isOpaque = false
            window.backgroundColor = NSColor.windowBackgroundColor
        }
    }
}
