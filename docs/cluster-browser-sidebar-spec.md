# Cluster Browser — Sidebar Navigation Spec

## Purpose

This document proposes a revised cluster browser model for Recon:

- the **cluster browser is separated from Telepresence kubeconfig selection**
- the browser uses a **left sidebar for contexts and namespaces**
- the browser supports **fast switching between clusters/namespaces**
- the design leaves room for **multiple windows** and future **comparisons**

This is a companion spec to:

- [Cluster Browser — Product Brief](./cluster-browser-product-brief.md)
- [Cluster Browser — Spec](./cluster-browser-spec.md)
- [Cluster Browser — Implementation Plan](./cluster-browser-implementation-plan.md)

## Problem

The current cluster browser direction assumes the browser should inherit the same kubeconfig source that Telepresence uses.

That creates a bad fit for real usage:

- many users only have Telepresence access to QA
- those same users may still have `kubectl` access to other contexts such as staging or production
- switching the Telepresence kubeconfig just to browse another cluster is disruptive and risky
- a single top-bar namespace picker does not scale well when users want to move between several contexts quickly

Recon should treat cluster browsing as its own workflow, not as a side effect of Telepresence configuration.

## Summary

The browser becomes a two-pane window:

```text
┌──────────────┬──────────────────────────────────┐
│ qa           │ Pods  Deployments  Services ...  │
│  ├ test    ● │ ┌──────────────────────────────┐ │
│  └ staging   │ │ NAME        STATUS    READY  │ │
│ prod-eu1     │ │ ...                          │ │
│  └ default   │ └──────────────────────────────┘ │
│              │ 42 pods      ctx: qa  ns: test  │
└──────────────┴──────────────────────────────────┘
```

The left side answers:

- which browser-visible contexts exist?
- which namespace is selected for each context?
- which context/namespace is active right now?

The right side answers:

- what resources are in that namespace?
- what looks unhealthy?
- what actions can I take?

## Goals

1. Decouple cluster browsing from Telepresence kubeconfig selection.
2. Let users preload the kubeconfig files they want available in the browser.
3. Make context and namespace switching much faster than the current picker model.
4. Preserve Recon's fast, native, low-memory behavior.
5. Make the active target obvious before any action is taken.
6. Set up future multi-window and comparison workflows without forcing them into V1.

## Non-Goals

- Replacing Telepresence connection settings
- Auto-merging all kubeconfig files on the machine by default
- Background watches across every loaded context
- Full topology or graph view
- Cluster comparison in V1

## Core UX Model

### Window Layout

The browser window has three major regions:

1. **Sidebar**
   Shows browser contexts and expandable namespaces.
2. **Main content**
   Shows resource tabs, filter, refresh, table, errors, and empty states.
3. **Status bar**
   Shows resource count, active context, active namespace, and optional source metadata.

### Sidebar Structure

The sidebar is a tree:

- top level: **contexts**
- second level: **namespaces**

Example:

```text
qa
  test
  staging
prod-eu1
  default
  payments
stg-us
  default
```

The selectable unit is the namespace row. Selecting a namespace activates one browser target:

- context = `qa`
- namespace = `test`

### MVP Decision: Parent Context Rows Are Selectable

The parent context row is selectable in V1.

Selecting a context row directly activates:

1. that context's remembered namespace, if one exists
2. otherwise the kubeconfig default namespace for that context
3. otherwise `default`

This keeps the common path fast:

- one click to jump into a context
- no forced expand-then-wait-then-click flow just to reach the default namespace

### Main Content

The main content keeps the existing browser mental model:

- resource tabs
- filter field
- refresh button
- native table
- loading, error, and empty states
- health-first ordering
- copy command and later resource actions

The big change is that the top bar no longer needs to do all navigation work.

### Status Bar

The status bar remains important and should still show:

- resource count
- `ctx: <context>`
- `ns: <namespace>`

It may also optionally show:

- source kubeconfig label when helpful
- a prod indicator for production-like contexts or namespaces

## Browser Configuration

### Separate Browser Sources

Recon gets a dedicated browser setting:

- **Browser kubeconfig sources**

