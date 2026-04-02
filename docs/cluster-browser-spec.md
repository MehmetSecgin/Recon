# Cluster Browser — Spec

Companion documents:
- [Cluster Browser — Product Brief](./cluster-browser-product-brief.md) for positioning, target users, product principles, and V1/V2 scope
- [Cluster Browser — Implementation Plan](./cluster-browser-implementation-plan.md) for engineering phases, sequencing, and delivery milestones

## Problem

People use OpenLens or raw terminal commands to see what's running in their Kubernetes clusters. OpenLens is Electron-based, slow to launch, and heavy on memory (400-800 MB idle). Terminal commands are fast but require memorizing kubectl flags and manually parsing output. There's no fast, native, always-available way to glance at cluster resources.

## Goal

Add a cluster resource browser to Recon that gives users instant visibility into their Kubernetes workloads. It should feel as fast as the terminal, look better than `kubectl get pods`, and use near-zero memory when closed.

No logs viewer. No YAML editor. No exec. A fast resource browser with targeted actions: delete, restart, scale, and port forwarding. This feature should be a great helper for simple Kubernetes flows, not a full dashboard replacement.

## Design Principles

1. **Open-n-close** — Fetch data when the window opens, release everything when it closes. No background watchers, no persistent caches, no retained resource lists.
2. **Shell out, don't embed** — Every query is a `kubectl` process that starts, returns JSON, and exits. No embedded Kubernetes client library, no lingering HTTP connections.
3. **Value types** — Resource models are Swift structs. Stack-allocated where possible, deterministic deallocation via ARC. No object graphs, no retain cycles.
4. **Native table rendering** — Use SwiftUI `Table` for the resource browser so column headers, selection, and sort indicators feel native on macOS. Filtering and sorting happen before data is passed into the table.
5. **No speculative work** — Don't pre-fetch resource types the user hasn't asked for. Don't poll in the background. Don't cache across window sessions.
6. **Trust through transparency** — Every action can reveal or copy the exact `kubectl` command Recon would run.

## Memory Budget

| State | Target |
|---|---|
| Menu bar idle (no browser open) | 0 MB additional (no cluster data retained) |
| Browser open, resource list loaded | 5-15 MB (depending on resource count) |
| Browser closed | Immediate return to idle baseline |

## Scope

### In scope

- List resources: Pods, Deployments, Services, Ingresses
- Status indicators per resource (phase, ready count, health color)
- Unhealthy-first sorting within the loaded resource list
- Filter/search across the loaded resource list
- Namespace picker (reuse existing `NamespaceDiscoveryService`)
- Context display (reuse existing `KubeTargetResolver`)
- Relationship hints between resources for the same workload (lightweight, read-only)
- Manual refresh (pull fresh data on demand)
- Pod actions: delete (with confirmation), port forward
- Deployment actions: scale replicas, restart (rollout restart)
- Service actions: port forward
- Port forward management: start, stop, see active forwards
- Copy the equivalent `kubectl` command for selections and actions
- Keyboard navigation: arrow keys, type-to-filter, keyboard shortcuts for actions

### Out of scope (future phases)

- Streaming logs
- kubectl exec / shell
- YAML viewing or editing
- Resource creation or patching
- Node or cluster-level resources
- CRDs or Helm releases
- Full dependency graph or topology map
- Background polling or file watching
- Notifications for resource state changes

## Architecture

### How it fits into Recon

The cluster browser follows the same patterns as the existing Diagnostics and Preferences windows:

```
ReconApp.swift
├── MenuBarExtra (existing)
├── Window("Preferences")  (existing)
├── Window("Diagnostics")  (existing)
└── Window("Cluster")      (new)
```

A new `ClusterBrowserViewModel` (like `DiagnosticsViewModel`) owns the state. A `ClusterBrowserWindowPresenter` (like `DiagnosticsWindowPresenter`) manages window lifecycle. A `ClusterBrowserWindowView` renders the UI.

### New files

```
Sources/Recon/
├── Models/
│   ├── ClusterResource.swift        # Resource type enum, shared identities, relationship hint types
│   ├── PodResource.swift            # Pod-specific model
│   ├── DeploymentResource.swift     # Deployment-specific model
│   ├── ServiceResource.swift        # Service-specific model
│   ├── IngressResource.swift        # Ingress-specific model
│   └── PortForwardEntry.swift       # Active port forward tracking
├── Services/
│   ├── ClusterBrowserViewModel.swift
│   ├── ClusterBrowserWindowPresenter.swift
│   ├── KubeResourceService.swift    # Actor that shells out to kubectl
│   └── PortForwardManager.swift     # Manages long-running kubectl port-forward processes
└── Views/
    └── ClusterBrowserWindowView.swift
```

