import AppKit
import SwiftUI

struct ClusterBrowserWindowSceneView: View {
    @StateObject private var viewModel: ClusterBrowserViewModel
    private let appActivationPolicyController: AppActivationPolicyController

    init(
        settingsStore: AppSettingsStore,
        browserConfigService: BrowserConfigService,
        appActivationPolicyController: AppActivationPolicyController
    ) {
        self.appActivationPolicyController = appActivationPolicyController
        _viewModel = StateObject(
            wrappedValue: ClusterBrowserViewModel(
                settingsStore: settingsStore,
                browserConfigService: browserConfigService,
                resourceService: KubeResourceService(browserConfigService: browserConfigService)
            )
        )
    }

    var body: some View {
        ClusterBrowserWindowView(
            viewModel: viewModel,
            appActivationPolicyController: appActivationPolicyController
        )
    }
}

struct ClusterBrowserWindowView: View {
    @ObservedObject var viewModel: ClusterBrowserViewModel
    let appActivationPolicyController: AppActivationPolicyController

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 380)

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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, minHeight: 700)
        .background(
            ClusterBrowserWindowConfigurator(
                appActivationPolicyController: appActivationPolicyController
            )
        )
        .background(copyCommandShortcutButton)
        .onAppear {
            viewModel.activateWindow()
        }
        .onDisappear {
            viewModel.deactivateWindow()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Clusters")
                    .font(.system(size: 13, weight: .semibold))

                Spacer(minLength: 8)

                Button(viewModel.isNamespaceEditMode ? "Done" : "Edit") {
                    viewModel.isNamespaceEditMode.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            TextField("Filter clusters / namespaces", text: $viewModel.sidebarFilterText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, weight: .regular))
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if viewModel.browserContexts.isEmpty && viewModel.isLoadingCatalog == false {
                        Text(viewModel.browserSourcesEmptyStateDescription)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    } else if viewModel.displayedBrowserContexts.isEmpty && viewModel.isSidebarFiltering {
                        Text("No clusters or namespaces match `\(viewModel.sidebarFilterText)`.")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(viewModel.displayedBrowserContexts) { context in
                            contextSection(for: context)
                        }
                    }
                }
                .padding(.vertical, 10)
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        }
    }

    @ViewBuilder
    private func contextSection(for context: BrowserContextDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                ClusterBrowserContextRow(
                    context: context,
                    isSelected: isContextSelected(context),
                    isExpanded: viewModel.expandedContextIDs.contains(context.id),
                    loadState: viewModel.contextLoadStates[context.id] ?? .idle,
                    onActivate: {
                        viewModel.activateContextRow(context)
                    }
                )

                if viewModel.isNamespaceEditMode {
                    let totalCount = viewModel.totalNamespaceCount(in: context)
                    let hiddenCount = viewModel.hiddenNamespaceCount(in: context)

                    if totalCount > 0 {
                        Text("\(hiddenCount)/\(totalCount)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: Capsule())
                            .help("Hidden namespaces / total namespaces")

                        Button(hiddenCount == totalCount ? "Show All" : "Hide All") {
                            viewModel.toggleHideAllNamespaces(in: context)
                        }
                        .buttonStyle(ClusterBrowserSidebarActionButtonStyle())
                        .help(hiddenCount == totalCount ? "Show all namespaces in normal mode" : "Hide all namespaces in normal mode")
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 32)

            let namespaces = viewModel.displayedNamespaces(for: context)
            if (viewModel.expandedContextIDs.contains(context.id) || viewModel.isSidebarFiltering),
               namespaces.isEmpty == false {
                ForEach(namespaces, id: \.self) { namespace in
                    ClusterBrowserNamespaceRow(
                        namespace: namespace,
                        isSelected: isNamespaceSelected(namespace, in: context),
                        isHidden: viewModel.isNamespaceHidden(namespace, in: context),
                        isEditMode: viewModel.isNamespaceEditMode,
                        isProductionLike: ProductionDetector.isProductionNamespace(namespace),
                        onSelect: {
                            viewModel.selectNamespace(namespace, in: context)
                        },
                        onToggleHidden: {
                            viewModel.toggleNamespaceHidden(namespace, in: context)
                        }
                    )
                    .padding(.horizontal, 10)
                }
            }
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
                .disabled(viewModel.selectedTarget == nil)

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
                    viewModel.shouldShowInitialLoadingState ||
                    viewModel.shouldShowBrowserSourcesEmptyState
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
                    Text(pod.ageText)
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
                    Text(deployment.ageText)
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
                    Text(service.ageText)
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

                TableColumn("Age", value: \.ageSortValue) { configMap in
                    Text(configMap.ageText)
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
        if viewModel.shouldShowBrowserSourcesEmptyState {
            ContentUnavailableView(
                label: {
                    Label(viewModel.browserSourcesEmptyStateTitle, systemImage: "externaldrive.badge.exclamationmark")
                },
                description: {
                    Text(viewModel.browserSourcesEmptyStateDescription)
                }
            )
        } else if viewModel.shouldShowErrorState {
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

    private func isContextSelected(_ context: BrowserContextDescriptor) -> Bool {
        viewModel.selectedTarget?.context.id == context.id
    }

    private func isNamespaceSelected(_ namespace: String, in context: BrowserContextDescriptor) -> Bool {
        viewModel.selectedTarget?.context.id == context.id &&
        viewModel.selectedTarget?.namespace == namespace
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

private struct ClusterBrowserNamespaceRow: View {
    let namespace: String
    let isSelected: Bool
    let isHidden: Bool
    let isEditMode: Bool
    let isProductionLike: Bool
    let onSelect: () -> Void
    let onToggleHidden: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                )

            Text(namespace)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(namespace)

            if isSelected {
                Text("CURRENT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }

            if isHidden && isEditMode {
                Text("HIDDEN")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            }

            Spacer(minLength: 0)

            if isProductionLike {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            if isEditMode {
                ClusterBrowserSidebarIconButton(
                    systemName: isHidden ? "eye.slash" : "eye",
                    helpText: isHidden
                    ? "Show namespace in normal mode"
                    : "Hide namespace from normal mode"
                ) {
                    onToggleHidden()
                }
            }
        }
        .frame(minHeight: 24)
        .padding(.leading, 36)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            guard isEditMode == false else { return }
            onSelect()
        }
    }

    private var textColor: Color {
        if isHidden && isEditMode {
            return Color(nsColor: .tertiaryLabelColor)
        }

        if isSelected || (isHovering && isEditMode == false) {
            return Color(nsColor: .labelColor)
        }

        return Color(nsColor: .secondaryLabelColor)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.1)
        }

        if isHovering && isEditMode == false {
            return Color(nsColor: .controlAccentColor).opacity(0.08)
        }

        return Color.clear
    }
}

private struct ClusterBrowserContextRow: View {
    let context: BrowserContextDescriptor
    let isSelected: Bool
    let isExpanded: Bool
    let loadState: BrowserContextLoadState
    let onActivate: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovering ? Color(nsColor: .labelColor) : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 12, height: 12)

                Circle()
                    .fill(context.isProductionLike ? Color.orange : Color.clear)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(context.isProductionLike ? Color.orange : Color(nsColor: .separatorColor), lineWidth: 1)
                    )

                Text(context.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(context.name)

                if let sourceBadge = context.sourceBadge {
                    Text(sourceBadge)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                        .help(context.sourcePath)
                }

                if isSelected {
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }

                if case .loadingNamespaces = loadState {
                    ProgressView()
                        .controlSize(.mini)
                } else if case .failed = loadState {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                }

                Spacer(minLength: 0)
            }
            .frame(minHeight: 24)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(borderColor, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.14)
        }

        if isHovering {
            return Color(nsColor: .controlAccentColor).opacity(0.08)
        }

        return Color.clear
    }

    private var borderColor: Color {
        if isHovering && isSelected == false {
            return Color(nsColor: .controlAccentColor).opacity(0.18)
        }

        return Color.clear
    }
}