This is a list of kubeconfig files the browser is allowed to load from.

This setting is separate from:

- Telepresence kubeconfig mode
- Telepresence pinned kubeconfig path

Changing browser sources must not reconnect Telepresence or otherwise affect the Telepresence controller.

### Why Sources, Not Just Envs

Users think in terms of environments like QA, STG, and PROD, but kubeconfig files can contain multiple contexts.

That means the configuration flow should be:

1. user adds one or more kubeconfig files
2. Recon reads the available contexts from those files
3. the sidebar displays contexts, not raw file names

If two files contain contexts with the same name, Recon should disambiguate them in the UI with a subtle source label.

### MVP Decision: Merge Browser Sources

For MVP, browser kubeconfig sources are treated as one browser-visible context catalog.

That means:

- users add one or more kubeconfig files to the browser
- Recon reads all contexts from those files
- the sidebar shows one combined list of contexts
- users do not need to think about file boundaries during normal browsing

Source file metadata is still retained internally and may be shown when needed:

- to disambiguate duplicate context names
- to help users debug where a context came from
- to support future settings or diagnostics UX

The browser should not require users to manually switch between isolated file scopes in V1.

## Browser Session Model

The browser owns its own active target state:

- active kubeconfig source set
- active context
- active namespace
- remembered namespace per context
- expanded/collapsed sidebar state

This state belongs to the cluster browser, not to Telepresence.

### Persistence

Persist:

- browser kubeconfig source list
- last selected context
- last selected namespace per context
- recently visited namespaces per context

Do not persist:

- loaded resource tables
- fetched namespace lists beyond lightweight session caches
- background cluster sessions

## Data Loading Model

### Context Loading

On browser open:

1. load configured browser kubeconfig files
2. resolve contexts from those files
3. build sidebar context list
4. restore the previously selected context/namespace if still valid
5. fetch namespaces only for the selected or expanded context
6. fetch resources only for the active namespace

### Lazy Namespace Loading

Namespaces should load lazily per context.

Do not query namespaces for every context immediately. Instead:

- fetch namespaces when a context is expanded
- fetch namespaces when a context is selected
- cache the result for the current browser session
- clear the cache when the browser window closes

This keeps the browser responsive when many contexts are configured.

### Resource Loading

Resource loading stays as it is conceptually:

- one active context
- one active namespace
- one active resource type
- no speculative prefetching of hidden tabs

All `kubectl` commands for the browser use the browser's own kubeconfig/context selection.

## Sidebar States

The sidebar should communicate more than selection state. In V1, each context row may also have a lightweight state:

- normal
- loading namespaces
- unreachable or error

This prevents the main pane from being the only place errors appear.

### Unreachable Contexts

A configured context may exist in kubeconfig but still be unusable at runtime:

- cluster endpoint unreachable
- expired or missing credentials
- VPN or network dependency missing
- context references broken auth setup

In that case:

- the context remains visible in the sidebar
- selecting it still activates the target
- the main pane shows the concrete error for the attempted namespace/resource fetch
- the sidebar row also shows an error marker so the failure is clearly attached to that context

The goal is to avoid a confusing experience where the user sees a valid-looking context in the sidebar but only gets a generic error elsewhere.

### Namespace Loading Feedback

When a context is expanded and namespaces are loading:

- show a lightweight spinner or loading affordance on the context row
- keep the UI interactive
- avoid blocking other contexts or the current main-pane session

## Safety Model

### Production Visibility

Production-like contexts and namespaces should be visually obvious in the sidebar.

### MVP Decision: Sidebar Indicator First

For MVP, production visibility should use a simple, persistent sidebar indicator on the context row:

- colored dot
- tinted badge
- similarly lightweight high-signal marker

This should ship in the first version because it is low effort and always visible during navigation.

A larger warning banner in the main pane can be added later if real usage shows it is needed.

The goal is not to block users. The goal is to reduce accidental mistakes.

### Telepresence Separation

The cluster browser must never imply that its selected context is also the Telepresence target.

If helpful, the UI can make this explicit:

- browser target shown in the browser window
- Telepresence target shown in the menu bar popover

These are related tools, but different sessions.

