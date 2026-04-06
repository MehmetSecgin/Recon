import Foundation

@main
struct ClusterBrowserPhase1Harness {
    static func main() throws {
        try testPodStatusNormalization()
        try testPodHealthClassification()
        try testDeploymentHealthClassification()
        try testDefaultHealthFirstOrdering()
        try testUserSortOverridesAndReset()
        try testSelectionRetention()
        try testInspectCommandGeneration()
        try testKubectlConfigTargetParsing()
        try testKubectlContextCatalogParsing()
        try testKubectlAgeParsing()
        try testKubectlPodTableParsing()
        try testKubectlDeploymentTableParsing()
        try testKubectlServiceTableParsing()
        try testKubectlConfigMapTableParsing()
        try testBrowserContextIdentity()
        try testBrowserNamespaceFallback()
        try testHiddenNamespaceSelectionFallback()
        try testDuplicateContextBadges()
        try testSidebarFiltering()

        print("Cluster browser phase 1 harness passed")
    }

    private static func testPodStatusNormalization() throws {
        try expect(
            PodStatusTextNormalizer.normalize("ErrImagePull") == "ImagePullBackOff",
            "ErrImagePull should normalize to ImagePullBackOff"
        )
        try expect(
            PodStatusTextNormalizer.normalize(" CrashLoopBackOff ") == "CrashLoopBackOff",
            "Known pod status text should trim and normalize"
        )
        try expect(
            PodStatusTextNormalizer.normalize("ContainerCreating") == "ContainerCreating",
            "Unrecognized status text should be preserved"
        )
        try expect(
            PodStatusTextNormalizer.normalize("   ") == "Unknown",
            "Empty status text should fall back to Unknown"
        )
    }

    private static func testPodHealthClassification() throws {
        let crashLoop = makePod(
            name: "crash",
            statusText: "CrashLoopBackOff",
            readyCount: 0,
            totalCount: 1,
            restartCount: 5,
            ageText: "4h"
        )
        let pulling = makePod(
            name: "pull",
            statusText: "ImagePullBackOff",
            readyCount: 0,
            totalCount: 1,
            restartCount: 0,
            ageText: "3h"
        )
        let healthy = makePod(
            name: "ok",
            statusText: "Running",
            readyCount: 2,
            totalCount: 2,
            restartCount: 0,
            ageText: "2h"
        )
        let completed = makePod(
            name: "done",
            statusText: "Completed",
            readyCount: 0,
            totalCount: 0,
            restartCount: 0,
            ageText: "1h"
        )

        try expect(crashLoop.healthBucket == .unhealthy, "CrashLoopBackOff pod should be unhealthy")
        try expect(pulling.healthBucket == .transitional, "Image pull failure should be transitional")
        try expect(healthy.healthBucket == .healthy, "Fully ready running pod should be healthy")
        try expect(completed.healthBucket == .neutral, "Completed pod should be neutral")
        try expect(crashLoop.displayStatusText == "CrashLoopBackOff", "Display status should come from parsed status text")
    }

    private static func testDeploymentHealthClassification() throws {
        let down = makeDeployment(name: "down", ready: 0, desired: 3, updated: 0, available: 0, ageText: "4h")
        let partial = makeDeployment(name: "partial", ready: 1, desired: 3, updated: 2, available: 1, ageText: "3h")
        let healthy = makeDeployment(name: "healthy", ready: 3, desired: 3, updated: 3, available: 3, ageText: "2h")
        let scaledToZero = makeDeployment(name: "zero", ready: 0, desired: 0, updated: 0, available: 0, ageText: "1h")

        try expect(down.healthBucket == .unhealthy, "Zero-available deployment should be unhealthy")
        try expect(partial.healthBucket == .transitional, "Partially ready deployment should be transitional")
        try expect(healthy.healthBucket == .healthy, "Fully available deployment should be healthy")
        try expect(scaledToZero.healthBucket == .neutral, "Scale-to-zero deployment should be neutral")
    }

    private static func testDefaultHealthFirstOrdering() throws {
        let pods = [
            makePod(name: "healthy", statusText: "Running", readyCount: 1, totalCount: 1, restartCount: 0, ageText: "1h"),
            makePod(name: "transitional", statusText: "Pending", readyCount: 0, totalCount: 1, restartCount: 0, ageText: "2h"),
            makePod(name: "unhealthy", statusText: "CrashLoopBackOff", readyCount: 0, totalCount: 1, restartCount: 4, ageText: "3h")
        ]

        let sortedPods = ClusterBrowserSorting.sortPods(pods, using: .defaultHealth)
        try expect(sortedPods.map(\.name) == ["unhealthy", "transitional", "healthy"], "Pods should sort unhealthy first by default")

        let deployments = [
            makeDeployment(name: "healthy", ready: 2, desired: 2, updated: 2, available: 2, ageText: "1h"),
            makeDeployment(name: "partial", ready: 1, desired: 2, updated: 1, available: 1, ageText: "2h"),
            makeDeployment(name: "down", ready: 0, desired: 2, updated: 0, available: 0, ageText: "3h")
        ]

        let sortedDeployments = ClusterBrowserSorting.sortDeployments(deployments, using: .defaultHealth)
        try expect(sortedDeployments.map(\.name) == ["down", "partial", "healthy"], "Deployments should sort health-first by default")
    }

