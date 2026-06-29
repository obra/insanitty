# 04 — Session & Workspace Data Model, Persistence, Lifecycle, Theming

## 1. Scope

### Files read in full
- `Fantastty/Models/Session.swift` (270 lines) — the `Session` workspace class
- `Fantastty/Models/SessionManager.swift` (2079 lines) — central orchestrator
- `Fantastty/Models/SessionType.swift` (112) — session-type enum + Codable
- `Fantastty/Models/SessionMetadata.swift` (407) — persistent metadata + `SessionMetadataStore`
- `Fantastty/Models/SessionDisplayInfo.swift` (124) — derived display/status strings
- `Fantastty/Models/SessionBackingState.swift` (6) — backing availability enum
- `Fantastty/Models/TerminalTab.swift` (104) — tab (terminal or browser)
- `Fantastty/Models/TerminalLifecycleRouter.swift` (39) — routes tab/pane lifecycle to tmux
- `Fantastty/Models/LayoutPersistence.swift` (117) — layout snapshot I/O
- `Fantastty/Models/LayoutSnapshot.swift` (103) — layout snapshot codable types
- `Fantastty/Models/V2/WorkspaceBindingStore.swift` (38) — workspace↔client binding map
- `Fantastty/Models/ThemeManager.swift` (131) — writes Ghostty theme files
- `Fantastty/Models/AppearanceMode.swift` (50) — light/dark/system mode
- `Fantastty/Models/SpriteManager.swift` (193) — Fly.io sprite CLI wrapper
- `Fantastty/Models/TmuxControlMode/TmuxAttachmentInfo.swift` (165) — `SessionMode`, `TmuxAttachmentInfo`, `TmuxHost`, `SSHHostInfo`, `ConnectionState`
- `Fantastty/Models/TmuxManager.swift` (293) — tmux session naming/discovery (read for naming + workspace grouping)
- `Fantastty/Models/TmuxControlMode/SSHHostStore.swift` (41) — saved SSH hosts
- Tests: `LayoutPersistenceTests.swift` (136), `SessionDisplayInfoTests.swift` (166), `TerminalLifecycleRouterTests.swift` (144) in full; `PersistenceTests.swift` (1009) — structure + key sections (Codable round-trips, save/restore, trash, SSHHostStore)

### Read for wiring context (not full)
- `App/AppDelegate.swift` (appearance/launch hooks), `GhosttyBridge/Ghostty.Config.swift` (theme overlay load), `GhosttyBridge/Ghostty.App.swift` (notification posting), `GhosttyBridge/Ghostty.Package.swift` (notification name defs), `Models/ShellIntegration.swift` (grep only)

### NOT covered (other agents' scope)
- tmux control-mode internals (`TmuxControlClient`, `TmuxSessionBridge`, layout mapping)
- Remote engine internals (`RemoteEngineClient`, `RemoteWorkspaceBridge`, QUIC, predictive echo)
- `SplitTree` implementation (splits subsystem)
- OSC/escape-sequence parsing and desktop-notification plumbing inside the Ghostty bridge
- Linear/sprite CLI protocol details, shell-integration script internals

---

## 2. What it does (behavior & features)

### The conceptual model
The sidebar shows **workspaces**. Each workspace is one `Session` (runtime object). A workspace owns an ordered list of **tabs**; each tab is either a **terminal** tab or a **browser** tab. A terminal tab owns a **split tree** of **panes**; each pane is one Ghostty surface (terminal view). The mapping to tmux:

| App concept | tmux concept | Stable identity |
|---|---|---|
| Workspace (`Session`) | tmux **session** named `fantastty-ws-<id>` | `workspaceID` (8-char) — persistent |
| Terminal tab (`TerminalTab`) | tmux **window** | `tmuxWindowID` / `tmuxWindowIndex` (runtime, from tmux) |
| Pane (`Ghostty.SurfaceView` leaf) | tmux **pane** | `surface.tmuxPaneID` (runtime, from tmux) |
| Browser tab | — (local WebKit) | URL + position only |

The only supported runtime is **attached tmux control mode** — `SessionMode` has exactly one case, `.attached(TmuxAttachmentInfo)` (`TmuxAttachmentInfo.swift:162`). "Local terminal", "SSH", and "remote engine" are all *attached* sessions differing by host + transport, not by mode.

