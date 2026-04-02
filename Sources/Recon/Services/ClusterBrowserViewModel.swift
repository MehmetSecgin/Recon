import AppKit
import Foundation

@MainActor
final class ClusterBrowserViewModel: ObservableObject {
    @Published var selectedResourceType: ResourceType = .pods
    @Published var filterText = "" {
        didSet {
            reconcileSelectionWithVisibleResources()
        }
    }
    @Published var selectedResourceID: String?
    @Published private(set) var loadedResources: LoadedResources = .none
    @Published private(set) var contextDisplay = "-"
    @Published private(set) var selectedNamespace = ""
    @Published private(set) var namespacePickerOptions: [NamespacePickerOption] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingNamespacePickerOptions = false
    @Published private(set) var errorMessage: String?

    private let settingsStore: AppSettingsStore
    private let targetResolver: KubeTargetResolver
    private let namespaceDiscoveryService: NamespaceDiscoveryService
    private let resourceService: KubeResourceService

    private var currentContext: String?
    private var kubeconfigDefaultNamespace: String?
    private var activationTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var namespaceOptionsTask: Task<Void, Never>?
    private var isWindowActive = false
    private var currentFetchID = UUID()
    private var currentNamespaceOptionsLoadID = UUID()
    private var hasLoadedAtLeastOnce = false

    private var podSortMode: PodSortMode = .defaultHealth
    private var deploymentSortMode: DeploymentSortMode = .defaultHealth
    private var serviceSortMode: ServiceSortMode = .name(.ascending)
    private var configMapSortMode: ConfigMapSortMode = .name(.ascending)

    init(
        settingsStore: AppSettingsStore,
        targetResolver: KubeTargetResolver,
        namespaceDiscoveryService: NamespaceDiscoveryService,
        resourceService: KubeResourceService
    ) {
        self.settingsStore = settingsStore
        self.targetResolver = targetResolver
        self.namespaceDiscoveryService = namespaceDiscoveryService
        self.resourceService = resourceService
    }

    var displayNamespace: String {
        selectedNamespace.nilIfEmpty ?? "-"
    }

    var filterPrompt: String {
        "Filter \(selectedResourceType.title.lowercased())"
    }

    var currentVisibleRowCount: Int {
        currentFilteredRowCount
    }

    var hasLoadedRows: Bool {
        currentUnfilteredRowCount > 0
    }

    var shouldShowRefreshingOverlay: Bool {
        isLoading && hasLoadedRows
    }

    var selectedNamespacePickerOptionID: String? {
        guard !selectedNamespace.isEmpty else {
            return nil
        }

        if currentNamespaceOverride != nil {
            return NamespacePickerOption(kind: .namespace(selectedNamespace), title: selectedNamespace).id
        }

        let defaultNamespace = kubeconfigDefaultNamespace ?? selectedNamespace
        return NamespacePickerOption(kind: .namespace(defaultNamespace), title: defaultNamespace).id
    }

    var filteredPods: [PodResource] {
        guard case .pods(let pods) = loadedResources else {
            return []
        }

        return ClusterBrowserSorting.sortPods(filteredPods(from: pods), using: podSortMode)
    }

    var filteredDeployments: [DeploymentResource] {
        guard case .deployments(let deployments) = loadedResources else {
            return []
        }

        return ClusterBrowserSorting.sortDeployments(filteredDeployments(from: deployments), using: deploymentSortMode)
    }

    var filteredServices: [ServiceResource] {
        guard case .services(let services) = loadedResources else {
            return []
        }

        return ClusterBrowserSorting.sortServices(filteredServices(from: services), using: serviceSortMode)
    }

    var filteredConfigMaps: [ConfigMapResource] {
        guard case .configMaps(let configMaps) = loadedResources else {
            return []
        }

        return ClusterBrowserSorting.sortConfigMaps(filteredConfigMaps(from: configMaps), using: configMapSortMode)
    }

    var shouldShowInitialLoadingState: Bool {
        isLoading && hasLoadedAtLeastOnce == false && currentUnfilteredRowCount == 0
    }