### KubeResourceService

A new actor that fetches resources by shelling out to `kubectl`. Follows the same pattern as `NamespaceDiscoveryService`.

```swift
actor KubeResourceService {
    // Read
    func fetchPods(namespace:)        async -> Result<[PodResource], ResourceFetchError>
    func fetchDeployments(namespace:) async -> Result<[DeploymentResource], ResourceFetchError>
    func fetchServices(namespace:)    async -> Result<[ServiceResource], ResourceFetchError>
    func fetchIngresses(namespace:)   async -> Result<[IngressResource], ResourceFetchError>
    func fetchRelationshipHints(for: ClusterResourceIdentity, namespace:) async -> Result<[RelatedResourceHint], ResourceFetchError>

    // Pod actions
    func deletePod(name:namespace:)   async -> Result<Void, ResourceFetchError>

    // Deployment actions
    func scaleDeployment(name:namespace:replicas:) async -> Result<Void, ResourceFetchError>
    func restartDeployment(name:namespace:)        async -> Result<Void, ResourceFetchError>

    // RBAC
    func checkPermissions(namespace:) async -> NamespacePermissions
}
```

Each method:
1. Resolves the `kubectl` executable via `CommandEnvironmentResolver`
2. Runs `kubectl get <resource> -n <namespace> -o json` with a 5-second timeout
3. Decodes the JSON items array into the corresponding Swift model
4. Returns the result — no caching, no side effects

### Resource Models

Minimal structs that decode only the fields we display. No full Kubernetes API object graphs.

```swift
struct PodResource: Identifiable {
    let id: String            // metadata.uid
    let name: String          // metadata.name
    let namespace: String     // metadata.namespace
    let phase: PodPhase       // status.phase → enum
    let statusReason: String? // derived from container statuses (see below)
    let readyCount: Int       // count of ready containers
    let totalCount: Int       // total containers
    let restarts: Int         // sum of container restart counts
    let createdAt: Date       // metadata.creationTimestamp
    let nodeName: String?     // spec.nodeName
    let ownerReference: OwnerReferenceSummary? // deployment/replicaset/statefulset/etc.
    let containerPorts: [ContainerPort]  // all declared container ports (for port forward pre-fill)
}

/// `statusReason` is derived from `status.containerStatuses[].state`:
///
/// CrashLoopBackOff is NOT a pod phase — it's a container waiting reason.
/// A pod can be phase=Running but have a container in CrashLoopBackOff.
/// Similarly, ImagePullBackOff, ErrImagePull, etc. are container-level.
///
/// Derivation logic at decode time:
/// 1. Scan all `status.containerStatuses[].state.waiting.reason`
/// 2. If any container is waiting with a recognized reason, capture it:
///    - "CrashLoopBackOff" → statusReason = "CrashLoopBackOff"
///    - "ImagePullBackOff" / "ErrImagePull" → statusReason = "ImagePullBackOff"
///    - "CreateContainerConfigError" → statusReason = same
/// 3. If multiple containers have different reasons, pick the most severe
///    (CrashLoopBackOff > ImagePullBackOff > other)
/// 4. If no containers are in a waiting state with a recognized reason, statusReason = nil
///
/// This gives the UI a reliable signal for status coloring and display text
/// without resorting to unreliable heuristics like "high restart count".

struct ContainerPort {
    let name: String?
    let containerPort: UInt16
    let protocol: String      // TCP, UDP
}

enum PodPhase: String, Decodable {
    case running = "Running"
    case pending = "Pending"
    case succeeded = "Succeeded"
    case failed = "Failed"
    case unknown = "Unknown"
}

struct DeploymentResource: Identifiable {
    let id: String
    let name: String
    let namespace: String
    let readyReplicas: Int
    let desiredReplicas: Int
    let updatedReplicas: Int
    let availableReplicas: Int
    let selector: [String: String]   // spec.selector.matchLabels
    let createdAt: Date
}

struct ServiceResource: Identifiable {
    let id: String
    let name: String
    let namespace: String
    let type: String          // ClusterIP, NodePort, LoadBalancer
    let clusterIP: String?
    let externalIP: String?
    let selector: [String: String]   // spec.selector, empty if not selector-backed
    let ports: [ServicePort]
    let createdAt: Date
}

struct ServicePort {
    let name: String?
    let port: UInt16              // service port
    let targetPort: IntOrString   // container port — can be numeric (8080) or named ("http")
    let protocol: String          // TCP, UDP
}

/// Kubernetes uses IntOrString for fields like targetPort that accept either a port number
/// or a named port reference. This needs a custom Decodable implementation that tries
/// Int first, then String.
enum IntOrString: Equatable {
    case int(UInt16)
    case string(String)

    /// The numeric value if available, nil for named ports.
    /// Port forward UI uses this to pre-fill; named ports show the name and require
    /// the user to enter a numeric local port.
    var numericValue: UInt16? {
        switch self {
        case .int(let v): return v
        case .string: return nil
        }
    }

    var displayValue: String {
        switch self {
        case .int(let v): return "\(v)"
        case .string(let s): return s
        }
    }
}

struct IngressResource: Identifiable {
    let id: String
    let name: String
    let namespace: String
    let hosts: [String]
    let backendServices: [String]    // service names referenced by backend rules
    let createdAt: Date
}

struct OwnerReferenceSummary {
    let kind: String
    let name: String
}

struct ClusterResourceIdentity {
    let type: ResourceType
    let name: String
}

struct RelatedResourceHint: Identifiable {
    let id: String                   // stable: "<type>:<name>"
    let title: String                // e.g. "api-server pods"
    let resourceType: ResourceType
    let resourceNames: [String]
    let suggestedFilterText: String  // applied when user jumps to the target tab
}
```

