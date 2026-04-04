# Cluster Browser — Implementation Plan

## Purpose

This document turns the product brief and technical spec into an execution plan.

It is intentionally phase-based:

- the **product brief** defines what V1 / V1.5 / V2 should achieve
- the **technical spec** defines how the feature should work
- this document defines **how to build it in a sensible order**

Companion documents:

- [Cluster Browser — Product Brief](./cluster-browser-product-brief.md)
- [Cluster Browser — Spec](./cluster-browser-spec.md)

## Delivery Strategy

Build the cluster browser in vertical slices that are useful on their own.

The key rule is: do not start with the hardest subsystem.

In particular:

- build the window shell and read path before actions
- build resource fetching and table rendering before relationship hints
- build deployment and pod actions before long-running port forwarding
- keep each phase shippable to internal testers where practical

## Phase 0 — Window Shell And Read-Only Browser Foundation

### Goal

Get a real browser window on screen with tabs, context/namespace framing, filter input, and read-only data loading for all four resource types.

### Deliverables

- Add the Cluster Browser window scene to `ReconApp`
- Add `AppWindowID.cluster`
- Add `ClusterBrowserWindowPresenter`
- Add `ClusterBrowserViewModel`
- Add `ClusterBrowserWindowView`
- Add menu entry in `ReconMenuView`
- Show current context and namespace
- Reuse `NamespaceDiscoveryService` for namespace picker
- Reuse `KubeTargetResolver` for initial context/namespace defaults
- Implement `KubeResourceService` read methods for:
  - pods
  - deployments
  - services
  - ingresses
- Render each resource type in a SwiftUI `Table`
- Support:
  - tab switching
  - in-memory filter/search
  - manual refresh
  - loading state
  - empty state
  - error state

### Out of scope for this phase

- RBAC-aware action gating
- delete / restart / scale / port-forward execution
- relationship hints
- copy command
- active port-forward management

### Why this comes first

This phase validates the architecture and data model with the lowest operational risk.

If Phase 0 feels bad, everything built on top of it will feel bad too.

### Done means

- The window opens reliably from the menu
- Each tab fetches and renders its resource list
- Namespace switching works
- Filtering works without re-fetching
- Window close releases loaded cluster data
- The browser is useful for read-only cluster inspection

### Main risks

- Table rendering and selection quirks in SwiftUI
- Model decoding edge cases across clusters
- Namespace/context edge cases when kubectl is unavailable

## Phase 1 — Health-First Presentation And Safe Read UX

### Goal

Make the browser immediately useful for “what is wrong?” workflows before adding mutating actions.

### Deliverables

- Pod status-text normalization from kubectl table output
- Health color/status logic for pods and deployments
- Unhealthy-first ordering for pods and deployments
- Name-only fallback sorting for services and ingresses
- Column header sorting for supported columns
- Stable selection behavior across refreshes where practical
- Status bar with:
  - resource count
  - context display
  - namespace display
- Copy `kubectl get ...` command for selected resources

### Out of scope for this phase

- Mutating actions
- relationship hints
- port forwarding

### Why this comes before actions

Users need to trust the browser as an inspection tool before they trust it to perform operations.

This phase also reduces implementation risk by finishing the health-ranking and sorting model before action logic depends on selection semantics.

### Done means

- The default view clearly surfaces unhealthy workloads first
- The browser is meaningfully better than `kubectl get` for quick diagnosis
- Copy-command behavior works for read-only resource selection

### Main risks

- Overfitting health logic to pods/deployments while services/ingresses remain read-only and less expressive
- Confusion between default health-first ordering and temporary user-selected table sorting

## Phase 2 — RBAC-Aware Core Actions

### Goal

Ship the highest-value mutating actions except long-running port forwards.

### Deliverables

- `checkPermissions(namespace:)` in `KubeResourceService`
- View-model permission loading and session updates
- UI gating for allowed vs denied actions
- Pod delete with confirmation
- Deployment restart with confirmation
- Deployment scale with popover
- Copy-command support for mutating flows:
  - delete
  - restart
  - scale
- Inline execution errors with useful messages
- Execution-time fallback behavior when `can-i` and reality diverge

### Out of scope for this phase

- Port forwarding
- relationship hints

### Why this comes before port forwarding

Delete, restart, and scale are single-shot commands. They fit the existing `ProcessRunner` pattern and are much simpler than long-running process management.

### Done means

- Users can perform the core safe actions from the browser
- RBAC mismatches are handled gracefully
- The browser is already valuable for routine operational work without port forwarding

### Main risks

- Permission checks may be correct in theory but surprising in real clusters
- Action confirmation/copy-command UX may become cluttered if not kept consistent

## Phase 3 — Port Forwarding And Active Forward Management

### Goal

