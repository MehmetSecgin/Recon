import AppKit
import Combine
import Foundation

@MainActor
final class ClusterBrowserViewModel: ObservableObject {
    @Published var selectedResourceType: ResourceType = .pods
    @Published var filterText = "" {
        didSet {
            reconcileSelectionWithVisibleResources()
        }
    }
    @Published var sidebarFilterText = "" {
        didSet {
            handleSidebarFilterChange()
        }
    }
    @Published var isNamespaceEditMode = false {
        didSet {
            handleNamespaceEditModeChange()
        }
    }
    @Published var selectedResourceID: String?
    @Published private(set) var loadedResources: LoadedResources = .none
    @Published private(set) var browserContexts: [BrowserContextDescriptor] = []
    @Published private(set) var sourceStatuses: [BrowserSourceStatus] = []
    @Published private(set) var contextLoadStates: [String: BrowserContextLoadState] = [:]
    @Published private(set) var expandedContextIDs = Set<String>()
    @Published private(set) var selectedTarget: BrowserTarget?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingCatalog = false
    @Published private(set) var errorMessage: String?

    private let settingsStore: AppSettingsStore
    private let browserConfigService: BrowserConfigService
    private let resourceService: KubeResourceService

    private var activationTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private var namespaceTasks: [String: Task<Void, Never>] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var isWindowActive = false
    private var currentFetchID = UUID()
    private var hasLoadedAtLeastOnce = false
    private var hasLoadedCatalogAtLeastOnce = false

    private var podSortMode: PodSortMode = .defaultHealth
    private var deploymentSortMode: DeploymentSortMode = .defaultHealth
    private var serviceSortMode: ServiceSortMode = .name(.ascending)
    private var configMapSortMode: ConfigMapSortMode = .name(.ascending)

    init(
        settingsStore: AppSettingsStore,
        browserConfigService: BrowserConfigService,
        resourceService: KubeResourceService
    ) {
        self.settingsStore = settingsStore
        self.browserConfigService = browserConfigService
        self.resourceService = resourceService
        bindSettings()
    }

    var contextDisplay: String {
        selectedTarget?.context.name ?? "-"
    }

    var displayNamespace: String {
        selectedTarget?.namespace.nilIfEmpty ?? "-"
    }

    var filterPrompt: String {
        "Filter \(selectedResourceType.title.lowercased())"
    }

    var displayedBrowserContexts: [BrowserContextDescriptor] {
        browserContexts.filter { context in
            if selectedTarget?.context.id == context.id {
                return true
            }

            return BrowserSidebarFiltering.matchesContext(
                context,
                loadState: contextLoadStates[context.id] ?? .idle,
                query: sidebarFilterText
            )
        }
    }

    var isSidebarFiltering: Bool {
        trimmedSidebarFilterText.isEmpty == false
    }