### Relationship Hints

V1 includes **lightweight relationship hints**, not a full graph.

When the user selects a row, the browser resolves a small set of related resources in the same namespace and shows them as clickable hints:

- **Pod** → owner workload (if present), matching services
- **Deployment** → matching pods, matching services
- **Service** → selected backing pods, likely workload name when obvious
- **Ingress** → backend services

Clicking a hint switches to the corresponding tab and applies a transient filter such as the related resource name or shared workload name. This keeps the browser in "simple helper" territory: quick navigation, not topology visualization.

Hints are resolved **on selection only**. No relationship data is fetched in the background, and nothing is cached across window sessions.

**Selection-change behavior:**

- Relationship hint resolution is debounced by ~200 ms after selection change.
- Any in-flight hint fetch is canceled when selection changes again.
- Arrow-key traversal should feel cheap; scrolling through rows must not leave a trail of overlapping `kubectl` processes behind.

**Navigation semantics:**

- Relationship hints are **best-effort pointers**, not guaranteed cross-references.
- Clicking a hint switches tabs and applies a transient filter, but the destination tab still performs its normal fresh fetch.
- If the hinted resource no longer exists by the time the destination tab loads, the filtered result may be empty. That is expected and not treated as an error.

### RBAC-Aware Actions

Not every user has the same permissions in every cluster and namespace. A read-only engineer shouldn't see a "Delete Pod" button that will just 403. We handle this with a two-layer approach: **check upfront, handle at execution**.

#### Permission Model

```swift
struct NamespacePermissions {
    let canDeletePods: Bool
    let canCreatePodPortForward: Bool
    let canUpdateDeploymentScale: Bool
    let canPatchDeployments: Bool        // needed for rollout restart
    let canGetServices: Bool             // needed to resolve service → pod for port-forward
    let checkedAt: Date
}
```

Permissions are scoped to a namespace. When the user switches namespace, permissions are re-checked. When the window closes, permissions are released with everything else.

#### Upfront Check: `kubectl auth can-i`

When the browser loads resources for a namespace (on window open, namespace switch, or tab switch), the view model fires permission checks **in parallel** with the resource fetch:

```
kubectl auth can-i delete pods -n <ns>
kubectl auth can-i create pods/portforward -n <ns>
kubectl auth can-i update deployments/scale -n <ns>
kubectl auth can-i patch deployments -n <ns>
kubectl auth can-i get services -n <ns>
```

Each returns `yes` or `no` with exit code 0 or 1. They're fast (~50ms each) and run concurrently, so the total wall time is ~50-100ms — well within the time it takes to fetch the resource list itself.

The results are stored in a `NamespacePermissions` struct on the view model. This is checked before rendering action buttons and context menu items.

