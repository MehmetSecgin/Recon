# Recon — Component build prompts

Use these as starting prompts when building each component with an AI coding assistant. Each prompt includes the context, constraints, and acceptance criteria so the assistant has enough to produce working SwiftUI code.

---

## Prompt 1: Core state model

```
I'm building a macOS menu bar app called Recon that monitors Telepresence (a Kubernetes dev tool) status. I need the core state model in Swift.

Create the following models:

1. `ConnectionState` enum with cases: connected, connecting, disconnected, error(message: String, suggestion: String?)
2. `ReconState` as an @Observable class (macOS 14+) containing:
   - connectionState: ConnectionState
   - kubeconfigPath: String
   - kubeconfigMode: KubeconfigMode enum (.pinned(path: String), .followEnv)
   - context: String? (current kubectl context)
   - namespace: String? (current namespace)
   - intercepts: [Intercept] (array of active intercepts)
   - lastUpdated: Date?
   - isProduction: Bool (computed — true if context contains "prod", case-insensitive)
   - userDaemonRunning: Bool
   - rootDaemonRunning: Bool
   - trafficManagerVersion: String?
   - dnsActive: Bool
   - sessionId: String?
   - clusterInfo: String?
3. `Intercept` struct with: serviceName: String, sourcePort: Int, targetPort: Int, isActive: Bool
4. `AppSettings` class backed by @AppStorage for: launchAtLogin, autoConnectOnLaunch, autoReconnectOnFailure, pollIntervalSeconds, iconStyle, and notification toggles (notifyUnexpectedDisconnect, notifyReconnectFailed, notifyRecovery, notifyProduction)

All defaults should be safe: launch at login off, auto-connect off, auto-reconnect off, poll interval 30s, all notifications on.

Use Swift 5.9+ / macOS 14+ conventions. No UIKit.
```

---

## Prompt 2: Telepresence service (CLI interaction + polling)

```
I'm building a macOS menu bar app that polls Telepresence CLI for status. I need a TelepresenceService class.

Requirements:
- An @Observable class that owns the polling loop
- On each poll, run `telepresence status` and parse the output into my ReconState model
- Also run `telepresence list` when connected, to get active intercepts
- Use Swift's Process (Foundation) to run shell commands asynchronously
- Polling interval is configurable (10s, 30s, 60s, or manual only)
- Expose a `refresh()` method that triggers an immediate poll (read-only, no mutation)
- Expose `connect()`, `disconnect()`, `reconnect()` methods that run the corresponding telepresence CLI commands and then refresh
- Parse common error messages and map them to structured errors with human-readable suggestions:
  - "failed to launch the daemon service" → "The Telepresence daemon couldn't start. Check if another instance is running."
  - "kubeconfig has no context definition" → "The kubeconfig file doesn't define the expected context. Check your kubeconfig."
  - "Traffic Manager not found" → "The Traffic Manager isn't installed in this cluster. Run 'telepresence helm install'."
- Use async/await, not Combine

The CLI commands are:
- `telepresence status` — returns connection state, context, namespace, daemon info
- `telepresence list` — returns active intercepts
- `telepresence connect` — connects to the cluster
- `telepresence quit` — disconnects
- `telepresence connect --context <name>` — reconnects to a specific context

Handle the case where the `telepresence` binary is not found at the configured path. That's a distinct error state from "Telepresence is installed but can't connect."
```

---

## Prompt 3: Popover view (main container)