    var sidebarActiveTargetSummary: String? {
        guard let selectedTarget else {
            return nil
        }

        return "\(selectedTarget.context.name) / \(selectedTarget.namespace)"
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

    var shouldShowInitialLoadingState: Bool {
        (isLoadingCatalog || isLoading) && hasLoadedAtLeastOnce == false && currentUnfilteredRowCount == 0
    }

    var shouldShowSearchEmptyState: Bool {
        !trimmedFilterText.isEmpty && currentUnfilteredRowCount > 0 && currentFilteredRowCount == 0 && errorMessage == nil
    }

    var shouldShowResourceEmptyState: Bool {
        hasLoadedAtLeastOnce && !isLoading && errorMessage == nil && trimmedFilterText.isEmpty && currentUnfilteredRowCount == 0
    }

    var shouldShowBrowserSourcesEmptyState: Bool {
        hasLoadedCatalogAtLeastOnce &&
        !isLoadingCatalog &&
        browserContexts.isEmpty &&
        currentUnfilteredRowCount == 0 &&
        errorMessage == nil
    }

    var browserSourcesEmptyStateTitle: String {
        if sourceStatuses.isEmpty {
            return "No Browser Sources"
        }

        return "No Valid Browser Contexts"
    }

    var browserSourcesEmptyStateDescription: String {
        if sourceStatuses.isEmpty {
            return "Add kubeconfig files for the cluster browser in Preferences."
        }

        return "Recon couldn't find a usable context in the configured browser kubeconfig files."
    }

    var shouldShowErrorState: Bool {
        errorMessage != nil && currentUnfilteredRowCount == 0 && !isLoading && !isLoadingCatalog
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
        catalogTask?.cancel()
        fetchTask?.cancel()
        namespaceTasks.values.forEach { $0.cancel() }
        namespaceTasks.removeAll()
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

    func refresh() {
        if selectedTarget == nil {
            reloadCatalog(preserveCurrentSelection: true)
            return
        }

        if let context = selectedTarget?.context {
            loadNamespaces(for: context, force: true)
        }
        startFetch(clearExistingData: false)
    }

    func toggleExpanded(for context: BrowserContextDescriptor) {
        if expandedContextIDs.contains(context.id) {
            expandedContextIDs.remove(context.id)
            return
        }

        expandedContextIDs.insert(context.id)
        loadNamespaces(for: context)
    }

    func activateContextRow(_ context: BrowserContextDescriptor) {
        let shouldCollapse = expandedContextIDs.contains(context.id)
        selectContext(context)

        if shouldCollapse {
            expandedContextIDs.remove(context.id)
        } else {
            expandedContextIDs.insert(context.id)
            loadNamespaces(for: context)
        }
    }

    func selectContext(_ context: BrowserContextDescriptor) {
        let namespace = BrowserNamespaceSelectionResolver.resolve(
            rememberedNamespace: settingsStore.browserSelectedNamespace(for: context.id),
            defaultNamespace: context.defaultNamespace
        )

        select(target: BrowserTarget(context: context, namespace: namespace), persistSelection: true, clearExistingData: true)
    }

    func selectNamespace(_ namespace: String, in context: BrowserContextDescriptor) {
        select(target: BrowserTarget(context: context, namespace: namespace), persistSelection: true, clearExistingData: true)
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

    func displayedNamespaces(for context: BrowserContextDescriptor) -> [String] {
        let loadState = contextLoadStates[context.id] ?? .idle
        var displayedNamespaces = BrowserSidebarFiltering.filteredNamespaces(
            from: loadState.namespaces,
            query: sidebarFilterText
        )
        let activeNamespace = selectedTarget?.context.id == context.id ? selectedTarget?.namespace : nil

        if let activeNamespace,
           loadState.namespaces.contains(activeNamespace),
           displayedNamespaces.contains(activeNamespace) == false {
            displayedNamespaces.insert(activeNamespace, at: 0)
        }

        guard isNamespaceEditMode == false else {
            return displayedNamespaces
        }

        let hiddenNamespaces = Set(settingsStore.browserHiddenNamespaces(for: context.id))

        return displayedNamespaces.filter { namespace in
            hiddenNamespaces.contains(namespace) == false || namespace == activeNamespace
        }
    }

    func isNamespaceHidden(_ namespace: String, in context: BrowserContextDescriptor) -> Bool {
        settingsStore.browserHiddenNamespaces(for: context.id).contains(namespace)
    }

    func toggleNamespaceHidden(_ namespace: String, in context: BrowserContextDescriptor) {
        let isHidden = isNamespaceHidden(namespace, in: context)
        settingsStore.setBrowserNamespaceHidden(!isHidden, namespace: namespace, for: context.id)
        objectWillChange.send()
    }

    func hiddenNamespaceCount(in context: BrowserContextDescriptor) -> Int {
        let visibleNamespaces = Set((contextLoadStates[context.id] ?? .idle).namespaces)
        guard visibleNamespaces.isEmpty == false else {
            return 0
        }

        return settingsStore.browserHiddenNamespaces(for: context.id)
            .filter { visibleNamespaces.contains($0) }
            .count
    }

    func totalNamespaceCount(in context: BrowserContextDescriptor) -> Int {
        (contextLoadStates[context.id] ?? .idle).namespaces.count
    }

    func toggleHideAllNamespaces(in context: BrowserContextDescriptor) {
        let namespaces = (contextLoadStates[context.id] ?? .idle).namespaces
        guard namespaces.isEmpty == false else {
            loadNamespaces(for: context, force: true)
            return
        }

        if hiddenNamespaceCount(in: context) == namespaces.count {
            settingsStore.setBrowserHiddenNamespaces([], for: context.id)
        } else {
            settingsStore.setBrowserHiddenNamespaces(namespaces, for: context.id)
        }

        objectWillChange.send()
    }

    private var trimmedFilterText: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSidebarFilterText: String {
        sidebarFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func bindSettings() {
        settingsStore.$browserKubeconfigPaths
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.isWindowActive else { return }
                    self.reloadCatalog(preserveCurrentSelection: true)
                }
            }
            .store(in: &cancellables)
    }

    private func loadInitialState() async {
        reloadCatalog(preserveCurrentSelection: false)
    }

    private func reloadCatalog(
        preserveCurrentSelection: Bool
    ) {
        catalogTask?.cancel()
        isLoadingCatalog = true

        catalogTask = Task { [weak self] in
            guard let self else { return }
            let catalog = await self.browserConfigService.loadContextCatalog()
            guard self.isWindowActive else { return }

            self.sourceStatuses = catalog.sourceStatuses
            self.browserContexts = catalog.contexts
            self.hasLoadedCatalogAtLeastOnce = true
            self.isLoadingCatalog = false

            guard let target = self.resolveInitialTarget(
                from: catalog.contexts
            ) else {
                self.selectedTarget = nil
                self.loadedResources = .none
                self.selectedResourceID = nil
                self.errorMessage = nil
                self.isLoading = false
                return
            }

            self.select(target: target, persistSelection: true, clearExistingData: true)
        }
    }

    private func resolveInitialTarget(
        from contexts: [BrowserContextDescriptor]
    ) -> BrowserTarget? {
        guard contexts.isEmpty == false else {
            return nil
        }

        if let lastSelectedContextID = settingsStore.browserLastSelectedContextID,
           let context = contexts.first(where: { $0.id == lastSelectedContextID }) {
            return BrowserTarget(
                context: context,
                namespace: BrowserNamespaceSelectionResolver.resolve(
                    rememberedNamespace: settingsStore.browserSelectedNamespace(for: context.id),
                    defaultNamespace: context.defaultNamespace
                )
            )
        }

        guard let firstContext = contexts.first else {
            return nil
        }

        return BrowserTarget(
            context: firstContext,
            namespace: BrowserNamespaceSelectionResolver.resolve(
                rememberedNamespace: settingsStore.browserSelectedNamespace(for: firstContext.id),
                defaultNamespace: firstContext.defaultNamespace
            )
        )
    }

    private func select(
        target: BrowserTarget,
        persistSelection: Bool,
        clearExistingData: Bool
    ) {
        selectedTarget = target
        selectedResourceID = nil
        errorMessage = nil
        expandedContextIDs.insert(target.context.id)

        if persistSelection {
            settingsStore.setBrowserLastSelectedContextID(target.context.id)
            settingsStore.setBrowserSelectedNamespace(target.namespace, for: target.context.id)
            settingsStore.recordBrowserRecentNamespace(target.namespace, for: target.context.id)
        }

        loadNamespaces(for: target.context)
        startFetch(clearExistingData: clearExistingData)
    }

    private func loadNamespaces(for context: BrowserContextDescriptor, force: Bool = false) {
        if !force {
            switch contextLoadStates[context.id] ?? .idle {
            case .loadingNamespaces, .loadedNamespaces:
                return
            case .idle, .failed:
                break
            }
        }

        namespaceTasks[context.id]?.cancel()
        contextLoadStates[context.id] = .loadingNamespaces

        namespaceTasks[context.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let namespaces = try await self.browserConfigService.fetchNamespaces(for: context)
                guard self.isWindowActive else { return }
                self.contextLoadStates[context.id] = .loadedNamespaces(namespaces)
            } catch is CancellationError {
                return
            } catch {
                guard self.isWindowActive else { return }
                self.contextLoadStates[context.id] = .failed(error.localizedDescription)
            }
        }
    }

    private func handleSidebarFilterChange() {
        guard isWindowActive, trimmedSidebarFilterText.isEmpty == false else { return }

        for context in browserContexts {
            loadNamespaces(for: context)
        }
    }

    private func handleNamespaceEditModeChange() {
        guard isWindowActive, isNamespaceEditMode else { return }

        for context in displayedBrowserContexts {
            loadNamespaces(for: context)
        }
    }

    private func startFetch(clearExistingData: Bool) {
        guard isWindowActive, let selectedTarget else { return }

        fetchTask?.cancel()
        currentFetchID = UUID()
        let fetchID = currentFetchID

        if clearExistingData {
            loadedResources = .none
        }

        isLoading = true
        errorMessage = nil

        fetchTask = Task { [weak self] in
            await self?.performFetch(target: selectedTarget, fetchID: fetchID)
        }
    }

    private func performFetch(target: BrowserTarget, fetchID: UUID) async {
        do {
            let resources = try await loadResources(target: target)
            guard currentFetchID == fetchID, isWindowActive else { return }

            loadedResources = resources
            hasLoadedAtLeastOnce = true
            isLoading = false
            errorMessage = nil
            reconcileSelectionWithVisibleResources()

            if case .failed = contextLoadStates[target.context.id] {
                contextLoadStates[target.context.id] = .idle
            }
        } catch is CancellationError {
            return
        } catch {
            guard currentFetchID == fetchID, isWindowActive else { return }

            hasLoadedAtLeastOnce = true
            isLoading = false
            errorMessage = error.localizedDescription
            loadedResources = .none
            selectedResourceID = nil
            contextLoadStates[target.context.id] = .failed(error.localizedDescription)
        }
    }

    private func loadResources(target: BrowserTarget) async throws -> LoadedResources {
        switch selectedResourceType {
        case .pods:
            return .pods(try await resourceService.fetchPods(target: target))
        case .deployments:
            return .deployments(try await resourceService.fetchDeployments(target: target))
        case .services:
            return .services(try await resourceService.fetchServices(target: target))
        case .configMaps:
            return .configMaps(try await resourceService.fetchConfigMaps(target: target))
        }
    }

    private func clearState() {
        browserContexts = []
        sourceStatuses = []
        contextLoadStates = [:]
        expandedContextIDs = []
        selectedTarget = nil
        loadedResources = .none
        filterText = ""
        sidebarFilterText = ""
        isNamespaceEditMode = false
        selectedResourceID = nil
        errorMessage = nil
        isLoading = false
        isLoadingCatalog = false
        hasLoadedAtLeastOnce = false
        hasLoadedCatalogAtLeastOnce = false
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
