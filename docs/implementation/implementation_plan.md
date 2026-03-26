# Recon v0.2 — Implementation plan

**Date:** 2026-03-27
**Baseline:** Recon v0.1.0 (current screenshot)
**Platform:** macOS, SwiftUI, MenuBarExtra (window-style)
**Theme:** Native dark / system dark — no light-mode override

---

## What we have today (v0.1.0)

The current popover has:

- A green status dot + "Connected" heading with a sub-label and timestamp
- A `KUBECONFIG` section with a dropdown picker and "Choose…" button
- Four action buttons stacked vertically: Connect (disabled), Disconnect, Reconnect, Refresh Now
- A collapsible Preferences… accordion
- A `LAST ERROR` section showing a truncated error string
- A footer with version and "Quit Recon"

What's missing or needs rework based on the UX research:

1. No context or namespace visibility — the two most important targeting nouns
2. No intercept visibility
3. All four actions shown at once regardless of state — creates clutter and ambiguity about which one matters right now
4. Error has no next step, no way to get to logs or CLI
5. No production-safety cues
6. No CLI escape hatches (copy command, open logs, reveal kubeconfig)
7. Preferences live in an accordion that's close to its natural limit
8. No diagnostics path (daemon state, session details, event history)
9. "Connected / Connected" is redundant — status + sub-label say the same thing

---

## Architecture: three-tier UI

### Tier 1 — Menu bar icon

The `NSStatusItem` icon in the system menu bar. Communicates state with zero interaction.

| State | Icon | Description |
|---|---|---|
| Connected | Green circle + checkmark | Small SF Symbol or custom glyph |
| Connected to prod | Red circle + checkmark | Same shape, red fill — prod is visually "louder" |
| Connecting | Orange circle, pulsing | Animated opacity pulse |
| Error | Red triangle | Distinct shape from connected states |
| Disconnected | Gray circle + X | Lowest visual weight |

Use `Image(systemName:)` with SF Symbols where possible. The icon should be 16×16pt, template-rendered for menu bar consistency.

### Tier 2 — Popover (MenuBarExtra, window-style)

The primary surface. Opens on click. Target width: **340pt**. Should never scroll.

### Tier 3 — Standalone windows

Preferences, Diagnostics, and the Kubeconfig Chooser sheet. These open from the popover via menu items with ellipsis labels (`Preferences…`, `Choose kubeconfig…`). They persist independently of the popover — closing the popover does not close these windows.

Use `Window` or `WindowGroup` in the SwiftUI App scene, opened via `openWindow(id:)`.

---

## Popover — section-by-section spec

The popover follows this fixed ordering. Sections are always present but adapt their content to the current state.

### Section 1: Status header

**Layout:** Single row. Status dot (8pt diameter) + state label (13pt medium) + right-aligned timestamp.

| State | Dot color | Label | Timestamp |
|---|---|---|---|
| Connected | Green | "Connected" | "12 min ago" (relative, from last successful poll) |
| Connected to prod | Red | "Connected" | "4 min ago" + see prod treatment below |
| Connecting | Orange (pulsing) | "Connecting…" | Hidden |
| Error | Red | "Connection failed" | "just now" |
| Disconnected | Gray | "Disconnected" | Hidden |

**Production treatment:** When the resolved context name contains `prod` (case-insensitive substring match, or matches a user-defined list in Preferences):

- Status dot → red instead of green
- A `PRODUCTION` badge appears after the label (red background pill, 10pt text)
- A warning banner appears below the metadata grid:
  - Red-tinted background, triangle-warning icon, text: "You are connected to a production cluster. Actions here affect live traffic."
- The context value in the metadata grid renders in red

### Section 2: Target metadata

**Layout:** Two-column grid. Left column is 11pt labels in secondary text color. Right column is 11pt monospace values, right-aligned.

Always show these three rows:

| Key | Value | Notes |
|---|---|---|
| Kubeconfig | `~/.kube/config` | Show the resolved file path. If inherited from `$KUBECONFIG`, show the pinned file or "Inherited (3 files)". See kubeconfig mode logic below. |
| Context | `dev-us-east-1` | Exact string from kubectl. Render in red if it contains "prod". |
| Namespace | `payments-team` | The resolved default namespace for the context. |

