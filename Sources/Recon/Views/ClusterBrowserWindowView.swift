import AppKit
import SwiftUI

struct ClusterBrowserWindowSceneView: View {
    @StateObject private var viewModel: ClusterBrowserViewModel

    init(settingsStore: AppSettingsStore) {
        let environmentResolver = CommandEnvironmentResolver()
        let targetResolver = KubeTargetResolver(environmentResolver: environmentResolver)
        let namespaceDiscoveryService = NamespaceDiscoveryService(
            environmentResolver: environmentResolver,
            targetResolver: targetResolver,
            settingsStore: settingsStore
        )
        _viewModel = StateObject(
            wrappedValue: ClusterBrowserViewModel(
                settingsStore: settingsStore,
                targetResolver: targetResolver,
                namespaceDiscoveryService: namespaceDiscoveryService,
                resourceService: KubeResourceService(environmentResolver: environmentResolver)
            )
        )
    }

    var body: some View {
        ClusterBrowserWindowView(viewModel: viewModel)
    }
}

struct ClusterBrowserWindowView: View {
    @ObservedObject var viewModel: ClusterBrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            controlsSection

            if viewModel.shouldShowInlineErrorBanner, let errorMessage = viewModel.errorMessage {
                ClusterBrowserInlineErrorBanner(message: errorMessage) {
                    viewModel.refresh()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            contentArea
            statusBar
        }
        .frame(minWidth: 840, minHeight: 620)
        .background(ClusterBrowserWindowConfigurator())
        .background(copyCommandShortcutButton)
        .onAppear {
            viewModel.activateWindow()
        }
        .onDisappear {
            viewModel.deactivateWindow()
        }
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Array(ResourceType.allCases.enumerated()), id: \.element) { index, resourceType in
                    Button {
                        viewModel.selectResourceType(resourceType)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: resourceType.systemImage)
                                .font(.system(size: 12, weight: viewModel.selectedResourceType == resourceType ? .medium : .regular))

                            Text(resourceType.title)
                                .font(.system(size: 12, weight: viewModel.selectedResourceType == resourceType ? .medium : .regular))
                        }
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(viewModel.selectedResourceType == resourceType ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(Self.tabShortcut(for: index))
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

    private var controlsSection: some View {
        HStack(spacing: 10) {
            KeyboardFilterField(prompt: viewModel.filterPrompt, text: $viewModel.filterText)
                .frame(minWidth: 220)

            Button {
                viewModel.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .keyboardShortcut("r", modifiers: [.command])
            .help("Refresh")

            ClusterNamespacePicker(
                title: viewModel.displayNamespace,
                options: viewModel.namespacePickerOptions,
                selection: Binding(
                    get: { viewModel.selectedNamespacePickerOptionID },
                    set: { newValue in
                        guard let newValue else { return }
                        viewModel.selectNamespacePickerOption(withID: newValue)
                    }
                ),
                isLoading: viewModel.isLoadingNamespacePickerOptions
            )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var contentArea: some View {
        ZStack {
            currentTable

            overlayStateView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    viewModel.shouldShowErrorState ||
                    viewModel.shouldShowSearchEmptyState ||
                    viewModel.shouldShowResourceEmptyState ||
                    viewModel.shouldShowInitialLoadingState
                    ? Color(nsColor: .windowBackgroundColor).opacity(0.94)
                    : Color.clear
                )
        }
        .overlay(alignment: .topTrailing) {
            if viewModel.shouldShowRefreshingOverlay {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)

                    Text("Refreshing...")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private var currentTable: some View {
        switch viewModel.selectedResourceType {
        case .pods:
            Table(viewModel.filteredPods, selection: $viewModel.selectedResourceID, sortOrder: podSortOrderBinding) {
                TableColumn("Name", value: \.name) { pod in
                    Text(pod.name)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .clusterBrowserTableCell {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: pod)
                            }
                        }
                }
                .width(min: 240, ideal: 280)

                TableColumn("Status", value: \.statusSortValue) { pod in
                    Text(pod.displayStatusText)
                        .foregroundStyle(Self.color(for: pod.healthBucket))
                        .clusterBrowserTableCell {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: pod)
                            }
                        }
                }
                .width(min: 130, ideal: 150)

                TableColumn("Ready", value: \.readySortValue) { pod in
                    Text(pod.readyText)
                        .foregroundStyle(.secondary)
                        .clusterBrowserTableCell {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: pod)
                            }
                        }
                }
                .width(70)

                TableColumn("Restarts", value: \.restartCount) { pod in
                    Text("\(pod.restartCount)")
                        .foregroundStyle(.secondary)
                        .clusterBrowserTableCell(alignment: .trailing) {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: pod)
                            }
                        }
                }
                .width(80)