### Session/transport taxonomy
Two orthogonal axes distinguish session kinds:
- `SessionType` (user-facing identity): `.local`, `.ssh(host,user,port)`, `.sprite(name)` (`SessionType.swift:4`).
- `TmuxAttachmentInfo.host` (`.local` / `.ssh`) + `.transport` (`.tmuxControl` / `.remoteEngine`).

Resulting combinations:
- **Local tmux**: type `.local`, host `.local`, transport `.tmuxControl`. tmux runs locally.
- **SSH tmux control**: type `.ssh`, host `.ssh`, transport `.tmuxControl`. Attaches `tmux -CC` over `ssh -t`.
- **Remote engine**: type `.ssh`, host `.ssh`, transport `.remoteEngine`. Connects the bundled Go helper over QUIC. Session name is `fantastty-remote-<id>` rather than `fantastty-ws-<id>` (`SessionManager.swift:1767`).
- **Sprite**: type `.sprite`, host `.local`. The `sprite console -s "<name>"` command runs *inside the local tmux* (`SessionType.swift:67`); it is not its own host.
- **Browser**: not a session type — a `TabKind.browser` tab (WebKit) inside any workspace (`TerminalTab.swift:7`).

### Lifecycle (create / restore / archive / trash / delete)
- **Create** (`createSession`, `SessionManager.swift:883`): generate an 8-char `workspaceID` (`UUID().uuidString.prefix(8).lowercased()`), build attachment with `launchMode = .create`, append + select, start reconnect if backing available. Auto-assign a name like **`bold-falcon`** if metadata name is empty (`generateWorkspaceName`, `SessionManager.swift:403` — random adjective+noun from two 20-word lists → 400 combos). Persist the attachment into metadata.
- **Create remote engine** (`createRemoteEngineSession`, `SessionManager.swift:1764`): same shape, transport `.remoteEngine`, starts the QUIC client.
- **Restore on launch** (`restoreTmuxSessions`, `SessionManager.swift:451`): gated by the `persistentSessions` setting. Reads `layout.json`; for each workspace in saved order, reconnects an attached session (skipping archived/trashed). Then appends any *live* tmux workspaces not in the layout, then appends **metadata-only placeholders** (workspaces known to metadata but with no layout entry/live tmux). Restores the previously selected workspace. **Terminal tabs are NOT restored from the layout** — they are reconstructed from tmux on reconnect; only **browser tabs** are restored (by URL + interleave position). `autoReconnect` is decided by `shouldAutoReconnect` (`:765`): local needs tmux available, SSH is always attempted.
- **Archive** (`archiveSession`, `:1011`): kill tmux, set `isArchived` + `archivedAt`, remove from active sessions. If it was the last session, a fresh one is created.
- **Unarchive** (`unarchiveSession`, `:1046`): clear `isArchived`, re-add as a placeholder.
- **Close = trash** (`closeSession`, `:937`): closing a workspace does **not** delete it — it sets `isTrashed` + `trashedAt` (soft delete, `updateLifecycleMetadata`). `killTmux` defaults true; the app passes `killTmux:false` at quit so sessions survive. If the last session is closed, a new one is auto-created. (Confirmed by `testCloseSessionMovesWorkspaceToTrash`.)
- **Restore trashed** (`restoreTrashedWorkspace`, `:1070`), **empty trash / delete** (`deleteTrashedWorkspace`, `deleteArchivedWorkspace`, `emptyTrash`, `:1094-1108`): permanent metadata removal.
- **Close tab** (`closeTab`, `:1161`): terminal tabs in tmux route a kill-window through `TerminalLifecycleRouter`; the tab is removed only when tmux echoes `%window-close`. Browser tabs are removed locally. Closing the last tab trashes the session.
- **Close pane** (`closeSurface`, `:1249`): tmux panes route kill-pane through the router; removal happens on `%layout-change`. Non-tmux panes are removed from the split tree locally.

### Attention indicators (bell / command-finish)
`Session.needsAttention` (persisted, with `attentionFlaggedAt` timestamp). Set **true only when the session is not currently selected** on:
- terminal **bell** (`handleBellDidRing`, `:1628`, plus a per-surface `$bell` Combine observer `:1730`) — also always calls `NSSound.beep()`,
- **command finished** (`handleCommandFinished`, `:1639`),
- arrival of a **session note** from the terminal (`handleSessionNote`, `:1662`).