When disconnected, context and namespace values should render in tertiary (dimmed) text to indicate they're the *last known* values, not live state.

**Kubeconfig mode display logic:**

| Mode | Display |
|---|---|
| Pinned to a specific file | `~/.kube/config` (just the path) |
| Following `$KUBECONFIG` with a single file | `~/.kube/config` (same display, but internally tracking the env var) |
| Following `$KUBECONFIG` with multiple merged files | `Inherited (3 files)` — consider making this a clickable link to show the full list in diagnostics |
| Default (no env var, no pin, using `~/.kube/config`) | `~/.kube/config (default)` |

### Section 3: Intercepts (connected states only)

**Layout:** Section label "Intercepts" (10pt uppercase, tertiary text). Below it, a list of intercept rows.

Each intercept row: icon (12pt, green plus/crosshair) + service name in monospace + "active" badge (green pill) + port mapping in secondary text, right-aligned.

If no intercepts: Show a single line "No active intercepts" in secondary text. Do not hide the section — its presence teaches users that intercepts are a thing Recon can surface.

If connected but still loading intercepts: Show "Checking…" in secondary text.

**Do not show this section when disconnected.** In error state, show "Unknown" in secondary text.

### Section 4: Primary actions

**Layout:** Horizontal row of 1–2 buttons, full-width. Button style: rounded rect, 12pt medium text, icon + label.

Actions change based on state:

| State | Actions |
|---|---|
| Connected | `Reconnect` (secondary style) + `Disconnect` (danger/red text style) |
| Connected to prod | Same, but `Disconnect` is the more visually prominent action |
| Connecting | `Cancel` (danger style, centered, full-width) |
| Error | `Reconnect` (primary/blue style, centered, full-width) |
| Disconnected | `Connect` (primary/blue style, centered, full-width) |

**Busy state:** While any action is in-flight, disable all action buttons. Show a subtle progress indicator (2pt orange bar below the metadata section, animated).

### Section 5: Utilities menu

**Layout:** Standard menu-item rows. Each row: 14pt icon + 12pt label + optional right-aligned keyboard shortcut in tertiary text.

Fixed items, always present:

| Item | Icon | Shortcut | Notes |
|---|---|---|---|
| Copy 'telepresence status' | Terminal icon | — | Copies the command string to clipboard. Shows a brief "Copied" confirmation. |
| Copy 'telepresence list' | Terminal icon | — | Same clipboard behavior. |
| Open logs… | Folder icon | ⌥L | Opens the log file in Console.app or the system default log viewer. |
| Choose kubeconfig… | External link icon | — | Opens the kubeconfig chooser sheet (tier 3). |
| Preferences… | Gear icon | ⌘, | Opens the Preferences window (tier 3). |

