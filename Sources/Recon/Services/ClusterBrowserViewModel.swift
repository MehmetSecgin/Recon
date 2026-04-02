import Foundation

@MainActor
final class ClusterBrowserViewModel: ObservableObject {
    @Published var selectedResourceType: ResourceType = .pods
    @Published var filterText = ""
    @Published var selectedResourceID: String?
    @Published private(set) var loadedResources: LoadedResources = .none
    @Published private(set) var contextDisplay = "\u{2014}"
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
        selectedNamespace.nilIfEmpty ?? "\u{2014}"
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

        return pods.filter { pod in
            matchesFilter([
                pod.name,
                pod.statusText,
                pod.readyText,
                "\(pod.restartCount)"
            ])
        }
    }

    var filteredDeployments: [DeploymentResource] {
        guard case .deployments(let deployments) = loadedResources else {
            return []
        }

        return deployments.filter { deployment in
            matchesFilter([
                deployment.name,
                deployment.readyText,
                "\(deployment.updatedReplicas)",
                "\(deployment.availableReplicas)"
            ])
        }
    }

    var filteredServices: [ServiceResource] {
        guard case .services(let services) = loadedResources else {
            return []
        }

        return services.filter { service in
            matchesFilter([
                service.name,
                service.type,
                service.clusterIP ?? "",
                service.portsText
            ])
        }
    }

    var filteredIngresses: [IngressResource] {
        guard case .ingresses(let ingresses) = loadedResources else {
            return []
        }

        return ingresses.filter { ingress in
            matchesFilter([
                ingress.name,
                ingress.hostsText
            ])
        }
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
        case .ingresses(let ingresses):
            return ingresses.count
        }
    }

    private var currentFilteredRowCount: Int {
        switch selectedResourceType {
        case .pods:
            return filteredPods.count
        case .deployments:
            return filteredDeployments.count
        case .services:
            return filteredServices.count
        case .ingresses:
            return filteredIngresses.count
        }
    }

    private func loadInitialState() async {
        let resolvedMetadata = await targetResolver.resolveTargetMetadata()
        guard isWindowActive else { return }

        currentContext = resolvedMetadata.context
        contextDisplay = resolvedMetadata.context ?? "\u{2014}"
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
        } catch is CancellationError {
            return
        } catch {
            guard currentFetchID == fetchID, isWindowActive else { return }

            hasLoadedAtLeastOnce = true
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func loadResources(resourceType: ResourceType, namespace: String) async throws -> LoadedResources {
        switch resourceType {
        case .pods:
            let pods = try await resourceService.fetchPods(namespace: namespace)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return .pods(pods)
        case .deployments:
            let deployments = try await resourceService.fetchDeployments(namespace: namespace)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return .deployments(deployments)
        case .services:
            let services = try await resourceService.fetchServices(namespace: namespace)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return .services(services)
        case .ingresses:
            let ingresses = try await resourceService.fetchIngresses(namespace: namespace)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return .ingresses(ingresses)
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
        contextDisplay = "\u{2014}"
        namespacePickerOptions = []
        loadedResources = .none
        filterText = ""
        selectedResourceID = nil
        errorMessage = nil
        isLoading = false
        isLoadingNamespacePickerOptions = false
        hasLoadedAtLeastOnce = false
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
}