Cleared when the user types in that session (`handleKeyInput`, `:1648`) or via `toggleAttention`/`clearAttention`. The flag drives a sidebar badge.

### Workspace metadata: URLs, tags, notes
`SessionMetadata` (`SessionMetadata.swift:50`) persists per workspace:
- `ticketURL`, `pullRequestURL` — settable programmatically or via terminal escape sequences (`.fantasttyTicketURL` / `.fantasttyPullRequestURL` notifications, `SessionManager.swift:1674-1686`).
- `tags: [String]`.
- `noteEntries: [SessionNoteEntry]` — a timestamped **note log**. Each entry has `id`, `timestamp`, `content`, `tags`, `source` (`terminal`/`user`/`system`), and a `revisions` history (editing a note pushes the old content into `revisions`, `SessionMetadata.swift:40`). Notes arrive from the terminal (`fantastty-note` shell helper → OSC → `.fantasttySessionNote`) or are added manually. A computed `notes: String` joins entry contents for back-compat.
- `totalActiveSeconds` — cumulative **focused** time. A 5s tick (`activityTick`, `:375`) adds 5s to the selected session only if the last input was < 60s ago (idle threshold). Flushed to disk on deselect, every 60s, and at quit.

### Theme / appearance
- `AppearanceMode` (`system`/`light`/`dark`) stored in `UserDefaults["appearance"]`. `applyCurrent` sets `NSApp.appearance`; `system` consults `NSApp.effectiveAppearance` (`AppearanceMode.swift`).
- On launch and whenever appearance changes, `applyGhosttyColorScheme` calls `ghostty_app_set_color_scheme(GHOSTTY_COLOR_SCHEME_DARK|LIGHT)` (`AppDelegate.swift:93`). A KVO observer on `NSApp.effectiveAppearance` keeps "system" mode in sync (`:71`).
- `ThemeManager` writes default `~/.fantastty/themes/Fantastty Light` + `Fantastty Dark` and a `~/.fantastty/ghostty-config` overlay (`theme = light:...,dark:...` + `window-theme = auto`) — **only if the user has no `~/.config/ghostty/config`** (`ThemeManager.swift:23,40`). The overlay is loaded into Ghostty config at startup (`Ghostty.Config.swift:83`).

---

## 3. How it's built (architecture)

### Key types
- `Session` (`Session.swift:5`) — `ObservableObject`. In-memory `id = UUID()` (fresh, **not persisted**). Persistent identity is `workspaceID`. Holds `tabs`, `selectedTabID`, `mode: SessionMode`, `backingState: SessionBackingState`, `controlClient: TmuxControlClient?`, live `totalActiveSeconds`. All metadata accessors (`name`, `tags`, `notes`, `ticketURL`, `needsAttention`, …) are thin proxies onto `SessionMetadataStore` keyed by `workspaceID`, firing `objectWillChange` after writes.
- `TerminalTab` (`TerminalTab.swift:13`) — `ObservableObject`. `kind` (terminal/browser), `surfaceTree: SplitTree<SurfaceView>?`, `focusedSurface`, browser `url`/`webView`, `tmuxWindowID`/`tmuxWindowIndex`, `terminalTabsBefore` (restore-time interleave hint).
- `SessionManager` (`SessionManager.swift:9`) — `ObservableObject`, the orchestrator. Owns `sessions: [Session]`, `selectedSessionID`, an O(1) `surfaceIndex: [ObjectIdentifier: (Session, TerminalTab)]`, the tmux/remote bridges, per-workspace `lifecycleRouterByWorkspaceID` and `remoteEngineClientsByWorkspaceID`. Routes libghostty `NotificationCenter` actions (new tab/split, close, goto tab, focus split, bell, command-finished, key input, notes, URLs) to the right session/tab.
- `SessionMetadataStore` (`SessionMetadata.swift:213`) — `ObservableObject` singleton (`.shared`). `@Published metadata: [String: SessionMetadata]` keyed by `workspaceID`. Loads/saves the whole map to `workspaces.json`.
- `TmuxAttachmentInfo` (`TmuxAttachmentInfo.swift:85`) — the attachment descriptor: `sessionName`, `host: TmuxHost`, `connectionState`, `launchMode`, `transport`. Generates the `tmux -CC attach`/`new-session` commands.
- `SessionDisplayInfo` (`SessionDisplayInfo.swift:4`) — pure value type that maps `(SessionMode, SessionBackingState)` → host label, connecting/reconnecting/disconnected/missing-backing booleans, status text, accessibility label, overlay flag. Cleanly separates derived UI strings from state (transport-aware copy for tmux vs remote-engine).
- `WorkspaceBindingStore` (`WorkspaceBindingStore.swift:3`) — bidirectional map `workspaceID ↔ Session` and `TmuxControlClient ↔ Session` (via `ObjectIdentifier`).

