# Cluster Browser UI/UX Research

Research compiled for the Recon cluster browser window. Focused on native macOS patterns, keyboard-first design, and perceived performance for a SwiftUI utility window showing Kubernetes resources (pods, deployments, services, ingresses).

---

## 1. Reference App Analysis

### Activity Monitor
- **Layout:** Five tabs across the top (CPU, Memory, Energy, Disk, Network), each switching a full-window table view. Bottom section has a persistent real-time graph with summary statistics.
- **Status colors:** Memory pressure graph uses green/yellow/red semantic colors. CPU usage differentiates system (red) vs user (blue). Unresponsive processes are highlighted red.
- **What to borrow:** The tab-per-resource-type pattern maps directly to our Pods/Deployments/Services/Ingresses tabs. The bottom-of-window summary bar (count + context indicator) is the same pattern we need. Status colors are semantic, not decorative — green means healthy, red means broken. No ambiguity.

### Console.app
- **Filtering:** Fast incremental filter across streaming log data. Filter toolbar stays fixed; content scrolls independently.
- **What to borrow:** The separation of filter controls from content — a fixed toolbar with search/filter that does not scroll with the data. Console proves that type-to-filter with immediate results is the expected Mac pattern for data-heavy utility windows.

### Finder List View
- **Keyboard navigation:** Arrow keys move selection. Type-ahead jumps to matching items. Column headers are clickable for sorting with ascending/descending toggle indicators. Enter renames (not opens — Return is the "confirm" key on Mac).
- **What to borrow:** Clickable column headers with sort direction arrows. Arrow key navigation for row selection. The convention that Enter/Return triggers the primary action on a selected item (in our case, this could open the detail/action context for a resource).

### Transmit / Forklift (File Browsers)
- **Actions:** Context menus on right-click with the most common actions. Toolbar has quick-action buttons for frequent operations. Double-click navigates into/opens the selected item.
- **What to borrow:** Context menu as the primary action surface. Toolbar buttons only for the most universal actions (Refresh, Filter). Resource-specific actions live in the context menu, not cluttering the toolbar.

### TablePlus / Postico (Database Browsers)
- **Layout:** Tab bar for switching between tables/views. Inline data editing. Quick jump to any table via search. Filter bar at the top of the content view. Footer shows row count and connection info.
- **Postico's simplicity:** Footer buttons for switching between Content/Structure/DDL views — a lightweight alternative to tabs for sub-views.
- **What to borrow:** The footer/status bar pattern: row count on the left, connection/context info on the right. This directly maps to "42 pods | context: prod-cluster". TablePlus's quick-jump (Cmd+P to jump to any table) is analogous to our Cmd+1/2/3/4 tab switching.

### Tower / Fork (Git Clients)
- **Status indicators:** Fork shows a dot/star in tabs when the repo has uncommitted changes. Tower uses contextual branch coloring — branches get distinct colors for visual tracking.
- **Context menus:** Rich right-click menus on files and branches with copy path, reveal in Finder, open in editor.
- **What to borrow:** The status dot in tabs — we could show a colored dot on the Pods tab when unhealthy pods exist, giving an at-a-glance signal without switching tabs. Context menus with "Copy kubectl command" as an action (analogous to "Copy file path").

### Proxyman (Network Inspector)
- **Layout:** Three-panel: source list (left sidebar with domains), flow list (center with request rows), flow content (right with request/response details). Advanced multi-criteria filtering (protocol, content-type, URL, headers, body, duration).
- **What to borrow:** The filter approach — combining a text search field with category/scope filters. For our use case, this translates to a search field that filters by name, plus scope pickers (namespace, resource type). Proxyman's attention to following macOS HIG makes it feel immediately familiar.

### Raycast
- **Instant feel:** Sub-500ms startup time. Results appear as you type with zero perceptible lag. The window disappears completely when dismissed (no residual process churn).
- **Architecture:** Built with custom AppKit components (not SwiftUI) for rendering. Uses lightweight Swift view models with bitset-based diffing, translating patches to AppKit. LRU disk cache for extension data.
- **What makes it feel instant vs Spotlight:** (1) Keyboard-first interaction means no mouse targeting delay. (2) Results are pre-indexed and filtered in-memory, not fetched on each keystroke. (3) UI updates happen on every keystroke with no debouncing — the filtering is fast enough to not need it.
- **What to borrow:** Filter the already-loaded resource list in memory (no re-fetch on filter change within an open session). Keep the keyboard-first paradigm: every action reachable without a mouse. Do **not** copy Raycast's keep-the-window-alive strategy for Recon V1; the tech spec intentionally releases cluster state on close.