    var shouldShowSearchEmptyState: Bool {
        !trimmedFilterText.isEmpty && currentUnfilteredRowCount > 0 && currentFilteredRowCount == 0 && errorMessage == nil
    }

    var shouldShowResourceEmptyState: Bool {
        hasLoadedAtLeastOnce && !isLoading && errorMessage == nil && trimmedFilterText.isEmpty && currentUnfilteredRowCount == 0
    }

    var shouldShowErrorState: Bool {
        errorMessage != nil && currentUnfilteredRowCount == 0 && !isLoading
    }

    var shouldShowInlineErrorBanner: Bool {
        errorMessage != nil && currentUnfilteredRowCount > 0
    }

    var statusBarCountText: String {
        let resourceLabel = selectedResourceType.pluralTitleForStatusBar
        if trimmedFilterText.isEmpty {
            return "\(currentUnfilteredRowCount) \(resourceLabel)"
        }

        return "\(currentFilteredRowCount) of \(currentUnfilteredRowCount) \(resourceLabel)"
    }

    var statusBarContextText: String {
        "ctx: \(contextDisplay)"
    }

    var statusBarNamespaceText: String {
        "ns: \(displayNamespace)"
    }

    var canCopySelectedResourceCommand: Bool {
        selectedResourceID != nil && selectedSelectedResourceCommand != nil
    }

    var podTableSortOrder: [KeyPathComparator<PodResource>] {
        get { Self.makePodSortOrder(from: podSortMode) }
        set {
            podSortMode = Self.resolvePodSortMode(from: newValue)
            objectWillChange.send()
            reconcileSelectionWithVisibleResources()
        }
    }

    var deploymentTableSortOrder: [KeyPathComparator<DeploymentResource>] {
        get { Self.makeDeploymentSortOrder(from: deploymentSortMode) }
        set {
            deploymentSortMode = Self.resolveDeploymentSortMode(from: newValue)
            objectWillChange.send()
            reconcileSelectionWithVisibleResources()
        }
    }

    var serviceTableSortOrder: [KeyPathComparator<ServiceResource>] {
        get { Self.makeServiceSortOrder(from: serviceSortMode) }
        set {
            serviceSortMode = Self.resolveServiceSortMode(from: newValue)
            objectWillChange.send()
            reconcileSelectionWithVisibleResources()
        }
    }

    var configMapTableSortOrder: [KeyPathComparator<ConfigMapResource>] {
        get { Self.makeConfigMapSortOrder(from: configMapSortMode) }
        set {
            configMapSortMode = Self.resolveConfigMapSortMode(from: newValue)
            objectWillChange.send()
            reconcileSelectionWithVisibleResources()
        }
    }

    func activateWindow() {
        guard isWindowActive == false else { return }
        isWindowActive = true

        activationTask?.cancel()
        activationTask = Task { [weak self] in
            await self?.loadInitialState()
        }
    }

    func deactivateWindow() {
        isWindowActive = false
        activationTask?.cancel()
        fetchTask?.cancel()
        namespaceOptionsTask?.cancel()
        Task {
            await namespaceDiscoveryService.clearSessionCache()
        }
        clearState()
    }

    func selectResourceType(_ resourceType: ResourceType) {
        guard selectedResourceType != resourceType else { return }
        selectedResourceType = resourceType
        selectedResourceID = nil
        errorMessage = nil
        loadedResources = .none
        startFetch(clearExistingData: true)
    }

    func selectNamespacePickerOption(withID optionID: String) {
        guard let option = namespacePickerOptions.first(where: { $0.id == optionID }),
              let context = currentContext else {
            return
        }

        switch option.kind {
        case .namespace(let namespace):
            guard namespace != selectedNamespace else { return }
            settingsStore.setOverride(namespace, for: context)
            settingsStore.recordRecentNamespace(namespace, for: context)
            selectedNamespace = namespace
        case .useKubeconfigDefault:
            guard currentNamespaceOverride != nil else { return }
            settingsStore.clearOverride(for: context)
            selectedNamespace = kubeconfigDefaultNamespace ?? "default"
        }

        selectedResourceID = nil
        errorMessage = nil
        refreshNamespacePickerOptions()
        startFetch(clearExistingData: false)
    }

