# 06 — tmux Integration (Local Persistence + Control Mode) & Shell Integration

## 1. Scope

### Files read in full
| File | Lines |
|------|-------|
| `Fantastty/Models/TmuxManager.swift` | 292 |
| `Fantastty/Models/TmuxSessionBridge.swift` | 443 |
| `Fantastty/Models/ShellIntegration.swift` | 138 |
| `Fantastty/Resources/shell-integration/fantastty.sh` | 40 |
| `Fantastty/Models/TmuxControlMode/TmuxControlClient.swift` | 1281 |
| `Fantastty/Models/TmuxControlMode/TmuxProtocolParser.swift` | 525 |
| `Fantastty/Models/TmuxControlMode/TmuxEvent.swift` | 73 |
| `Fantastty/Models/TmuxControlMode/TmuxLayoutParser.swift` | 165 |
| `Fantastty/Models/TmuxControlMode/TmuxLayoutMapper.swift` | 80 |
| `Fantastty/Models/TmuxControlMode/TmuxPaneController.swift` | 48 |
| `Fantastty/Models/TmuxControlMode/TmuxWindowController.swift` | 163 |
| `Fantastty/Models/TmuxControlMode/AttachedTmuxWindowRuntime.swift` | 75 |
| `Fantastty/Models/TmuxControlMode/TmuxAttachmentInfo.swift` | 164 |
| `Fantastty/Models/TmuxControlMode/CommandQueue.swift` | 139 |
| `Fantastty/Models/TmuxControlMode/CoalescingInjector.swift` | 68 |
| `Fantastty/Models/TmuxControlMode/SSHHostStore.swift` | 40 |
| `Fantastty/Models/TmuxControlMode/V2/AttachedWorkspaceRuntimeV2.swift` | 125 |
| `Fantastty/Models/TmuxControlMode/V2/AttachedWindowRuntimeV2.swift` | 35 |
| `Fantastty/Models/TmuxControlMode/V2/AttachedPaneRuntimeV2.swift` | 18 |
| `Fantastty/Models/TmuxControlMode/V2/AttachedRuntimeActionV2.swift` | 18 |
| `Fantastty/Models/TmuxControlMode/V2/AttachedRuntimeEventV2.swift` | 12 |
| `Fantastty/Models/V2/WorkspaceBindingStore.swift` | 38 |
| `Fantastty/Models/TerminalLifecycleRouter.swift` | 39 |
| `docs/superpowers/specs/2026-03-14-tmux-control-mode-architecture-design.md` | 167 |
| `docs/superpowers/plans/2026-03-16-tmux-resize-redesign.md` | 560 |

### Files read in part (relevant slices only)
- `Fantastty/Models/SessionManager.swift` (tmux glue: ~111–290, 419–648, 758–980, 2032–2079) — workspace lifecycle, restoration, connect/reconnect.
- `Fantastty/GhosttyBridge/SurfaceView_AppKit.swift` (282–326, 720–778) — `AttachedTmuxInputRouter`, keystroke→tmux routing.
- `Fantastty/GhosttyBridge/Ghostty.App.swift` (1455–1509) — OSC 9 `fantastty:note;` interception.
- `Fantastty/Splits/SplitTree.swift` (constraints only) — `SplitTree<ViewType: NSView & Codable & Identifiable>`.
- Tests: `TmuxControlClientTests.swift` (handshake/parse slices + name survey), `TmuxResizeTests.swift` (full), `TmuxLayoutMapperTests.swift` (direction semantics). Surveyed names of `TmuxProtocolParserTests`, `TmuxLayoutParserTests`, `TmuxPaneControllerTests`, `TmuxWindowControllerTests`, `CommandQueueTests`, `TmuxSessionBridgeTests`, `AttachedWindowRuntimeV2Tests`, `AttachedWorkspaceRuntimeV2Tests`.

### NOT covered
- The **RemoteEngine** transport (QUIC + Go helper) — a parallel attachment path (`transport: .remoteEngine`); separate report. I only noted its branch points.
- Full `SessionManager` (1600+ lines), Views layer, `SplitTree` internals, thumbnail/activity tracking.
- Persisted layout schema details (`LayoutPersistence`/`LayoutSnapshot`) beyond what touches tmux restore.

