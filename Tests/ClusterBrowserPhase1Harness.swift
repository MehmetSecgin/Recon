import Foundation

@main
struct ClusterBrowserPhase1Harness {
    static func main() throws {
        try testStatusReasonDerivation()
        try testPodHealthClassification()
        try testDeploymentHealthClassification()
        try testDefaultHealthFirstOrdering()
        try testUserSortOverridesAndReset()
        try testSelectionRetention()
        try testInspectCommandGeneration()
        try testConfigMapDecoding()
        try testBrowserContextIdentity()
        try testBrowserNamespaceFallback()
        try testDuplicateContextBadges()
        try testSidebarFiltering()

        print("Cluster browser phase 1 harness passed")
    }

    private static func testStatusReasonDerivation() throws {
        try expect(
            PodStatusReasonDeriver.derive(from: ["ImagePullBackOff", "CrashLoopBackOff"]) == "CrashLoopBackOff",
            "CrashLoopBackOff should win over lower-severity reasons"
        )
        try expect(
            PodStatusReasonDeriver.derive(from: ["ErrImagePull"]) == "ImagePullBackOff",
            "ErrImagePull should normalize to ImagePullBackOff"
        )
        try expect(
            PodStatusReasonDeriver.derive(from: ["CreateContainerConfigError"]) == "CreateContainerConfigError",
            "CreateContainerConfigError should be preserved"
        )
        try expect(
            PodStatusReasonDeriver.derive(from: [nil, "ContainerCreating"]) == "ContainerCreating",
            "Unknown waiting reasons should pass through"
        )
        try expect(
            PodStatusReasonDeriver.derive(from: [nil, "   "]) == nil,
            "Empty waiting reasons should produce nil"
        )
    }