    func refresh() {
        startFetch(clearExistingData: false)
    }

    func copySelectedResourceCommand() {
        guard let command = selectedSelectedResourceCommand else {
            return
        }

        copyToPasteboard(command)
    }

    func copyInspectCommand(for pod: PodResource) {
        copyToPasteboard(ClusterBrowserInspectCommandBuilder.pod(name: pod.name, namespace: pod.namespace))
    }

    func copyInspectCommand(for deployment: DeploymentResource) {
        copyToPasteboard(ClusterBrowserInspectCommandBuilder.deployment(name: deployment.name, namespace: deployment.namespace))
    }

    func copyInspectCommand(for service: ServiceResource) {
        copyToPasteboard(ClusterBrowserInspectCommandBuilder.service(name: service.name, namespace: service.namespace))
    }

    func copyInspectCommand(for configMap: ConfigMapResource) {
        copyToPasteboard(ClusterBrowserInspectCommandBuilder.configMap(name: configMap.name, namespace: configMap.namespace))
    }

    private var currentNamespaceOverride: String? {
        guard let currentContext else {
            return nil
        }

        return settingsStore.override(for: currentContext)
    }

    private var trimmedFilterText: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentUnfilteredRowCount: Int {
        switch loadedResources {
        case .none:
            return 0
        case .pods(let pods):
            return pods.count
        case .deployments(let deployments):
            return deployments.count
        case .services(let services):
            return services.count
        case .configMaps(let configMaps):
            return configMaps.count
        }
    }

    private var currentFilteredRowCount: Int {
        currentVisibleResourceIDs.count
    }

    private var currentVisibleResourceIDs: [String] {
        switch selectedResourceType {
        case .pods:
            return filteredPods.map(\.id)
        case .deployments:
            return filteredDeployments.map(\.id)
        case .services:
            return filteredServices.map(\.id)
        case .configMaps:
            return filteredConfigMaps.map(\.id)
        }
    }

    private var selectedSelectedResourceCommand: String? {
        guard let selectedResourceID else {
            return nil
        }

        switch selectedResourceType {
        case .pods:
            guard let pod = filteredPods.first(where: { $0.id == selectedResourceID }) else {
                return nil
            }
            return ClusterBrowserInspectCommandBuilder.pod(name: pod.name, namespace: pod.namespace)
        case .deployments:
            guard let deployment = filteredDeployments.first(where: { $0.id == selectedResourceID }) else {
                return nil
            }
            return ClusterBrowserInspectCommandBuilder.deployment(name: deployment.name, namespace: deployment.namespace)
        case .services:
            guard let service = filteredServices.first(where: { $0.id == selectedResourceID }) else {
                return nil
            }
            return ClusterBrowserInspectCommandBuilder.service(name: service.name, namespace: service.namespace)
        case .configMaps:
            guard let configMap = filteredConfigMaps.first(where: { $0.id == selectedResourceID }) else {
                return nil
            }
            return ClusterBrowserInspectCommandBuilder.configMap(name: configMap.name, namespace: configMap.namespace)
        }
    }

    private func loadInitialState() async {
        let resolvedMetadata = await targetResolver.resolveTargetMetadata()
        guard isWindowActive else { return }

        currentContext = resolvedMetadata.context
        contextDisplay = resolvedMetadata.context ?? "-"
        kubeconfigDefaultNamespace = resolvedMetadata.kubeconfigDefaultNamespace ?? resolvedMetadata.namespace ?? "default"

        if let context = resolvedMetadata.context,
           let namespaceOverride = settingsStore.override(for: context) {
            selectedNamespace = namespaceOverride
        } else {
            selectedNamespace = kubeconfigDefaultNamespace ?? "default"
        }

        refreshNamespacePickerOptions()

        if resolvedMetadata.context == nil, let resolutionError = resolvedMetadata.resolutionError {
            errorMessage = resolutionError
            hasLoadedAtLeastOnce = true
            isLoading = false
            return
        }

        startFetch(clearExistingData: true)
    }