### Persistence formats (actual schemas)

All live under **`~/.fantastty/`**. JSON is pretty-printed, sorted-keys, **ISO-8601 dates**.

**`workspaces.json`** — a JSON **array** of `SessionMetadata` (`SessionMetadata.swift:188`). Per element:
```jsonc
{
  "id": "<UUID>",
  "workspaceID": "a1b2c3d4",          // 8-char, the stable key
  "name": "bold-falcon",
  "noteEntries": [
    { "id": "<UUID>", "timestamp": "<ISO8601>", "content": "...",
      "tags": ["..."], "source": "terminal|user|system",
      "revisions": [ { "content": "...", "timestamp": "<ISO8601>" } ] }
  ],
  "needsAttention": false,
  "attentionFlaggedAt": "<ISO8601>",   // omitted when nil
  "tags": ["..."],
  "isArchived": false, "archivedAt": "<ISO8601>",   // archivedAt omitted when nil
  "isTrashed": false,  "trashedAt": "<ISO8601>",    // trashedAt omitted when nil
  "ticketURL": "...", "pullRequestURL": "...",       // omitted when nil
  "attachment": { <TmuxAttachmentInfo> },            // omitted when nil
  "createdAt": "<ISO8601>", "modifiedAt": "<ISO8601>",
  "totalActiveSeconds": 0.0
}
```
The computed `notes` string is **not** encoded. Decoder is migration-tolerant: every field uses `decodeIfPresent` with defaults, so older/partial files load cleanly (`SessionMetadata.swift:165`).

**`layout.json`** — a single `LayoutSnapshot` (`LayoutSnapshot.swift:4`):
```jsonc
{
  "schemaVersion": 1,                 // attachedOnlySchemaVersion; absent → decodes as 0 (legacy)
  "workspaces": [
    {
      "workspaceID": "a1b2c3d4",
      "tabs": [ { "kind": "terminal" }, { "kind": "browser", "url": "https://..." } ],
      "selectedTabIndex": 2,          // index into the FULL tab list (terminal+browser)
      "sessionType": { <SessionType> }, // omitted when .local
      "attachment": { <TmuxAttachmentInfo> }
    }
  ],
  "selectedWorkspaceID": "a1b2c3d4",
  "savedAt": "<ISO8601>"
}
```
Only `.attached` sessions are written (`LayoutPersistence.swift:32`). All tabs are persisted (terminal as kind-only placeholders) so browser tabs keep their position relative to terminal tabs on restore. The persisted attachment is normalized to `connectionState = .disconnected(nil)`, `launchMode = .attach` (`:111`).

**Nested enum encodings** (Swift-synthesized; the Linux port must match these shapes to read existing files):
- `TmuxHost`: `{"local":{}}` or `{"ssh":{"_0":{ "hostname":..., "user":..., "port":... }}}`.
- `ConnectionState`: `{"connecting":{}}` / `{"connected":{}}` / `{"reconnecting":{"reason":...}}` / `{"disconnected":{"reason":...}}`.
- `SessionType` has a **hand-written** Codable: `{"kind":"local"}` / `{"kind":"ssh","host":...,"user":...,"port":...}` / `{"kind":"sprite","spriteName":...}` (`SessionType.swift:75`).
- `launchMode`/`transport` are string raw-values.

**`ssh-hosts.json`** — JSON array of `SSHHostInfo` (`SSHHostStore.swift`), saved SSH targets for the connect sheet.