```
I'm building the main popover view for a macOS MenuBarExtra (window-style) app called Recon. It's a Telepresence status monitor.

The popover is 340pt wide and uses native macOS dark mode colors. It has these sections in order:

1. **Status header:** Status dot (8pt, colored by state) + state label (13pt medium) + relative timestamp right-aligned. When connected to a context containing "prod", show a red dot, a red "PRODUCTION" pill badge, and a warning banner below.

2. **Target metadata:** A 2-column grid (11pt labels left, 11pt monospace values right-aligned) showing Kubeconfig, Context, Namespace. When disconnected, dim the context/namespace values to tertiary color.

3. **Intercepts:** Section heading "INTERCEPTS" (10pt uppercase tertiary). List of intercept rows showing: service name in monospace + "active" green badge + port mapping. "No active intercepts" when empty. Hide entire section when disconnected.

4. **Actions:** State-driven horizontal button row:
   - Connected: Reconnect (secondary) + Disconnect (danger)
   - Connecting: Cancel (danger, full-width) + progress bar
   - Error: Reconnect (primary/blue, full-width)
   - Disconnected: Connect (primary/blue, full-width)

5. **Utilities menu:** Menu item rows with 14pt icons and 12pt labels:
   - Copy 'telepresence status' (copies to clipboard)
   - Copy 'telepresence list'
   - Open logs… (⌥L shortcut shown)
   - Choose kubeconfig… (opens a window)
   - Preferences… (⌘, shortcut shown)

6. **Footer:** Version left (10pt mono tertiary), Diagnostics + Quit buttons right.

Sections are separated by 0.5pt dividers using Color(.separatorColor).

The view takes a ReconState @Observable object and an AppSettings object. Actions call methods on a TelepresenceService.

Use SwiftUI for macOS 14+. No UIKit. Use SF Symbols for icons. Use .monospacedSystemFont for values. Keep it native — no custom color schemes, use semantic colors.
```

---

## Prompt 4: Production safety treatment

```
I need to add production safety cues to my macOS SwiftUI menu bar app.

When the current kubectl context name contains "prod" (case-insensitive), the following changes should apply to the popover:

1. Status dot changes from green to red
2. A pill badge "PRODUCTION" appears after the status label — red background (Color.red.opacity(0.12)), red text
3. A warning banner appears below the target metadata grid:
   - Red-tinted background (Color.red.opacity(0.08))
   - 0.5pt red-tinted border
   - Warning triangle SF Symbol icon (exclamationmark.triangle) in red
   - Text: "You are connected to a production cluster. Actions here affect live traffic." in 11pt red
4. The context value in the metadata grid renders in Color.red instead of primary text color
5. The menu bar icon changes to use red instead of green

Create a `ProductionDetector` utility that:
- Checks if a context name contains "prod" (case-insensitive)
- Also supports a user-defined list of production patterns stored in UserDefaults
- Returns a `ProductionLevel` enum: .safe, .production, .unknown

And a `ProductionBanner` SwiftUI view that renders the warning banner, and a `ProductionBadge` view for the pill.
```

---

## Prompt 5: Preferences window

```
I need a Preferences window for my macOS SwiftUI menu bar app called Recon.

It should be a standalone window (opened via openWindow(id: "preferences")) with:
- macOS-native title bar with traffic lights
- Title: "Recon — Preferences"
- ~520pt wide, non-resizable
- Three-tab toolbar using a segmented picker or toolbar-style tabs: General, Notifications, Paths

**General tab:**
- Startup section: "Launch at login" toggle (off default), "Auto-connect on launch" toggle (off default) with sub-label "Connects to last-used context automatically"
- Connection section: "Auto-reconnect on failure" toggle (off default) with sub-label, "Poll interval" dropdown (10s/30s/60s/Manual)
- Appearance section: "Menu bar icon style" dropdown (Status glyph / Monochrome)

**Notifications tab:**
- "Notify me when" section with toggles: Unexpected disconnect (on), Auto-reconnect failed (on), Recovery after failure (on), Context points at production (on, sub-label: "Warns when context name contains 'prod'")
- "Never notify for" section showing Routine status polls and Successful connect on launch — these are non-toggleable, just shown with a dash/minus icon to communicate they're permanently suppressed
- Hint text at bottom

**Paths tab:**
- Tool paths: telepresence and kubectl paths with "Detect" buttons (scans $PATH)
- Kubeconfig: source path with "Choose…" button (NSOpenPanel), mode dropdown (Pinned to file / Follow $KUBECONFIG)
- Logs: log directory with "Reveal" button (opens Finder)

Settings rows should have white/card background (Color(.controlBackgroundColor)), grouped with minimal spacing between rows and rounded corners on first/last rows.

All settings backed by @AppStorage. Use native SwiftUI Toggle with .switch style, native Picker with .menu style. macOS 14+ only.
```