    private func startFetch(clearExistingData: Bool) {
        guard isWindowActive else { return }

        let namespace = selectedNamespace.trimmingCharacters(in: .whitespacesAndNewlines)
        let resourceType = selectedResourceType
        guard namespace.isEmpty == false else {
            errorMessage = "Couldn't resolve the active namespace."
            hasLoadedAtLeastOnce = true
            isLoading = false
            return
        }

        fetchTask?.cancel()
        currentFetchID = UUID()
        let fetchID = currentFetchID

        if clearExistingData {
            loadedResources = .none
        }

        isLoading = true
        errorMessage = nil

        fetchTask = Task { [weak self] in
            await self?.performFetch(
                resourceType: resourceType,
                namespace: namespace,
                fetchID: fetchID
            )
        }
    }

    private func performFetch(resourceType: ResourceType, namespace: String, fetchID: UUID) async {
        do {
            let resources = try await loadResources(resourceType: resourceType, namespace: namespace)
            guard currentFetchID == fetchID, isWindowActive else { return }

            loadedResources = resources
            hasLoadedAtLeastOnce = true
            isLoading = false
            errorMessage = nil
            reconcileSelectionWithVisibleResources()
        } catch is CancellationError {
            return
        } catch {
            guard currentFetchID == fetchID, isWindowActive else { return }

            hasLoadedAtLeastOnce = true
            isLoading = false
            errorMessage = error.localizedDescription
            reconcileSelectionWithVisibleResources()
        }
    }

    private func loadResources(resourceType: ResourceType, namespace: String) async throws -> LoadedResources {
        switch resourceType {
        case .pods:
            return .pods(try await resourceService.fetchPods(namespace: namespace))
        case .deployments:
            return .deployments(try await resourceService.fetchDeployments(namespace: namespace))
        case .services:
            return .services(try await resourceService.fetchServices(namespace: namespace))
        case .configMaps:
            return .configMaps(try await resourceService.fetchConfigMaps(namespace: namespace))
        }
    }