---

## 2. What it does (behavior & features)

### Persistent, tmux-backed workspaces
- Every **local workspace** is backed by exactly **one tmux session** named `fantastty-ws-<workspaceID>` (`TmuxManager.baseSessionName`, `TmuxManager.swift:46`). `workspaceID` is an 8-char lowercased UUID prefix.
- Inside that one session, **each tmux window = one app tab**, and **each tmux pane = one split surface** in that tab. Splitting a tab issues `split-window`; new tab issues `new-window`; closing a tab issues `kill-window`; closing a pane issues `kill-pane`.
- Sessions **survive app restart and crash**: tmux keeps running when the app quits (`closeSession(killTmux: false)` on app shutdown). On next launch the app discovers and re-attaches.
- Tabs/splits are **not persisted by the app** for terminal content — they are **re-derived from tmux** on attach (the live tmux layout drives the split tree). Only **browser tabs** are persisted in `layout.json`. So whatever the tmux server still holds (windows, panes, scrollback) is exactly what comes back.
- **Explicit workspace close** kills tmux: `killWorkspaceSessions` runs `kill-session -t` for every `fantastty-ws-<id>*` (`TmuxManager.swift:252`). Archiving/trashing also tears tmux down.

### Discovery / restore on launch (`SessionManager.restoreTmuxSessions`, SessionManager.swift:451)
1. Loads a `LayoutSnapshot` (sidebar order, tab order, selection) if present.
2. Discovers live sessions via `tmux list-sessions -F '#{session_name}:#{session_created}:#{session_windows}'`, filtered to the `fantastty-` prefix (`listFantasttySessions`).
3. Cross-references a metadata store (skips archived/trashed workspaces — defensive even though their tmux should be dead).
4. Restores workspaces in layout order, appends any live-but-unlayouted sessions, then metadata-only placeholders.
5. Each restored workspace becomes an **attached** session (`launchMode: .attach`) and auto-reconnects (gated on tmux being installed for local; always for SSH).
- Metadata store also persists `TmuxAttachmentInfo` as a fallback so a workspace survives even if `layout.json` is lost/corrupt (`attachToTmuxSession`, SessionManager.swift:2069).

### Attaching to arbitrary tmux sessions
- A user can attach to **any** local or remote tmux session (not just `fantastty-` ones) via the attach sheet. `listAllSessions` (local) and `listRemoteSessions(host:)` (SSH) enumerate them. Remote discovery shells out: `ssh -o ConnectTimeout=5 -o BatchMode=yes [-p N] [user@]host tmux list-sessions -F ...` (`TmuxManager.swift:160`).

### Connection states & placeholder UI
- `ConnectionState`: `connecting | reconnecting | connected | disconnected(reason)`. `SessionBackingState`: `available | missingAttachedBacking(reason)`.
- When a connection drops and no terminal tabs remain, the workspace enters `missingAttachedBacking` (a "placeholder" / re-attach prompt). Reconnect has a **20s handshake timeout** (`connectAttachedSessionWithTimeout`, SessionManager.swift:138).

### Live input/output behavior
- **Output**: tmux `%output` for a pane is injected into that pane's Ghostty surface. The local child process under each surface is a deliberately **silent** `cat >/dev/null` (`TmuxSessionBridge.attachedTmuxSilentCommand`, line 23) so the only thing drawn is tmux's injected stream.
- **Keystrokes**: in attached panes, keys are routed to tmux via `send-keys -t %<pane> -H <hex>` rather than to the local PTY (`AttachedTmuxInputRouter`, SurfaceView_AppKit.swift:282; `sendPaneInput`, line 738). **⌘-modified keys stay local** (app shortcuts); everything else goes to tmux for full app fidelity (vim, readline, etc.).
- **Extended keys**: connection enables `set-option -g extended-keys on` so modified keys produce CSI-u sequences (e.g. shift-enter → `ESC[13;2u`).
- **Resize**: window/pane size is driven from the surface's rendered grid size and pushed to tmux (debounced). Resizing the macOS window reflows tmux.
- **Pane titles**: screen-title escape sequences (`ESC k … ESC \`) embedded in pane output are stripped and surfaced as pane titles.

### Shell integration (two distinct mechanisms)
1. **`fantastty-note` / `fn`** (`fantastty.sh`, manually sourced): sends OSC 9 with a `fantastty:note;<text>` payload. Wrapped for tmux DCS passthrough (`ESC Ptmux; … ESC \`), GNU screen passthrough, or emitted directly (works over SSH/mosh). The app intercepts the OSC 9 desktop-notification and files it as an **in-app timestamped note** instead of a system notification (`Ghostty.App.swift:1476`). Same channel carries `fantastty:ticket;` and `fantastty:pr;` for workspace URL metadata.
2. **OSC 7 pwd tracking** (`ShellIntegration.swift`, auto-written): a ZDOTDIR proxy + `osc7-passthrough.zsh` hook that, inside tmux interactive zsh, reports cwd on every `chpwd`/`precmd` as `ESC Ptmux; ESC ESC]7;kitty-shell-cwd://<host><pwd> BEL ESC \` (DCS-wrapped OSC 7) so the outer Ghostty learns the pwd through tmux. **NOTE: this path appears unwired — see §7.**