| Check | Command | Controls |
|---|---|---|
| Delete pods | `kubectl auth can-i delete pods -n <ns>` | Delete Pod action |
| Port forward pods | `kubectl auth can-i create pods/portforward -n <ns>` | Port Forward on pods |
| Scale deployments | `kubectl auth can-i update deployments/scale -n <ns>` | Scale action |
| Restart deployments | `kubectl auth can-i patch deployments -n <ns>` | Restart action |
| Get services | `kubectl auth can-i get services -n <ns>` | Port Forward on services (see note) |

**Note on service port-forward permissions:** There is no `services/portforward` subresource in the Kubernetes API. When kubectl port-forwards a service, it resolves the service to a backing pod (via label selector), then calls `pods/{name}/portforward` on that pod. This means service port-forwarding requires: (1) permission to read the service (`get services`), and (2) permission to create pod port-forwards (`create pods/portforward`). The "Port Forward" action on services is shown when **both** `canGetServices` and `canCreatePodPortForward` are true.

#### UI Behavior

- **Permitted actions** — shown normally in context menu and respond to keyboard shortcuts
- **Denied actions** — hidden from the context menu entirely. Keyboard shortcuts for denied actions do nothing. This keeps the UI clean rather than showing a wall of grayed-out items. If *all* actions for a resource type are denied, the context menu simply doesn't appear for that type
- **Permission check failed** (e.g., cluster unreachable during `can-i`) — treat as permitted. We'd rather show a button that fails with a clear error than hide functionality because of a transient issue. The execution-time error handling catches this case

#### Execution-Time Fallback

Even when `can-i` said `yes`, the action can still fail at execution time:

- RBAC policies changed between the check and the action
- Admission webhooks reject the request beyond RBAC
- OPA/Gatekeeper or Kyverno policies deny the operation
- Resource-specific constraints (e.g., PDB preventing pod deletion)

When `kubectl` returns a `403 Forbidden` or similar authorization error at execution time, the error is shown inline: "Permission denied: you don't have access to delete pods in namespace `<ns>`." The resource list is not refreshed (nothing changed). The view model updates `NamespacePermissions` to reflect the newly-known denial, so the action is hidden going forward for this session.

#### Lifecycle

```
Window opens / namespace switches
  → fetchResources() and checkPermissions() fire in parallel
  → Resources render as soon as they arrive
  → Permissions arrive shortly after (or simultaneously) → action buttons appear/hide
  → If permissions arrive after resources, action availability updates reactively

Window closes
  → NamespacePermissions released with everything else

Action executed but gets 403
  → Show inline error
  → Update NamespacePermissions for this session
  → Action hidden from context menu going forward
```

### ClusterBrowserViewModel

`@MainActor` `ObservableObject`, same pattern as `DiagnosticsViewModel`.