    private func refreshNamespacePickerOptions() {
        guard let currentContext else {
            namespacePickerOptions = []
            isLoadingNamespacePickerOptions = false
            return
        }

        namespaceOptionsTask?.cancel()
        currentNamespaceOptionsLoadID = UUID()
        let loadID = currentNamespaceOptionsLoadID
        isLoadingNamespacePickerOptions = true

        namespaceOptionsTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.namespaceDiscoveryService.fetchAvailable(for: currentContext)
            guard self.currentNamespaceOptionsLoadID == loadID, self.isWindowActive else { return }

            self.namespacePickerOptions = self.makeNamespacePickerOptions(from: result)
            self.isLoadingNamespacePickerOptions = false
        }
    }

    private func makeNamespacePickerOptions(from result: NamespaceListResult) -> [NamespacePickerOption] {
        let orderedNamespaces = result.available +
            result.recentlyUsed +
            [result.kubeconfigDefault] +
            [selectedNamespace].compactMap { $0.nilIfEmpty }

        var options: [NamespacePickerOption] = []
        var seen = Set<String>()

        if result.currentOverride != nil {
            options.append(
                NamespacePickerOption(
                    kind: .useKubeconfigDefault,
                    title: formatNamespaceOptionTitle(result.kubeconfigDefault, suffix: "kubeconfig default")
                )
            )
        }

        for namespace in orderedNamespaces {
            let trimmedNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedNamespace.isEmpty == false,
                  seen.insert(trimmedNamespace).inserted else {
                continue
            }

            let suffix = result.currentOverride != nil && trimmedNamespace == result.kubeconfigDefault
                ? "kubeconfig default"
                : nil
            options.append(
                NamespacePickerOption(
                    kind: .namespace(trimmedNamespace),
                    title: formatNamespaceOptionTitle(trimmedNamespace, suffix: suffix)
                )
            )
        }

        return options
    }

    private func formatNamespaceOptionTitle(_ namespace: String, suffix: String?) -> String {
        var components = [namespace]
        if let suffix, suffix.isEmpty == false {
            components.append("(\(suffix))")
        }
        if ProductionDetector.isProductionNamespace(namespace) {
            components.append("[PROD]")
        }
        return components.joined(separator: " ")
    }

    private func clearState() {
        currentContext = nil
        kubeconfigDefaultNamespace = nil
        selectedNamespace = ""
        contextDisplay = "-"
        namespacePickerOptions = []
        loadedResources = .none
        filterText = ""
        selectedResourceID = nil
        errorMessage = nil
        isLoading = false
        isLoadingNamespacePickerOptions = false
        hasLoadedAtLeastOnce = false
        podSortMode = .defaultHealth
        deploymentSortMode = .defaultHealth
        serviceSortMode = .name(.ascending)
        configMapSortMode = .name(.ascending)
    }

    private func filteredPods(from pods: [PodResource]) -> [PodResource] {
        pods.filter { pod in
            matchesFilter([
                pod.name,
                pod.displayStatusText,
                pod.readyText,
                "\(pod.restartCount)"
            ])
        }
    }

    private func filteredDeployments(from deployments: [DeploymentResource]) -> [DeploymentResource] {
        deployments.filter { deployment in
            matchesFilter([
                deployment.name,
                deployment.readyText,
                "\(deployment.updatedReplicas)",
                "\(deployment.availableReplicas)"
            ])
        }
    }

    private func filteredServices(from services: [ServiceResource]) -> [ServiceResource] {
        services.filter { service in
            matchesFilter([
                service.name,
                service.type,
                service.clusterIP ?? "",
                service.portsText
            ])
        }
    }

    private func filteredConfigMaps(from configMaps: [ConfigMapResource]) -> [ConfigMapResource] {
        configMaps.filter { configMap in
            matchesFilter([
                configMap.name,
                "\(configMap.dataKeyCount)",
                configMap.immutableText
            ])
        }
    }

    private func reconcileSelectionWithVisibleResources() {
        selectedResourceID = ClusterBrowserSorting.retainedSelection(
            selectedID: selectedResourceID,
            visibleIDs: currentVisibleResourceIDs
        )
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func matchesFilter(_ values: [String]) -> Bool {
        let query = trimmedFilterText
        guard query.isEmpty == false else {
            return true
        }

        return values.contains { value in
            value.localizedCaseInsensitiveContains(query)
        }
    }

    private static func makePodSortOrder(from mode: PodSortMode) -> [KeyPathComparator<PodResource>] {
        switch mode {
        case .defaultHealth:
            return [
                KeyPathComparator(\.statusSortValue, order: .forward),
                KeyPathComparator(\.name, order: .forward)
            ]
        case .name(let direction):
            return [KeyPathComparator(\.name, order: direction.sortOrder)]
        case .status(let direction):
            return [KeyPathComparator(\.statusSortValue, order: direction.sortOrder)]
        case .ready(let direction):
            return [KeyPathComparator(\.readySortValue, order: direction.sortOrder)]
        case .restarts(let direction):
            return [KeyPathComparator(\.restartCount, order: direction.sortOrder)]
        case .age(let direction):
            return [KeyPathComparator(\.ageSortValue, order: direction.sortOrder)]
        }
    }

    private static func resolvePodSortMode(from sortOrder: [KeyPathComparator<PodResource>]) -> PodSortMode {
        guard let comparator = sortOrder.first else {
            return .defaultHealth
        }

        let direction = ClusterBrowserSortDirection(sortOrder: comparator.order)
        switch comparator.keyPath {
        case \PodResource.name:
            return .name(direction)
        case \PodResource.statusSortValue:
            return direction == .ascending ? .defaultHealth : .status(direction)
        case \PodResource.readySortValue:
            return .ready(direction)
        case \PodResource.restartCount:
            return .restarts(direction)
        case \PodResource.ageSortValue:
            return .age(direction)
        default:
            return .defaultHealth
        }
    }

    private static func makeDeploymentSortOrder(from mode: DeploymentSortMode) -> [KeyPathComparator<DeploymentResource>] {
        switch mode {
        case .defaultHealth:
            return [
                KeyPathComparator(\.defaultHealthSortValue, order: .forward),
                KeyPathComparator(\.name, order: .forward)
            ]
        case .name(let direction):
            return [KeyPathComparator(\.name, order: direction.sortOrder)]
        case .ready(let direction):
            return [KeyPathComparator(\.defaultHealthSortValue, order: direction.sortOrder)]
        case .updated(let direction):
            return [KeyPathComparator(\.updatedReplicas, order: direction.sortOrder)]
        case .available(let direction):
            return [KeyPathComparator(\.availableReplicas, order: direction.sortOrder)]
        case .age(let direction):
            return [KeyPathComparator(\.ageSortValue, order: direction.sortOrder)]
        }
    }

    private static func resolveDeploymentSortMode(from sortOrder: [KeyPathComparator<DeploymentResource>]) -> DeploymentSortMode {
        guard let comparator = sortOrder.first else {
            return .defaultHealth
        }

        let direction = ClusterBrowserSortDirection(sortOrder: comparator.order)
        switch comparator.keyPath {
        case \DeploymentResource.name:
            return .name(direction)
        case \DeploymentResource.defaultHealthSortValue:
            return direction == .ascending ? .defaultHealth : .ready(direction)
        case \DeploymentResource.updatedReplicas:
            return .updated(direction)
        case \DeploymentResource.availableReplicas:
            return .available(direction)
        case \DeploymentResource.ageSortValue:
            return .age(direction)
        default:
            return .defaultHealth
        }
    }

    private static func makeServiceSortOrder(from mode: ServiceSortMode) -> [KeyPathComparator<ServiceResource>] {
        switch mode {
        case .name(let direction):
            return [KeyPathComparator(\.name, order: direction.sortOrder)]
        case .type(let direction):
            return [KeyPathComparator(\.type, order: direction.sortOrder)]
        case .clusterIP(let direction):
            return [KeyPathComparator(\.clusterIPSortValue, order: direction.sortOrder)]
        case .age(let direction):
            return [KeyPathComparator(\.ageSortValue, order: direction.sortOrder)]
        }
    }

    private static func resolveServiceSortMode(from sortOrder: [KeyPathComparator<ServiceResource>]) -> ServiceSortMode {
        guard let comparator = sortOrder.first else {
            return .name(.ascending)
        }

        let direction = ClusterBrowserSortDirection(sortOrder: comparator.order)
        switch comparator.keyPath {
        case \ServiceResource.name:
            return .name(direction)
        case \ServiceResource.type:
            return .type(direction)
        case \ServiceResource.clusterIPSortValue:
            return .clusterIP(direction)
        case \ServiceResource.ageSortValue:
            return .age(direction)
        default:
            return .name(.ascending)
        }
    }

    private static func makeConfigMapSortOrder(from mode: ConfigMapSortMode) -> [KeyPathComparator<ConfigMapResource>] {
        switch mode {
        case .name(let direction):
            return [KeyPathComparator(\.name, order: direction.sortOrder)]
        case .keyCount(let direction):
            return [KeyPathComparator(\.dataKeyCount, order: direction.sortOrder)]
        case .immutable(let direction):
            return [KeyPathComparator(\.immutableSortValue, order: direction.sortOrder)]
        case .age(let direction):
            return [KeyPathComparator(\.ageSortValue, order: direction.sortOrder)]
        }
    }

    private static func resolveConfigMapSortMode(from sortOrder: [KeyPathComparator<ConfigMapResource>]) -> ConfigMapSortMode {
        guard let comparator = sortOrder.first else {
            return .name(.ascending)
        }

        let direction = ClusterBrowserSortDirection(sortOrder: comparator.order)
        switch comparator.keyPath {
        case \ConfigMapResource.name:
            return .name(direction)
        case \ConfigMapResource.dataKeyCount:
            return .keyCount(direction)
        case \ConfigMapResource.immutableSortValue:
            return .immutable(direction)
        case \ConfigMapResource.ageSortValue:
            return .age(direction)
        default:
            return .name(.ascending)
        }
    }
}

private extension ClusterBrowserSortDirection {
    init(sortOrder: SortOrder) {
        switch sortOrder {
        case .forward:
            self = .ascending
        case .reverse:
            self = .descending
        @unknown default:
            self = .ascending
        }
    }

    var sortOrder: SortOrder {
        switch self {
        case .ascending:
            return .forward
        case .descending:
            return .reverse
        }
    }
}