**Other `~/.fantastty/` artifacts** (written by adjacent subsystems): `themes/Fantastty Light`, `themes/Fantastty Dark`, `ghostty-config` (ThemeManager); `shell/zsh/.zshenv`, `shell/zsh/.zshrc`, `shell-integration/osc7-passthrough.zsh` (ShellIntegration); `~/.fantastty_debug.log` (sibling file).

**UserDefaults / `@AppStorage` keys**: `persistentSessions` (Bool, gates restore/save), `appearance` (String), `showArchivedSessions`, `showTrashedSessions`, `tabsInSidebar` (Bool), plus the remote predictive-echo key.

### Control flow & invariants
- The stable key everywhere is `workspaceID`; `Session.id`/`TerminalTab.id`/`SurfaceView.id` are ephemeral. Tabs and panes are **not** persisted by identity — they are rebuilt from tmux state. Layout persistence stores only ordering and browser URLs.
- `makeAttachedSession` (`:2032`) constructs the `Session`, sets `.attached(info)`, and for `.tmuxControl` transport creates a `TmuxControlClient` + registers with the tmux bridge.
- Reconnect: `startAttachedSessionReconnect` (`:862`) sets `connectionState = .connecting`, calls the injectable `attachedSessionReconnectStarter` (default `:159` runs `client.connect()` with a 20s timeout), and on failure with no terminal tabs marks `backingState = .missingAttachedBacking(reason)`.
- A restored-but-unreachable workspace stays as a **disconnected placeholder** (empty tabs, `missingAttachedBacking`), surfaced by `SessionDisplayInfo` rather than being dropped (`testRestoreTmuxSessionsKeepsDisconnectedPlaceholderWhenReconnectFails`).
- Remote-engine fallback: if the QUIC engine fails before any remote pane renders and the host is SSH, the session **falls back to SSH tmux control mode** in place (`fallbackRemoteEngineSessionToSSHControlMode`, `:2008`).

### Threading / concurrency
`SessionManager` and the stores are `ObservableObject`s mutated on the main thread; many methods/closures are `@MainActor` or hop via `Task { @MainActor }` / `DispatchQueue.main`. Combine drives the activity tick (5s), the disk flush + layout save (60s), and selection-change flush. Subprocess work (`TmuxManager`, `SpriteManager`) runs `Process` on `DispatchQueue.global`. Persistence writes are `Data.write(options: .atomic)`. The `surfaceIndex` gives O(1) surface→session/tab lookup with a linear fallback (`:1307`).

---

## 4. Platform dependencies (macOS-specific)

**AppKit**
- `NSApp.appearance`, `NSAppearance(named: .aqua/.darkAqua)`, `NSApp.effectiveAppearance`, `(NSAppearance).isDark` (`AppearanceMode.swift`).
- `NSApp.observe(\.effectiveAppearance)` — KVO for live system dark/light switches (`AppDelegate.swift:71`).
- `NSEvent.addLocalMonitorForEvents([.leftMouseDown,…,.scrollWheel,.mouseMoved])` — keeps the idle clock alive on mouse activity (`SessionManager.swift:1464`); removed in `deinit`.
- `NSSound.beep()` on bell (`:1629`).
- `NSWorkspace.shared.open(url)` for opening links in the system browser (`:1232`).
- `NSAlert` (tabs-disabled warning, in `Ghostty.App.swift`).

**WebKit**
- `WKWebView` backs browser tabs (`TerminalTab.swift:31`).

**GhosttyKit (C API)**
- `ghostty_app_set_color_scheme`, `GHOSTTY_COLOR_SCHEME_DARK/LIGHT` (`AppDelegate.swift:95`).
- `ghostty_surface_binding_action(_, "clear_screen", …)` (`:1223`).
- `ghostty_config_load_file` for the theme overlay; split-direction enums in notification routing.
- `Ghostty.SurfaceView` is an `NSView` subclass; surfaces carry runtime extensions `tmuxPaneID`, `tmuxControlClient`, `remotePaneInputHandler`.