When disconnected, "Copy 'telepresence status'" is still available (it's useful for debugging why connection failed). "Copy 'telepresence list'" should be disabled (dimmed) because there's no session to list.

### Section 6: Footer

**Layout:** Full-width row. Version string left-aligned in 10pt tertiary. "Diagnostics" and "Quit" buttons right-aligned in 11pt secondary.

- `Recon v0.4.1` (left)
- `Diagnostics` (right, opens Diagnostics window)
- `Quit` (right, quits the app)

---

## Preferences window spec

**Window ID:** `preferences`
**Title:** "Recon — Preferences"
**Size:** ~520pt wide, height fits content
**Style:** Standard macOS utility window with traffic lights, no resize

Three-tab toolbar: **General**, **Notifications**, **Paths**

### General tab

**Startup section:**

| Setting | Type | Default | Notes |
|---|---|---|---|
| Launch at login | Toggle | Off | Uses `SMAppService.mainApp` or `ServiceManagement` for login items |
| Auto-connect on launch | Toggle | Off | Sub-label: "Connects to last-used context automatically" |

Hint text below: "Both off by default. Auto-connect may reconnect to yesterday's target in multi-cluster setups."

**Connection section:**

| Setting | Type | Default | Notes |
|---|---|---|---|
| Auto-reconnect on failure | Toggle | Off | Sub-label: "Retries up to 3 times after unexpected disconnect" |
| Poll interval | Dropdown | 30 seconds | Options: 10s, 30s, 60s, Manual only |

**Appearance section:**

| Setting | Type | Default | Notes |
|---|---|---|---|
| Menu bar icon style | Dropdown | Status glyph | Options: Status glyph (colored), Monochrome |

### Notifications tab

**"Notify me when" section — toggleable:**

| Event | Default | Notes |
|---|---|---|
| Unexpected disconnect | On | |
| Auto-reconnect failed | On | |
| Recovery after failure | On | |
| Context points at production | On | Sub-label: "Warns when context name contains 'prod'" |

**"Never notify for" section — non-toggleable, shown with a dash icon:**

| Event | Notes |
|---|---|
| Routine status polls | Permanently suppressed |
| Successful connect on launch | Permanently suppressed |

Hint text: "These are always suppressed. Recon only notifies for events that need your attention."

### Paths tab

**Tool paths section:**

| Row | Value | Action button |
|---|---|---|
| telepresence | `/usr/local/bin/telepresence` | `Detect` (re-scans PATH) |
| kubectl | `/usr/local/bin/kubectl` | `Detect` |

**Kubeconfig section:**

| Row | Value | Action |
|---|---|---|
| Source | `~/.kube/config` | `Choose…` (opens file picker) |
| Mode | "Pinned to file" | Dropdown: "Pinned to file" / "Follow $KUBECONFIG" |

Hint text: "When pinned, Recon always uses this file. 'Follow $KUBECONFIG' inherits whatever your shell exports, which may be a merged set of files."

**Logs section:**

| Row | Value | Action |
|---|---|---|
| Log directory | `~/Library/Logs/Recon/` | `Reveal` (opens in Finder) |

---

## Diagnostics window spec

**Window ID:** `diagnostics`
**Title:** "Recon — Diagnostics"
**Size:** ~560pt wide, height fits content
**Style:** Standard macOS utility window with traffic lights, no resize

Three-tab toolbar: **Health**, **Logs**, **History**

### Health tab

**Component status section:** 2×2 grid of cards showing the four critical Telepresence layers.

| Component | Possible values | Source |
|---|---|---|
| User daemon | running / stopped / error | `telepresence status` |
| Root daemon | running / stopped / error | `telepresence status` |
| Traffic Manager | version string / unreachable / not installed | `telepresence status` |
| DNS resolution | active / inactive / error | `telepresence status` |

Each card: status dot (green/orange/red/gray) + component name + value in monospace.

**Session details section:** Key-value grid.

| Key | Value |
|---|---|
| Session | Session ID from Telepresence |
| Telepresence | Version string |
| Cluster | Cluster ARN/URL (truncated with tooltip) |
| Mapped subnets | Comma-separated CIDR list |
| DNS suffix | e.g., `.svc.cluster.local` |
| Connected since | ISO timestamp |

**Action bar:**

- `Copy 'telepresence status'` (primary style)
- `Export diagnostic bundle` (secondary style) — runs `telepresence gather-logs` or equivalent

### Logs tab

**Layout:** A dark-background log viewer (monospace, 11pt) with scrolling.

**Log toolbar:** Filter text input + level-filter badges (INFO, WARN, ERR). Badges are toggleable — click to include/exclude a level.

**Log source:** Read from the Telepresence log file(s) and/or Recon's own log file. Tail the file for live updates.

**Action bar:**

- `Open in Console.app` — opens the log file in the system log viewer
- `Reveal log file` — opens the containing directory in Finder

### History tab

**Layout:** A vertical list of event rows. Each row: colored dot + event description + right-aligned timestamp.

Events to capture:

| Event | Dot color |
|---|---|
| Connected to context/namespace | Green |
| Disconnected (user-initiated) | Gray |
| Disconnected (unexpected) | Red |
| Session timeout | Red |
| Auto-reconnect succeeded | Green |
| Auto-reconnect failed | Orange |
| Root daemon restarted | Orange |
| Kubeconfig changed | Blue |

**Retention:** Show last 7 days. Hint text at bottom: "Showing last 7 days. Older events are in the log file."

---

## Kubeconfig chooser spec

**Trigger:** "Choose kubeconfig…" from the popover utilities section.
**Style:** A modal sheet or standalone window, ~400pt wide.

**Header:**
- Title: "Choose kubeconfig"
- Subtitle: "Switching will disconnect and reconnect Telepresence to the new target."

**File list:** Vertical list of kubeconfig files.

Each row: file icon + file name (bold) + file path (monospace, secondary text) + optional badge.

Badges:
- `current` (green) on the actively used file
- `prod` (red) on files whose active context contains "prod"

**File discovery:** Scan `~/.kube/` for files. Also include any files previously used (stored in Recon's own prefs). Allow manual addition via a "Browse…" button.

**Disambiguation:** When two files share the same basename (e.g., both named `config`), show enough parent path to distinguish them. E.g., `~/.kube/config` vs `~/projects/infra/.kube/config`.

**Warning text:** Orange-tinted box at the bottom: "Switching kubeconfig will disconnect your current session and reconnect to the selected file's active context."

**Footer buttons:**
- `Cancel` (secondary)
- `Switch & reconnect` (primary/blue)

---

## macOS notifications spec

Use `UNUserNotificationCenter`. Request permission on first relevant event, not on launch.

### Events that trigger notifications

| Event | Title | Body | Condition |
|---|---|---|---|
| Unexpected disconnect | "Connection lost" | "Telepresence disconnected from {context}. Click to reconnect." | Always (if notification toggle is on) |
| Auto-reconnect failed | "Auto-reconnect failed" | "{n} attempts failed. Open Recon to retry or view logs." | Only if auto-reconnect is enabled |
| Recovery after failure | "Reconnected" | "Session restored to {context} / {namespace}." | Only after a failure, not on routine connect |
| Production context | "Production cluster" | "Connected to {context}. Actions affect live traffic." | If prod-notification toggle is on |

### Events that never trigger notifications

- Routine status polls
- Successful connect on launch
- Successful manual connect/disconnect
- Refresh completed

---

## Visual design spec (dark theme)

Recon uses native macOS dark appearance. Do not force a custom color scheme — use semantic system colors so the UI adapts if Apple changes dark mode in the future.

### Colors

| Role | SwiftUI token | Hex approximation | Usage |
|---|---|---|---|
| Panel background | `.background` (window material) | ~#1e1e1e | Window and popover background |
| Card/row background | `Color(.controlBackgroundColor)` | ~#2c2c2e | Setting rows, health cards |
| Primary text | `.primary` | ~#f5f5f7 | Labels, values, headings |
| Secondary text | `.secondary` | ~#98989d | Sub-labels, hints, meta keys |
| Tertiary text | `Color(.tertiaryLabelColor)` | ~#636366 | Timestamps, disabled text, shortcut hints |
| Separator | `Color(.separatorColor)` | ~rgba(255,255,255,0.06) | Section dividers |
| Green (connected) | `Color.green` | ~#34c759 | Status dot, intercept badges |
| Orange (warning) | `Color.orange` | ~#ff9f0a | Connecting dot, warning badges |
| Red (error/prod) | `Color.red` | ~#ff3b30 | Error dot, prod banner, prod context text |
| Blue (primary action) | `Color.accentColor` | ~#007aff | Primary buttons, selected states |

### Typography

| Role | Font | Size | Weight |
|---|---|---|---|
| Status label | System (SF Pro) | 13pt | Medium (.medium) |
| Section heading | System | 10pt | Semibold, uppercased, letter-spaced | 
| Meta key (left column) | System | 11pt | Regular |
| Meta value (right column) | System monospace (.monospacedSystemFont) | 11pt | Regular |
| Action button | System | 12pt | Medium |
| Menu item | System | 12pt | Regular |
| Hint text | System | 11pt | Regular, tertiary color |
| Footer version | System monospace | 10pt | Regular, tertiary color |
| Log viewer | System monospace | 11pt | Regular |

### Spacing

| Element | Value |
|---|---|
| Section horizontal padding | 14pt |
| Section vertical padding | 10pt |
| Grid row gap | 3pt |
| Grid column gap | 12pt |
| Button corner radius | 6pt |
| Badge corner radius | 10pt (pill) |
| Status dot diameter | 8pt |
| Card corner radius | 6pt |
| Window corner radius | 10pt (system default for MenuBarExtra) |

### Component patterns

**Status dot:** A filled circle. Use a subtle outer ring for emphasis: `Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.3), radius: 2)`.

**Badge (pill):** Rounded rect with tinted background and same-hue text. E.g., green badge: `background: green.opacity(0.15)`, `foreground: green`.

**Action button:** Full-width, rounded rect, 6pt corner radius. Primary style: blue-tinted background + blue text. Secondary: transparent background + secondary text. Danger: transparent background + red text.

**Menu item row:** Full-width, 5pt vertical padding, 10pt horizontal padding, 6pt corner radius. On hover: subtle background highlight (`.hover` modifier or manual `isHovered` tracking with `onHover`).

**Toggle:** Use native SwiftUI `Toggle` with `.toggleStyle(.switch)`. It automatically renders as the macOS toggle switch in the correct system colors.

**Dropdown:** Use native `Picker` with `.pickerStyle(.menu)` for dropdowns inside settings rows.

---

## State management

### Core state model

```
enum ConnectionState {
    case connected
    case connecting
    case disconnected
    case error(message: String)
}

struct ReconState {
    var connectionState: ConnectionState
    var kubeconfigPath: String
    var kubeconfigMode: KubeconfigMode  // .pinned, .followEnv
    var context: String?
    var namespace: String?
    var intercepts: [Intercept]
    var lastUpdated: Date?
    var isProduction: Bool  // derived from context name
    
    // Daemon-level details (for diagnostics)
    var userDaemonRunning: Bool
    var rootDaemonRunning: Bool
    var trafficManagerVersion: String?
    var dnsActive: Bool
    var sessionId: String?
    var clusterInfo: String?
}

struct Intercept {
    var serviceName: String
    var sourcePort: Int
    var targetPort: Int
    var isActive: Bool
}

enum KubeconfigMode {
    case pinned(path: String)
    case followEnv
}
```

### Polling

Use a `Timer` or `Task.sleep` loop. Default interval: 30 seconds. Configurable in Preferences.

On each poll:
1. Run `telepresence status --output json` (or parse text output)
2. Parse connection state, context, namespace, daemon states
3. Run `telepresence list --output json` to get intercepts (only if connected)
4. Update `ReconState`
5. Update menu bar icon
6. Fire notifications if state transitions match notification rules

**Refresh button** triggers an immediate poll. It must not mutate state — it only observes.

---

## Implementation phases

### Phase 1: Popover redesign (current → v0.2)

**Goal:** Restructure the popover to match the new section ordering and state-driven actions.

Tasks:
1. Replace the status header: remove redundant "Connected / Connected" sub-label. Show state + relative timestamp.
2. Add target metadata grid: kubeconfig, context, namespace.
3. Add intercepts section (read-only, from `telepresence list`).
4. Refactor actions to be state-driven: show 1–2 relevant actions per state instead of all four.
5. Add utilities menu: copy commands, open logs, choose kubeconfig, preferences.
6. Update footer: add Diagnostics button.
7. Wire up production detection: substring match on context name for "prod".

### Phase 2: Production safety + error improvements

**Goal:** Make errors actionable and prod connections visually loud.

Tasks:
1. Implement production banner and red context styling.
2. Replace truncated error string with a structured error banner: icon + message + next-step hint.
3. Parse common Telepresence errors and map them to human-readable messages with suggested actions.
4. Add "Copy 'telepresence status'" and "Open logs…" as the primary escape hatches in error state.

### Phase 3: Preferences window

**Goal:** Move preferences out of the accordion and into a proper window.

Tasks:
1. Create the Preferences window with three tabs (General, Notifications, Paths).
2. Migrate existing accordion settings into the General tab.
3. Add notification controls.
4. Add kubeconfig mode selector (pinned vs. follow env).
5. Add tool path detection and manual override.
6. Wire up `@AppStorage` or a `UserDefaults`-backed settings model.
7. Remove the accordion from the popover; replace with `Preferences…` menu item.

### Phase 4: Diagnostics window

**Goal:** Give power users a place to debug without leaving Recon.

Tasks:
1. Create the Diagnostics window with three tabs (Health, Logs, History).
2. Build the health grid from `telepresence status` output.
3. Build the log viewer: read + tail the Telepresence log file, apply level filtering.
4. Build the event history: store events in a local SQLite DB or a simple JSON file, display last 7 days.
5. Add "Export diagnostic bundle" action (wraps `telepresence gather-logs`).

### Phase 5: Kubeconfig chooser + notifications

**Goal:** Safer kubeconfig switching and non-disruptive notifications.

Tasks:
1. Build the kubeconfig chooser sheet.
2. Scan `~/.kube/` for files, track recently-used files.
3. Show prod badges and disambiguation paths.
4. Wire up the switch-and-reconnect flow with explicit confirmation.
5. Implement `UNUserNotificationCenter` integration.
6. Request permission lazily (on first notification-worthy event).
7. Map state transitions to notification rules from the Preferences.

---

## File structure suggestion

```
Recon/
├── ReconApp.swift                  # App entry, MenuBarExtra + Window scenes
├── Models/
│   ├── ReconState.swift            # Core state model
│   ├── ConnectionState.swift       # State enum
│   ├── Intercept.swift             # Intercept model
│   └── Settings.swift              # @AppStorage-backed preferences
├── Services/
│   ├── TelepresenceService.swift   # CLI interaction, polling, parsing
│   ├── KubeconfigService.swift     # File discovery, mode resolution
│   ├── NotificationService.swift   # UNUserNotificationCenter wrapper
│   └── EventHistoryService.swift   # Local event storage
├── Views/
│   ├── Popover/
│   │   ├── PopoverView.swift       # Main popover container
│   │   ├── StatusHeader.swift      # Section 1
│   │   ├── TargetMetadata.swift    # Section 2
│   │   ├── InterceptsSection.swift # Section 3
│   │   ├── ActionsSection.swift    # Section 4 (state-driven)
│   │   ├── UtilitiesMenu.swift     # Section 5
│   │   └── PopoverFooter.swift     # Section 6
│   ├── Preferences/
│   │   ├── PreferencesView.swift   # Window container + tab bar
│   │   ├── GeneralTab.swift
│   │   ├── NotificationsTab.swift
│   │   └── PathsTab.swift
│   ├── Diagnostics/
│   │   ├── DiagnosticsView.swift   # Window container + tab bar
│   │   ├── HealthTab.swift
│   │   ├── LogsTab.swift
│   │   └── HistoryTab.swift
│   └── KubeconfigChooser/
│       └── KubeconfigChooserView.swift
├── Components/
│   ├── StatusDot.swift             # Reusable colored dot
│   ├── Badge.swift                 # Pill badge component
│   ├── MetadataGrid.swift          # Two-column key-value grid
│   ├── MenuItemRow.swift           # Clickable menu item with icon
│   └── ActionButton.swift          # State-aware action button
└── Utilities/
    ├── ShellRunner.swift           # Process/shell command execution
    ├── ProductionDetector.swift    # Context name → is-prod logic
    └── ClipboardHelper.swift       # NSPasteboard convenience
```

---

## Open questions to resolve during implementation

1. **Telepresence output format:** Does your current version support `--output json` for structured parsing, or are you parsing text output? JSON is strongly preferred for reliability.
2. **Log file location:** Where does Telepresence write logs on this system? The default is usually `~/Library/Logs/telepresence/`, but it can vary.
3. **Kubeconfig scanning:** Should Recon only look in `~/.kube/`, or also in common paths like `~/projects/*/.kube/`? The current dropdown already has `config-qa`, suggesting multiple files.
4. **Event persistence:** SQLite (more robust, queryable) or a simple JSON file (simpler, good enough for 7 days of events)?
5. **SwiftUI version target:** Are you targeting macOS 14+ (Sonoma)? That affects which `MenuBarExtra` APIs and window management patterns are available.
6. **Menu bar icon approach:** SF Symbols, custom asset catalog images, or programmatic SwiftUI rendering?
