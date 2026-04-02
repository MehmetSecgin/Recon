# Cluster Browser — Product Brief

## Summary

Recon should be the fastest macOS helper for routine Kubernetes checks and actions.

This feature is not trying to replace Lens, K9s, or a full terminal workflow. It should win the "2-minute Kubernetes task": open the app, confirm context and namespace, spot what is unhealthy, and take one safe action without memorizing `kubectl` syntax.

## Market Context

### What existing tools are good at

- **Lens** is the broad, full-featured Kubernetes IDE. It is strong when users want a deep control surface, lots of resource views, and long-lived cluster sessions.
- **OpenLens** is no longer a strong strategic benchmark. The open source product path has effectively stalled, so it is mostly useful as a historical UX reference.
- **K9s** is the speed benchmark for operator workflows. It wins on keyboard-first navigation, density, and low-latency feedback for people who already think in Kubernetes primitives.
- **Headlamp** is the strongest open source GUI reference. It points toward app-centric views, relationship-aware navigation, and keeping users in task flow instead of making them constantly jump between screens.
- **Raw terminal + kubectl** remains the source of truth for most engineers. Real usage is usually short bursts of commands, not full-session dashboard usage.

### What that means for Recon

Recon should not try to out-feature Lens or out-density K9s.

Recon should instead be:

- faster to open than a heavy desktop UI
- easier to use than a terminal-first tool
- safer than ad-hoc `kubectl` for destructive actions
- more focused than a full dashboard

## Product Positioning

**Recon Cluster Browser** is a lightweight Kubernetes helper for simple operational flows.

It answers:

- What is running in this namespace?
- What looks unhealthy?
- Why does it look unhealthy?
- What is the safest next action?

It should feel like a native, low-friction companion to `kubectl`, not a replacement for it.

## Target Users

### Primary

- Application engineers who use Kubernetes regularly but do not want to live in a cluster UI all day
- Developers who already use Telepresence and need quick visibility into the active cluster they are working against
- Engineers who currently bounce between menu bar status, a terminal, and a heavyweight GUI for short operational tasks

### Secondary

- Platform or DevEx-minded developers who want a fast local helper for routine checks
- Engineers who know K9s or Lens well enough to appreciate speed, but do not need their full feature sets for common tasks

## Core Jobs To Be Done

1. Confirm the current context and namespace before doing anything risky.
2. Quickly find a deployment, pod, service, or ingress by name.
3. See which workloads are unhealthy without manually reading large tables.
4. Understand the likely reason for an unhealthy workload in one line.
5. Restart a deployment safely.
6. Scale a deployment without remembering flags.
7. Delete a broken pod with clear confirmation.
8. Port-forward a pod or service without terminal syntax.
9. Move between related resources for the same workload.
10. Copy the equivalent `kubectl` command when needed for trust, learning, or handoff.

## Product Principles

1. **Health first** — Surface problems before complete inventory.
2. **Context always visible** — Context and namespace should never be easy to miss.
3. **One safe action away** — The UI should help the user take the likely next action immediately.
4. **Native and low-latency** — The app should feel closer to K9s responsiveness than to a large webview desktop app.
5. **Trust through transparency** — Users should always be able to understand what Recon is doing and map it back to `kubectl`.
6. **Small surface area, high confidence** — Prefer a narrow set of excellent flows over broad, shallow coverage.

## UX Direction

### Patterns to borrow

From **K9s**:

- keyboard-first navigation
- instant filtering
- low-latency refresh and action feedback
- shortcuts that become muscle memory

From **Lens**:

- clear resource tables
- obvious action affordances
- polished row-level inspection
- strong context and cluster framing

From **Headlamp**:

- relationship-oriented navigation
- lightweight app or workload grouping
- staying in task flow instead of forcing drill-in and drill-out loops

From **terminal workflows**:

- deterministic actions
- explicit resource targeting
- easy copying of the generated `kubectl` command

### Product tone

The browser should feel:

