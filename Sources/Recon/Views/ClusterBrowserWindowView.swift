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
        }
        .frame(width: 720, height: 520)
        .background(ClusterBrowserWindowConfigurator())
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
        VStack(spacing: 12) {
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
            }

            HStack(spacing: 12) {
                ClusterInfoBadge(label: "Context", value: viewModel.contextDisplay)
                ClusterInfoBadge(label: "Namespace", value: viewModel.displayNamespace)

                Spacer(minLength: 0)

                Text("\(viewModel.currentVisibleRowCount) shown")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
            }
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

                    Text("Refreshing…")
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
            Table(viewModel.filteredPods, selection: $viewModel.selectedResourceID) {
                TableColumn("Name") { pod in
                    Text(pod.name)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                }
                .width(min: 240, ideal: 280)

                TableColumn("Status") { pod in
                    Text(pod.statusText)
                        .foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 120)

                TableColumn("Ready") { pod in
                    Text(pod.readyText)
                        .foregroundStyle(.secondary)
                }
                .width(70)

                TableColumn("Restarts") { pod in
                    Text("\(pod.restartCount)")
                        .foregroundStyle(.secondary)
                }
                .width(80)

                TableColumn("Age") { pod in
                    Text(Self.ageText(from: pod.createdAt))
                        .foregroundStyle(.secondary)
                }
                .width(70)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))

        case .deployments:
            Table(viewModel.filteredDeployments, selection: $viewModel.selectedResourceID) {
                TableColumn("Name") { deployment in
                    Text(deployment.name)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                }
                .width(min: 240, ideal: 280)

                TableColumn("Ready") { deployment in
                    Text(deployment.readyText)
                        .foregroundStyle(.secondary)
                }
                .width(80)

                TableColumn("Up-to-date") { deployment in
                    Text("\(deployment.updatedReplicas)")
                        .foregroundStyle(.secondary)
                }
                .width(90)

                TableColumn("Available") { deployment in
                    Text("\(deployment.availableReplicas)")
                        .foregroundStyle(.secondary)
                }
                .width(90)

                TableColumn("Age") { deployment in
                    Text(Self.ageText(from: deployment.createdAt))
                        .foregroundStyle(.secondary)
                }
                .width(70)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))

        case .services:
            Table(viewModel.filteredServices, selection: $viewModel.selectedResourceID) {
                TableColumn("Name") { service in
                    Text(service.name)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                }
                .width(min: 220, ideal: 250)

                TableColumn("Type") { service in
                    Text(service.type)
                        .foregroundStyle(.secondary)
                }
                .width(100)

                TableColumn("Cluster IP") { service in
                    Text(service.clusterIP ?? "\u{2014}")
                        .foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 140)

                TableColumn("Ports") { service in
                    Text(service.portsText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 180, ideal: 220)

                TableColumn("Age") { service in
                    Text(Self.ageText(from: service.createdAt))
                        .foregroundStyle(.secondary)
                }
                .width(70)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))

        case .ingresses:
            Table(viewModel.filteredIngresses, selection: $viewModel.selectedResourceID) {
                TableColumn("Name") { ingress in
                    Text(ingress.name)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                }
                .width(min: 220, ideal: 250)

                TableColumn("Hosts") { ingress in
                    Text(ingress.hostsText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 280, ideal: 360)

                TableColumn("Age") { ingress in
                    Text(Self.ageText(from: ingress.createdAt))
                        .foregroundStyle(.secondary)
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

                Text("Loading \(viewModel.selectedResourceType.title.lowercased())…")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        } else {
            EmptyView()
        }
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
            return "\u{2014}"
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

private struct ClusterInfoBadge: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)

            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
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
