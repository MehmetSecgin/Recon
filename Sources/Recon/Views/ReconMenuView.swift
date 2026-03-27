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

    private var isNamespaceRowInteractive: Bool {
        controller.snapshot.state == .connected &&
        controller.isRunningCommand == false &&
        controller.targetMetadata.context != nil &&
        controller.namespacePickerOptions.isEmpty == false
    }

    var body: some View {
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
        VStack(alignment: .leading, spacing: 6) {
            MenuSectionHeading(title: "TARGET")

            MenuCard {
                MenuCardRow {
                    KubeconfigPickerMetadataRow(
                        key: "Kubeconfig",
                        value: controller.displayKubeconfig,
                        isInteractive: controller.isKubeconfigRowInteractive,
                        options: controller.kubeconfigPickerOptions,
                        selection: Binding<String?>(
                            get: { controller.selectedKubeconfigPickerOptionID },
                            set: { newValue in
                                guard let newValue else { return }
                                if newValue == "kubeconfig:choose-file" {
                                    browseForKubeconfig()
                                } else {
                                    controller.selectKubeconfigPickerOption(withID: newValue)
                                }
                            }
                        )
                    )
                }

                InsetDivider()

                MenuCardRow {
                    MetadataRow(
                        key: "Context",
                        value: controller.displayContext,
                        dimmed: controller.targetMetadata.isLastKnown,
                        valueColor: controller.isProductionConnection ? .red : nil
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
                        options: controller.namespacePickerOptions,
                        selection: Binding<String?>(
                            get: { controller.selectedNamespacePickerOptionID },
                            set: { newValue in
                                guard let newValue else { return }
                                controller.selectNamespacePickerOption(withID: newValue)
                            }
                        )
                    )
                }
            }
        }
    }

    private var switchingHint: some View {
        Text(controller.snapshot.detailText)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.tertiary)
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
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 8)

                FooterQuitButton {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
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

private struct NamespacePickerMetadataRow: View {
    let key: String
    let value: String
    let dimmed: Bool
    let showsOverrideAnnotation: Bool
    let isInteractive: Bool
    let isLoading: Bool
    let options: [NamespacePickerOption]
    let selection: Binding<String?>

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            if isInteractive {
                Picker(
                    selection: selection
                ) {
                    ForEach(options) { option in
                        Text(option.title).tag(Optional(option.id))
                    }
                } label: {
                    namespaceValueLabel
                }
                .pickerStyle(.menu)
                .labelsHidden()
            } else {
                namespaceValueLabel
            }
        }
    }

    private var namespaceValueLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)

            if showsOverrideAnnotation {
                Text("(override)")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.tertiary)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Color(nsColor: .tertiaryLabelColor))
            } else if isInteractive {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct KubeconfigPickerMetadataRow: View {
    let key: String
    let value: String
    let isInteractive: Bool
    let options: [KubeconfigPickerOption]
    let selection: Binding<String?>

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            if isInteractive {
                Picker(selection: selection) {
                    ForEach(options) { option in
                        Text(option.title).tag(Optional(option.id))
                    }
                } label: {
                    kubeconfigValueLabel
                }
                .pickerStyle(.menu)
                .labelsHidden()
            } else {
                kubeconfigValueLabel
            }
        }
    }

    private var kubeconfigValueLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)

            if isInteractive {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct MenuSectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            .tracking(0.5)
    }
}

private struct MenuCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))

                Text("Preferences…")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color(nsColor: .labelColor))

                Spacer(minLength: 8)

                Text("⌘,")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.white.opacity(0.06) : Color.clear)
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
            return Color(nsColor: .tertiaryLabelColor)
        }

        switch variant {
        case .primary:
            return .white
        case .secondary:
            return Color(nsColor: .labelColor)
        case .danger:
            return .red
        }
    }

    private func backgroundColor(configuration: Configuration) -> Color {
        let opacityAdjustment = configuration.isPressed ? 0.88 : 1

        switch variant {
        case .primary:
            return Color.accentColor.opacity(opacityAdjustment)
        case .secondary:
            return Color(nsColor: .controlBackgroundColor).opacity(opacityAdjustment)
        case .danger:
            return Color.red.opacity(0.12 * opacityAdjustment)
        }
    }
}

private struct ProductionBadge: View {
    var label = "PRODUCTION"

    var body: some View {
        Text(label)
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

private struct InsetDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 0.5)
            .padding(.leading, 12)
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