**State:**
- `selectedResourceType: ResourceType` — which tab is active (Pods, Deployments, Services, Ingresses)
- `loadedResources: LoadedResources` — typed resource data for the active tab (see below)
- `selectedResourceID: String?` — selected row for keyboard actions and relationship hints
- `permissions: NamespacePermissions?` — resolved permissions for the current namespace. `nil` while checking
- `filterText: String` — user's search/filter input
- `relationshipHints: [RelatedResourceHint]` — lightweight same-namespace jumps for the selected resource
- `isLoading: Bool` — whether a fetch is in progress
- `isLoadingRelationshipHints: Bool` — whether related resources are being resolved for the current selection
- `errorMessage: String?` — last fetch error, cleared on success
- `selectedNamespace: String` — active namespace (initialized from controller's current namespace)

**Lifecycle:**
- `activateWindow()` — called from `onAppear`. Triggers initial resource fetch **and** permission check in parallel for the current namespace.
- `deactivateWindow()` — called from `onDisappear`. Cancels any in-flight fetch task. Sets all resource arrays to empty. Clears filter text, error state, selected row, relationship hints, and permissions. After this call, the view model holds no cluster data.
- `refresh()` — re-fetches the current resource type in the current namespace. Does **not** re-check permissions (they don't change often enough to warrant re-checking on every refresh).
- `selectResourceType(_:)` — switches tab, triggers fetch for new type, clears previous results. Permissions are per-namespace so they carry over across tabs.
- `selectNamespace(_:)` — switches namespace, triggers fresh resource fetch **and** fresh permission check (permissions are namespace-scoped).
- `selectResource(_:)` — updates selection and schedules on-demand relationship hint resolution for that row after a short debounce. Cancels any in-flight hint fetch for the previous selection.
- `copyKubectlCommand(for:)` — copies the generated inspect/action command to the pasteboard without executing it.

**Typed resource state:**

Rather than erasing to `[any Identifiable]`, the view model uses a discriminated enum so each tab's view can pattern-match into the typed array with full access to resource-specific fields, columns, and actions:

```swift
enum LoadedResources {
    case pods([PodResource])
    case deployments([DeploymentResource])
    case services([ServiceResource])
    case ingresses([IngressResource])
    case none
}
```

The view switches on this enum to render the correct columns and context menus per resource type. No type erasure, no casting.

**Default ordering:**

For resource types with a meaningful health signal, rows are sorted **unhealthy first**, then transitional, then healthy/neutral, then by name. Search/filter is applied first, then the remaining rows are ordered by health priority.

- **Pods** — use status reason / phase / readiness to compute priority
- **Deployments** — use readiness / availability to compute priority
- **Services** — no health signal in V1, so sort by name only
- **Ingresses** — no health signal in V1, so sort by name only

This is a V1 product requirement, not an optional enhancement. The default browser state should help the user answer "what needs attention?" before "what exists?".

**No retained data between sessions.** When the window closes, `deactivateWindow()` wipes everything.

### ClusterBrowserWindowView

Fixed window size, wider than Diagnostics to support a true columnar resource table. Target default size: ~720x520.

**Layout:**

```
┌─────────────────────────────────────────────────┐
│  Pods   Deployments   Services   Ingresses      │  ← tab bar (capsule style, same as Diagnostics)
├─────────────────────────────────────────────────┤
│  [🔍 Filter...]            [↻ Refresh]  ns: ▾  │  ← toolbar: search, refresh button, namespace picker
├─────────────────────────────────────────────────┤
│  NAME          STATUS    READY   RESTARTS  AGE  │  ← clickable table column headers
│  cron-job-x    Pending   0/1     0         2m   │  ← unhealthy/transitional rows sort first
│  worker-abc    Running   1/1     4         1d   │
│  api-server    Running   2/2     0         3d   │
│  ...                                            │  ← native SwiftUI Table rows
│  Related: [auth-service] [api pods]             │  ← lightweight relationship hints for selected row
│                                                 │
├─────────────────────────────────────────────────┤
│  42 pods                   ctx: prod-eu1   ns ▸ │  ← status bar: count + current context
└─────────────────────────────────────────────────┘
```

**Columns per resource type:**

| Resource | Columns |
|---|---|
| Pods | Name, Status, Ready (n/m), Restarts, Age |
| Deployments | Name, Ready (n/m), Up-to-date, Available, Age |
| Services | Name, Type, Cluster IP, Ports, Age |
| Ingresses | Name, Hosts, Age |

**Table behavior:**

- Use SwiftUI `Table`, not `List`, for the main resource browser.
- Column headers are clickable where V1 sorting makes sense (for example Name or Age).
- The browser opens in the default V1 ordering described below; user-selected column sorting is a temporary override for the active tab/session.
- Choosing the Status column (or equivalent health-oriented sort control) restores the default health-first ordering for resource types that support it.

**Status colors:**
- Green: healthy (Pod phase Running + all containers ready + no statusReason, Deployment fully available)
- Yellow: transitional (Pod Pending, Pod with ImagePullBackOff, Deployment partially ready)
- Red: unhealthy (Pod Failed, Pod with statusReason=CrashLoopBackOff, Deployment zero available)
- Gray: terminal/neutral (Pod Succeeded)

**Pod status display text** shows `statusReason` when present (e.g., "CrashLoopBackOff") instead of the phase. This matches `kubectl get pods` behavior, where the STATUS column shows the most relevant state, not always the phase.

**Relationship hint strip:**

Below the list, the selected row can show a small strip of related-resource chips such as:

- deployment → related pods and services
- pod → owning workload and matching services
- service → backing pods
- ingress → backend services

The strip is intentionally lightweight. It is a navigation aid, not a second inspector pane.

**Keyboard:**
- `Cmd+R` or `R` when list is focused — refresh
- `Cmd+F` or `/` — focus filter field
- Arrow keys — navigate list
- `Cmd+1/2/3/4` — switch resource type tabs
- `Delete` or `Backspace` on selected pod — delete with confirmation
- `Cmd+Shift+R` on selected deployment — restart
- `Cmd+Shift+C` on selected row — copy the inspect `kubectl` command

**V1 shortcut policy:**

- Port forward and scale remain context-menu / sheet actions in V1.
- We intentionally do **not** bind them to `Cmd+P` or `Cmd+S`, which carry strong macOS conventions for Print and Save.
- Context menus and any status/help hinting should only advertise the shortcuts that actually exist in V1.

### Resource Actions

All actions are available via right-click context menu on a resource row. Destructive actions require confirmation.

### Copy Kubectl Command

Every row supports a **Copy kubectl Command** action. This is a core trust and learnability feature, not a debug-only affordance.

For a selected resource, Recon can copy a non-mutating inspect command:

- Pod → `kubectl get pod <name> -n <ns>`
- Deployment → `kubectl get deployment <name> -n <ns>`
- Service → `kubectl get service <name> -n <ns>`
- Ingress → `kubectl get ingress <name> -n <ns>`

For mutating flows, the confirmation dialog or sheet also includes a secondary **Copy Command** action instead of immediately executing:

- Delete Pod → `kubectl delete pod <name> -n <ns>`
- Restart Deployment → `kubectl rollout restart deployment/<name> -n <ns>`
- Scale Deployment → `kubectl scale deployment/<name> --replicas=<n> -n <ns>`
- Port Forward → `kubectl port-forward <target> <local>:<remote> -n <ns>`

**Pod actions:**
- **Delete Pod** — confirmation alert → `kubectl delete pod <name> -n <ns>` → refresh list
- **Port Forward** — opens a port forward sheet (see Port Forwarding section below)
- **Copy kubectl Command** — copies `kubectl get pod <name> -n <ns>`

**Deployment actions:**
- **Restart** — confirmation alert ("Restart deployment `<name>`?") → `kubectl rollout restart deployment/<name> -n <ns>` → refresh list. This triggers a rolling restart, same as the CLI. No downtime if the deployment has >1 replica.
- **Scale** — opens an inline popover with a numeric stepper showing current replica count. User adjusts the number, clicks Apply → `kubectl scale deployment/<name> --replicas=<n> -n <ns>` → refresh list. The popover shows current desired vs ready count so the user knows what they're changing.
- **Copy kubectl Command** — copies `kubectl get deployment <name> -n <ns>`

**Service actions:**
- **Port Forward** — opens a port forward sheet. Pre-fills the remote port from the service's port list (if only one port, auto-fills it).
- **Copy kubectl Command** — copies `kubectl get service <name> -n <ns>`

**Ingress actions:**
- **Copy kubectl Command** — copies `kubectl get ingress <name> -n <ns>`

### Port Forwarding

Port forwarding is the one feature that breaks the open-n-close model — a forward needs to stay alive after the browser window closes. This requires a dedicated manager that lives at the app level.

#### PortForwardManager

An actor that owns the lifecycle of all active `kubectl port-forward` processes. It lives on `TelepresenceController` (or directly on `ReconApp`) so it survives window close/open cycles.

```swift
actor PortForwardManager {
    func start(target:namespace:remotePort:localPort:) async throws -> PortForwardEntry
    func stop(id:) async
    func stopAll() async
    func activeForwards() async -> [PortForwardEntry]
}
```

```swift
struct PortForwardEntry: Identifiable {
    let id: UUID
    let target: String          // "pod/api-server" or "svc/api-service"
    let namespace: String
    let localPort: UInt16
    let remotePort: UInt16
    let startedAt: Date
    var status: PortForwardStatus  // .active, .failed(reason), .stopped
}

enum PortForwardStatus: Equatable {
    case active
    case failed(String)
    case stopped
}
```

**How it works:**

1. User right-clicks a pod or service → "Port Forward"
2. **TCP-only gate:** `kubectl port-forward` only supports TCP. The port forward action filters the port list to TCP ports only. If a pod or service has no TCP ports, the "Port Forward" action is hidden from the context menu entirely (same as if the user lacks RBAC permission). If a resource has a mix of TCP and UDP ports, only TCP ports appear in the dropdown.
3. A sheet appears with:
   - **Remote port** — pre-filled from the resource's TCP ports. Dropdown if multiple TCP ports. For services with named `targetPort` values, the display shows the name but the forward targets the service port (kubectl resolves the named port server-side). Editable for pods with no declared ports.
   - **Local port** — defaults to same as remote. Editable. If the port is busy, the system will pick a free one (kubectl handles this with `:0` syntax, but we default to matching the remote port since that's what people expect).
   - **Start** button
4. On start: `PortForwardManager.start()` spawns `kubectl port-forward <target> <local>:<remote> -n <ns>` as a long-running `Process`. The process handle is retained in the manager.
5. The manager monitors the process — if it exits unexpectedly, the entry status becomes `.failed(reason)`.
6. The entry appears in the **active forwards bar** (see below).

**Memory model for port forwards:**

- Each active forward holds: one `Process` handle (~negligible), one `PortForwardEntry` struct, two `Pipe` objects for stdout/stderr monitoring.
- Estimated overhead: ~1-2 KB per active forward. Even 20 simultaneous forwards would be under 50 KB.
- When a forward is stopped, the process is terminated and all references are released.
- When the app quits, `PortForwardManager.stopAll()` terminates all child processes.

#### Active Forwards Bar

Active port forwards are visible in two places:

**1. Browser window — bottom bar**

The status bar at the bottom of the cluster browser gains a forwards indicator:

```
┌─────────────────────────────────────────────────┐
│  ...resource list...                            │
├─────────────────────────────────────────────────┤
│  42 pods    ⇌ 3 forwards active     context ▸  │
└─────────────────────────────────────────────────┘
```

Clicking "3 forwards active" expands an inline panel showing each forward with a stop button:

```
┌─────────────────────────────────────────────────┐
│  ⇌ pod/api-server      8080 → 8080   [Stop]    │
│  ⇌ svc/auth-service    3000 → 3000   [Stop]    │
│  ⇌ pod/worker-abc      9090 → 9090   [Stop]    │
│                               [Stop All]        │
└─────────────────────────────────────────────────┘
```

**2. Menu bar popover**

The main Recon menu shows active forwards even when the browser is closed:

```
  ⇌ Port Forwards (3 active)
    pod/api-server       8080 → 8080   [Stop]
    svc/auth-service     3000 → 3000   [Stop]
    pod/worker-abc       9090 → 9090   [Stop]
```

This is how users manage forwards without re-opening the browser. It's a lightweight section in the existing `ReconMenuView`, only visible when there are active forwards.

#### Port Forward Lifecycle

```
User right-clicks pod → "Port Forward"
  → Sheet appears with port fields
  → User clicks Start
  → PortForwardManager.start() spawns kubectl port-forward process
  → Entry added to activeForwards list
  → Sheet dismisses, forward indicator updates in status bar

User closes browser window
  → Resource data released (normal open-n-close behavior)
  → Port forwards keep running (owned by PortForwardManager, not the view model)
  → Menu bar shows active forwards section

User clicks Stop on a forward (from browser or menu)
  → PortForwardManager.stop(id:) terminates the kubectl process
  → Entry removed from activeForwards list
  → UI updates

kubectl port-forward process dies unexpectedly
  → PortForwardManager detects process exit
  → Entry status → .failed("Connection refused" or whatever stderr said)
  → UI shows the failed forward with an option to restart or dismiss

User quits Recon
  → PortForwardManager.stopAll() terminates all kubectl port-forward processes
  → Clean exit, no orphaned processes
```

### Integration with Existing Code

**Reuses directly (no changes needed):**
- `CommandEnvironmentResolver` — kubectl path resolution, execution environment, kubeconfig handling
- `ProcessRunner` — spawning kubectl processes with timeouts. Used for all request/response commands (get, delete, scale, restart, auth can-i). **Not** used for port forwarding (see below)
- `AppWindowID` — add `static let cluster = "cluster"` alongside existing `preferences` and `diagnostics`

**New process primitive for port forwarding:**

The existing `ProcessRunner` is request/response: start process, wait for exit, return captured output. Port forwarding needs a different primitive — a long-lived process that:
1. Retains the `Process` handle so it can be terminated on demand
2. Streams stderr while running to detect errors (e.g., "bind: address already in use")
3. Parses stdout for the "Forwarding from 127.0.0.1:<port>" confirmation line before reporting the forward as active
4. Detects unexpected exit and reports the failure reason from stderr

This is a new `LongRunningProcess` helper (or built into `PortForwardManager` directly). It does not replace or modify `ProcessRunner` — the two serve different use cases. `ProcessRunner` stays unchanged for all fire-and-forget commands.

**Reuses with minor touchpoint:**
- `NamespaceDiscoveryService` — the cluster browser calls its existing `fetchAvailable(for:)` to populate the namespace picker
- `KubeTargetResolver` — called once on window open to get the current context and namespace as defaults
- `ReconApp.swift` — add a new `Window("Recon — Cluster", id: AppWindowID.cluster)` scene. Initialize `PortForwardManager` at the app level so it survives window lifecycle
- `ReconMenuView.swift` — add a "Cluster Browser" button to the menu (alongside existing Diagnostics button). Add an "Active Port Forwards" section that appears when there are active forwards, with stop buttons
- `TelepresenceController` — the view model reads the current context/namespace from the controller. The controller also holds a reference to `PortForwardManager` so the menu view can access active forwards
- `NSPasteboard` — used by the view model to copy generated `kubectl` commands without executing them

### kubectl Commands Used

| Action | Command | Timeout |
|---|---|---|
| List pods | `kubectl get pods -n <ns> -o json` | 5s |
| List deployments | `kubectl get deployments -n <ns> -o json` | 5s |
| List services | `kubectl get services -n <ns> -o json` | 5s |
| List ingresses | `kubectl get ingresses -n <ns> -o json` | 5s |
| Resolve related pods | `kubectl get pods -n <ns> -l <selector> -o json` | 5s |
| Resolve related services | `kubectl get services -n <ns> -o json` | 5s |
| Delete pod | `kubectl delete pod <name> -n <ns>` | 10s |
| Scale deployment | `kubectl scale deployment/<name> --replicas=<n> -n <ns>` | 10s |
| Restart deployment | `kubectl rollout restart deployment/<name> -n <ns>` | 10s |
| Port forward | `kubectl port-forward <target> <local>:<remote> -n <ns>` | long-running |
| Check permission | `kubectl auth can-i <verb> <resource> -n <ns>` | 3s |

Permission checks run 5 `can-i` calls in parallel per namespace switch (~50-100ms wall time).

All commands use the environment from `CommandEnvironmentResolver.executionEnvironment()` (inherits kubeconfig, PATH, etc.).

### Error Handling

- kubectl not found → show inline message in window, same pattern as existing `TargetMetadata.resolutionError`
- kubectl times out (5s) → show "Request timed out. The cluster may be unreachable." with a retry button
- kubectl returns non-zero exit → parse stderr, show first meaningful line as error message
- 403 Forbidden on action → show "Permission denied: you don't have access to `<verb>` `<resource>` in namespace `<ns>`." Update `NamespacePermissions` to hide that action for the rest of the session
- 403 Forbidden on resource list → show "You don't have access to list `<resource>` in namespace `<ns>`." The tab remains visible but shows the error instead of an empty list — this distinguishes "no resources" from "no access"
- No resources found → show empty state, not an error ("No pods in namespace `<ns>`")
- Namespace query fails → namespace picker shows recently-used namespaces only (existing behavior from `NamespaceDiscoveryService`)
- Permission check fails (can-i times out or errors) → assume permitted, rely on execution-time error handling

### Window Lifecycle

```
User clicks "Cluster Browser" in menu
  → ClusterBrowserWindowPresenter.present()
  → Window opens, onAppear fires
  → viewModel.activateWindow()
  → Fetch current context + namespace from KubeTargetResolver
  → In parallel:
      → Fetch pods in that namespace from KubeResourceService
      → Check permissions for that namespace via kubectl auth can-i
  → Render list (actions appear/hide as permissions resolve)

User switches namespace
  → In parallel:
      → Fetch resources for new namespace
      → Check permissions for new namespace
  → Previous namespace data + permissions released

User closes window
  → onDisappear fires
  → viewModel.deactivateWindow()
  → Cancel in-flight tasks
  → Set resources = [], permissions = nil, filterText = "", errorMessage = nil
  → All resource data deallocated
  → Memory returns to baseline
```

### Memory Budget (updated)

Port forwarding is the sole exception to the open-n-close rule:

| State | Target |
|---|---|
| Menu bar idle, no forwards | 0 MB additional |
| Browser open, resource list loaded | 5-15 MB |
| Browser closed, 5 active forwards | ~50 KB (process handles + entry structs) |
| Browser closed, no forwards | 0 MB (back to baseline) |

### What This Doesn't Do

To keep scope tight, the cluster browser intentionally does not:

- Watch or stream resource changes (no `kubectl get --watch`)
- Cache resources across window open/close cycles
- Run any background work when the window is closed (port forwards excepted — they are user-initiated and explicitly managed)
- Persist resource state to disk or SQLite
- Show resources from multiple namespaces simultaneously
- Show events, nodes, configmaps, secrets, or CRDs
- Provide streaming logs, exec/shell, or YAML editing