---

## 3. How it's built (architecture)

### Layered event chain (per the design spec)
```
PTY/SSH transport ──lines──▶ TmuxControlClient (actor, protocol layer)
                                   │ @MainActor delegate callbacks
                                   ▼
                         TmuxSessionBridge (TmuxControlClientDelegate)
                                   │ routes events through a pure reducer …
                                   ▼
                  AttachedWorkspaceRuntimeV2 (value-type state machine)
                                   │ … which returns [AttachedRuntimeActionV2]
                                   ▼  bridge applies actions to UI model
              TmuxWindowController (1 per tmux window / app tab)
                                   │ owns SplitTree + per-pane controllers + resize subs
                                   ▼
              TmuxPaneController (1 per pane) ──▶ CoalescingInjector
                                                     │ ghostty_surface_inject_output()
                                                     ▼  Ghostty.SurfaceView (NSView)
```

### Transport (`TmuxControlClient.swift`)
- `TmuxControlTransport` protocol; production impl `PtyTmuxControlTransport` (line 80).
- Spawns `/bin/sh -lc "<control command>"` on a **pseudo-terminal** created with `openpty()` (Darwin). The PTY is mandatory: tmux `-CC` needs a tty. slave fd → child's stdin/out/err; master fd is read/written by the app.
- **Read loop** runs on `Task.detached`, splits on `0x0a`, emits each line (`readLoop`, line 190).
- **Writes** are dispatched to a serial `DispatchQueue` (line 93) precisely to avoid a deadlock: if the actor wrote inline and tmux's stdout buffer was full, the actor couldn't drain the read side → circular block. This is a real, documented hazard (line 88–93, 145–149).
- Lines/terminations are funneled through an `AsyncStream<TransportEvent>` consumed by a single actor task (`handleTransportEvent`, line 740) — serializes all protocol handling onto the actor.

### Connection handshake (`connect()`, line 402) — exact order
1. If `launchMode == .create`: run a **separate** synchronous `Process` for `tmux has-session -t 'NAME' 2>/dev/null || tmux new-session -d -s 'NAME' -c ~` (`createSessionCommand`, TmuxAttachmentInfo.swift:121). This keeps the control transport on the simpler attach path.
2. Control command = `tmux -CC attach-session -t 'NAME'` (local) or `<ssh -t prefix> tmux -CC attach-session -t 'NAME'` (SSH) (`controlCommand`, line 109). Local tmux path resolved from `TmuxManager` candidate list; remote is bare `tmux`.
3. Force `TERM=xterm-256color` if unset/`dumb`.
4. **Pre-enqueue a nil command slot** for tmux's one spontaneous `%begin/%end` greeting *before* starting the reader (avoids a startup race), set state `.connecting`.
5. Start transport; `await waitForInitialGreeting()` (blocks on a `CheckedContinuation` resolved by the first `%end`).
6. `send("display-message -p ready")` — the ready handshake (`readyCommand`, line 1071).
7. `send("set-option -g extended-keys on")`.
8. `bootstrapWindows()`: `list-windows -F '#{window_id}\t#{window_name}\t#{window_layout}\t#{window_index}\t#{window_active}'`; parse each row (`parseBootstrapWindowLine`, line 1035), build `TmuxWindow` + layout, fire `didAddWindow` then `didChangeLayoutForWindowID` per window, then **pause %output** for all panes via `refresh-client -A '%<id>:pause'` and record `_pausedPaneIDs` (line 605).
9. If `.create` and still no windows: `newWindow()`.
10. State `.connected`.