**Foundation / SwiftUI / Combine**
- `FileManager.homeDirectoryForCurrentUser` → hardcoded `~/.fantastty/...` and `~/.config/ghostty/config` (`ThemeManager`, `SessionMetadata`, `LayoutPersistence`, `SSHHostStore`).
- `Process` + `Pipe` + `FileHandle.nullDevice` to shell out to `tmux`, `ssh` (`/usr/bin/ssh` hardcoded), `sprite` (`TmuxManager`, `SpriteManager`).
- Hardcoded binary search paths: tmux `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/run/current-system/sw/bin` (NixOS already present); sprite `~/.local/bin`, `/usr/local/bin`, `/opt/homebrew/bin`, `~/.fly/bin`.
- `UserDefaults` + SwiftUI `@AppStorage` for settings (`persistentSessions`, `appearance`, …) and SwiftUI `ObservableObject`/`@Published` reactivity throughout the model.
- `NotificationCenter` for the libghostty action bus; `os.Logger` with `subsystem: Bundle.main.bundleIdentifier`.
- `NotificationCenter.publisher(for: UserDefaults.didChangeNotification)` to react to settings changes.

**Adjacent (named in brief, not in these files)**: Linear token in the macOS **Keychain**.

---

## 5. Linux mapping

| macOS dependency | Linux-native equivalent |
|---|---|
| `NSApp.appearance` / `NSAppearance` light-dark | GTK4/libadwaita `AdwStyleManager.color_scheme` (`PREFER_DARK`/`PREFER_LIGHT`/`DEFAULT`); per-window via `AdwStyleManager`. |
| `NSApp.effectiveAppearance` + KVO for "system" | XDG Settings portal `org.freedesktop.appearance` `color-scheme` (read + `SettingChanged` D-Bus signal) via `xdg-desktop-portal`; libadwaita exposes this as `AdwStyleManager:dark`/`:system-supports-color-schemes`. |
| `ghostty_app_set_color_scheme` | **Unchanged** — same libghostty C call. |
| `NSEvent.addLocalMonitorForEvents` (idle/mouse) | No global input monitor on Wayland by design. Use GTK event controllers (`GtkEventControllerMotion`/key) per surface for input, and `ext-idle-notify-v1` (Wayland) or `org.freedesktop.ScreenSaver`/`login1` D-Bus idle for true idle. **RISK**: behavior differs; likely re-architect idle detection around GTK input events already flowing through surfaces. |
| `NSSound.beep()` | `gtk_widget_error_bell()` or `libcanberra` (`ca_context_play`, event `bell`/`dialog-error`). |
| `NSWorkspace.shared.open(url)` | `gtk_show_uri`/`gtk_uri_launcher` or `g_app_info_launch_default_for_uri` (XDG). |
| `WKWebView` (browser tabs) | **WebKitGTK** `WebKitWebView`. API differs; needs a rewrite of the tab view + title/URL observation. |
| `UserDefaults` / `@AppStorage` | `GSettings`/dconf, or a keyfile under `$XDG_CONFIG_HOME`. The harder part is replacing SwiftUI's reactive `@AppStorage` binding (see §7). |
| `~/.fantastty/*` paths | XDG base dirs: data (`workspaces.json`, `layout.json`, `ssh-hosts.json`) under `$XDG_DATA_HOME/fantastty`; could keep `~/.fantastty` for parity but XDG is the native choice. Ghostty already uses XDG (`$XDG_CONFIG_HOME/ghostty/config`) on Linux — the "user has own config" check ports directly. |
| `Process`/`Pipe` (tmux/ssh/sprite) | Ports largely as-is; GLib `GSubprocess` is the idiomatic alternative. Binary search paths need Linux defaults (`/usr/bin`, `/usr/local/bin`, Nix path already there; drop Homebrew). |
| `os.Logger` | `g_log`/structured logging or systemd journal (`sd_journal`). |
| `NotificationCenter` / Combine | swift-corelibs-foundation provides `NotificationCenter`; Combine is **not** on Linux — replace with an observation mechanism (GObject signals, callbacks, or swift-async-algorithms). |
| Keychain (Linear token, adjacent) | **libsecret / Secret Service** (`org.freedesktop.secrets`). |
| `Bundle.main.bundleIdentifier` | App-ID string constant. |

The persistence/business logic itself (`SessionMetadata`, `SessionMetadataStore`, `LayoutPersistence`, `LayoutSnapshot`, `TmuxAttachmentInfo`, `SessionDisplayInfo`, `Session` lifecycle, naming, attention, activity) is plain Foundation and ports with only the path swap.

---