    private static func testUserSortOverridesAndReset() throws {
        let pods = [
            makePod(name: "alpha", statusText: "Running", readyCount: 1, totalCount: 1, restartCount: 0, ageText: "1h"),
            makePod(name: "zeta", statusText: "CrashLoopBackOff", readyCount: 0, totalCount: 1, restartCount: 3, ageText: "2h")
        ]

        let nameDescending = ClusterBrowserSorting.sortPods(pods, using: .name(.descending))
        try expect(nameDescending.map(\.name) == ["zeta", "alpha"], "Name sort should temporarily override health-first ordering")

        let reset = ClusterBrowserSorting.sortPods(pods, using: .defaultHealth)
        try expect(reset.map(\.name) == ["zeta", "alpha"], "Reset should restore health-first ordering")

        let configMaps = [
            makeConfigMap(name: "b", keyCount: 1, ageText: "1h"),
            makeConfigMap(name: "a", keyCount: 4, ageText: "2h")
        ]

        let keyCountDescending = ClusterBrowserSorting.sortConfigMaps(configMaps, using: .keyCount(.descending))
        try expect(keyCountDescending.map(\.name) == ["a", "b"], "Configmaps should support user-selected column sorting")
    }

    private static func testSelectionRetention() throws {
        try expect(
            ClusterBrowserSorting.retainedSelection(
                selectedID: "pod:ns:keep",
                visibleIDs: ["pod:ns:keep", "pod:ns:other"]
            ) == "pod:ns:keep",
            "Selection should remain when the selected row is still visible"
        )
        try expect(
            ClusterBrowserSorting.retainedSelection(
                selectedID: "pod:ns:drop",
                visibleIDs: ["pod:ns:other"]
            ) == nil,
            "Selection should clear when the selected row disappears"
        )
    }

    private static func testInspectCommandGeneration() throws {
        try expect(
            ClusterBrowserInspectCommandBuilder.pod(name: "api", namespace: "prod") == "kubectl get pod api -n prod",
            "Pod inspect command should match expected kubectl form"
        )
        try expect(
            ClusterBrowserInspectCommandBuilder.deployment(name: "api", namespace: "prod") == "kubectl get deployment api -n prod",
            "Deployment inspect command should match expected kubectl form"
        )
        try expect(
            ClusterBrowserInspectCommandBuilder.service(name: "api", namespace: "prod") == "kubectl get service api -n prod",
            "Service inspect command should match expected kubectl form"
        )
        try expect(
            ClusterBrowserInspectCommandBuilder.configMap(name: "app-config", namespace: "prod") == "kubectl get configmap app-config -n prod",
            "Configmap inspect command should match expected kubectl form"
        )
    }

    private static func testKubectlConfigTargetParsing() throws {
        let parsed = KubectlConfigOutputParsing.parseTargetFields(from: "prod-eu1\tpayments\n")
        try expect(parsed.context == "prod-eu1", "Target parsing should preserve current context")
        try expect(parsed.namespace == "payments", "Target parsing should preserve namespace")

        let fallback = KubectlConfigOutputParsing.parseTargetFields(from: "prod-eu1\t\n")
        try expect(fallback.context == "prod-eu1", "Target parsing should keep context when namespace is empty")
        try expect(fallback.namespace == nil, "Empty namespace should decode as nil")
    }

    private static func testKubectlContextCatalogParsing() throws {
        let output = """
        prod-eu1\tpayments
        staging\t
        qa
        """

        let parsed = KubectlConfigOutputParsing.parseContextEntries(from: output)
        try expect(parsed.count == 3, "Three contexts should decode from compact jsonpath output")
        try expect(parsed[0] == .init(name: "prod-eu1", namespace: "payments"), "Explicit namespaces should decode")
        try expect(parsed[1] == .init(name: "staging", namespace: nil), "Empty namespaces should decode as nil")
        try expect(parsed[2] == .init(name: "qa", namespace: nil), "Missing namespace field should decode as nil")
    }