                TableColumn("Age", value: \.ageSortValue) { pod in
                    Text(Self.ageText(from: pod.createdAt))
                        .foregroundStyle(.secondary)
                        .clusterBrowserTableCell {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: pod)
                            }
                        }
                }
                .width(70)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))

        case .deployments:
            Table(viewModel.filteredDeployments, selection: $viewModel.selectedResourceID, sortOrder: deploymentSortOrderBinding) {
                TableColumn("Name", value: \.name) { deployment in
                    Text(deployment.name)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .clusterBrowserTableCell {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: deployment)
                            }
                        }
                }
                .width(min: 240, ideal: 280)

                TableColumn("Ready", value: \.defaultHealthSortValue) { deployment in
                    Text(deployment.readyText)
                        .foregroundStyle(Self.color(for: deployment.healthBucket))
                        .clusterBrowserTableCell {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: deployment)
                            }
                        }
                }
                .width(80)

                TableColumn("Up-to-date", value: \.updatedReplicas) { deployment in
                    Text("\(deployment.updatedReplicas)")
                        .foregroundStyle(.secondary)
                        .clusterBrowserTableCell(alignment: .trailing) {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: deployment)
                            }
                        }
                }
                .width(90)

                TableColumn("Available", value: \.availableReplicas) { deployment in
                    Text("\(deployment.availableReplicas)")
                        .foregroundStyle(.secondary)
                        .clusterBrowserTableCell(alignment: .trailing) {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: deployment)
                            }
                        }
                }
                .width(90)

                TableColumn("Age", value: \.ageSortValue) { deployment in
                    Text(Self.ageText(from: deployment.createdAt))
                        .foregroundStyle(.secondary)
                        .clusterBrowserTableCell {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: deployment)
                            }
                        }
                }
                .width(70)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))

        case .services:
            Table(viewModel.filteredServices, selection: $viewModel.selectedResourceID, sortOrder: serviceSortOrderBinding) {
                TableColumn("Name", value: \.name) { service in
                    Text(service.name)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .clusterBrowserTableCell {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: service)
                            }
                        }
                }
                .width(min: 220, ideal: 250)

                TableColumn("Type", value: \.type) { service in
                    Text(service.type)
                        .foregroundStyle(.secondary)
                        .clusterBrowserTableCell {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: service)
                            }
                        }
                }
                .width(100)

                TableColumn("Cluster IP", value: \.clusterIPSortValue) { service in
                    Text(service.clusterIP ?? "-")
                        .foregroundStyle(.secondary)
                        .clusterBrowserTableCell {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: service)
                            }
                        }
                }
                .width(min: 110, ideal: 140)

                TableColumn("Ports") { service in
                    Text(service.portsText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .clusterBrowserTableCell {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: service)
                            }
                        }
                }
                .width(min: 180, ideal: 220)

                TableColumn("Age", value: \.ageSortValue) { service in
                    Text(Self.ageText(from: service.createdAt))
                        .foregroundStyle(.secondary)
                        .clusterBrowserTableCell {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: service)
                            }
                        }
                }
                .width(70)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))

        case .configMaps:
            Table(viewModel.filteredConfigMaps, selection: $viewModel.selectedResourceID, sortOrder: configMapSortOrderBinding) {
                TableColumn("Name", value: \.name) { configMap in
                    Text(configMap.name)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .clusterBrowserTableCell {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: configMap)
                            }
                        }
                }
                .width(min: 240, ideal: 280)

                TableColumn("Keys", value: \.dataKeyCount) { configMap in
                    Text("\(configMap.dataKeyCount)")
                        .foregroundStyle(.secondary)
                        .clusterBrowserTableCell(alignment: .trailing) {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: configMap)
                            }
                        }
                }
                .width(70)

                TableColumn("Immutable", value: \.immutableSortValue) { configMap in
                    Text(configMap.immutableText)
                        .foregroundStyle(.secondary)
                        .clusterBrowserTableCell {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: configMap)
                            }
                        }
                }
                .width(90)

                TableColumn("Age", value: \.ageSortValue) { configMap in
                    Text(Self.ageText(from: configMap.createdAt))
                        .foregroundStyle(.secondary)
                        .clusterBrowserTableCell {
                            Button("Copy kubectl Command") {
                                viewModel.copyInspectCommand(for: configMap)
                            }
                        }
                }
                .width(70)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    @ViewBuilder
    private var overlayStateView: some View {
        if viewModel.shouldShowErrorState {
            ContentUnavailableView(
                label: {
                    Label("Couldn't Load \(viewModel.selectedResourceType.title)", systemImage: "exclamationmark.triangle")
                },
                description: {
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                    }
                },
                actions: {
                    Button("Retry") {
                        viewModel.refresh()
                    }
                    .buttonStyle(.borderedProminent)
                }
            )
        } else if viewModel.shouldShowSearchEmptyState {
            ContentUnavailableView.search(text: viewModel.filterText)
        } else if viewModel.shouldShowResourceEmptyState {
            ContentUnavailableView(
                label: {
                    Label(viewModel.selectedResourceType.emptyStateTitle, systemImage: viewModel.selectedResourceType.systemImage)
                },
                description: {
                    Text(viewModel.selectedResourceType.emptyStateDescription(namespace: viewModel.displayNamespace))
                }
            )
        } else if viewModel.shouldShowInitialLoadingState {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)

                Text("Loading \(viewModel.selectedResourceType.title.lowercased())...")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        } else {
            EmptyView()
        }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)

            HStack(spacing: 12) {
                Text(viewModel.statusBarCountText)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Text(viewModel.statusBarContextText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(viewModel.statusBarNamespaceText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var copyCommandShortcutButton: some View {
        Button(action: viewModel.copySelectedResourceCommand) {
            EmptyView()
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(viewModel.canCopySelectedResourceCommand == false)
        .frame(width: 0, height: 0)
        .opacity(0.001)
    }

    private var podSortOrderBinding: Binding<[KeyPathComparator<PodResource>]> {
        Binding(
            get: { viewModel.podTableSortOrder },
            set: { viewModel.podTableSortOrder = $0 }
        )
    }

    private var deploymentSortOrderBinding: Binding<[KeyPathComparator<DeploymentResource>]> {
        Binding(
            get: { viewModel.deploymentTableSortOrder },
            set: { viewModel.deploymentTableSortOrder = $0 }
        )
    }

    private var serviceSortOrderBinding: Binding<[KeyPathComparator<ServiceResource>]> {
        Binding(
            get: { viewModel.serviceTableSortOrder },
            set: { viewModel.serviceTableSortOrder = $0 }
        )
    }

    private var configMapSortOrderBinding: Binding<[KeyPathComparator<ConfigMapResource>]> {
        Binding(
            get: { viewModel.configMapTableSortOrder },
            set: { viewModel.configMapTableSortOrder = $0 }
        )
    }

    private static func tabShortcut(for index: Int) -> KeyEquivalent {
        switch index {
        case 0:
            return "1"
        case 1:
            return "2"
        case 2:
            return "3"
        default:
            return "4"
        }
    }

    private static func ageText(from date: Date?) -> String {
        guard let date else {
            return "-"
        }

        let interval = max(0, Int(Date().timeIntervalSince(date)))
        if interval < 60 {
            return "\(interval)s"
        }
        if interval < 3600 {
            return "\(interval / 60)m"
        }
        if interval < 86_400 {
            return "\(interval / 3600)h"
        }
        return "\(interval / 86_400)d"
    }

    private static func color(for healthBucket: ResourceHealthBucket) -> Color {
        switch healthBucket {
        case .healthy:
            return Color.green
        case .transitional:
            return Color.yellow
        case .unhealthy:
            return Color.red
        case .neutral:
            return Color.secondary
        }
    }
}

private struct ClusterNamespacePicker: View {
    let title: String
    let options: [NamespacePickerOption]
    let selection: Binding<String?>
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("ns")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            if options.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Picker(selection: selection) {
                    ForEach(options) { option in
                        Text(option.title).tag(Optional(option.id))
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.primary)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }
}

private struct ClusterBrowserInlineErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)

            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Retry", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.red.opacity(0.18), lineWidth: 0.5)
        )
    }
}

private struct ClusterBrowserWindowConfigurator: NSViewRepresentable {
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
            ClusterBrowserWindowPresenter.configure(window)
            window.isOpaque = false
            window.backgroundColor = NSColor.windowBackgroundColor
            window.level = .floating
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
}

private extension View {
    func clusterBrowserTableCell<MenuItems: View>(
        alignment: Alignment = .leading,
        @ViewBuilder menu: () -> MenuItems
    ) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .contentShape(Rectangle())
            .contextMenu(menuItems: menu)
    }
}