private struct ClusterBrowserSidebarIconButton: View {
    let systemName: String
    let helpText: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? Color(nsColor: .labelColor) : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isHovering ? Color.accentColor.opacity(0.24) : Color.clear, lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { isHovering = $0 }
    }
}

private struct ClusterBrowserSidebarActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarActionButtonBody(configuration: configuration)
    }

    private struct SidebarActionButtonBody: View {
        let configuration: Configuration

        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(borderColor, lineWidth: 0.5)
                )
                .contentShape(Capsule(style: .continuous))
                .onHover { isHovering = $0 }
        }

        private var isHighlighted: Bool {
            isHovering || configuration.isPressed
        }

        private var foregroundColor: Color {
            isHighlighted ? Color(nsColor: .labelColor) : .secondary
        }

        private var backgroundColor: Color {
            isHighlighted ? Color.accentColor.opacity(0.12) : Color.clear
        }

        private var borderColor: Color {
            isHighlighted ? Color.accentColor.opacity(0.24) : Color(nsColor: .separatorColor).opacity(0.35)
        }
    }
}

private struct ClusterBrowserWindowConfigurator: NSViewRepresentable {
    let appActivationPolicyController: AppActivationPolicyController

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
            appActivationPolicyController.registerDeckWindow(window)
            window.isOpaque = false
            window.backgroundColor = NSColor.windowBackgroundColor
            window.level = .normal
            window.standardWindowButton(.zoomButton)?.isHidden = false
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