---

## Prompt 6: Diagnostics window

```
I need a Diagnostics window for my macOS SwiftUI menu bar app called Recon.

Standalone window (opened via openWindow(id: "diagnostics")), ~560pt wide, non-resizable.
Title: "Recon — Diagnostics"
Three-tab toolbar: Health, Logs, History

**Health tab:**
- 2x2 grid of "health cards" showing component status:
  - User daemon: running/stopped/error
  - Root daemon: running/stopped/error
  - Traffic Manager: version string or unreachable
  - DNS resolution: active/inactive/error
  Each card: colored dot (green/orange/red/gray) + name + monospace value
- Session details: key-value grid showing Session ID, Telepresence version, Cluster, Mapped subnets, DNS suffix, Connected since
- Action bar: "Copy 'telepresence status'" (primary) + "Export diagnostic bundle" (secondary)

**Logs tab:**
- A dark-background (Color.black or Color(.textBackgroundColor)) scrollable log viewer
- Monospace 11pt text with colored level prefixes: INFO (blue), WARN (yellow), ERROR (red), timestamps in gray
- Filter text field above + toggleable level-filter pill badges
- Reads from the Telepresence log file, tails for live updates
- Action bar: "Open in Console.app" + "Reveal log file"

**History tab:**
- Vertical list of event rows: colored dot + event description + right-aligned timestamp
- Events: connected (green), disconnected-user (gray), disconnected-unexpected (red), timeout (red), reconnect-success (green), reconnect-failed (orange), daemon-restart (orange), kubeconfig-changed (blue)
- Show last 7 days, hint text about older events in log file
- Data source: a local JSON file or SQLite DB managed by EventHistoryService

macOS 14+, SwiftUI, native dark appearance.
```

---

## Prompt 7: Kubeconfig chooser

```
I need a kubeconfig chooser window/sheet for my macOS SwiftUI menu bar app.

It's a standalone window (~400pt wide) that lets users pick a kubeconfig file. It should feel like a macOS open-dialog but specialized for kubeconfig files.

**Header:** "Choose kubeconfig" title + subtitle: "Switching will disconnect and reconnect Telepresence to the new target."

**File list:** Vertical list of kubeconfig files discovered by scanning:
1. ~/.kube/ directory for all files (excluding directories and hidden files)
2. Any previously-used files stored in UserDefaults

Each row: file document icon + filename (bold 12pt) + full path (monospace 10pt secondary) + optional badge
- "current" badge (green) on the actively-used file
- "prod" badge (red) on files whose active context contains "prod" (read the context from the file without applying it)

**Disambiguation:** When two files share the same filename, show enough parent path to distinguish them.

**Warning box:** Orange-tinted box at bottom: "Switching kubeconfig will disconnect your current session and reconnect to the selected file's active context."

**Footer:** Cancel (secondary) + "Switch & reconnect" (primary/blue) buttons. "Switch & reconnect" is disabled until a file different from current is selected.

**Behavior on confirm:** Call kubeconfigService.switchTo(path:) which disconnects, updates the config, and reconnects. Close the window. Show connecting state in the popover.

Use NSOpenPanel for "Browse…" if the user wants a file not in the list.

macOS 14+, SwiftUI, native dark appearance.
```

---

## Prompt 8: Notification service