Add robust port forwarding without breaking the browser’s open-n-close memory model.

### Deliverables

- `PortForwardManager`
- Long-running process primitive for `kubectl port-forward`
- Start/stop active forwards
- Parse readiness / assigned port from process output
- Detect unexpected exit and show failure state
- Port-forward sheet for pods and services
- TCP-only filtering
- Service port-forward behavior aligned with upstream kubectl semantics
- Active forwards section in the browser status area
- Active forwards section in `ReconMenuView`
- Copy-command support for port-forward flows

### Out of scope for this phase

- Restart failed forward
- advanced address binding options
- multiple simultaneous port mappings in one action

### Why this is its own phase

Port forwarding is the only subsystem that introduces long-lived child processes and app-level lifecycle concerns.

It is the most implementation-sensitive part of V1 and deserves isolation.

### Done means

- Users can start and stop forwards from the browser
- Forwards survive window close
- Forwards can be managed from the menu bar
- The app exits cleanly without orphaned processes

### Main risks

- Race conditions around process startup and cancellation
- Parsing readiness output robustly across kubectl versions
- UX confusion when a service resolves to a pod but the user thinks they are forwarding “the service”

## Phase 4 — Lightweight Relationship Hints And Navigation

### Goal

Make the browser better at “show me the related thing” without turning it into a graph explorer.

### Deliverables

- Shared relationship-hint models
- On-selection hint resolution
- ~200 ms debounce on selection changes
- Cancellation of in-flight hint fetches
- Relationship hint strip in the window
- Best-effort cross-tab navigation with transient filters
- Empty filtered result behavior when a hinted target no longer exists

### Why this comes after actions

Relationship hints improve navigation quality, but they are not required for the core read/action loop.

Shipping them later keeps early phases simpler and reduces the number of moving parts during the first usable release.

### Done means

- Selected rows can reveal likely related resources
- Hint resolution does not create kubectl process pile-ups
- The feature helps users jump between workload resources quickly

### Main risks

- False confidence if hints look more authoritative than they are
- Too many per-selection fetches if debounce/cancellation is implemented poorly

## Phase 5 — V1 Polish And Hardening

### Goal

Make the feature feel production-ready for daily use.

### Deliverables

- Final keyboard shortcut polish
- Better loading and empty states
- Context and namespace visibility audit
- Error message audit
- Table behavior polish:
  - selection retention
  - scroll behavior
  - sort-reset behavior
- Performance checks with large namespaces
- QA pass on mixed-RBAC environments
- QA pass on clusters with:
  - no ingresses
  - many pods
  - named service targetPorts
  - UDP-only ports
  - missing selectors

### Done means

- The feature is coherent end-to-end
- The window feels fast and predictable
- The team is comfortable putting it in front of real users

## Suggested Milestones

If we want a practical milestone structure, this is the cleanest split:

1. **M1: Read-only browser**
   - Phase 0
   - Phase 1

2. **M2: Core actions**
   - Phase 2

3. **M3: Port forwarding**
   - Phase 3

4. **M4: Relationship hints + polish**
   - Phase 4
   - Phase 5

This creates a good internal-release cadence:

- M1 gives a usable inspection tool
- M2 gives real operational value
- M3 adds the highest-complexity feature
- M4 makes it feel cohesive and polished

## Sequencing Notes

### Recommended engineering order inside Phase 0

1. Window scene + presenter
2. View model shell
3. Pods tab end-to-end
4. Deployments tab
5. Services tab
6. Ingresses tab
7. Namespace picker + refresh polish

### Recommended engineering order inside Phase 2

1. Permission model + checks
2. Delete pod
3. Restart deployment
4. Scale deployment
5. Copy-command actions

### Recommended engineering order inside Phase 3

1. Long-running process helper
2. Pod port-forward
3. Active forwards state + stop
4. Menu bar management UI
5. Service port-forward
6. Failure and recovery polish

## What We Should Not Do Early

Avoid pulling these forward before the earlier phases are stable:

- logs
- exec
- YAML viewing
- CRD support
- background watches
- app-centric grouping beyond lightweight hints
- event summaries
- “smart” diagnosis features

These may all be useful later, but they increase scope faster than they increase early user value.

## Exit Criteria For V1

V1 is complete when all of the following are true:

- The browser opens quickly and behaves predictably
- Context and namespace are obvious
- Pods, Deployments, Services, and Ingresses render correctly
- The default view surfaces unhealthy workloads first where health exists
- Users can delete a pod, restart a deployment, scale a deployment, and start/stop a port-forward
- Copy-command support exists for resource inspection and actions
- Relationship hints work as lightweight navigation aids
- Browser close releases cluster data while active forwards continue intentionally
- The feature feels like a simple Kubernetes helper, not an unfinished dashboard