### 1Password 8
- **Layout:** Sidebar (vaults/categories) + list (items) + detail (selected item). The sidebar can be toggled/collapsed. Search is global across all items.
- **Keyboard navigation:** Cmd+Shift+Space for Quick Access (a Raycast-like overlay). Hold Cmd to see all available shortcuts. Arrow keys navigate the list.
- **What to borrow:** The "hold Cmd to see shortcuts" pattern as a discoverability mechanism. The sidebar-less approach for our V1 (tabs replace the sidebar since we have only 4 resource types — a sidebar would be overkill).

---

## 2. SwiftUI Implementation Patterns

### Table vs List — When to Use Which

**Use SwiftUI `Table` for the cluster browser.** Reasons:
- Table provides native columnar layout with sortable column headers — exactly what `kubectl get pods` output looks like
- Built-in sort indicators in column headers
- Built-in selection (single and multi) with proper macOS highlight styling
- Column width control via `.width(min:ideal:max:)` and fixed `.width()`

**Performance caveats:**
- Pre-filter data before passing to Table. Conditional logic inside ForEach/Table body breaks performance badly. One developer measured a 13-second hang from click-to-select with ~1200 rows when using conditionals in row construction
- Use only the first `KeyPathComparator` for sorting: `newOrder.first` rather than sorting by the full array
- The table itself does not sort — it updates a `@State var sortOrder: [KeyPathComparator<T>]` binding, and you re-sort the data source in `.onChange(of: sortOrder)`

**Key modifiers and types:**
- `Table(data, selection: $selection, sortOrder: $sortOrder) { ... }` — the core declaration
- `TableColumn("Name", value: \.name) { row in Text(row.name) }` — sortable column (the `value:` keypath enables sorting)
- `TableColumn("Status") { row in StatusView(row) }` — non-sortable column (closure without `value:`)
- `.tableStyle(.inset(alternatesRowBackgrounds: true))` — macOS-native alternating row backgrounds
- `.tableStyle(.bordered(alternatesRowBackgrounds: true))` — bordered variant, also macOS-only

### Searchable Modifier for Filtering

- `.searchable(text: $filterText, prompt: "Filter pods...")` — places a search field in the toolbar automatically
- `.searchScopes($scope)` — adds scope buttons below the search field (e.g., filter by status: All, Running, Failed)
- On macOS, the search field integrates into the window's toolbar area
- Use `ContentUnavailableView.search` for the "no results" state — it shows a native empty state with a search icon
- For our case: `.searchable` on the main content view, with filtering applied to the resource array before passing it to Table. The filtering runs on every keystroke against the in-memory array (fast — no debounce needed for <1000 items)

### Tab Bar Styles

**Match the existing Diagnostics window pattern.** The codebase already uses custom capsule-style tabs:
- Capsule fill with `Color(nsColor: .controlBackgroundColor)` for the selected tab
- Plain button style with `.foregroundStyle(Color(nsColor: .labelColor))`
- System image + text label per tab
- This is already implemented in `DiagnosticsWindowView.swift` and should be reused for visual consistency

**Alternative considered — toolbar segmented control:**
- `Picker` with `.pickerStyle(.segmented)` in a `.toolbar { }` renders a native segmented control integrated into the window toolbar
- Pros: more "standard" macOS. Cons: breaks visual consistency with the existing Diagnostics window. Recommendation: keep the capsule tabs for V1, since both windows should look like they belong to the same app

### Context Menus on Table Rows

SwiftUI does not natively support row-level context menus on Table. The workaround:

```swift
// Reusable modifier for table column context menus
extension View {
    func tableColumnContextMenu<MenuItems: View>(
        @ViewBuilder _ menu: () -> MenuItems
    ) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu { menu() }
    }
}
```

Apply to each column's content so the context menu triggers on right-click anywhere in the row, not just on the text. The `.contentShape(Rectangle())` is essential — without it, the hit area is only the text bounds.

### Keyboard Shortcuts