```
I need a NotificationService for my macOS menu bar app that wraps UNUserNotificationCenter.

Requirements:
- Do NOT request notification permission on app launch
- Request permission lazily: on the first event that would trigger a notification, request permission, and if granted, deliver the notification immediately
- Cache the permission state to avoid re-requesting

Notification events and their rules:
1. unexpectedDisconnect(context: String) → Title: "Connection lost", Body: "Telepresence disconnected from {context}. Click to reconnect." — Only if notifyUnexpectedDisconnect setting is on
2. autoReconnectFailed(attempts: Int) → Title: "Auto-reconnect failed", Body: "{n} attempts failed. Open Recon to retry or view logs." — Only if notifyReconnectFailed is on AND autoReconnect is enabled
3. recoveryAfterFailure(context: String, namespace: String) → Title: "Reconnected", Body: "Session restored to {context} / {namespace}." — Only if notifyRecovery is on, AND only after a failure (not on routine connect)
4. productionContext(context: String) → Title: "Production cluster", Body: "Connected to {context}. Actions affect live traffic." — Only if notifyProduction is on

Each notification should:
- Use the Recon app icon as the notification icon
- Support click-to-open (bring the popover to front / activate the app)
- Use .timeSensitive interruption level for disconnect and reconnect-failed
- Use .active for recovery and production warnings

Also implement a `shouldNotify(for event:)` method that checks the relevant AppSettings toggle before delivering.

Swift, macOS 14+, no third-party dependencies.
```

---

## Prompt 9: Menu bar icon

```
I need a dynamic menu bar icon for my macOS SwiftUI app using MenuBarExtra.

The icon should change based on ConnectionState:

| State | Icon | Color |
|---|---|---|
| connected | circle with checkmark (checkmark.circle.fill) | green |
| connected + production | circle with checkmark | red |
| connecting | circle (circle.fill), pulsing opacity animation | orange |
| error | triangle (exclamationmark.triangle.fill) | red |
| disconnected | circle with X (xmark.circle) | gray (secondary label color) |

Requirements:
- Use SF Symbols rendered as template images for proper menu bar appearance
- Icons should be 16x16pt
- The connecting state should have a subtle opacity pulse animation (0.4 to 1.0, 1.5s ease-in-out, repeating)
- For the MenuBarExtra label, use the icon only (no text) to conserve menu bar space

Create a `MenuBarIcon` view that takes a ConnectionState and isProduction: Bool, and renders the appropriate SF Symbol with the correct color.

Also handle the case where the user has selected "Monochrome" icon style in preferences — in that case, all states use the same template tint (label color) but different shapes to distinguish them.

SwiftUI, macOS 14+.
```

---

## Prompt 10: Reusable components

```
I need a set of small reusable SwiftUI components for my macOS menu bar app. All should use native macOS dark mode colors, no custom themes.

1. **StatusDot(color: Color, pulsing: Bool = false)**
   - 8pt filled circle with a subtle outer glow ring (color.opacity(0.3), 2pt radius shadow)
   - If pulsing, animate opacity between 0.4 and 1.0

2. **Badge(text: String, style: BadgeStyle)** where BadgeStyle is .green, .red, .orange, .blue
   - Pill shape (10pt corner radius), 10pt text, medium weight
   - Tinted background (color.opacity(0.12–0.15)) with same-hue text

3. **MetadataGrid(items: [(key: String, value: String, valueColor: Color?)])**
   - Two-column grid: left column 11pt secondary text, right column 11pt monospace right-aligned
   - 3pt row gap, 12pt column gap

4. **MenuItemRow(icon: String, label: String, shortcut: String? = nil, action: () -> Void)**
   - Takes an SF Symbol name for the icon (14pt, secondary color)
   - Label 12pt primary text, shortcut 10pt tertiary text right-aligned
   - Full-width, 6pt corner radius, hover highlight

5. **ActionButton(label: String, icon: String, style: ActionButtonStyle, action: () -> Void)** where style is .primary, .secondary, .danger
   - Full-width rounded rect, 6pt corners, 12pt medium text, icon + label
   - Primary: blue-tinted bg + blue text. Secondary: transparent + secondary text. Danger: transparent + red text.

6. **SectionDivider()**
   - 0.5pt line using Color(.separatorColor)

SwiftUI, macOS 14+, no external dependencies.
```