### Command/response protocol (block framing)
- Every command response is framed `%begin <ts> <id> <flags>` … payload … `%end <ts> <id> <flags>` (success) or `%error …` (failure).
- `CommandQueue` (CommandQueue.swift) is a strict **FIFO** of `CheckedContinuation`s (or `nil` for fire-and-forget). `%end` → `setCurrentResponse` + `dequeue` (resumes the awaiting `send()` with the block body); `%error` → `dequeueWithError(.serverError(msg))`.
- `TmuxControlBlockTracker` accumulates the active block and enforces invariants: no nested `%begin`, matched ids on `%end`/`%error`. A violation **inside** an active block tears the connection down as a protocol violation (`handleProtocolViolation`, line 997); **outside** a block it is tolerated (lenient dequeue) because some tmux builds emit stray `%end`/`%error` (line 835–896).
- Spec guarantee leveraged: notifications never occur inside a block, so any `%`-line that isn't `%end`/`%error` while a block is open is treated as **literal payload** (e.g. shell output starting with `%`) (line 812–818).

### Protocol parser (`TmuxProtocolParser.swift`) — value type, no I/O
- `parse(lineData:)` operates on **raw bytes**; strips trailing `\r`, strips the one-time DCS prefix `ESC P 1000 p`, strips leading control/whitespace before the first `%`.
- **`%output` fast path stays in byte space** to avoid lossy UTF-8: octal escapes (`\NNN`, tmux escapes bytes <32 and backslash) are decoded via `decodeOctalEscapesFromBytes` (line 470) so high bytes 0x80–0xFF and UTF-8 sequences split across two `%output` messages aren't corrupted with U+FFFD.
- Recognizes the full `%`-notification vocabulary → `TmuxEvent` (TmuxEvent.swift): `%output`, `%extended-output`, `%window-add/-close/-renamed`, `%session-window-changed`, `%window-pane-changed`, `%layout-change`, `%begin/%end/%error`, `%exit`, plus many parsed-but-ignored (`%session-changed`, `%sessions-changed`, `%pause`, `%continue`, `%pane-mode-changed`, `%subscription-changed`, `%client-detached`, `%config-error`, `%message`, `%paste-buffer-*`, `%unlinked-window-*`).
- ID token helpers: `@N`=window, `%N`=pane, `$N`=session.