- `.keyboardShortcut("r", modifiers: .command)` — Cmd+R for refresh
- `.keyboardShortcut("f", modifiers: .command)` — Cmd+F for focus search (though `.searchable` may handle this natively)
- `.keyboardShortcut("1", modifiers: .command)` through `.keyboardShortcut("4", modifiers: .command)` — tab switching
- `.keyboardShortcut(.delete)` — Delete key for delete action
- Command (Cmd) is the default modifier — omitting modifiers assumes Cmd

**Standard reserved shortcuts to avoid:**
- Cmd+Q (quit), Cmd+W (close window), Cmd+H (hide), Cmd+M (minimize)
- Cmd+C (copy), Cmd+V (paste), Cmd+X (cut), Cmd+Z (undo)
- Cmd+A (select all), Cmd+F (find — unless we want to use it for our filter)
- Cmd+, (preferences/settings)
- Cmd+N (new window), Cmd+O (open), Cmd+S (save), Cmd+P (print)

**Available for our use:**
- Cmd+R (refresh — standard in browsers, acceptable)
- Cmd+1/2/3/4 (tab switching — standard in tabbed apps)
- Cmd+K (common for command palette / quick actions)
- Cmd+Shift+R (restart deployment — uses Shift to distinguish from plain refresh)
- Delete/Backspace (delete with confirmation)
- / (slash for filter — common in developer tools, used without Cmd modifier)

**Focus management for keyboard navigation:**
- `@FocusState` to track which element has focus (search field vs table)
- `.focused($focusState, equals: .table)` to bind focus to the table
- `.onMoveCommand { direction in }` for arrow key handling in custom views
- As of macOS 14+, custom views are always focusable without requiring system-wide keyboard navigation to be enabled

### NSWindow Configuration for Utility Windows

Based on the existing `DiagnosticsWindowConfigurator` pattern:
- `window.level = .floating` — stays above regular windows
- Hide zoom button: `window.standardWindowButton(.zoomButton)?.isHidden = true`
- `window.isOpaque = false` with `window.backgroundColor = NSColor.windowBackgroundColor`

**Sizing recommendation:**
- The Diagnostics window is 560x520. The cluster browser needs more width for the table columns
- Recommended: 720x520 minimum, allowing comfortable display of Name + Status + Ready + Restarts + Age columns
- Use `.windowResizability(.contentSize)` to constrain resizing to the frame bounds
- Use `.defaultWindowPlacement` to position near the menu bar area

### Status Bar at Bottom of Window

No built-in SwiftUI component for a bottom status bar. Build it as a custom view:
- Fixed height HStack at the bottom of the VStack, separated from the content by a `Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5)` divider
- Left side: resource count ("42 pods")
- Right side: context name + active forwards indicator
- Use `.font(.system(size: 11))` and `.foregroundStyle(.secondary)` for status bar text — smaller than body, lower visual priority

---

## 3. Perceived Performance Patterns

### What Makes Apps Feel Fast

**Fast-feeling open path without retained cluster state:**
- Keep the initial view hierarchy light so opening the window and showing a loading state is cheap
- Rebuild window/view-model state on each open, but keep cluster fetches scoped and deterministic
- Do not retain resource data across close/open cycles; this is a deliberate product constraint, not an accidental limitation

**Immediate feedback on every interaction:**
- When the user switches tabs, immediately show the new tab UI (even if data is loading). Show a loading indicator within the tab's content area rather than a full-window spinner
- When the user types in the filter field, filter the in-memory array on every keystroke. For <1000 items, `String.localizedCaseInsensitiveContains` is effectively instant
- When the user hits Cmd+R to refresh, immediately show a subtle loading indicator (e.g., the refresh button spinning) while keeping the current data visible. Replace data only when the new fetch completes — never flash the list to empty

