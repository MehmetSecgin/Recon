# Recon Research: macOS Menu Bar UX for a Telepresence Companion

Prepared: 2026-03-26

Legend:
- `[Evidence]` Directly supported by linked source material or by Recon's current product scope.
- `[Inference]` A conclusion drawn from multiple sources and the shape of the problem.
- `[Opinion]` A product judgment where evidence is thinner and tradeoffs matter.

## 1. Executive Summary

- `[Evidence]` Apple treats menu bar extras as small, space-constrained controls, and `MenuBarExtra` specifically notes that more complex or data-rich content may justify a window-style presentation rather than a plain menu. Recon should stay compact, but a small utility panel is acceptable for richer status. [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra), [NSStatusBar](https://developer.apple.com/documentation/appkit/nsstatusbar)
- `[Inference]` Recon's core job is not "manage Kubernetes"; it is "tell me whether Telepresence is healthy, pointed at the right target, and easy to recover." Anything beyond that should justify its weight carefully.
- `[Evidence]` Telepresence status surfaces first-class concepts like connection status, Kubernetes context, namespace, intercepts, and daemon state. Those are the concepts users already see in CLI output and are the best candidates for a trustworthy UI. [Telepresence CLI reference](https://telepresence.io/docs/reference/cli/telepresence), [Telepresence engagements CLI](https://telepresence.io/docs/reference/engagements/cli)
- `[Evidence]` Kubernetes treats kubeconfig, contexts, and namespaces as distinct concepts, and kubeconfig files can be merged or overridden via `KUBECONFIG`. That means a helper app can easily mislead users if it oversimplifies "what cluster am I about to hit?" [Organizing Cluster Access Using kubeconfig Files](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/), [kubectl config reference](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_config/), [Namespaces](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)
- `[Inference]` The most important Recon metadata is: kubeconfig source, current context, current namespace, Telepresence connection state, and whether intercepts exist. Everything else is secondary.
- `[Evidence]` Comparable tools follow the same split: quick controls in the menu bar, richer discovery and debugging elsewhere. Tailscale added a windowed macOS UI because menu-only UI limited search, discovery, and error handling; Docker later added a CLI to reduce dependence on its dashboard. [Tailscale's windowed macOS UI is now in beta](https://tailscale.com/blog/windowed-macos-ui-beta), [Docker Desktop CLI](https://docs.docker.com/desktop/features/desktop-cli/)
- `[Inference]` Terminal-native users will accept a wrapper only if it does not hide state, silently mutate shared config, or trap them in GUI-only recovery paths.
- `[Evidence]` Apple recommends pairing color with other indicators and being conservative with notifications. Recon should not rely on color alone for status, and notifications should focus on failure, recovery, or action-worthy transitions. [Color](https://developer.apple.com/design/human-interface-guidelines/color), [Notifications](https://developer.apple.com/design/human-interface-guidelines/notifications)
- `[Opinion]` Recon should expose intercept visibility, but not full intercept authoring, at least not yet. Read-only visibility improves trust; intercept creation/editing is where a "small helper" can easily become a half-baked Telepresence IDE.
- `[Opinion]` The most valuable next step is not "more features"; it is clearer target visibility, safer kubeconfig/context handling, and better diagnostics/log escape hatches.

## 2. User Jobs To Be Done

### Frequent / simple jobs

- `[Inference]` Confirm, at a glance, whether Telepresence is connected without opening Terminal.
- `[Inference]` Confirm the exact target before running commands locally: which kubeconfig, which context, which namespace.
- `[Inference]` Connect, disconnect, or reconnect quickly when a session is stale, dropped, or clearly pointed at the wrong environment.
- `[Inference]` Recover from common breakage without remembering the exact CLI sequence.
- `[Inference]` Keep Recon around quietly in the background and trust that it is not doing surprising things.
- `[Inference]` Know whether automatic behavior is enabled: launch at login, auto-connect on launch, auto-reconnect, notifications.

### Advanced / debugging jobs

- `[Evidence]` Diagnose why Telepresence is not usable even though "something is running": user daemon running but no active cluster connection, root daemon state, invalid kubeconfig, no context definition, DNS/routing issues, or Traffic Manager problems. [Telepresence CLI reference](https://telepresence.io/docs/reference/cli/telepresence), [Telepresence DNS reference](https://telepresence.io/docs/reference/dns), [Telepresence issue #2689](https://github.com/telepresenceio/telepresence/issues/2689)
- `[Inference]` Distinguish "wrong target" from "disconnected" from "Telepresence itself is unavailable."
- `[Evidence]` Inspect intercept state or at least confirm whether intercepts exist, because Telepresence status itself treats intercepts as meaningful status output. [Telepresence engagements CLI](https://telepresence.io/docs/reference/engagements/cli)
- `[Inference]` Jump from GUI state to CLI recovery with minimal translation: open logs, copy a command, or reveal the relevant path.
- `[Inference]` Avoid dangerous cluster mistakes when juggling multiple kubeconfigs, clusters, namespaces, or shells.

## 3. Mental Models

- `[Evidence]` Users usually think of `kubeconfig` as the source of truth for credentials and context definitions, `context` as "which cluster/account am I targeting?", and `namespace` as the default scope within that target. Kubernetes docs reinforce those as separate concepts. [Organizing Cluster Access Using kubeconfig Files](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/), [Namespaces](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)
- `[Inference]` In Recon, `kubeconfig file` is provenance, `context` is target, and `namespace` is scope. The UI should not blur those together.
- `[Evidence]` Telepresence adds another layer: connection/session state, daemons, Traffic Manager communication, and optionally intercepts. Users often think "connected to the cluster" as one thing, but Telepresence's own status output shows it is actually several layers. [Telepresence CLI reference](https://telepresence.io/docs/reference/cli/telepresence), [Telepresence engagements CLI](https://telepresence.io/docs/reference/engagements/cli)
- `[Inference]` Users likely think of Telepresence as "my laptop is temporarily on the cluster network." That means wrong context, wrong namespace, broken DNS, or a dead daemon all feel like "Telepresence is broken," even if the specific layer differs.
- `[Inference]` `Refresh` should mean "observe current state only." If it mutates or reconnects, users will stop trusting the label.
- `[Inference]` `Reconnect` is mentally different from `Connect`: users expect it to repair a stale session and preserve intent, not quietly retarget them elsewhere.
- `[Opinion]` `connection` is a risky label for Recon's UI because it can mean Telepresence session name, Kubernetes target, or generic network status. Prefer precise labels such as `Context`, `Namespace`, and `Telepresence session`.

### Where terminology can confuse people

- `[Evidence]` `KUBECONFIG` may refer to one file, a colon-separated merge of files, or the default `~/.kube/config`. A picker that pretends it is always one file can mislead advanced users. [Organizing Cluster Access Using kubeconfig Files](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/)
- `[Inference]` If Recon is pinned to one file, say that explicitly. If it inherited a merged `KUBECONFIG`, say that explicitly too.
- `[Evidence]` The active namespace can be stored as part of context preferences. Users may think they are "just changing namespace for Recon" when they are actually changing a shared kubectl default. [Namespaces](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)
- `[Inference]` Any future UI for context or namespace mutation needs unusually strong clarity because those changes may affect other shells and tools that read the same kubeconfig.

## 4. What Users Want In This Kind Of App

- `[Inference]` A fast glanceable truth source. The app should answer three questions in under two seconds: "Am I connected?", "To what?", and "Do I need to care right now?"
- `[Evidence]` Status concepts that match the CLI. Telepresence already exposes context, namespace, intercepts, and daemon status. Using those same concepts increases trust because the UI is not inventing a parallel vocabulary. [Telepresence CLI reference](https://telepresence.io/docs/reference/cli/telepresence), [Telepresence engagements CLI](https://telepresence.io/docs/reference/engagements/cli)
- `[Inference]` Explicit targeting metadata. Context and namespace matter more than decorative status language.
- `[Inference]` Deterministic actions. `Connect`, `Disconnect`, `Reconnect`, and `Refresh` should each do one obvious thing.
- `[Evidence]` Lightweight, low-friction behavior. Tools like OrbStack explicitly position "native UI", "menu bar app", and "quick global actions" as value, and Tailscale frames its menu bar client as something that stays out of the way until needed. [OrbStack](https://orbstack.dev/), [Tailscale's windowed macOS UI is now in beta](https://tailscale.com/blog/windowed-macos-ui-beta)
- `[Inference]` Honest failures with a next step. "Status check failed" is less useful than "Telepresence found, but kubeconfig has no context definition" plus a logs/CLI escape hatch.
- `[Evidence]` Shared control across UI and CLI. Tailscale documents preferences that can be changed from either the menu bar or CLI, and Docker explicitly added CLI operations to reduce dashboard dependence. [Manage client preferences](https://tailscale.com/docs/features/client/manage-preferences), [Docker Desktop CLI](https://docs.docker.com/desktop/features/desktop-cli/)
- `[Inference]` A native feel. That usually means restrained visuals, predictable labels, respect for system conventions, and not forcing users through a custom worldview just to toggle a background utility.

## 5. What Users Usually Dislike

- `[Inference]` Hidden state. The biggest trust-killer is when the helper app appears "connected" but is using a different kubeconfig, context, or namespace than the user assumes.
- `[Evidence]` Surprise automation. Kubernetes config can be inherited, merged, or stored in shared files. Silent mutation is dangerous in multi-cluster workflows. [Organizing Cluster Access Using kubeconfig Files](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/), [kubectl config reference](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_config/)
- `[Inference]` Silent failures. If Telepresence depends on daemons, routing, DNS, and cluster-side components, a wrapper that compresses every failure into "Reconnect failed" will feel flaky even when the underlying tool is diagnosable.
- `[Evidence]` Overstuffed menu-only design. Tailscale's own rationale for adding a windowed app was that menu bar dropdowns are poor for search, discovery, and better error handling. [Tailscale's windowed macOS UI is now in beta](https://tailscale.com/blog/windowed-macos-ui-beta)
- `[Inference]` Too much abstraction. Advanced users usually do not want a helper app that hides cluster terms behind "friendly" labels. They want the real nouns, shown clearly.
- `[Inference]` Chatty notifications. A background dev utility that announces every state poll or successful reconnect quickly becomes noise.
- `[Opinion]` Un-native styling can also reduce trust. For a utility app, forcing an unusual look or behavior is more likely to read as awkward than delightful.

### Good and bad patterns

- `[Evidence]` Good pattern: Tailscale keeps quick toggles close to the menu bar, but adds a separate window for search, discovery, and debugging once the menu stops scaling. [Tailscale's windowed macOS UI is now in beta](https://tailscale.com/blog/windowed-macos-ui-beta)
- `[Evidence]` Good pattern: Docker recognized that power users do not want to depend on a dashboard for lifecycle operations and added CLI controls for start/stop/status/logs/diagnostics. [Docker Desktop CLI](https://docs.docker.com/desktop/features/desktop-cli/)
- `[Inference]` Bad pattern for Recon: a UI that can connect or reconnect, but does not clearly reveal target metadata or how to get to logs when something breaks.

## 6. macOS Menu Bar Best Practices

### General shape

- `[Evidence]` Menu bar extras are space-constrained, and Apple notes they are not always guaranteed space in the menu bar. Keep the menu bar title compact and meaningful. [NSStatusBar](https://developer.apple.com/documentation/appkit/nsstatusbar)
- `[Inference]` Recon's menu bar icon should prioritize state clarity over branding. A tiny status glyph plus accessible tooltip/label is more valuable than a long title.
- `[Evidence]` Apple indicates that more complex or data-rich menu bar experiences may use a window-style extra. Recon's current utility-panel direction is valid, but it should still behave like a lightweight companion, not a miniature dashboard. [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)

### Menu structure and section ordering

- `[Inference]` Recommended top-to-bottom order:
- `[Inference]` 1. Current status: state, one-line reason, last updated.
- `[Inference]` 2. Current target: kubeconfig source, context, namespace, optional environment cue.
- `[Inference]` 3. Active work: intercept summary and, if relevant, daemon/debug status.
- `[Inference]` 4. Primary actions: the one or two actions most relevant in the current state.
- `[Inference]` 5. Secondary utilities: refresh, open logs, copy command, reveal full kubeconfig path.
- `[Inference]` 6. Preferences and automation settings.
- `[Inference]` 7. Footer: version, maybe diagnostics/help, quit.

### Density and width

- `[Inference]` Keep the default surface narrow enough to scan quickly and wide enough to avoid wrapping high-signal metadata. For Recon's data model, roughly 320-380 pt is a sensible target.
- `[Inference]` The menu should privilege 2-3 lines of high-signal status over more rows of low-signal detail. If a section needs scrolling, search, or large tables, it belongs in another window.
- `[Evidence]` Tailscale's move to a separate window was driven in part by menu limitations around feature discovery and richer interaction. [Tailscale's windowed macOS UI is now in beta](https://tailscale.com/blog/windowed-macos-ui-beta)

### Labels and action patterns

- `[Evidence]` Apple menu guidance favors direct, conventional item naming and uses ellipses when an item opens another surface or requires further input. Recon should keep labels literal: `Choose Kubeconfig...`, `Preferences...`, `Open Logs...`. [Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
- `[Inference]` Make one action primary per state:
- `[Inference]` Disconnected: `Connect`
- `[Inference]` Connected: `Reconnect` or `Disconnect`
- `[Inference]` Error: `Reconnect` and `Open Logs...`
- `[Inference]` Busy: disable mutating actions and show progress
- `[Inference]` This reduces button clutter versus giving equal visual weight to every action all the time.

### Disabled states

- `[Inference]` Prefer disabled over hidden for core actions such as `Disconnect` or `Reconnect` when the disabled state teaches the model of what the app can do.
- `[Inference]` If an action is disabled for a non-obvious reason, pair it with short explanatory text nearby rather than a silent gray button.

### Preferences handling

- `[Evidence]` Once a menu bar utility accumulates more settings and troubleshooting needs, richer UI often moves to a dedicated settings or utility window. Tailscale's redesign is a concrete example. [Tailscale's windowed macOS UI is now in beta](https://tailscale.com/blog/windowed-macos-ui-beta)
- `[Inference]` Recon can keep a few high-frequency toggles in-menu for now, but if preferences continue to grow, `Preferences...` should open a dedicated window instead of expanding the popup further.
- `[Opinion]` The in-menu accordion works for today's scope, but it is close to its natural limit.

### Footer usage

- `[Inference]` The footer should be quiet and utilitarian: version, help/diagnostics entry point, quit.
- `[Inference]` Avoid loading the footer with marketing copy, links, or decorative text. This is a control surface, not a landing page.

### Notifications

- `[Evidence]` Apple recommends being careful and realistic about notifications and interruption. [Notifications](https://developer.apple.com/design/human-interface-guidelines/notifications)
- `[Inference]` Recon notifications should be opt-in or tightly scoped.
- `[Inference]` Good notification cases: unexpected disconnect, auto-reconnect failure, successful recovery after failure, action-blocking environment issue.
- `[Inference]` Poor notification cases: every refresh, every successful connect on launch, every routine state poll.

### What makes it feel native

- `[Evidence]` Apple recommends not relying on color alone and respecting platform conventions. [Color](https://developer.apple.com/design/human-interface-guidelines/color)
- `[Inference]` For Recon, "native" means:
- `[Inference]` Use standard macOS terminology and labels.
- `[Inference]` Keep the menu calm and sparse.
- `[Inference]` Pair color with shape/text for status.
- `[Inference]` Respect system appearance and notification conventions.
- `[Inference]` Avoid custom-styled chrome unless it clearly improves comprehension.

## 7. Telepresence-Specific Recommendations

### What Recon should expose directly

- `[Evidence]` Connection state: connected, disconnected, busy, unavailable, error. [Telepresence CLI reference](https://telepresence.io/docs/reference/cli/telepresence)
- `[Evidence]` Current Kubernetes context and namespace, because Telepresence itself treats those as core status. [Telepresence CLI reference](https://telepresence.io/docs/reference/cli/telepresence)
- `[Evidence]` Intercept visibility, at minimum as a count and optionally a read-only list, because `telepresence status` presents intercepts as part of normal status. [Telepresence engagements CLI](https://telepresence.io/docs/reference/engagements/cli)
- `[Inference]` Last meaningful error with a next step.
- `[Inference]` Quick access to logs or a diagnostic bundle path.
- `[Inference]` Whether Recon is following an inherited environment or using a pinned kubeconfig source.

### What Recon should not expose directly

- `[Opinion]` Full intercept creation, service/port selection, multi-port mapping, `replace`, `ingest`, `wiretap`, and other advanced workload engagement flows.
- `[Opinion]` Traffic Manager install/upgrade/Helm management.
- `[Opinion]` Low-level networking flags such as routed subnet manipulation, VNAT rules, or proxy routing knobs.
- `[Opinion]` Cluster browsing or Kubernetes object inspection. That pulls Recon toward becoming a dashboard instead of a helper.

### What should remain a CLI escape hatch

- `[Evidence]` Telepresence has mature CLI status, list, connect, leave, and diagnostic flows already. [Telepresence CLI reference](https://telepresence.io/docs/reference/cli/telepresence), [Telepresence engagements CLI](https://telepresence.io/docs/reference/engagements/cli)
- `[Inference]` Recon should provide fast escape hatches such as:
- `[Inference]` `Open Logs...`
- `[Inference]` `Copy 'telepresence status'`
- `[Inference]` `Copy 'telepresence list'`
- `[Inference]` `Copy diagnostic command`
- `[Inference]` `Reveal kubeconfig path`
- `[Inference]` This lets power users recover in familiar territory without abandoning the helper app entirely.

### Tradeoffs

- `[Opinion]` Showing daemon state directly is useful for debugging, but probably too low-level for the default top section.
- `[Inference]` Best compromise: keep default status human-readable, with an optional advanced/debug subsection or secondary window for root daemon, user daemon, Traffic Manager, and raw session details.

## 8. kubectl / Kubeconfig / Context Recommendations

### What metadata should be shown

- `[Evidence]` Kubeconfig source. Kubernetes supports default config, explicit file, or merged files via `KUBECONFIG`. The app should say which mode it is in. [Organizing Cluster Access Using kubeconfig Files](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/)
- `[Evidence]` Current context, exactly as kubectl resolves it. [kubectl config reference](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_config/)
- `[Evidence]` Current namespace, because it changes the default scope of commands and is easy to forget. [Namespaces](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)
- `[Inference]` If possible, a higher-level environment cue derived from context naming or user-supplied labels such as `prod`, `staging`, `dev`, but never in place of the raw context name.
- `[Inference]` If multiple kubeconfig files share the same basename, show enough parent-path context to disambiguate them.

### What risky actions need extra clarity

- `[Evidence]` Switching kubeconfig sources can change cluster access, credentials, contexts, and default namespace in one move. [Organizing Cluster Access Using kubeconfig Files](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/)
- `[Inference]` If Recon reconnects after kubeconfig selection, the UI should say so explicitly before or during the action.
- `[Inference]` Any future context/namespace switching UI should warn when it mutates shared kubeconfig state rather than only app-local state.
- `[Inference]` Auto-connect on launch is riskier than it looks in multi-environment teams because it can silently reconnect to yesterday's target.
- `[Opinion]` Anything that could plausibly point a user at production should be visually louder than ordinary state changes.

### What defaults are safest

- `[Inference]` Default to read-only visibility for context and namespace before offering mutation.
- `[Inference]` Default `launch at login` to off.
- `[Inference]` Default `auto-connect on launch` to off.
- `[Inference]` Default `auto-reconnect` to off unless user explicitly opts in.
- `[Inference]` Default notifications to off or to a very narrow set of failure/recovery events.
- `[Opinion]` Prefer "follow current kubectl context" only if Recon can show that mode clearly. Otherwise, "pinned kubeconfig source" is easier to trust because it is explicit.

## 9. Actionable Product Recommendations For Recon

### Recommended now

- `[Evidence]` Recon's current scope is already directionally correct for a menu bar helper: it focuses on connect/disconnect/reconnect, status visibility, kubeconfig selection, lightweight automation, and notifications rather than trying to replace Telepresence wholesale.
- `[Inference]` Keep Recon tightly focused on truth and recovery: status, target, reconnect path, and diagnostics.
- `[Inference]` Make target metadata a named top-level section: `Kubeconfig`, `Context`, `Namespace`. These terms match user mental models better than a generic `connection` label.
- `[Inference]` Add intercept visibility soon, but start read-only: `No active intercepts`, `1 active intercept`, or a compact list of names.
- `[Inference]` Add `Open Logs...` and a simple CLI escape hatch such as `Copy 'telepresence status'`.
- `[Inference]` Distinguish kubeconfig modes:
- `[Inference]` `Pinned kubeconfig: /path/to/file`
- `[Inference]` `Inherited KUBECONFIG: 3 files`
- `[Inference]` `Default kubeconfig: ~/.kube/config`
- `[Inference]` This is especially important because advanced users often merge configs and can have multiple files named `config`.
- `[Inference]` Make the reconnect side effect explicit on kubeconfig change: "Switching kubeconfig reconnects Telepresence."
- `[Inference]` Keep `Refresh` strictly non-mutating.
- `[Inference]` Tighten notification policy to only unexpected disconnects, failed auto-reconnect, and successful recovery after failure.
- `[Opinion]` Respect macOS appearance instead of forcing a custom visual mode. A background utility gains trust by feeling like part of the system.

### Medium-term improvements

- `[Inference]` Move growing preferences and diagnostics into a dedicated `Preferences...` or `Details...` window before the popup becomes too tall.
- `[Inference]` Add an advanced/debug area that can show daemon state, raw session details, Traffic Manager connectivity, and recent error history without burdening the default view.
- `[Inference]` Add production-safety cues based on context naming conventions or user-defined labels.
- `[Inference]` Add a hidden advanced affordance for power users, such as an Option-modified menu section or "Advanced..." entry, similar to how Tailscale keeps debug functionality available without cluttering the primary surface. [Troubleshooting guide](https://tailscale.com/docs/reference/troubleshooting)
- `[Opinion]` Consider a small onboarding/health-check flow that validates Telepresence path, kubectl path, kubeconfig source, notification permission, and login item state on first run.

### Nice-to-have ideas

- `[Opinion]` Show recent targets or remembered safe targets.
- `[Opinion]` Let users attach friendly labels or colors to contexts while preserving raw context names.
- `[Opinion]` Add a "recommended next command" row for common failures.
- `[Opinion]` Add a compact diagnostics history so users can tell whether reconnect loops are frequent or one-off.

### Avoid for now

- `[Opinion]` Full intercept creation and editing UI.
- `[Opinion]` Writing kubectl context or namespace changes back into shared kubeconfig from the menu bar.
- `[Opinion]` Cluster browser, namespace explorer, pod list, or log tailer features.
- `[Opinion]` Automated "magic fixups" for network/routing problems that users cannot inspect or understand.
- `[Opinion]` A larger pseudo-dashboard living permanently behind the menu bar popup.

## 10. Open Questions / Unknowns

- `[Inference]` Do Recon users want the app to follow their shell's active kubeconfig/context, or do they want Recon to be explicitly pinned and independent?
- `[Inference]` How often are failures due to wrong target selection versus Telepresence daemon/routing problems?
- `[Inference]` Is intercept visibility enough as a count, or do users actually need a read-only intercept list in the primary UI?
- `[Inference]` Would users prefer auto-reconnect off forever, or only until the app proves it is predictable?
- `[Inference]` Do teams have reliable context naming conventions that allow safe `prod` / `staging` / `dev` cues?
- `[Opinion]` At what point does Recon need a second window for diagnostics/preferences rather than continuing to grow inside the popup?

## Design Rules For Recon

- `[Inference]` One glance should answer: connected, to what, safe or risky.
- `[Inference]` Show the real target nouns: kubeconfig, context, namespace.
- `[Inference]` Do not silently mutate shared cluster state.
- `[Inference]` Keep `Refresh` observational and `Reconnect` intentional.
- `[Inference]` Default to visibility before automation.
- `[Inference]` Pair color with text or symbol; never color alone.
- `[Inference]` If an error has no next step, the UI is incomplete.
- `[Inference]` Use the menu bar for fast control; move search-heavy or debug-heavy work to another window or the CLI.
- `[Inference]` If a feature needs a long explanation, it probably does not belong in the default popup.

## Sources

- Apple: [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- Apple: [NSStatusBar](https://developer.apple.com/documentation/appkit/nsstatusbar)
- Apple: [Human Interface Guidelines - Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
- Apple: [Human Interface Guidelines - Notifications](https://developer.apple.com/design/human-interface-guidelines/notifications)
- Apple: [Human Interface Guidelines - Color](https://developer.apple.com/design/human-interface-guidelines/color)
- Telepresence: [CLI reference](https://telepresence.io/docs/reference/cli/telepresence)
- Telepresence: [Configure workload engagements using CLI](https://telepresence.io/docs/reference/engagements/cli)
- Telepresence: [DNS resolution](https://telepresence.io/docs/reference/dns)
- Kubernetes: [Organizing Cluster Access Using kubeconfig Files](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/)
- Kubernetes: [kubectl config reference](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_config/)
- Kubernetes: [Namespaces](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)
- Comparable tool: [Tailscale's windowed macOS UI is now in beta](https://tailscale.com/blog/windowed-macos-ui-beta)
- Comparable tool: [Manage client preferences - Tailscale](https://tailscale.com/docs/features/client/manage-preferences)
- Comparable tool: [Troubleshoot Tailscale icon not appearing](https://tailscale.com/docs/reference/troubleshooting/apple/macos-doesnt-display-tailscale-icon)
- Comparable tool: [Troubleshooting guide - Tailscale](https://tailscale.com/docs/reference/troubleshooting)
- Comparable tool: [Docker Desktop CLI](https://docs.docker.com/desktop/features/desktop-cli/)
- Comparable tool: [OrbStack](https://orbstack.dev/)
- Practitioner evidence: [telepresence issue #2689: kubeconfig has no context definition](https://github.com/telepresenceio/telepresence/issues/2689)