    private static func testPodHealthClassification() throws {
        let crashLoop = PodResource(
            id: "pod:ns:crash",
            name: "crash",
            namespace: "ns",
            phase: .running,
            statusReason: "CrashLoopBackOff",
            readyCount: 0,
            totalCount: 1,
            restartCount: 5,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let pulling = PodResource(
            id: "pod:ns:pull",
            name: "pull",
            namespace: "ns",
            phase: .pending,
            statusReason: "ImagePullBackOff",
            readyCount: 0,
            totalCount: 1,
            restartCount: 0,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let healthy = PodResource(
            id: "pod:ns:ok",
            name: "ok",
            namespace: "ns",
            phase: .running,
            statusReason: nil,
            readyCount: 2,
            totalCount: 2,
            restartCount: 0,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let completed = PodResource(
            id: "pod:ns:done",
            name: "done",
            namespace: "ns",
            phase: .succeeded,
            statusReason: nil,
            readyCount: 0,
            totalCount: 0,
            restartCount: 0,
            createdAt: Date(timeIntervalSince1970: 400)
        )

        try expect(crashLoop.healthBucket == .unhealthy, "CrashLoopBackOff pod should be unhealthy")
        try expect(pulling.healthBucket == .transitional, "Image pull failure should be transitional")
        try expect(healthy.healthBucket == .healthy, "Fully ready running pod should be healthy")
        try expect(completed.healthBucket == .neutral, "Succeeded pod should be neutral")
        try expect(crashLoop.displayStatusText == "CrashLoopBackOff", "Display status should prefer status reason")
    }

    private static func testDeploymentHealthClassification() throws {
        let down = DeploymentResource(
            id: "deployment:ns:down",
            name: "down",
            namespace: "ns",
            readyReplicas: 0,
            desiredReplicas: 3,
            updatedReplicas: 0,
            availableReplicas: 0,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let partial = DeploymentResource(
            id: "deployment:ns:partial",
            name: "partial",
            namespace: "ns",
            readyReplicas: 1,
            desiredReplicas: 3,
            updatedReplicas: 2,
            availableReplicas: 1,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let healthy = DeploymentResource(
            id: "deployment:ns:healthy",
            name: "healthy",
            namespace: "ns",
            readyReplicas: 3,
            desiredReplicas: 3,
            updatedReplicas: 3,
            availableReplicas: 3,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let scaledToZero = DeploymentResource(
            id: "deployment:ns:zero",
            name: "zero",
            namespace: "ns",
            readyReplicas: 0,
            desiredReplicas: 0,
            updatedReplicas: 0,
            availableReplicas: 0,
            createdAt: Date(timeIntervalSince1970: 400)
        )

        try expect(down.healthBucket == .unhealthy, "Zero-available deployment should be unhealthy")
        try expect(partial.healthBucket == .transitional, "Partially ready deployment should be transitional")
        try expect(healthy.healthBucket == .healthy, "Fully available deployment should be healthy")
        try expect(scaledToZero.healthBucket == .neutral, "Scale-to-zero deployment should be neutral")
    }

    private static func testDefaultHealthFirstOrdering() throws {
        let pods = [
            PodResource(
                id: "pod:ns:healthy",
                name: "healthy",
                namespace: "ns",
                phase: .running,
                statusReason: nil,
                readyCount: 1,
                totalCount: 1,
                restartCount: 0,
                createdAt: Date(timeIntervalSince1970: 300)
            ),
            PodResource(
                id: "pod:ns:transitional",
                name: "transitional",
                namespace: "ns",
                phase: .pending,
                statusReason: nil,
                readyCount: 0,
                totalCount: 1,
                restartCount: 0,
                createdAt: Date(timeIntervalSince1970: 200)
            ),
            PodResource(
                id: "pod:ns:unhealthy",
                name: "unhealthy",
                namespace: "ns",
                phase: .running,
                statusReason: "CrashLoopBackOff",
                readyCount: 0,
                totalCount: 1,
                restartCount: 4,
                createdAt: Date(timeIntervalSince1970: 100)
            )
        ]

        let sortedPods = ClusterBrowserSorting.sortPods(pods, using: .defaultHealth)
        try expect(sortedPods.map(\.name) == ["unhealthy", "transitional", "healthy"], "Pods should sort unhealthy first by default")

        let deployments = [
            DeploymentResource(
                id: "deployment:ns:healthy",
                name: "healthy",
                namespace: "ns",
                readyReplicas: 2,
                desiredReplicas: 2,
                updatedReplicas: 2,
                availableReplicas: 2,
                createdAt: Date(timeIntervalSince1970: 300)
            ),
            DeploymentResource(
                id: "deployment:ns:partial",
                name: "partial",
                namespace: "ns",
                readyReplicas: 1,
                desiredReplicas: 2,
                updatedReplicas: 1,
                availableReplicas: 1,
                createdAt: Date(timeIntervalSince1970: 200)
            ),
            DeploymentResource(
                id: "deployment:ns:down",
                name: "down",
                namespace: "ns",
                readyReplicas: 0,
                desiredReplicas: 2,
                updatedReplicas: 0,
                availableReplicas: 0,
                createdAt: Date(timeIntervalSince1970: 100)
            )
        ]

        let sortedDeployments = ClusterBrowserSorting.sortDeployments(deployments, using: .defaultHealth)
        try expect(sortedDeployments.map(\.name) == ["down", "partial", "healthy"], "Deployments should sort health-first by default")
    }

    private static func testUserSortOverridesAndReset() throws {
        let pods = [
            PodResource(
                id: "pod:ns:alpha",
                name: "alpha",
                namespace: "ns",
                phase: .running,
                statusReason: nil,
                readyCount: 1,
                totalCount: 1,
                restartCount: 0,
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            PodResource(
                id: "pod:ns:zeta",
                name: "zeta",
                namespace: "ns",
                phase: .running,
                statusReason: "CrashLoopBackOff",
                readyCount: 0,
                totalCount: 1,
                restartCount: 3,
                createdAt: Date(timeIntervalSince1970: 200)
            )
        ]

        let nameDescending = ClusterBrowserSorting.sortPods(pods, using: .name(.descending))
        try expect(nameDescending.map(\.name) == ["zeta", "alpha"], "Name sort should temporarily override health-first ordering")

        let reset = ClusterBrowserSorting.sortPods(pods, using: .defaultHealth)
        try expect(reset.map(\.name) == ["zeta", "alpha"], "Reset should restore health-first ordering")

        let configMaps = [
            ConfigMapResource(
                id: "configmap:ns:b",
                name: "b",
                namespace: "ns",
                dataKeyCount: 1,
                isImmutable: false,
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            ConfigMapResource(
                id: "configmap:ns:a",
                name: "a",
                namespace: "ns",
                dataKeyCount: 4,
                isImmutable: true,
                createdAt: Date(timeIntervalSince1970: 200)
            )
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

    private static func testConfigMapDecoding() throws {
        let rawJSON = """
        {
          "items": [
            {
              "metadata": {
                "name": "app-config",
                "creationTimestamp": "2024-01-01T10:00:00Z"
              },
              "data": {
                "A": "1",
                "B": "2"
              },
              "immutable": true
            },
            {
              "metadata": {
                "name": "empty-config",
                "namespace": "override-ns",
                "creationTimestamp": "2024-01-02T10:00:00.123Z"
              }
            }
          ]
        }
        """

        let decoded = try ConfigMapResourceDecoder.decode(from: Data(rawJSON.utf8), defaultNamespace: "fallback-ns")
        try expect(decoded.count == 2, "Two configmaps should decode")
        try expect(decoded[0].namespace == "fallback-ns", "Missing namespace should fall back to requested namespace")
        try expect(decoded[0].dataKeyCount == 2, "Configmap key count should reflect decoded data keys")
        try expect(decoded[0].isImmutable == true, "Configmap immutable flag should decode")
        try expect(decoded[1].namespace == "override-ns", "Explicit namespace should be preserved")
        try expect(decoded[1].dataKeyCount == 0, "Missing data should decode as zero keys")
        try expect(decoded[1].isImmutable == false, "Missing immutable flag should default to false")
        try expect(decoded[1].createdAt != nil, "Fractional-second timestamps should decode")
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