## Multi-Window And Comparison

### Recommendation

Do not build a dedicated compare mode first.

Instead, make the sidebar/browser model compatible with:

- multiple browser windows
- each window having its own selected context and namespace

That immediately enables useful workflows:

- keep QA open in one window
- keep STG open in another
- manually compare health or rollout state

### Future Compare Hooks

If comparison is added later, this design supports it well:

- "Open in New Window"
- "Duplicate Window to Another Context"
- "Compare With..."

A true side-by-side compare view can be deferred until users prove they need more than two independent windows.

## Proposed Settings UX

Add a browser-specific settings section such as:

- **Browser kubeconfig sources**
- list of configured files
- add file
- remove file
- optionally reorder files

Optional future controls:

- auto-expand selected context
- show only favorite namespaces
- highlight production contexts

Do not mix these controls into the Telepresence kubeconfig section without clearly separating them.

## Proposed Window UX

### Sidebar Behavior

- selecting a namespace updates the main content immediately
- selected context expands automatically
- the active namespace gets a strong selected state
- the last selected namespace is remembered per context
- empty namespace results show a friendly per-context error
- context rows may show loading or error state

### Sidebar Width

The sidebar should be user-resizable in V1.

This matters because real context names are often long and messy, for example:

- EKS or GKE-generated names
- ARNs
- team-specific environment prefixes

When names do not fit:

- truncate gracefully in the row
- show the full value on hover or tooltip
- preserve badges and state markers in the visible portion of the row

### Main Pane Behavior

- tabs remain local to the window
- filter text remains local to the window
- refresh acts on the active context/namespace only
- copy-command actions use the active browser target only

## Technical Direction

### High-Level Shape

Introduce browser-specific state rather than reusing the Telepresence selection model directly.

### MVP Decision: Start With One Browser Config Service

For MVP, prefer a smaller service surface:

- `BrowserConfigService`
  Owns browser kubeconfig source list, resolves contexts, keeps source metadata, and builds the browser command environment.
- `ClusterBrowserSessionViewModel`
  Owns the active context, active namespace, sidebar state, namespace caches, and resource loading.

This is enough to validate the architecture without over-layering too early.

If responsibilities actually diverge later, `BrowserConfigService` can be split into narrower services.

The non-negotiable architectural rule is still:

- Telepresence and the browser must not share one kubeconfig-selection state machine

### Command Behavior

Browser `kubectl` commands should run with:

- browser kubeconfig paths
- explicit browser context when needed
- browser namespace

That means a browser request should be able to say, in effect:

- use these kubeconfig files
- target this context
- query this namespace

without modifying the Telepresence command environment.

## Migration Strategy

1. Keep the current resource tables and browser view model behavior where possible.
2. Replace the top-level context/namespace assumption with browser-owned target state.
3. Add sidebar navigation.
4. Add browser-specific settings for kubeconfig sources.
5. Preserve existing status bar and health-first table behavior.
6. Add multi-window support after the sidebar model is stable.

## MVP Recommendation

The first good version of this design should include:

- browser-specific kubeconfig source list
- merged browser-visible context catalog from those sources
- sidebar with contexts
- selectable parent context rows
- lazy-loaded namespaces under each context
- remembered namespace per context
- sidebar loading/error state
- sidebar production indicator
- resizable sidebar with truncation plus tooltip handling
- existing resource tabs and table behavior
- clear status bar target display

It should not require:

- built-in comparison mode
- split-pane compare UI
- Telepresence integration changes

## Success Criteria

This design is working if users can:

- browse STG or PROD without disturbing Telepresence
- switch between contexts/namespaces in one or two clicks
- keep a stable mental model of where they are
- leave two browser windows open for QA and STG when needed
- trust that browser actions target the visible context and namespace only

## Open Questions

1. When context names collide across files, should the sidebar stay flat with source badges, or should those collisions create a grouped substructure?
2. Should unreachable contexts keep their last known namespace children visible, or collapse to a context-only error row?
3. For future mutating actions, should production-like targets get stronger confirmation than non-production targets?
4. Should multi-window ship alongside the sidebar redesign, or immediately after it?
