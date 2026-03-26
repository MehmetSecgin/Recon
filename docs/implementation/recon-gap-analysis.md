# Recon — Gap analysis (v0.1.0 → v0.2)

A side-by-side breakdown of what exists today versus what the redesign calls for, organized by area.

---

## Status header

| Aspect | v0.1.0 (current) | v0.2 (target) |
|---|---|---|
| State display | Green dot + "Connected" + "Connected" (redundant sub-label) + timestamp | Green dot + "Connected" + relative timestamp ("12 min ago"). No redundant sub-label. |
| Error display | "LAST ERROR" section at the bottom with truncated string | Error message inline in status header with structured message + suggestion + escape hatches |
| Prod awareness | None | Red dot, PRODUCTION badge, warning banner, red context text |
| Connecting state | Not visually distinct | Pulsing orange dot + "Connecting…" + progress bar + Cancel button |

**Delta:** Remove redundant sub-label. Add production detection. Move error from bottom to inline. Add connecting state UX.

---

## Target metadata

| Aspect | v0.1.0 | v0.2 |
|---|---|---|
| Kubeconfig | Shown as dropdown picker ("config-qa") with "Choose…" | Shown as read-only text in metadata grid + "Choose kubeconfig…" in utilities menu |
| Context | Not shown | Shown in metadata grid, monospace, red if prod |
| Namespace | Not shown | Shown in metadata grid, monospace |
| Kubeconfig mode | Not shown | "Pinned to file" vs "Inherited (3 files)" vs "default" |

**Delta:** This is the biggest information gap. Context and namespace are the two most important targeting nouns and are completely absent today.

---

## Intercepts

| Aspect | v0.1.0 | v0.2 |
|---|---|---|
| Visibility | None | Read-only section: service name + active badge + port mapping |
| Empty state | N/A | "No active intercepts" (always shown when connected) |

**Delta:** Entirely new section. Requires parsing `telepresence list` output.

---

## Actions

| Aspect | v0.1.0 | v0.2 |
|---|---|---|
| Layout | 4 buttons stacked vertically, all visible at once | 1–2 buttons horizontally, state-driven |
| Connect | Always shown, disabled when connected | Only shown when disconnected (primary style) |
| Disconnect | Always shown | Only shown when connected (danger style) |
| Reconnect | Always shown | Only shown when connected or in error (secondary or primary) |
| Refresh Now | Dedicated button | Moved to utilities menu or triggered by pull-down / timer |
| Cancel | Not available | Shown during connecting state |
| Busy state | Not handled | All actions disabled, progress indicator shown |

**Delta:** Reduce from 4-always-visible to 1–2 state-relevant buttons. Add Cancel. Add busy state handling.

---

## Error handling

| Aspect | v0.1.0 | v0.2 |
|---|---|---|
| Error display | "LAST ERROR" section at bottom, truncated red text | Structured error banner inline: icon + message + suggestion |
| Next step | None — user sees "failed to launch the daemon service: ex…" and has no guidance | Each error maps to a human-readable message + suggested action |
| CLI escape | None | "Copy 'telepresence status'" + "Open logs…" immediately accessible |
| Error persistence | Shown until next refresh | Shown until state changes, also logged to event history |

**Delta:** Errors go from cryptic truncated strings to actionable messages with escape hatches.

---

## CLI escape hatches

| Aspect | v0.1.0 | v0.2 |
|---|---|---|
| Copy status command | Not available | "Copy 'telepresence status'" in utilities menu |
| Copy list command | Not available | "Copy 'telepresence list'" in utilities menu |
| Open logs | Not available | "Open logs…" with ⌥L shortcut |
| Reveal kubeconfig | Not available | Available in Paths tab of Preferences |
| Copy diagnostic command | Not available | Available in Diagnostics window |

**Delta:** Entirely new capability. Critical for the "trust" story — users can always escape to the CLI.

---

## Preferences

| Aspect | v0.1.0 | v0.2 |
|---|---|---|
| Location | In-popover accordion ("Preferences…" disclosure) | Standalone window with tabs |
| Scope | Unknown (accordion is collapsed in screenshot) | General (startup, connection, appearance), Notifications (per-event toggles), Paths (tools, kubeconfig, logs) |
| Notification control | Unknown | Fine-grained per-event toggles + permanently suppressed events list |
| Kubeconfig mode | Not configurable | Pinned vs. Follow $KUBECONFIG |
| Tool paths | Not configurable | Detect + manual override for telepresence and kubectl |

**Delta:** Major expansion. The accordion is replaced by a proper window that can grow without bloating the popover.

---

## Diagnostics

| Aspect | v0.1.0 | v0.2 |
|---|---|---|
| Component health | Not available | 2×2 grid: user daemon, root daemon, Traffic Manager, DNS |
| Session details | Not available | Session ID, version, cluster, subnets, DNS suffix, connected-since |
| Log viewer | Not available | Embedded dark-background log viewer with level filtering |
| Event history | Not available | 7-day event timeline with colored dots |
| Diagnostic export | Not available | "Export diagnostic bundle" wrapping telepresence gather-logs |

**Delta:** Entirely new window. Moves debug info out of the user's face but makes it reachable in two clicks.

---

## Menu bar icon

| Aspect | v0.1.0 | v0.2 |
|---|---|---|
| State encoding | Unclear from screenshot (likely static icon) | Dynamic: green checkmark (connected), red checkmark (prod), orange pulse (connecting), red triangle (error), gray X (disconnected) |
| Color+shape pairing | Unknown | Every state has a unique shape AND color — never color alone |
| Monochrome option | Not available | User can choose monochrome (shape-only) in Preferences |

**Delta:** Icon becomes the first glance — it should answer "am I connected?" without clicking.

---

## Notifications

| Aspect | v0.1.0 | v0.2 |
|---|---|---|
| Implementation | Unknown | UNUserNotificationCenter with lazy permission request |
| Triggers | Unknown | 4 events: unexpected disconnect, reconnect failed, recovery, prod context |
| Suppression | Unknown | Routine polls and successful connects permanently suppressed |
| User control | Unknown | Per-event toggles in Preferences → Notifications |

**Delta:** If notifications exist in v0.1.0, they likely need tightening. If they don't, this is net-new.

---

## Summary: effort by phase

| Phase | Effort estimate | Depends on |
|---|---|---|
| Phase 1: Popover redesign | Medium — restructure views, add metadata grid + intercepts | Telepresence parsing improvements |
| Phase 2: Prod safety + errors | Small-medium — mostly new views + error mapping table | Phase 1 |
| Phase 3: Preferences window | Medium — new window, 3 tabs, settings model | Phase 1 (to remove accordion) |
| Phase 4: Diagnostics window | Medium-large — log viewer, event history storage, health grid | Phase 1 |
| Phase 5: Kubeconfig chooser + notifications | Medium — file scanning, chooser UI, notification service | Phase 3 (for settings) |

Phases 1 and 2 deliver the most user-visible value per effort. Phase 1 alone — adding context/namespace visibility and state-driven actions — is probably the single highest-impact change.