- practical, not dashboard-y
- opinionated, not noisy
- safe for production-aware workflows
- helpful for users who do not remember exact CLI syntax

## Feature Strategy

### V1: Great helper for simple flows

Implementation sequencing lives in [Cluster Browser — Implementation Plan](./cluster-browser-implementation-plan.md).

Ship the smallest set that makes Recon materially useful for everyday Kubernetes work:

- Pods, Deployments, Services, Ingresses
- Strong context and namespace display
- Unhealthy-first sorting or filtering
- Fast search
- Row-level health signals and status reasons
- Relationship hints between resources for the same workload
- Actions: restart deployment, scale deployment, delete pod, port-forward
- Keyboard shortcuts for common actions
- Active port-forward management
- Copy the equivalent `kubectl` command for actions and selections

### V1.5: Better decision support

Add just enough extra context to reduce guesswork:

- rollout summary for deployments
- last meaningful event summary
- obvious "why unhealthy?" details
- recent or favorite namespaces
- quick filters such as "Only unhealthy"

### V2: Stronger workload understanding

Expand only if V1 proves users want more:

- workload-centric grouping when labels/owners make it clear
- lightweight dependency view: deployment -> pods -> service -> ingress
- recent actions/history
- read-only helper suggestions based on current object state

## Non-Goals

These are intentionally not the product direction for this feature:

- full Kubernetes dashboard replacement
- embedded shell or `kubectl exec`
- general-purpose YAML editor
- full logs product
- CRD explorer for every custom resource
- background watchers everywhere
- cluster-wide observability or metrics platform

## Why this should work for Recon

Recon already has two strong advantages:

- it is a native app with a menu bar home, so it is already present in the user's workflow
- it already knows about kubeconfig, context, namespace, and local cluster tooling

That means Recon can win by reducing switching cost:

- less need to open a heavy GUI
- less need to remember command syntax
- less chance of acting in the wrong namespace
- fewer steps between "something looks wrong" and "take the safe next action"

## Success Criteria

This feature is succeeding if users can do the following faster than with their current mix of tools:

- identify unhealthy workloads
- confirm active context and namespace
- restart or scale a deployment
- delete a broken pod
- start and stop a port-forward

Qualitatively, success looks like:

- "I only open Lens for deep debugging now."
- "I do not need to remember the command for routine actions."
- "I trust this for quick checks before or during Telepresence work."

## Research Notes

This brief is informed by the current tool landscape as of **March 30, 2026**:

- Lens remains the main commercial Kubernetes desktop IDE and continues shipping broad cluster-management features.
- OpenLens is no longer an active forward-looking benchmark.
- K9s continues to define the speed and keyboard-first terminal experience.
- Headlamp is the strongest open source GUI reference and has moved toward app-centric and relationship-aware UX.
- `kubectl` remains the dominant execution model for short operational tasks, with tools like `kubectx`, `kubens`, `stern`, and `popeye` filling specific gaps.

## References

- [Lens product overview](https://lenshq.io/products/lens-k8s-ide)
- [Lens 2026.1 release notes](https://docs.k8slens.dev/release-notes/lens-k8s-ide/lens-2026-1-161237/)
- [OpenLens binary repo note](https://github.com/MuhammedKalkan/OpenLens)
- [K9s](https://k9scli.io/)
- [K9s hotkeys](https://k9scli.io/topics/hotkeys/)
- [K9s commands](https://k9scli.io/topics/commands/)
- [Headlamp](https://headlamp.dev/)
- [Headlamp GitHub](https://github.com/kubernetes-sigs/headlamp)
- [Headlamp in 2025 project highlights](https://kubernetes.io/blog/2026/01/22/headlamp-in-2025-project-highlights/)
- [kubectl reference](https://kubernetes.io/docs/reference/kubectl/)
- [kubectl port-forward reference](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_port-forward/)
- [kubectx](https://github.com/ahmetb/kubectx)
- [stern](https://github.com/stern/stern)
- [Popeye](https://github.com/derailed/popeye)