**Transition design:**
- Never clear existing data to show a loading state. Overlay the loading indicator on existing content, then swap atomically when new data arrives
- Use `.animation(.default, value: resources)` for smooth list transitions rather than abrupt replacement
- When switching namespaces, show a brief inline progress indicator at the top of the table (similar to a web browser's thin loading bar) rather than replacing the content with a spinner

### Loading / Empty / Error States Without Layout Jumps

**The `LoadingState<T>` enum pattern:**
```
enum LoadingState<T> {
    case idle        // window just opened, no fetch yet
    case loading     // fetch in progress
    case loaded(T)   // data arrived
    case failed(String) // fetch failed with error message
}
```

**Preventing layout jumps:**
- Use `ContentUnavailableView` (iOS 17+ / macOS 14+) for empty and error states — it provides a centered, native-looking placeholder that occupies the same space as the content would
- For loading states: keep the Table/List in the view hierarchy with empty data, overlay a `ProgressView()` at center. This means the table headers and status bar stay visible during loading — the structure doesn't jump
- For the "no matching filter results" state: `ContentUnavailableView.search(text: filterText)` gives a native "No Results" view
- For "no resources in namespace": custom `ContentUnavailableView` with an appropriate message
- For errors: custom `ContentUnavailableView` with a retry button

**Skeleton views vs spinners:**
- For the initial load (first time opening the window), a small centered `ProgressView` with "Loading pods..." text is appropriate. Skeletons are overkill for a utility window — the load time should be <1 second
- For subsequent loads (refresh, namespace switch), keep showing stale data with a subtle refresh indicator. Never blank the screen

### What Makes K9s Feel Fast (And What We Can Borrow)

K9s achieves its speed through several patterns:

1. **Single-keystroke navigation:** No modifier keys needed for most actions. `:` opens command mode, `/` starts search, `l` opens logs, `d` describes, `y` shows YAML. Every action is one or two keystrokes away.

2. **Context never changes unexpectedly:** The current view stays stable. Navigation is explicit (you drill into a resource, you press Escape to go back). Data refreshes in-place without resetting scroll position.

3. **Immediate filtering:** `/` starts filtering instantly. Results narrow in real-time. Escape cancels and restores the full list.

4. **Resource-type switching as a command:** Typing `:pods` or `:deploy` switches resource types. This is the command-line equivalent of our Cmd+1/2/3/4 tab shortcuts.

5. **Sorting by column with a single key:** Shift+N sorts by name, Shift+A sorts by age. We can offer clickable column headers for the same effect.

6. **Unhealthy-first sorting:** By default, failing resources bubble to the top. This is a critical UX win — the user opens the window to see what's wrong, not to admire healthy pods.

**What we can borrow for a native Mac app:**
- `/` for instant filter focus (no Cmd modifier — just the slash key when the table has focus)
- Escape to clear filter and return to the full list
- Unhealthy-first as the default sort order
- Keep scroll position on refresh
- In-place data updates (never blank the view to reload)

---

## 4. macOS HIG Relevant Points

### Toolbars
- A toolbar provides convenient access to frequently used commands and controls
- Toolbar items should be the most common actions — not every possible action
- Segmented controls in toolbars render natively when using `Picker` with `.segmented` style inside `.toolbar { }`
- For our window: the toolbar should contain only the search field, refresh button, and namespace picker. Resource-specific actions belong in context menus

### Tables and List Views
- Use alternating row backgrounds for readability in data-dense tables (`.tableStyle(.inset(alternatesRowBackgrounds: true))`)
- Sortable columns should show ascending/descending arrows in their headers — SwiftUI Table handles this automatically when using `sortOrder:`
- Selection highlighting should use the system selection color (automatic with SwiftUI Table)
- Row height is locked to the system default on macOS — do not try to customize it

### Status Indicators and Color Usage
- Use semantic system colors: `.green`, `.orange`, `.red`, `.secondary`
- Do not redefine the semantic meaning of dynamic system colors
- Colors should communicate meaning, not decoration: green = healthy, yellow/orange = transitional/warning, red = error/unhealthy, gray = neutral/terminal
- Our existing Diagnostics window already uses this pattern with `Circle().fill(color).frame(width: 8, height: 8)` for status dots — reuse this exact pattern for resource health indicators in table rows
- Use `.foregroundStyle(.primary)`, `.foregroundStyle(.secondary)`, `.foregroundStyle(.tertiary)` for text hierarchy — these adapt to light/dark mode automatically

### Context Menu Conventions
- Right-click (or Control-click) on any item should show relevant actions
- Menu items should be grouped logically with separators (use `Divider()` in SwiftUI context menus)
- Destructive actions should be at the bottom of the menu, visually separated
- Destructive actions should use red text: `.foregroundStyle(.red)` or the `role: .destructive` parameter on `Button`
- Disabled actions that the user lacks permission for should be hidden entirely (our spec already calls for this via RBAC checks) rather than shown grayed out

### Keyboard Shortcut Conventions
**System-reserved (never use):**
- Cmd+Q, Cmd+W, Cmd+H, Cmd+M, Cmd+Tab
- Cmd+C/V/X/Z/A (clipboard and undo)
- Cmd+, (settings)

**Conventional meanings (use as expected):**
- Cmd+R (refresh/reload — standard in browsers and many apps)
- Cmd+F (find/filter)
- Cmd+1/2/3/... (switch tabs — standard in browsers, Finder, Terminal)
- Cmd+. (cancel current operation)
- Cmd+Shift+C (copy special — we could use for "Copy kubectl command")

**Our keyboard shortcut plan (validated against conventions):**
| Shortcut | Action | Conflict Risk |
|---|---|---|
| Cmd+R | Refresh | None — standard meaning |
| Cmd+F or / | Focus filter | Cmd+F is standard; / is K9s-inspired |
| Cmd+1/2/3/4 | Switch resource tabs | None — standard tabbed app |
| Delete | Delete pod (with confirmation) | None |
| Cmd+Shift+R | Restart deployment | None |
| Cmd+Shift+C | Copy kubectl command | Minor — some apps use for color picker. Acceptable |

**Explicit V1 non-bindings:**
- No dedicated keyboard shortcut for **Port Forward** in V1
- No dedicated keyboard shortcut for **Scale** in V1
- Both remain context-menu / sheet-driven actions to avoid conflicting with macOS expectations for Cmd+P and Cmd+S

---

## 5. Kubernetes Resource Browser UX

### What K9s Gets Right (And What's Transferable)

1. **Command-line-native navigation model:** `:pods`, `:deploy`, `:svc`. In our app, this maps to Cmd+1/2/3/4 or the tab bar. The mental model is the same: switch resource type quickly without drilling through a hierarchy.

2. **Filtering is the primary discovery mechanism:** In K9s, you press `/` and start typing. The list narrows instantly. This is more efficient than scrolling through hundreds of pods. We should make the filter field the most prominent tool in the toolbar.

3. **Unhealthy resources surface automatically:** Default sort puts failing pods first. This is the single most important UX decision for a Kubernetes browser. When someone opens the cluster browser, they're usually looking for what's wrong.

4. **Actions are discoverable through a consistent pattern:** In K9s, you select a resource and press a key. A help bar at the bottom shows available actions for the current context. We can achieve this with context menus and keyboard shortcut hints in the status bar.

5. **Minimal navigation depth:** K9s keeps you at the resource list level. You don't navigate into a resource detail view — you trigger actions directly from the list. Our design should follow this: no drill-down detail pane in V1. Actions happen via context menu and popover sheets.

### What Lens Gets Wrong (And How We Avoid It)

1. **Tab clutter:** Lens opens a new tab for every drilled-into resource. Users reported that the tab bar easily becomes cluttered, with tabs from different clusters mixing together. We avoid this by not having per-resource tabs — our tabs are fixed resource types.

2. **Heavyweight Electron rendering:** Lens can consume 2GB+ RAM with multiple clusters open. Our shell-out-to-kubectl architecture and open-n-close memory model prevents this categorically.

3. **Information overload:** Lens shows everything — events, conditions, labels, annotations, containers, volumes — in a detail pane. For V1, we show only the columns that match `kubectl get` output. Users who need more detail can "Copy kubectl command" and run it in their terminal.

### What Would Make Someone Prefer This Over `kubectl get pods | grep`

1. **Always available:** One keyboard shortcut from any context. No need to find a terminal, cd to the right directory, or remember which kubeconfig to use. Recon already has the kubeconfig and context configured.

2. **Visual health at a glance:** Color-coded status indicators are faster to parse than scanning text output for "CrashLoopBackOff" or "0/1" ready counts.

3. **Unhealthy-first sorting:** `kubectl get pods` sorts alphabetically. Finding the broken pod in 200 healthy ones requires piping through grep. Our browser puts broken pods at the top by default.

4. **One-click actions:** Right-click to delete a pod, restart a deployment, or start a port forward — instead of typing `kubectl delete pod <name> -n <namespace>` from memory.

5. **Namespace and context awareness:** The browser inherits the current context from Recon's existing kubeconfig management. No `--context` or `-n` flags to remember.

6. **Copy kubectl command:** For users who want to learn or share, every action can be copied as the equivalent kubectl command. This makes the GUI a teaching tool rather than an opaque abstraction.

---

## 6. Actionable Recommendations for Implementation

### Window Structure (SwiftUI View Hierarchy)

```
ClusterBrowserWindowView (VStack, spacing: 0)
  |-- TabBar (capsule style, matching DiagnosticsWindowView)
  |   |-- Pods tab (with optional unhealthy count badge)
  |   |-- Deployments tab
  |   |-- Services tab
  |   |-- Ingresses tab
  |-- Toolbar area (HStack)
  |   |-- Search/filter TextField
  |   |-- Spacer
  |   |-- Refresh button
  |   |-- Namespace Picker
  |-- Content area (Table or ContentUnavailableView)
  |   |-- SwiftUI Table with resource-type-specific columns
  |   |-- .searchable or manual filter binding
  |   |-- .contextMenu on each column cell (via reusable modifier)
  |-- Separator (0.5px)
  |-- Status bar (HStack)
      |-- Resource count ("42 pods")
      |-- Spacer
      |-- Port forwards indicator ("3 forwards active", clickable)
      |-- Context name
```

### Key SwiftUI Modifiers to Use

| Modifier | Purpose |
|---|---|
| `Table(data, selection:, sortOrder:)` | Core table view |
| `.tableStyle(.inset(alternatesRowBackgrounds: true))` | Native macOS table appearance |
| `.searchable(text:, prompt:)` | Filter field in toolbar |
| `.contextMenu { }` on column content | Right-click actions |
| `.keyboardShortcut("r", modifiers: .command)` | Keyboard shortcuts on buttons |
| `.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())` | Full-row context menu hit area |
| `.onChange(of: sortOrder)` | Re-sort data when column headers clicked |
| `.focusable()` and `@FocusState` | Keyboard focus management |
| `.onMoveCommand { direction in }` | Arrow key navigation |
| `ContentUnavailableView` | Empty, error, and no-results states |

### Default Sort Order

Implement "unhealthy-first" sorting as the default:
1. Primary: health status (failed/error first, then pending/warning, then running/healthy, then succeeded/terminal)
2. Secondary: name alphabetical

When the user clicks a column header to sort, switch to that column's sort. Provide a way to return to health-first sort (e.g., clicking the Status column header).

### Color System (Matching Existing Diagnostics Patterns)

| State | Color | SwiftUI | Usage |
|---|---|---|---|
| Healthy | Green | `.green` | Pod Running + all ready, Deployment fully available |
| Warning | Orange | `.orange` | Pod Pending, Deployment partially ready |
| Error | Red | `.red` | Pod Failed, CrashLoopBackOff, Deployment 0 available |
| Neutral | Gray | `.secondary` | Pod Succeeded, informational |

Use the same `Circle().fill(color).frame(width: 8, height: 8)` pattern already established in DiagnosticsHealthCardView and DiagnosticsHistoryRow.

### Performance Checklist

- [ ] Do **not** retain window/resource state across close/open cycles; opening should recreate lightweight UI and fetch fresh data
- [ ] Pre-filter data in the view model before passing to Table (never filter inside the Table body)
- [ ] Filter the in-memory array on every keystroke — no debounce needed for <1000 items
- [ ] On refresh: keep stale data visible, overlay a loading indicator, swap atomically on completion
- [ ] On namespace switch: show loading state in content area while keeping tab bar and toolbar stable
- [ ] On tab switch: immediately render the new tab's UI (even if showing a loading state)
- [ ] Use value types (structs) for all resource models — already specified in the tech spec
- [ ] Avoid conditional logic inside Table row construction — pre-compute any derived display values
- [ ] Sort using only the first `KeyPathComparator` for large lists
- [ ] Release all resource data in `deactivateWindow()` — already specified in the tech spec

### Discoverability Without Clutter

- Context menus are the primary action surface — right-click any row to see available actions
- Keyboard shortcuts are shown in the context menu items (standard macOS behavior — SwiftUI shows the shortcut hint automatically when you attach `.keyboardShortcut()` to a `Button` inside a `Menu` or context menu)
- The status bar shows the current context and active forwards count — ambient information without taking space from the resource list
- Tab badges (small colored dots or counts) can signal unhealthy resources in other tabs without requiring the user to switch to see