## 6. Reuse assessment

**Ports as-is (cross-platform Swift/Foundation):**
- `SessionType`, `SessionBackingState`, `SessionDisplayInfo`, `TmuxAttachmentInfo`/`SessionMode`/`TmuxHost`/`SSHHostInfo`/`ConnectionState`, `LayoutSnapshot`/`WorkspaceLayout`/`WorkspaceTabLayout`, `LayoutPersistence`, `WorkspaceBindingStore`, `TerminalLifecycleRouter`, `SSHHostStore`.
- `SessionMetadata` + `SessionMetadataStore` (swap base dir).
- `TmuxManager` naming/discovery/kill logic (swap binary paths).
- The bulk of `SessionManager`: workspaceID generation, name generation (`bold-falcon`), restore ordering, archive/trash/unarchive, metadata-only placeholders, attention/activity tracking, reconnect/fallback state machine, layout save/load. The injectable provider seams (`attachedSessionReconnectStarter`, `tmuxAvailabilityProvider`, `liveTmuxWorkspaceProvider`, `workspaceMetadataProvider`) make it testable and decoupled from platform glue — a real asset for the port.

**Must be rewritten (macOS glue):**
- `AppearanceMode` (NSAppearance) → libadwaita/portal.
- The `Session`/`TerminalTab`/`SessionManager`/store **reactivity layer** (`ObservableObject`/`@Published`/`@AppStorage`/Combine) → a Linux observation story.
- Browser tab (`WKWebView`) → WebKitGTK.
- Mouse/idle monitor, `NSSound.beep`, `NSWorkspace.open`.
- `ThemeManager` is *mostly* portable (it just writes files + checks for `~/.config/ghostty/config`); only the home-dir resolution changes.

**Reusable from Ghostty's own Linux/GTK frontend:**
- Color-scheme application, surface embedding (GTK/OpenGL), bell handling, OSC parsing/desktop notifications, the libghostty action bus — the GTK apprt already implements these natively, so the note/ticket/bell/command-finished *sources* can be wired from Ghostty's Linux side instead of reimplemented.

---

## 7. Open questions / risks

1. **Reactivity model.** The entire model leans on SwiftUI `ObservableObject`/`@Published`/`@AppStorage` and Combine pipelines (timers, selection-change flush, settings observation). None of these exist on Linux Swift. The port needs a chosen observation framework (GObject signals, Swift `Observation`, or hand-rolled callbacks) before this logic can be lifted. **Highest-leverage decision.**
2. **Idle/attention detection.** The global `NSEvent` mouse monitor has no Wayland equivalent. Idle accounting (`totalActiveSeconds`) and attention-clear-on-input must be re-derived from GTK per-surface input events + a Wayland/D-Bus idle signal. Behavior will differ; needs a design.
3. **"System" appearance.** Requires `xdg-desktop-portal` (the `org.freedesktop.appearance` portal). On minimal/headless setups the portal may be absent — need a fallback (e.g. `GTK_THEME`/env or default to dark).
4. **On-disk JSON compatibility.** Swift's *synthesized* enum Codable shapes (`TmuxHost`, `ConnectionState`) and the hand-written `SessionType` encoding define the exact wire format of `workspaces.json`/`layout.json`. If the Linux port reimplements these types (different Swift version or language), it must reproduce the shapes byte-for-byte to read existing files. Since these are Fantastty-private files and this is a fresh port, **confirm whether reading existing macOS state is a requirement** — if not, the format can be cleaned up; if yes, lock the schema. (Per global rules, any back-compat work needs explicit sign-off.)
5. **Browser tabs.** WebKitGTK integration (process model, title/URL observation, snapshot/thumbnail) is a non-trivial rewrite; verify WebKitGTK availability/packaging on target distros.
6. **Sprite + Linear (adjacent).** Sprite is a local CLI wrapper (ports as Process); the Linear token storage moves from Keychain to libsecret. Out of this subsystem but they touch the same `~/.fantastty` story.
7. **Single-runtime assumption.** `SessionMode` having only `.attached` and the hardcoded `fantastty-ws-<id>` / `fantastty-remote-<id>` naming bake tmux/remote-engine deeply into the model. This is fine to carry over, but worth confirming the Linux port keeps the same "everything is an attached tmux session" invariant.
