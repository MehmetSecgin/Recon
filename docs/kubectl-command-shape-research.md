# Kubectl Command Shape Research

Date: 2026-04-02

## Scope

This note looks at the `kubectl` commands Recon currently executes, maps them to the actual fields the app consumes, and recommends lower-volume alternatives where they are realistic.

The main question is not "can we print less text to stdout?" but "can we ask Kubernetes for less data in the first place?"

## Current Call Sites

### Target metadata and Telepresence

- `kubectl config current-context`
  - Used by Telepresence connect/reconnect to pass the current context through.
  - Code: [Sources/Recon/TelepresenceCLI.swift](/Users/mehmetsecgin/Projects/Recon/Sources/Recon/TelepresenceCLI.swift#L274)
- `kubectl config current-context`
  - Used by target resolution for the UI.
  - Code: [Sources/Recon/Services/KubeTargetResolver.swift](/Users/mehmetsecgin/Projects/Recon/Sources/Recon/Services/KubeTargetResolver.swift#L23)
- `kubectl config view --minify -o json`
  - Used to read the active namespace from the current kubeconfig.
  - Code: [Sources/Recon/Services/KubeTargetResolver.swift](/Users/mehmetsecgin/Projects/Recon/Sources/Recon/Services/KubeTargetResolver.swift#L68)

### Browser source and namespace discovery

- `kubectl config view --kubeconfig <path> -o json`
  - Used to enumerate browser contexts and read each context's default namespace.
  - Code: [Sources/Recon/Services/BrowserConfigService.swift](/Users/mehmetsecgin/Projects/Recon/Sources/Recon/Services/BrowserConfigService.swift#L31)
- `kubectl get namespaces -o jsonpath={.items[*].metadata.name}`
  - Used by the main app namespace discovery flow.
  - Code: [Sources/Recon/Services/NamespaceDiscoveryService.swift](/Users/mehmetsecgin/Projects/Recon/Sources/Recon/Services/NamespaceDiscoveryService.swift#L19)
- `kubectl --kubeconfig <path> --context <context> get namespaces -o jsonpath={.items[*].metadata.name}`
  - Used by cluster browser namespace loading.
  - Code: [Sources/Recon/Services/BrowserConfigService.swift](/Users/mehmetsecgin/Projects/Recon/Sources/Recon/Services/BrowserConfigService.swift#L129)

### Cluster browser list views

- `kubectl --kubeconfig <path> --context <context> get pods -n <namespace> -o json`
- `kubectl --kubeconfig <path> --context <context> get deployments -n <namespace> -o json`
- `kubectl --kubeconfig <path> --context <context> get services -n <namespace> -o json`
- `kubectl --kubeconfig <path> --context <context> get configmaps -n <namespace> -o json`
  - All four flow through the same helper.
  - Code: [Sources/Recon/Services/KubeResourceService.swift](/Users/mehmetsecgin/Projects/Recon/Sources/Recon/Services/KubeResourceService.swift#L216)

## What The UI Actually Needs

The current browser tables display far less than the app fetches.

### Pods

UI columns:

- `Name`
- `Ready`
- `Restarts`
- `Age`
- Status color/text

Fields currently read:

- `metadata.name`
- `metadata.namespace`
- `metadata.creationTimestamp`
- `status.phase`
- `status.containerStatuses[].ready`
- `status.containerStatuses[].restartCount`
- `status.containerStatuses[].state.waiting.reason`

Relevant code:

- [Sources/Recon/Services/KubeResourceService.swift](/Users/mehmetsecgin/Projects/Recon/Sources/Recon/Services/KubeResourceService.swift#L153)
- [Sources/Recon/Views/ClusterBrowserWindowView.swift](/Users/mehmetsecgin/Projects/Recon/Sources/Recon/Views/ClusterBrowserWindowView.swift#L306)

### Deployments

UI columns:

- `Name`
- `Ready`
- `Up-to-date`
- `Available`
- `Age`

Fields currently read:

- `metadata.name`
- `metadata.namespace`
- `metadata.creationTimestamp`
- `spec.replicas`
- `status.readyReplicas`
- `status.updatedReplicas`
- `status.availableReplicas`

Relevant code:

- [Sources/Recon/Services/KubeResourceService.swift](/Users/mehmetsecgin/Projects/Recon/Sources/Recon/Services/KubeResourceService.swift#L177)
- [Sources/Recon/Views/ClusterBrowserWindowView.swift](/Users/mehmetsecgin/Projects/Recon/Sources/Recon/Views/ClusterBrowserWindowView.swift#L341)

### Services

UI columns:

- `Name`
- `Type`
- `Cluster IP`
- `Ports`
- `Age`

Fields currently read:

- `metadata.name`
- `metadata.namespace`
- `metadata.creationTimestamp`
- `spec.type`
- `spec.clusterIP`
- `spec.ports[].name`
- `spec.ports[].port`
- `spec.ports[].protocol`

Relevant code:

- [Sources/Recon/Services/KubeResourceService.swift](/Users/mehmetsecgin/Projects/Recon/Sources/Recon/Services/KubeResourceService.swift#L194)
- [Sources/Recon/Views/ClusterBrowserWindowView.swift](/Users/mehmetsecgin/Projects/Recon/Sources/Recon/Views/ClusterBrowserWindowView.swift#L400)

### ConfigMaps

UI columns:

- `Name`
- `Keys`
- `Immutable`
- `Age`

Fields currently read:

- `metadata.name`
- `metadata.namespace`
- `metadata.creationTimestamp`
- `data`
- `immutable`

Important detail:

- Recon currently decodes the full `data` map only to count its keys.
- Code: [Sources/Recon/Models/ClusterBrowserDecoding.swift](/Users/mehmetsecgin/Projects/Recon/Sources/Recon/Models/ClusterBrowserDecoding.swift#L18)

This means the configmap list path can pull very large payloads even though the UI never renders the config values themselves.

## Findings

### 1. The real problem is the list views, not the config helpers

`config current-context` is already tiny. It returns one string and is not worth optimizing for data volume.

`config view --minify -o json` and `config view --kubeconfig <path> -o json` are over-broad for what Recon needs, but they read local kubeconfig files rather than large cluster lists. They are good cleanup targets, not the main scale problem.

The large payload risk is concentrated in:

- `get pods -o json`
- `get deployments -o json`
- `get services -o json`
- `get configmaps -o json`

### 2. `jsonpath` and `custom-columns` mainly reduce stdout, not necessarily server-side payload

Official Kubernetes docs distinguish between:

- output formatting options exposed by `kubectl get` such as `json`, `jsonpath`, and `custom-columns`
- API representations such as `Table` and `PartialObjectMetadata`, which are selected via HTTP content negotiation

From that, the safest reading is:

- switching from `-o json` to `-o jsonpath` or `-o custom-columns` helps Recon's stdout volume and local decoding work
- but it is unlikely to reduce the bytes fetched from the API server the way a true table or metadata-only response can

This is an inference from the official API model, not an explicit `kubectl` guarantee.

### 3. Server-side table responses are the only clearly documented compact list representation available through normal `kubectl get`

The Kubernetes API docs explicitly document table responses and metadata-only responses as distinct API representations for convenience and efficiency.

Within stock `kubectl`, the practical path to table responses is the default human-readable `get` output:

- `kubectl get pods -n <ns> --no-headers`
- `kubectl get deployments -n <ns> --no-headers`
- `kubectl get services -n <ns> --no-headers`
- `kubectl get configmaps -n <ns> --no-headers`

These shapes align unusually well with Recon's current browser columns:

| Resource | Default table already includes |
| --- | --- |
| Pods | name, ready, status, restarts, age |
| Deployments | name, ready, up-to-date, available, age |
| Services | name, type, cluster IP, ports, age |
| ConfigMaps | name, data count, age |

That makes table output the strongest kubectl-native option for large list views.

### 4. Table parsing has a real stability cost

The main downside is that Recon would be parsing terminal-oriented text output.

Risks:

- column rendering is meant for humans first
- age is relative text, not an ISO timestamp
- pod restart output can include extra text on some kubectl versions
- configmaps do not expose `immutable` in the default table

So table output is the best data-volume option, but not the cleanest parsing contract.

### 5. Field selectors help only in narrow cases

Official field selector docs show:

- all resource types support `metadata.name` and `metadata.namespace`
- pods also support `status.phase`
- namespaces support `status.phase`

That means field selectors can help if Recon adds explicit server-side filters such as:

- "only non-running pods"
- "only running pods"
- exact object lookup by name

But they do not solve the generic "list everything in this namespace" case for services, deployments, or configmaps.

### 6. ConfigMaps are the cleanest candidate for a behavior change

For configmaps, the current list call fetches full values only to compute:

- key count
- immutable flag
- age

That is a poor cost/benefit trade if namespaces contain large config payloads.

There are only three realistic fixes:

- accept table parsing and derive `Keys` from the default `DATA` column, then lazy-load `immutable`
- keep JSON, but accept that the API response remains heavy
- change the UI contract so `immutable` is not a list-column requirement

## Recommended Command Shapes

### A. Cheap cleanup wins

### Active target metadata

Current:

```bash
kubectl config current-context
kubectl config view --minify -o json
```

Recommended:

```bash
kubectl config view --minify -o jsonpath='{.current-context}{"\t"}{.contexts[0].context.namespace}'
```

Why:

- one call instead of two
- enough for current context plus namespace fallback
- smaller stdout than full minified JSON

Notes:

- this is a cleanup win, not a scale win
- the Telepresence path can keep `config current-context` if it only needs the context string

### Browser kubeconfig source loading

Current:

```bash
kubectl config view --kubeconfig <path> -o json
```

Recommended:

```bash
kubectl config view --kubeconfig <path> -o jsonpath='{range .contexts[*]}{.name}{"\t"}{.context.namespace}{"\n"}{end}'
```

Why:

- Recon only uses context name and default namespace
- avoids emitting clusters, users, and unrelated kubeconfig structure
- reduces command-history/log volume

### B. Keep namespace list commands mostly as-is

Current:

```bash
kubectl get namespaces -o jsonpath={.items[*].metadata.name}
kubectl --kubeconfig <path> --context <context> get namespaces -o jsonpath={.items[*].metadata.name}
```

Recommendation:

- keep the current basic shape
- add `--request-timeout=5s`
- optionally add `--chunk-size=200`

Why:

- namespace lists are usually much smaller than pod/configmap lists
- current stdout is already minimal
- changing these does not unlock the biggest win

### C. Replace browser list views with table-first list commands

### Recommended list commands

```bash
kubectl --kubeconfig <path> --context <context> --request-timeout=5s get pods -n <namespace> --chunk-size=200 --no-headers
kubectl --kubeconfig <path> --context <context> --request-timeout=5s get deployments -n <namespace> --chunk-size=200 --no-headers
kubectl --kubeconfig <path> --context <context> --request-timeout=5s get services -n <namespace> --chunk-size=200 --no-headers
kubectl --kubeconfig <path> --context <context> --request-timeout=5s get configmaps -n <namespace> --chunk-size=200 --no-headers
```

Why this is the best next move:

- maximum likely reduction in data volume while staying inside normal `kubectl`
- output matches the current browser tables surprisingly well
- much smaller stdout and command-history footprint
- avoids full-object JSON decoding for every row

What each resource still needs after the switch:

- Pods: parse `READY`, `STATUS`, `RESTARTS`, `AGE`
- Deployments: parse `READY`, `UP-TO-DATE`, `AVAILABLE`, `AGE`
- Services: parse `TYPE`, `CLUSTER-IP`, `PORT(S)`, `AGE`
- ConfigMaps: parse `DATA`, `AGE`

### D. Add lazy detail fetches only where the table output is insufficient

This is the best hybrid model.

List cheaply, then fetch exact details only for the selected row or only when a feature truly needs them.

Examples:

```bash
kubectl --kubeconfig <path> --context <context> --request-timeout=5s get pod <name> -n <namespace> -o json
kubectl --kubeconfig <path> --context <context> --request-timeout=5s get configmap <name> -n <namespace> -o json
```

Use detail fetches for:

- exact pod `creationTimestamp` if age sorting must remain exact
- exact numeric restart count if table output contains extra restart timing text
- configmap `immutable`
- any future side panel or details popover

This keeps the hot path small while preserving correctness where it matters.

## What I Would Not Recommend

### Do not expect `-o jsonpath` alone to fix the big list problem

Examples such as:

```bash
kubectl get pods -n <namespace> -o jsonpath=...
kubectl get services -n <namespace> -o custom-columns=...
```

may reduce stdout, but they are not the best answer if the goal is to stop pulling huge list objects through the system.

### Do not chase metadata-only fetches unless Recon is willing to leave normal `kubectl get`

The Kubernetes API supports `PartialObjectMetadata`, and the docs explicitly say it can significantly reduce response size.

However, stock Recon currently shells out through `kubectl`, and `kubectl` does not expose a simple high-level flag that says:

- "list services as metadata-only JSON"
- "list pods as table JSON"

If Recon wants compact structured responses rather than text tables, it likely needs a lower-level transport strategy than the current `kubectl get ... -o ...` model.

## Migration Order

### Phase 1: low-risk wins

1. Merge the target metadata double-call into one `config view --minify -o jsonpath=...`
2. Replace browser source loading `config view -o json` with `jsonpath`
3. Add `--request-timeout=5s` to all networked `kubectl get` calls

### Phase 2: highest impact with lowest parsing complexity

1. Switch deployments list to table output
2. Switch services list to table output
3. Switch configmaps list to table output plus lazy per-item detail fetch for `immutable`

Reason:

- deployments and services map very cleanly to their default kubectl tables
- configmaps are likely a major payload offender, so the win is worth the hybrid complexity

### Phase 3: pods

Switch pods to table output once Recon is comfortable with parsing:

- ready text
- restart count normalization
- age parsing behavior

Pods are still worth converting because they are the most common large list, but they have the trickiest text semantics.

## Bottom Line

If the goal is to materially reduce how much data Recon moves around, the best kubectl-native strategy is:

1. keep tiny config/helper commands simple
2. stop using `-o json` for list views
3. use default `kubectl get ... --no-headers` table output for large browser lists
4. lazy-load exact JSON only for the selected object or the small subset of fields the table cannot supply

If the goal is only to reduce local stdout and command-history noise, `jsonpath` cleanups help. If the goal is to reduce the heavy cluster payload itself, the list views need a table-first or non-`kubectl get` transport strategy.

## Sources

- Kubernetes API concepts: Table and metadata-only representations: [kubernetes.io/docs/reference/using-api/api-concepts](https://kubernetes.io/docs/reference/using-api/api-concepts/)
- Kubernetes field selectors: [kubernetes.io/docs/concepts/overview/working-with-objects/field-selectors](https://kubernetes.io/docs/concepts/overview/working-with-objects/field-selectors/)
- `kubectl get` reference, including `--chunk-size`: [kubernetes.io/docs/reference/kubectl/generated/kubectl_get](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_get/)
- `kubectl config current-context` reference, including inherited `--request-timeout`: [kubernetes.io/docs/reference/kubectl/generated/kubectl_config/kubectl_config_current-context](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_config/kubectl_config_current-context/)