    private static func testKubectlAgeParsing() throws {
        try expect(KubectlAgeParser.sortValue(for: "5m") == -(5 * 60), "Minutes should parse into sortable age values")
        try expect(KubectlAgeParser.sortValue(for: "2h") == -(2 * 60 * 60), "Hours should parse into sortable age values")
        try expect(KubectlAgeParser.sortValue(for: "3d") == -(3 * 60 * 60 * 24), "Days should parse into sortable age values")
        try expect(KubectlAgeParser.sortValue(for: "4w") == -(4 * 60 * 60 * 24 * 7), "Weeks should parse into sortable age values")
        try expect(KubectlAgeParser.sortValue(for: "1y") == -(60 * 60 * 24 * 365), "Years should parse into sortable age values")
    }

    private static func testKubectlPodTableParsing() throws {
        let output = """
        api-7b88c9  1/1  Running           0           5m
        worker-123  0/1  CrashLoopBackOff  3 (2d ago)  2h
        """

        let parsed = try KubectlTableParser.parsePods(from: output, namespace: "prod")
        try expect(parsed.count == 2, "Two pods should parse from kubectl table output")
        try expect(parsed[0].name == "api-7b88c9", "Pod name should parse")
        try expect(parsed[0].readyText == "1/1", "Ready counts should parse")
        try expect(parsed[0].displayStatusText == "Running", "Pod status should parse")
        try expect(parsed[1].restartCount == 3, "Pod restarts should normalize away extra timing text")
        try expect(parsed[1].healthBucket == .unhealthy, "Parsed CrashLoopBackOff pod should be unhealthy")
    }

    private static func testKubectlDeploymentTableParsing() throws {
        let output = """
        api  3/3  3  3  5m
        web  1/3  2  1  2h
        """

        let parsed = try KubectlTableParser.parseDeployments(from: output, namespace: "prod")
        try expect(parsed.count == 2, "Two deployments should parse from kubectl table output")
        try expect(parsed[0].readyText == "3/3", "Deployment ready text should parse")
        try expect(parsed[1].updatedReplicas == 2, "Updated replicas should parse")
        try expect(parsed[1].ageText == "2h", "Deployment age text should be preserved")
    }

    private static func testKubectlServiceTableParsing() throws {
        let output = """
        api  ClusterIP  10.96.0.1  <none>  80/TCP,443/TCP  5m
        web  LoadBalancer  10.96.0.2  34.1.2.3  80:30080/TCP  2h
        """

        let parsed = try KubectlTableParser.parseServices(from: output, namespace: "prod")
        try expect(parsed.count == 2, "Two services should parse from kubectl table output")
        try expect(parsed[0].clusterIP == "10.96.0.1", "Cluster IP should parse")
        try expect(parsed[0].portsText == "80/TCP,443/TCP", "Service ports should preserve kubectl display text")
        try expect(parsed[1].portsText == "80:30080/TCP", "Service parsing should ignore the extra EXTERNAL-IP column")
    }

    private static func testKubectlConfigMapTableParsing() throws {
        let output = """
        app-config  12  5m
        empty-config  0  2h
        """

        let parsed = try KubectlTableParser.parseConfigMaps(from: output, namespace: "prod")
        try expect(parsed.count == 2, "Two configmaps should parse from kubectl table output")
        try expect(parsed[0].dataKeyCount == 12, "Configmap key counts should parse from the DATA column")
        try expect(parsed[1].ageText == "2h", "Configmap age text should be preserved")
    }

    private static func testBrowserContextIdentity() throws {
        let sourcePath = "/Users/test/.kube/config-qa"
        let contextID = BrowserContextIdentity.makeID(contextName: "qa", sourcePath: sourcePath)
        try expect(
            contextID == "/Users/test/.kube/config-qa#qa",
            "Browser context IDs should be source-aware"
        )
    }

    private static func testBrowserNamespaceFallback() throws {
        try expect(
            BrowserNamespaceSelectionResolver.resolve(
                rememberedNamespace: "test",
                defaultNamespace: "default"
            ) == "test",
            "Remembered namespace should win over the kubeconfig default"
        )
        try expect(
            BrowserNamespaceSelectionResolver.resolve(
                rememberedNamespace: nil,
                defaultNamespace: "staging"
            ) == "staging",
            "Default namespace should be used when no remembered namespace exists"
        )
        try expect(
            BrowserNamespaceSelectionResolver.resolve(
                rememberedNamespace: nil,
                defaultNamespace: nil
            ) == "default",
            "Default fallback should be `default` when neither value exists"
        )
    }