### Pane-output sanitization (`TmuxControlClient`)
- `ScreenTitleSequenceSanitizer` (line 280): a byte state machine that lifts `ESC k <title> ESC \` out of the stream and emits `<title>` to `didReceivePaneTitle`. Per-pane sanitizer state is retained across `%output` messages (line 1235) so sequences split across messages still parse.
- `stripPromptEOLMarkerSequences` (line 1146): removes the zsh `PROMPT_EOL_MARK` artifact (`ESC[1m ESC[7m % ESC[27m … CR SP CR`).

### Deferred bootstrap & capture-as-displayed (the "right size" trick)
- After attach, panes are **paused** so nothing streams before the surfaces are sized.
- When a window's surfaces all report a non-nil grid size (or a **2s timeout** for never-rendered background tabs — SwiftUI doesn't render hidden tabs), `TmuxWindowController.onBootstrapReady` fires → `continueDeferredBootstrap(paneIDs:)` (line 624):
  1. `capturePaneContents` per pane: `display-message -p -t %N '#{alternate_on}'` → `capture-pane -p -e [-a] -t %N` (escapes preserved, wrapped lines kept) → `display-message -p -t %N '#{cursor_x} #{cursor_y}'`.
  2. Build a **replay buffer**: `ESC[H ESC[2J` + CRLF-normalized capture + `ESC[<row>;<col>H` (`capturePaneReplayData`, line 1186). Always clears first to avoid stale glyphs.
  3. Deliver as synthetic output, then `refresh-client -A '%N:continue'` to resume live `%output`.

### Layout mapping (tmux string ↔ split tree)
- Layout grammar (`TmuxLayoutParser.swift`): `checksum,WxH,X,Y…`; leaf = trailing `,paneID`; `{children}` = **horizontal** split (left↔right); `[children]` = **vertical** split (top↔bottom). Recursive-descent → `TmuxLayoutNode` tree; `allPaneIDs()` flattens depth-first.
- `TmuxLayoutMapper.mapToSplitTree` (TmuxLayoutMapper.swift): folds an N-ary tmux split into a right-nested **binary** `SplitTree` with size ratios (clamped to `[0.05, 0.95]` so no pane collapses). Surfaces are produced by a `surfaceForPane` closure; `AttachedTmuxWindowRuntime.buildLayoutTree` reuses existing surfaces by pane ID across rebuilds (line 47).
- `TmuxWindowController.applyLayout` only rebuilds on **structural** change: it compares the new pane-ID **set** to the current one and **ignores** a `%layout-change` whose pane set is unchanged (that just means tmux echoed our resize) (TmuxWindowController.swift:43).

### Per-surface resize model (post-redesign)
- Old model (deleted): centralized size computation + suppression flags + bidirectional feedback loop in the bridge.
- New model: each surface publishes `$surfaceSize` (cols×rows, Combine). `TmuxWindowController.subscribeSurfaceSize` (line 113) dedups, **debounces 100ms**, and pushes size to tmux. The **shipped path sends `refresh-client -C @<windowID>:<W>x<H>`** (`refreshClientSize`), sufficient for single-pane windows where the pane auto-fills. The lower-level `resize-pane -t %N -x C -y R` (`resizePane`, line 684) also exists as the per-pane building block. Container (window) resize additionally sends `refresh-client -C` from the view layer.
- First non-nil size per pane also gates the deferred bootstrap (`checkBootstrapReadiness`, line 147).

### Coalescing injector (back-pressure)
- `CoalescingInjector` (CoalescingInjector.swift): keeps **at most one in-flight** `ghostty_surface_inject_output` per surface, buffering bursts. This avoids a libghostty deadlock: its internal termio mailbox is a `BlockingQueue(64)` where `push()` blocks *before* `notify()`, so a flood of concurrent injects can wedge the io thread (documented, line 6–13). Inject runs on a per-pane serial `DispatchQueue`; `enqueue` must be called on the main thread.

### V1 vs V2 (what V2 changed)
- **V2 = pure value-type reducers** (`AttachedWorkspaceRuntimeV2` + `…WindowRuntimeV2` + `…PaneRuntimeV2`). `handle(event) -> [action]` is total, side-effect-free, and unit-testable. It owns the tricky **ordering/buffering** logic:
  - `%layout-change` arriving **before** its `%window-add` is parked in `pendingLayouts` and replayed when the window appears (AttachedWorkspaceRuntimeV2.swift:64).
  - `%output` for a pane whose window/layout isn't known yet is buffered in `pendingPaneOutput` and drained when the layout maps the pane (line 115).
  - Maintains `paneToWindowID` so output routes to the right window.
- The bridge (`TmuxSessionBridge.route`, line 146) feeds every delegate event into this reducer and then `apply`s the returned actions to the SwiftUI model + controllers.
- **What V2 replaced (per spec):** the monolithic `SessionManagerV2`/`SessionManager` tmux handling. The bridge is the renamed delegate; `TmuxWindowController`/`TmuxPaneController` are the controller layer that took over surface ownership, buffering, and the new per-surface resize (replacing centralized resize). `AttachedTmuxWindowRuntime` survives only as **stateless helpers** (`terminalInsertIndex`, `surface(forPaneID:)`, `buildLayoutTree`).
- Note both layers coexist at runtime: the V2 reducer computes *logical* actions; the controllers do *UI/surface* work. `apply(.applyLayout)` prefers the window controller and falls back to a direct bridge rebuild when no controller exists yet (TmuxSessionBridge.swift:190).

### Tab↔window ordering
- New tmux windows are inserted at a position that interleaves correctly with browser tabs using `windowIndex` + each browser tab's recorded `terminalTabsBefore` (`AttachedTmuxWindowRuntime.terminalInsertIndex`, line 10).

### Threading/concurrency model
- `TmuxControlClient` is an **`actor`**; delegate is `@MainActor`. Transport read on `Task.detached`; writes on a serial GCD queue; events serialized via `AsyncStream`. Injection on per-pane serial GCD queues. UI mutation on main. `nonisolated(unsafe) weak var delegate` (line 357).

### Key code refs
- Handshake: `TmuxControlClient.swift:402`. Block/queue: `:740`, `CommandQueue.swift`. Octal byte decode: `TmuxProtocolParser.swift:470`. Layout grammar: `TmuxLayoutParser.swift:90`. N-ary→binary: `TmuxLayoutMapper.swift:34`. Deferred bootstrap: `TmuxControlClient.swift:624` + `TmuxWindowController.swift:139`. V2 reducer: `AttachedWorkspaceRuntimeV2.swift:9`. Restore: `SessionManager.swift:451`. Lifecycle commands: `TerminalLifecycleRouter.swift`.

---

## 4. Platform dependencies (macOS-specific)

| Dependency | Where | Notes |
|---|---|---|
| `Foundation.Process` (NSTask) | `TmuxManager` (list/kill/has-session), `createSessionBeforeAttaching`, transport child | spawns `tmux`/`ssh`/`/bin/sh` |
| `openpty()` + `import Darwin` | `PtyTmuxControlTransport.start` (line 100) | pty allocation for `-CC` |
| `Darwin.read/write/close`, `errno`, `EINTR`, `POSIXError`/`POSIXErrorCode` | transport read/write loops | raw fd I/O |
| `FileHandle`, `Pipe`, `FileHandle.nullDevice` | discovery, create-session output capture | |
| `os.Logger` (unified logging / os_log) | `TmuxManager`, `ShellIntegration`, `SessionManager` | `subsystem`/`category`, `privacy:` interpolation |
| `Bundle.main.bundleIdentifier` | logger subsystem | |
| `FileManager.default.homeDirectoryForCurrentUser` | `~/.fantastty` paths (shell integration, SSH host store) | |
| `GhosttyKit` C API: `ghostty_surface_inject_output`, `ghostty_surface_set_focus` | `CoalescingInjector`, surface view | terminal engine |
| `SplitTree<ViewType: NSView & Codable & Identifiable>` + `import AppKit` | `TmuxLayoutMapper`, `AttachedTmuxWindowRuntime`, window controller | **whole split model is NSView-bound** |
| `Ghostty.SurfaceView : NSView`, `NSSize`, `ghostty_surface_size_s` | controllers, bridge | grid size source |
| `NSEvent`, `NSEvent.modifierFlags(.command)` | `AttachedTmuxInputRouter` | local-vs-tmux key decision |
| `Combine` (`@Published`, `$surfaceSize`, `$selectedTabID`, `debounce`, `removeDuplicates`) | window controller, bridge | reactive resize/tab-sync |
| `DispatchQueue` (GCD), `NSLock` | transport, injector | serialization/locking |
| Swift concurrency: `actor`, `AsyncStream`, `Task`, `CheckedContinuation`, `withThrowingTaskGroup` | client, queue, connect timeout | cross-platform Swift, but tmux-specific |
| `NotificationCenter` + `Notification.Name` | OSC 9 note/url routing | `fantasttySessionNote`, etc. |
| `ProcessInfo.processInfo.environment` | env for spawned tmux/ssh | |
| Hardcoded paths: `/bin/sh`, `/usr/bin/ssh`, `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`, `/usr/bin/tmux`, `/run/current-system/sw/bin/tmux` | `TmuxManager.tmuxPaths` (line 16), transport, ssh discovery | Homebrew/Nix-flavored |

Shell-side (cross-platform terminal protocols, not macOS APIs): DCS tmux passthrough `ESC Ptmux;…ESC\`, OSC 7 `kitty-shell-cwd://`, OSC 9 notifications, zsh `chpwd_functions`/`precmd_functions`, ZDOTDIR proxying.

---

## 5. Linux mapping

| macOS dependency | Linux-native equivalent | Risk |
|---|---|---|
| `Foundation.Process` | Same `Process` on swift-corelibs-Foundation, or `posix_spawn`/GLib `GSubprocess`. Works as-is. | Low |
| `openpty()` / `import Darwin` | `openpty()` from `<pty.h>` (glibc, util) via `import Glibc`; identical signature. | Low |
| `Darwin.read/write/close`, `errno` | `Glibc.read/write/close`, same POSIX semantics. | Low |
| `os.Logger` | `swift-log`, or `g_log`/`sd_journal_*` (journald) for native feel. | Low |
| `homeDirectoryForCurrentUser`, `~/.fantastty` | Keep `~/.fantastty` or move to XDG (`$XDG_DATA_HOME`, `$XDG_CONFIG_HOME`). Decision, not a blocker. | Low |
| tmux path candidates | `/usr/bin/tmux`, `/usr/local/bin/tmux`, Nix paths; **drop Homebrew**; prefer `$PATH` lookup. | Low |
| `/usr/bin/ssh`, `/bin/sh` | Same on Linux. | Low |
| `GhosttyKit` C API (`ghostty_surface_inject_output`, …) | **Same libghostty C API** — cross-platform; Ghostty's native platform is Linux/GTK. Reuse directly. | Low |
| `SplitTree<NSView…>` + AppKit | Rewrite split model over **GTK4 `GtkWidget`** (e.g. `GtkPaned`/custom). `TmuxLayoutMapper` rebinds to the new view type — logic unchanged, generic constraint changes. | **Med** |
| `Ghostty.SurfaceView : NSView`, `$surfaceSize` | GTK surface widget exposing grid-size change signals (Ghostty's GTK apprt already embeds a surface; add a cols×rows change notifier). | **Med** |
| `NSEvent.modifierFlags` | GDK/`GtkEventControllerKey` modifiers (Super/Ctrl/etc.); choose the Linux "app shortcut" modifier (Ctrl/Super). | Low |
| `Combine` publishers/debounce | Swift `Observation`, a small reactive shim, or manual callbacks + a GLib timeout for debounce. | Low–Med |
| `DispatchQueue`/`NSLock` | `DispatchQueue` exists in swift-corelibs-libdispatch on Linux; or GLib main-context dispatch. | Low |
| `actor`/`AsyncStream`/continuations | Pure Swift concurrency — portable as-is. | Low |
| `NotificationCenter` | Same on Linux Foundation, or a custom event bus / GObject signals. | Low |
| OSC 7/9, DCS passthrough, zsh hooks | Terminal-protocol level — **identical on Linux**; libghostty parses OSC 7/9 the same. `$HOST` is provided by zsh on Linux too. | Low |

No dependency in this subsystem has **no** clean Linux equivalent. The only meaningful surface is that the **split-tree/surface UI binding** (NSView/AppKit/Combine) must be rebound to GTK — but the tmux logic itself is platform-agnostic.

---

## 6. Reuse assessment

### Port largely as-is (pure cross-platform Swift; no UI deps)
- `TmuxProtocolParser`, `TmuxEvent`, octal decoders, `ScreenTitleSequenceSanitizer`, prompt-EOL stripper, capture-pane replay builder.
- `TmuxLayoutParser` + `TmuxLayoutNode`.
- `CommandQueue` + `TmuxControlBlockTracker`.
- The V2 reducers: `AttachedWorkspaceRuntimeV2`, `AttachedWindowRuntimeV2`, `AttachedPaneRuntimeV2`, `AttachedRuntimeAction/EventV2`.
- `TmuxPaneController` (just a buffer + injector closure — UI-agnostic).
- `TmuxAttachmentInfo`, `SSHHostInfo`, `TmuxHost`, `ConnectionState`, `SessionMode`, `SSHHostStore`.
- `TmuxManager` (swap path list + `os.Logger`), `TerminalLifecycleRouter`, `WorkspaceBindingStore`.
- All the **command-formatting statics** + the `TmuxControlClient` actor logic (handshake, block handling, bootstrap, deferred capture). Only `PtyTmuxControlTransport`'s `import Darwin` → `import Glibc` (openpty/read/write are identical).
- `ShellIntegration` (writes files + emits zsh) and `fantastty.sh` — the escape sequences and zsh hooks are cross-platform.
- The large existing **test suite** (~2,900 lines) is logic-level and ports with the code, giving the Linux port immediate protocol-contract coverage.

### Must be rewritten (macOS UI glue)
- `TmuxLayoutMapper` — rebind `SplitTree<NSView…>` to the GTK view type (algorithm unchanged).
- `TmuxWindowController` — owns `Ghostty.SurfaceView`, `$surfaceSize` Combine subs, GCD; rewrite against GTK surface + Linux size signals.
- `CoalescingInjector` — tied to `Ghostty.SurfaceView` and `ghostty_surface_inject_output`; the back-pressure logic ports, but the surface handle type changes. **Keep the one-inflight invariant — the libghostty mailbox deadlock is engine-level and applies on Linux too.**
- `TmuxSessionBridge` — heavy SwiftUI/`ObservableObject`/`TerminalTab`/`Ghostty.SurfaceView` glue; rewrite against the Linux UI model while reusing the V2 reducer beneath it.
- `AttachedTmuxWindowRuntime` helpers — `buildLayoutTree`/`surface(forPaneID:)` reference `Ghostty.SurfaceView`; rebind to GTK surface.

### Reuse from Ghostty's own Linux/GTK frontend
- Surface embedding, OpenGL/EGL rendering, GDK input handling, and the `ghostty_surface_inject_output`/`ghostty_surface_size_s` C entry points all exist in Ghostty's GTK apprt — the Linux port calls the **same C API**. The tmux control-mode subsystem is **Fantastty-specific** (not in upstream Ghostty), so it must be ported, but it sits cleanly on top of the existing GTK surface.

---

## 7. Open questions / risks

1. **OSC 7 auto pwd-tracking appears unwired (likely dead code).** `ShellIntegration` writes the ZDOTDIR proxy + `osc7-passthrough.zsh` and exposes `zdotdirPath`, but a repo-wide search found **no code that sets `ZDOTDIR=<proxy>` / `FANTASTTY_ORIGINAL_ZDOTDIR` in the environment of spawned tmux/shell processes** (only `ShellIntegration.swift` mentions them; `zdotdirPath` is never read; there are no `ShellIntegration` tests). The README claims it is "set up automatically." Either the env injection lives somewhere I didn't see, or the feature is currently inert. **The orchestrator should confirm before repromising it on Linux** — and if reimplementing, set `ZDOTDIR` when creating the tmux session / spawning shells. (The `fantastty-note` OSC 9 path *is* fully wired.)

2. **Resize: two mechanisms, partial design realization.** The resize *plan* specified per-pane `resize-pane`; the shipped `TmuxWindowController` size subscription actually sends per-window `refresh-client -C @id:WxH` (correct for single-pane, the "current state" per its own comment). Multi-pane exact sizing via `resize-pane` exists but isn't on the subscription path. The Linux port should decide the multi-pane resize policy deliberately rather than assume the plan was fully implemented.

3. **Split-tree is the integration seam.** `SplitTree<ViewType: NSView…>` is AppKit-bound and used well beyond tmux. The Linux port needs an equivalent generic split model over GTK widgets before `TmuxLayoutMapper`/controllers can be ported. This is the largest single piece of rework in this subsystem.

4. **PTY write-deadlock hazard is real and engine-coupled.** Both the transport write-queue offload and the `CoalescingInjector` one-inflight rule exist to dodge libghostty/tmux buffer deadlocks. These must be preserved on Linux; they are not macOS quirks. Validate the libghostty mailbox (`BlockingQueue(64)`) behavior is identical in the Linux build.

5. **tmux version assumptions.** Relies on control-mode features: `-CC`, `refresh-client -A '%id:pause|continue'` (pane pause/continue — newer tmux), `extended-keys`, `#{alternate_on}`, layout strings. Design notes reference tmux **3.3+** for passthrough. Linux distros may ship older tmux; the port should detect/version-gate (esp. pane pause/continue and `extended-keys`).

6. **`fantastty.sh` uses `export -f`** (bash builtin) — harmless in zsh (guarded `2>/dev/null || true`) but only actually exports the function under bash. Cross-shell behavior is fine; just note it if expanding shell support.

7. **SSH/remote discovery shells out to the system `ssh`** with `BatchMode=yes` (no interactive auth). Behavior depends on the user's SSH agent/keys — same on Linux, but worth surfacing in UX.