    private static func testHiddenNamespaceSelectionFallback() throws {
        try expect(
            BrowserVisibleNamespaceResolver.resolve(
                currentNamespace: "develop",
                defaultNamespace: "default",
                recentNamespaces: ["develop", "payments"],
                availableNamespaces: ["develop", "payments", "default"],
                hiddenNamespaces: ["develop"]
            ) == "default",
            "Hidden remembered namespaces should fall back to the default namespace when visible"
        )
        try expect(
            BrowserVisibleNamespaceResolver.resolve(
                currentNamespace: "develop",
                defaultNamespace: "default",
                recentNamespaces: ["develop", "payments"],
                availableNamespaces: ["develop", "payments", "default"],
                hiddenNamespaces: ["develop", "default"]
            ) == "payments",
            "Fallback should continue to recent or available visible namespaces when default is also hidden"
        )
        try expect(
            BrowserVisibleNamespaceResolver.resolve(
                currentNamespace: "develop",
                defaultNamespace: "default",
                recentNamespaces: ["develop"],
                availableNamespaces: ["develop"],
                hiddenNamespaces: ["develop", "default"]
            ) == "develop",
            "If every known namespace is hidden, the current namespace should remain selected"
        )
    }

    private static func testDuplicateContextBadges() throws {
        let qaA = BrowserContextDescriptor(
            id: BrowserContextIdentity.makeID(contextName: "qa", sourcePath: "/tmp/a.yaml"),
            name: "qa",
            sourcePath: "/tmp/a.yaml",
            sourceBadge: "a.yaml",
            defaultNamespace: "default",
            isProductionLike: false
        )
        let qaB = BrowserContextDescriptor(
            id: BrowserContextIdentity.makeID(contextName: "qa", sourcePath: "/tmp/b.yaml"),
            name: "qa",
            sourcePath: "/tmp/b.yaml",
            sourceBadge: "b.yaml",
            defaultNamespace: "default",
            isProductionLike: false
        )
        let stg = BrowserContextDescriptor(
            id: BrowserContextIdentity.makeID(contextName: "stg", sourcePath: "/tmp/a.yaml"),
            name: "stg",
            sourcePath: "/tmp/a.yaml",
            sourceBadge: nil,
            defaultNamespace: "default",
            isProductionLike: false
        )

        try expect(qaA.sourceBadge != nil && qaB.sourceBadge != nil, "Duplicate context names should carry source badges")
        try expect(stg.sourceBadge == nil, "Unique context names should not need source badges")
    }

    private static func testSidebarFiltering() throws {
        let context = BrowserContextDescriptor(
            id: BrowserContextIdentity.makeID(contextName: "qa", sourcePath: "/tmp/qa.yaml"),
            name: "qa",
            sourcePath: "/tmp/qa.yaml",
            sourceBadge: nil,
            defaultNamespace: "default",
            isProductionLike: false
        )

        try expect(
            BrowserSidebarFiltering.matchesContext(
                context,
                loadState: .loadedNamespaces(["default", "payments", "test"]),
                query: "pay"
            ),
            "Namespace matches should keep the context visible while filtering"
        )
        try expect(
            BrowserSidebarFiltering.filteredNamespaces(
                from: ["default", "payments", "test"],
                query: "te"
            ) == ["test"],
            "Namespace filtering should only keep matching namespaces"
        )
        try expect(
            BrowserSidebarFiltering.matchesContext(
                context,
                loadState: .loadedNamespaces(["default"]),
                query: "stg"
            ) == false,
            "Contexts with no context-name, source, or namespace match should be filtered out"
        )
    }

    private static func makePod(
        name: String,
        statusText: String,
        readyCount: Int,
        totalCount: Int,
        restartCount: Int,
        ageText: String
    ) -> PodResource {
        PodResource(
            id: "pod:ns:\(name)",
            name: name,
            namespace: "ns",
            statusText: statusText,
            readyCount: readyCount,
            totalCount: totalCount,
            restartCount: restartCount,
            ageText: ageText,
            ageSortValue: KubectlAgeParser.sortValue(for: ageText)
        )
    }

    private static func makeDeployment(
        name: String,
        ready: Int,
        desired: Int,
        updated: Int,
        available: Int,
        ageText: String
    ) -> DeploymentResource {
        DeploymentResource(
            id: "deployment:ns:\(name)",
            name: name,
            namespace: "ns",
            readyReplicas: ready,
            desiredReplicas: desired,
            updatedReplicas: updated,
            availableReplicas: available,
            ageText: ageText,
            ageSortValue: KubectlAgeParser.sortValue(for: ageText)
        )
    }

    private static func makeConfigMap(name: String, keyCount: Int, ageText: String) -> ConfigMapResource {
        ConfigMapResource(
            id: "configmap:ns:\(name)",
            name: name,
            namespace: "ns",
            dataKeyCount: keyCount,
            ageText: ageText,
            ageSortValue: KubectlAgeParser.sortValue(for: ageText)
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if condition() == false {
            throw HarnessError(message: message)
        }
    }
}

private struct HarnessError: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}
