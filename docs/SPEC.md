# insanitty — Specification

**A native Linux port of Fantastty: a libghostty-based terminal *workspace manager* with tmux-backed persistence and an SSH/QUIC remote engine.**

---

## 0. About this document

This spec defines **what insanitty must do** — full feature parity with Fantastty (the macOS app under `inspo/fantastty`), **including the remote feature set** — expressed platform-neutrally, plus the concrete contracts the port must honor and a macOS→Linux platform mapping. The chosen implementation approach lives separately in `docs/IMPLEMENTATION-PROPOSAL.md`.

**Sources.** Synthesized from a deep-dive of the Fantastty source (Swift app at git `153ca68`) and the upstream Ghostty source it vendors (pinned commit `5d0a82ba`). The eleven subsystem research reports are in `docs/research/` (`01`–`09`, `03b`, `10`); this document cites them as `[NN]` and cites Fantastty source as `path:line`.

**Provenance.** This spec was adversarially reviewed by two competing reviewers against the source; their findings (a libghostty-framing conflation, the `ghostty_surface_draw` claim, the close-kills-tmux semantics, the predictive-echo default, and omitted shipping features — desktop notifications, terminal search, progress bar) were verified against source and folded in.

**Naming.** "Fantastty" = the existing macOS app. "insanitty" = this Linux port (the repo). "Ghostty" / "libghostty" = the vendored terminal engine. "the helper" = the Go remote-engine helper.

**A framing fact that shapes everything below:** insanitty is **not a terminal emulator**. The terminal engine — VT parsing, scrollback, fonts, GPU rendering, shell-integration primitives — is **Ghostty**, whose *native* platform is Linux/GTK. insanitty is the **workspace/session manager** wrapped around it. The port therefore concentrates on three pillars, none of which is "rendering a terminal":

1. **The workspace model + persistence** (mostly portable logic).
2. **tmux-backed persistence and tmux control-mode** (mostly portable logic + a protocol).
3. **The remote engine** (SSH→QUIC; portable protocol logic + one hard transport rewrite).

> **Precision about "Ghostty on Linux" (this distinction is load-bearing — see `[03b]`, verified against source).** Three different things get loosely called "libghostty":
> 1. **`libghostty-vt`** — the VT parser/state machine *only* (no renderer, no surface). Genuinely cross-platform; it is what the Go remote helper links.
> 2. **The embeddable full-GUI libghostty C API** (`ghostty.h` / `embedded.zig`) — what the macOS app embeds behind AppKit. **This is Metal-only and cannot render on Linux today:** its platform handle accepts only `nsview`/`uiview`, and the OpenGL *embedded* path is an explicit no-op stub. There is **no** GL/EGL/Wayland embedded backend.
> 3. **Ghostty's GTK application + its `GhosttySurface` widget** — the *only* thing that renders a terminal on Linux (GtkGLArea + Ghostty's OpenGL renderer). It is Zig/GObject and **not** exposed over the C ABI; the widget is reusable but coupled to Ghostty's GTK `Application` singleton.
>
> So insanitty does **not** get a drop-in cross-platform terminal renderer for free. The renderer comes from **reusing Ghostty's GTK `Surface` widget** (the proposal's recommended path), not from the C-ABI embedding model the macOS app uses. The rest of this spec keeps the *engine* (VT/scrollback/fonts/render) on Ghostty's side and specifies only what insanitty wraps around it.

---

## 1. Product overview & design principles

Fantastty's own one-liner: *"a terminal app with workspace-based session management and persistent tmux-backed sessions."* Each sidebar item is an independent **workspace** that survives app restarts because it is backed by a tmux session; workspaces carry tabs, splits, notes, ticket/PR URLs, tags, and attention state. Workspaces can be local, SSH (tmux-over-ssh), **remote-engine** (a bundled Go helper attached over QUIC), or **sprite** (a Fly.io cloud VM). Tabs can also be web **browser** tabs.

**Design principles for the Linux port** (from Jesse's brief — "clean, fast, easy to use, Linux platform affordances"):

- **Native Linux, not a macOS skin.** GTK4 + libadwaita chrome; XDG base directories; Wayland-first (X11 fallback); D-Bus / xdg-desktop-portal for system integration (appearance, notifications, secrets, idle); `.desktop` + symbolic icons.
- **Fast.** Reuse Ghostty's GTK terminal surface (the GL renderer that is actually implemented for Linux); keep the portable value-type logic (split tree, protocol state machines) that is already allocation-light and well-tested.
- **Easy.** Match Fantastty's interaction model where it is good, but re-key shortcuts to Linux conventions (Ctrl/Super, not ⌘) and lean on native widgets (`AdwNavigationSplitView`, `GtkListBox`, `GtkPaned`, `AdwPreferencesPage`, `GtkEditableLabel`).
- **Honest parity.** "Same feature set" means the *shipping, wired* feature set — not the vestigial/dead code paths that exist in the macOS tree but are unreachable (see §6).

---

## 2. Domain model & core concepts

### 2.1 The hierarchy

```
Workspace (sidebar item; one tmux session "fantastty-ws-<id>")
  └── Tab  (terminal → one tmux window  |  browser → a web view)
        └── Pane  (one Ghostty surface = one tmux pane)   [terminal tabs only]
              arranged in a binary Split Tree
```

| App concept | tmux concept | Stable identity | Persisted? |
|---|---|---|---|
| **Workspace** (`Session`) | tmux **session** `fantastty-ws-<id>` (remote-engine: `fantastty-remote-<id>`) | `workspaceID` = 8-char lowercased UUID prefix | **Yes** — the durable key |
| **Terminal tab** (`TerminalTab`) | tmux **window** | runtime `tmuxWindowID`/index (from tmux) | order only; rebuilt from tmux |
| **Browser tab** | — (local web view) | — | URL + position |
| **Pane** (Ghostty surface) | tmux **pane** | runtime `tmuxPaneID` (from tmux) | no; rebuilt from tmux layout |

The stable key **everywhere** is `workspaceID`. Tabs and panes are *not* persisted by identity — on reconnect they are reconstructed from live tmux state. Layout persistence stores only ordering and browser-tab URLs. `[04]`

### 2.2 Session taxonomy — one runtime, two axes

There is exactly **one** session runtime: `.attached(TmuxAttachmentInfo)` (`TmuxAttachmentInfo.swift:162`). "Local", "SSH", "remote", "sprite" are not different runtimes — they are points in a 2-axis space:

- **`SessionType`** (user-facing identity): `.local` · `.ssh(host,user,port)` · `.sprite(name)`.
- **Attachment** = **host** (`.local` | `.ssh`) × **transport** (`.tmuxControl` | `.remoteEngine`).

| Kind | SessionType | host | transport | Notes |
|---|---|---|---|---|
| **Local tmux** | `.local` | `.local` | `.tmuxControl` | tmux runs on the local machine |
| **SSH tmux** | `.ssh` | `.ssh` | `.tmuxControl` | `tmux -CC` over `ssh -t` |
| **Remote engine** | `.ssh` | `.ssh` | `.remoteEngine` | Go helper over QUIC; session `fantastty-remote-<id>` |
| **Sprite** | `.sprite` | `.local` | `.tmuxControl` | `sprite console -s "<name>"` runs *inside local tmux* |
| **Browser** | — | — | — | a `TabKind.browser`, not a session type |

This "everything is an attached tmux session" invariant is intentional and the Linux port **keeps it**. `[04]`

---

## 3. Functional specification (the feature set)

> Conventions: **MUST** = required for parity. **SHOULD** = expected, native-adapted. Keyboard shortcuts are given in Fantastty's macOS form (⌘…) and **MUST be re-keyed** for Linux (§3.16, §5).

### 3.1 Workspaces

- **Create** a workspace → generates an 8-char `workspaceID`, an auto name of the form **`adjective-noun`** (e.g. `bold-falcon`; ~400 combinations from two 20-word lists), creates+attaches its tmux session, appends to the sidebar, and selects it. `[04]`
- **Auto-name** MUST be human-friendly and editable; the workspace name is shown in the header bar and is **click-to-edit** (see §3.9 EditableTitle). `[05]`
- **Select** a workspace from the sidebar (single selection). Switching workspaces recreates the detail view.
- **Reorder** workspaces by drag in the sidebar. `[05]`
- **Archive** → kills the workspace's tmux session, flags `isArchived`+timestamp, removes it from the active list (moves to a collapsible "Archived" section). **Unarchive** restores it as a (disconnected) placeholder. `[04]`
- **Close** soft-trashes the *metadata* **and kills the workspace's tmux session.** Closing sets `isTrashed`+timestamp (the workspace moves to a recoverable "Trashed" section) **and** runs the tmux kill (`closeSession(killTmux:)` defaults to `true`, and every UI call site uses the default — verified: no caller passes `false`, `SessionManager.swift:937`). Therefore **Restore from trash yields a *disconnected placeholder*** (empty tabs, "missing backing"), exactly like Unarchive — the live terminal is gone. **Empty Trash / Delete permanently** (with confirm dialog) remove the metadata too. *(This corrects an earlier belief that Close preserved tmux; it does not. Cross-restart persistence is a separate mechanism — see §3.4.)* `[04][05]`
- **Last-workspace rule:** archiving/closing/trashing the final active workspace auto-creates a fresh one (the app is never workspace-less). `[04]`
- **Disconnected placeholders:** a restored workspace whose tmux backing is gone is kept visible as a placeholder (empty tabs, "missing backing" indicator) rather than dropped. `[04]`

### 3.2 Tabs

- A workspace owns an ordered list of tabs, each **terminal** or **browser**. `[04][05]`
- **New tab** (`⌘T`), **New browser tab** (`⌘B`); a "+" menu in the tab bar offers both. The tab bar is shown only when a workspace has **>1 tab**. `[05]`
- **Switch:** `⌘1`–`⌘9` jump to tab N; `⌘⇧[` / `⌘⇧]` previous/next.
- **Close tab** (`⌘W`): for terminal tabs, routes a tmux *kill-window* and removes the tab only when tmux echoes the close; browser tabs close locally. Closing the **last** tab trashes the workspace. `[04]`
- Each terminal tab maps to one tmux window; browser tabs keep their interleaved position across restart. `[04]`

### 3.3 Splits & panes

A terminal tab's content is a **binary split tree** of panes (Ghostty surfaces). `[05]`

- **Create split:** `⌘D` split right, `⌘⇧D` split down. New splits start at **ratio 0.5**. In an attached tmux workspace the split is executed **by tmux** (`split-window -h/-v`) and the app renders the resulting layout; only right/down splits are allowed, and splitting is disabled for remote-engine sessions and sessions without a control client. `[05][06]`
- **Resize:** drag the divider. Minimum pane size **34 pt (~2 cell rows)**; ratio clamped to **0.1–0.9** for keyboard/programmatic resize; resize snaps to the **cell grid**. (These constants exist to prevent a real pane-collapse bug and to keep tmux layout stable — the `SplitLayoutPipelineTests` guard them and MUST be preserved as the layout oracle.) `[05]`
- **Equalize:** **double-click a divider** → weights each split by leaf count along its axis. `[05]`
- **Zoom:** toggle a pane to fill the whole tab area (Ghostty `toggle_split_zoom`). `[05]`
- **Focus navigation:** spatial (up/down/left/right — nearest leaf by geometry) and ordinal (prev/next, wrapping). Unfocused panes dim. `[05]`
- **Close pane:** routes a tmux *kill-pane*; the surviving sibling is promoted into the parent's place on the tmux layout echo. Closing the last pane closes the tab. `[04][05]`
- **Drag-to-split:** each pane shows a **grab handle** (a thin strip at the top revealing an ellipsis on hover). Dragging one pane onto another shows a **half-pane highlight** for one of **4 drop zones** (top/bottom/left/right, chosen by triangular regions); dropping re-inserts the dragged surface as a new split at the target. Dropping on self is rejected; `Esc` cancels; **releasing outside any window posts a tear-off signal** (`ghosttySurfaceDragEndedNoTarget`). `[05]`
  - *Tear-off* (drag a pane out to a new window) is a single-window-model affordance whose Linux semantics are an open question (§7) — the signal exists; the macOS app's actual multi-window handling of it should be confirmed before promising it.
- **Persistence:** the split tree is `Codable`/versioned with the zoomed node stored as a path; but in practice splits are reconstructed from tmux layout on reconnect (§4.2). `[05]`

### 3.4 Persistent sessions (tmux backing)

The defining feature. `[06][04]`

- Each local/SSH workspace is backed by exactly one tmux session named `fantastty-ws-<id>`; tmux **windows = tabs**, tmux **panes = split surfaces**.
- **Persistence is "free":** at app **quit** the app detaches but does **not** close/kill any session — the quit path only saves the layout (`AppDelegate.applicationShouldTerminate` → `saveLayout()`, `AppDelegate.swift:81`); it never calls `closeSession`. So tmux keeps running. (The `closeSession(killTmux:)` parameter has a `false` mode documented for "quit," but **no code path actually invokes it** — quit-persistence works because the app simply leaves sessions alone, not via that flag. The Linux port should implement the same "don't kill at quit" behavior directly.) On next launch the app discovers `fantastty-`-prefixed sessions (`tmux list-sessions`), re-attaches with `tmux -CC`, and **re-derives all tabs/splits from the live tmux layout**. Terminal tabs are therefore *not* serialized by the app — only their ordering and any browser tabs are (see §4.4). `[06][04]`
- **Restore-on-launch** is gated by the `persistentSessions` setting. Restore order: saved layout order → then live tmux sessions not in the layout → then metadata-only placeholders. The previously selected workspace is reselected; archived/trashed are skipped. `[04]`
- **Requires a modern tmux** (control mode `-CC`, `refresh-client -A pause/continue`, `extended-keys`) — roughly tmux ≥ 3.3. The Linux port MUST version-gate and degrade gracefully. `[06]`

### 3.5 SSH sessions

- An **SSH workspace** attaches `tmux -CC` to a remote host over `ssh -t` (the transport is literally `/bin/sh -lc "ssh -t <host> tmux -CC ..."` on a PTY). tmux persistence applies on **both** ends. `[06]`
- The **SSH connection sheet** collects host/user/port and a **"Remote engine"** toggle (which switches transport to the QUIC helper instead of ssh-tmux). Saved hosts are remembered (`ssh-hosts.json`) and offered in the attach sheet. `[05]`
- SSH auth is delegated entirely to the system `ssh` (agent/keys/config) — insanitty stores **no** SSH credentials. `[07]`

### 3.6 Remote engine (the headline remote feature set)

The remote engine is an alternative transport to ssh-tmux for an SSH-hosted tmux workspace: instead of tunneling tmux control mode over SSH, it deploys a **bundled Go helper** on the host, attaches to it over **QUIC**, and renders a **structured cell grid** with **predictive local echo**. It exists to give a lower-latency, higher-fidelity remote terminal than ssh-tmux. `[07][08]`

This entire subsystem MUST be reproduced. Its protocol is **already cross-platform**: the Go helper builds for Linux today, and the wire format is byte-for-byte mirrored between the Swift client and the Go helper `[08]`.

**End-to-end flow (MUST):**

1. **Bootstrap over SSH.** Shell out to system `ssh`/`scp` to (a) probe the remote platform (`uname -s/-m`), (b) deploy the arch-matched helper + `libghostty-vt.so` into `~/.cache/fantastty/remote-engine/` (only if checksums differ; verified by `sha256sum -c`), and (c) run `fantastty-helper launch-or-resume <workspaceID> --ttl 8h --key-ttl 30s`. The helper prints **one line** of attach material.
2. **Attach over QUIC.** Dial the helper's advertised **UDP** host:port, **pin its TLS cert by SPKI-SHA256** (delivered in the SSH line), send a one-time `{session,key}` attach on the first stream.
3. **Render structured grid.** Consume `workspaceSnapshot` / `paneKeyframe` / `paneDelta` / `unsupportedPaneState` over a reliable stream + unreliable datagrams; build per-pane grid state; push rows/cursor into a Ghostty surface (one per tmux pane); map tmux windows→tabs and tmux layout→split tree.
4. **Input & control.** Keystrokes → `sendKeys`; resizes → `resizePane`; tab create/select → `newWindow`/`selectWindow`; missing/garbled frames → `requestKeyframe`.
5. **Predictive echo.** For plain printable keys (and backspace), optimistically paint a faint+underlined tentative cell locally, reconcile against authoritative frames (see below).
6. **Reconnect/resume.** After ≥1 frame, on disconnect re-bootstrap (new one-time key; may resume the same long-lived helper session), reattach, and request fresh keyframes for every known pane. **Reconnecting/disconnected state is visible** in the UI.
7. **Fallback.** If startup fails *before any pane exists* on an SSH host, the workspace **silently falls back to ssh-tmux control mode** in place. After panes exist, hard failures (pin mismatch, attach rejected) **disconnect with a visible reason** instead of falling back.

**Rules & edge cases (MUST):** `[07]`
- One-time attach key TTL **30 s**, single-use (consumed on first attach); session TTL **8 h**. A reconnect needs a fresh key via a new `launch-or-resume`.
- Cert pin is **mandatory** (`peerAuthentication=.required`); SPKI mismatch → `REMOTE_ENGINE_QUIC_PIN_MISMATCH`, no fallback.
- Helper **version+arch must equal the bundled manifest** (`fantastty-helper version=<v> arch=<a>`), else abort.
- Supported hosts: `linux/{x86_64,amd64,aarch64,arm64}` and `darwin/arm64` only. *(Caveat: the client accepts `darwin/arm64`, but the darwin helper artifact cannot actually render — its renderer is gated `//go:build linux && cgo && ghostty_vt`, so it is probe/smoke-only; remote-engine **into** a macOS host is non-functional in practice. `[08]`)*
- **Datagram viability gate:** a keyframe carries `datagramsEnabledAfterKeyframe`; deltas arriving *over a datagram* are rejected (→ keyframe request) until a keyframe enables them. Reliable deltas always accepted.
- **Stale/forked frames are dropped, not applied** (wrong ws/pane, lower generation, stale keyframe/sequence); generation-ahead or base/row-version mismatch → keyframe request.
- **Resize mismatch self-heals:** if local surface size ≠ frame grid size, send `resizePane` + request a `resizeMismatch` keyframe rather than render a mismatched grid.
- **Unsupported panes:** the helper may declare a pane unsupported (`imageProtocol`, `glyphGlossaryMutation`, `unsupportedCellAttribute`, `snapshotExtractionFailure`) with fallback `keepLastGoodKeyframe` or `blankWithDiagnostic`.
- **Predictive echo is deliberately conservative:** suppressed for alternate-screen, invisible cursor / no output, paste, IME / non-printable, escape sequences, mouse, focus loss, reattach, resize, last-column crossings, and any authoritative mismatch (which triggers rollback + cooldown). It is **on by default** (`remotePredictiveEchoEnabled = true`, `SettingsView.swift:8`), heavily guarded by those suppression rules, and user-toggleable. *(The Linux port may choose to ship it off by default — that is a product call, not a parity requirement.)*
- **Diagnostics are redacted:** never log one-time keys, cert pins, raw typed input, pane contents, shell commands, or local paths.

The full bootstrap-line grammar, wire-protocol message schemas, grid state machine, predictive-echo state machine, and security model are specified as contracts in **§4.3**.

### 3.7 Sprites (Fly.io cloud workspaces)

- A **sprite** workspace is a Fly.io cloud VM reached via the `sprite` CLI. Mechanically it is a `.local` tmux workspace whose shell command is `sprite console -s "<name>"` — i.e. the sprite console runs *inside local tmux*, so it inherits tmux persistence. `[04][09]`
- The **sprite connection sheet** detects the `sprite` CLI (probing common install paths; shows an install hint if absent), lists existing sprites, and offers **Create & Connect** / **Connect**. A workspace context-menu **Destroy Sprite…** (with confirm) is available. `[05]`
- Implementation is pure subprocess shell-out (no macOS APIs) → **portable**; the port only fixes the CLI search-path list for Linux and confirms `sprite` ships for Linux. `[09]`

### 3.8 Browser tabs

- A tab can be a **web browser** (`WKWebView` on macOS → **WebKitGTK** on Linux). UI: URL bar with back/forward/reload, an editable address field that prepends `https://`, and "open in system browser." Title/URL track the page; thumbnails come from a web-view snapshot. `[05][09]`
- Browser tabs are the **one** tab type whose content (the URL) is persisted in the layout; they keep their position relative to terminal tabs across restart. `[04]`

### 3.9 Notes

A per-workspace **timestamped note log** with revision history. `[05][04]`

- The **notes panel** drops from the top of the terminal area (toggle `⌘.` or a toolbar button) and shows: **time stats** (Open = wall-clock since creation; Active = accumulated focused seconds, live-ticking), optional **Linear ticket detail** (§3.10), editable **Ticket URL / PR URL** fields, the **note log**, an **add-note** field, and **tag** chips. `[05]`
- Each **note entry** has a timestamp, content, source (`terminal` / `user` / `system`, color-coded), inline `#tags`, and a **revision history** (editing pushes the prior content into `revisions`). Entries support inline edit (double-click / pencil; commit on submit/blur; `Esc` cancels) and delete; the log auto-scrolls to newest. `[05]`
- **Escape-sequence-driven notes:** the bundled `fantastty-note` / `fn` shell function emits **OSC 9** `\e]9;fantastty:note;<content>\a` (with tmux/screen passthrough wrappers); the app appends it with source `terminal` and **flags the workspace for attention if it is backgrounded** (§3.11). `[05][06]`
- The editable workspace title (`EditableTitle`) in the header bar commits to the workspace name. `[05]`

### 3.10 Workspace URLs & Linear integration

- Each workspace carries a **`ticketURL`** and **`pullRequestURL`**, settable from the notes panel **or** via terminal escape sequences (`fantastty:ticket;<url>` / `fantastty:pr;<url>` over OSC, same channel as notes). `[04][06]`
- When a ticket URL is a Linear issue/project, the notes panel renders **live Linear detail** (issue/project title, state, assignee, priority, sub-issues, progress) fetched via the Linear GraphQL API. The API token is stored securely (macOS Keychain → **libsecret/Secret Service** on Linux). All of `LinearService` is cross-platform except the 3 Keychain calls. `[09]`

### 3.11 Attention indicators

- A workspace gets a **needs-attention** flag (persisted, with timestamp) — shown as a sidebar badge (dot + bold title) — set **only when the workspace is not the foreground one** on: terminal **bell**, **command-finished**, or arrival of a **terminal note**. Bell also plays a system beep. `[04]`
- The flag is **cleared on user input** to that workspace (and via a manual toggle / clear action). `[04]`
- **Focused-time accounting:** `totalActiveSeconds` accrues only while a workspace is selected and input occurred within the last 60 s (idle threshold), on a 5 s tick, flushed on deselect / every 60 s / at quit. Drives the notes-panel "Active" stat. `[04]`
  - *Linux note:* the macOS idle source is a **local** `NSEvent` monitor (`addLocalMonitorForEvents`, app-delivered events only — *not* a system-wide global monitor), so it maps **directly** to GTK per-surface event controllers; a Wayland/D-Bus system-idle signal is an optional enhancement, not a requirement (§5).

### 3.12 Shell integration

- A small, **terminal-protocol-level** (hence cross-platform) integration the app writes under the app data dir and that the user sources `[06]`:
  - **`fantastty-note` / `fn`** → OSC 9 notes (and `fantastty:ticket;` / `fantastty:pr;`), with tmux (`\ePtmux;…`) and GNU screen passthrough variants.
  - **OSC-7 pwd reporting** via a zsh `ZDOTDIR`-proxy + `chpwd/precmd` hooks emitting DCS-wrapped OSC 7 — so the app can track each pane's working directory through tmux.
- **Known defect to carry knowingly:** the README claims OSC-7 pwd tracking is set up *automatically*, but the `ZDOTDIR` injection that would enable it **appears unwired** in the source (no env injection into spawned shells, no tests). The Linux port should **either wire it properly or not promise "automatic"** — see §6. `[06]`

### 3.13 Theming & appearance

- An **appearance mode** of System / Light / Dark, persisted. Light/Dark force the toolkit theme; System follows the OS and updates live. The chosen scheme is also pushed into libghostty via `ghostty_app_set_color_scheme()` (this C call is **unchanged** on Linux). `[04]`
- If the user has **no** existing Ghostty config (`$XDG_CONFIG_HOME/ghostty/config`), insanitty writes default light/dark themes + a small overlay enabling `window-theme = auto`; if they *do* have one, it leaves it alone. `[04]`
- *Linux mapping:* macOS `NSAppearance`/KVO → libadwaita `AdwStyleManager` + the `org.freedesktop.appearance` portal for "System" (with a fallback when no portal is present). `[04][09]`

### 3.14 Settings

A small settings surface (grouped form) with: **Appearance** (System/Light/Dark), **Sidebar** (show live tab thumbnails inline in the sidebar), **Sessions** (enable persistent tmux sessions; disabled with guidance when tmux is absent), **Remote Engine** (predictive-echo toggle), **Integrations** (Linear API key, stored in the OS secret store). `[05]`

### 3.15 Thumbnails & workspace overview

- **Live tab thumbnails** appear in three places: a right-hand **thumbnail panel**, **inline in the sidebar** (when enabled), and an **Exposé-style overview grid** shown when a workspace has no tab selected (hover-scale tiles; click to focus). Terminal thumbnails composite the panes' images on a black canvas; browser thumbnails use a web-view snapshot. Refresh is **debounced ~150 ms**, suspended during scroll and when the workspace is inactive. `[05]`
- *Linux risk:* macOS snapshots an `NSView` cheaply via `cacheDisplay`; a GTK/GL terminal surface has **no cheap snapshot** — thumbnails need explicit FBO/`GdkTexture` readback. This is load-bearing UX and an early design item (§5, §7). `[05]`

### 3.16 Commands & keyboard

- All commands live in the app menu / command map: workspace create, new SSH/sprite/tmux-attach, new tab / browser tab, tab switch (1–9, prev/next), split right/down, equalize, zoom, focus nav, close tab/pane/workspace, toggle notes, toggle overview, toggle thumbnail panel, **find-in-terminal** (§3.17), **toggle/clear attention flag and "Show Next Flagged" (jump to the next workspace needing attention)**, clear screen, copy/paste (paste is **tmux-aware** — routed through the control client for tmux panes), and a Debug menu. `[01][05]`
- The macOS map is ⌘-centric and overloaded (e.g. ⌘W closes a *tab*; `` ⌘` `` hijacks window cycling for workspace switching; ⌘K clear vs ⌘⇧K new-SSH). The Linux port **MUST design a deliberate Ctrl/Super keymap**, not a 1:1 ⌘→Ctrl translation, and must avoid collisions with common desktop/WM shortcuts (especially Super). `[01][05]`

### 3.17 Desktop (system) notifications

A real, wired feature distinct from the in-app attention flag (§3.11): a terminal program can raise an **OS desktop notification** (via Ghostty's `desktop_notification` action — bell, command-completion, or OSC 777). `[01][09]`

- The app posts a system notification with title/body (and sound); **clicking it focuses the originating workspace/pane**. `Ghostty.App.swift:564→1453→showUserNotification (SurfaceView_AppKit.swift:2100)`; activation routes through `Ghostty.App.swift:2240`.
- Notification bodies beginning with the `fantastty:` prefix are **not** shown as OS notifications — they are intercepted as in-app notes/URLs (§3.9, §3.10).
- *Linux:* `libnotify` / `GNotification` (`org.freedesktop.Notifications`), with the default action wired to raise+focus the workspace. (Under the GTK-reuse path, Ghostty's GTK apprt already implements desktop notifications + the URI portal — insanitty maps "focus workspace" onto it.)

### 3.18 Terminal surface host UI (search, progress, scrollbar, clipboard confirmation)

Chrome the app draws *around* each Ghostty surface, all wired and shipping in Fantastty `[02]`:

- **Find-in-terminal:** an in-pane **search overlay** (needle field + `N/M` match count) driven by Ghostty's `start_search` action. `Ghostty.App.swift:666` → `SurfaceView.searchState` → `SurfaceSearchOverlay`. *(Ghostty's GTK apprt ships `search_overlay.zig`, inherited under the reuse path.)*
- **Progress bar:** a per-pane overlay for **OSC 9;4** progress reports (with ~15 s auto-dismiss). `SurfaceProgressBar.swift`, fed by `Ghostty.App.swift:1980`.
- **Scrollback scrollbar:** a scroll indicator over the terminal surface. `SurfaceScrollView.swift`.
- **Clipboard confirmation:** OSC-52 clipboard read/write **confirmation dialogs** before a remote app reads/writes the clipboard. *(Ghostty's GTK apprt ships `clipboard_confirmation_dialog.zig`.)*

These are mostly provided by Ghostty's GTK surface widget itself; insanitty's job is to keep them working when the surface is embedded in its own chrome.

---

## 4. Technical contracts (the port MUST reproduce these exactly)

### 4.1 libghostty embedding & the two required patches

- The macOS app embeds **libghostty** through its C API (`include/ghostty.h`). It **does not render the terminal itself**: it hands libghostty a native view handle + size/scale/display-id, and **libghostty owns its own render surface and render thread.** On macOS the platform struct is `ghostty_platform_macos_s(nsview:)`, the renderer is **Metal**, and it self-drives from a `CVDisplayLink` — so the macOS app never calls `ghostty_surface_draw` (which *does* exist, `ghostty.h:1113` / `embedded.zig:1691`, and is exactly how a *host-driven* GL path would drive draws). **This embedded C-API path is Metal-only and is not available on Linux** (see §0 box and `[03b]`): there is no Linux platform handle and the embedded OpenGL backend is a no-op stub. insanitty therefore obtains the renderer by **reusing Ghostty's GTK `GhosttySurface` widget** (GtkGLArea + Ghostty's OpenGL renderer), not by embedding the C API as the macOS app does. The C-API/embedding details below describe the *macOS* contract and the engine capabilities the GTK path must expose equivalently. `[02][03][03b]`
- The C API used spans ~90 `ghostty_*` calls: app lifecycle, string-keyed config (`ghostty_config_*`), surface create/size/scale/display/free, input (`surface_key`/`text`/`preedit`/`mouse_*`/`set_focus`/`ime_point`), actions, text/selection/clipboard, inspector, and **6 host→engine callbacks** (`wakeup_cb`, `action_cb`, 3 clipboard callbacks, `close_surface_cb`). The single `action_cb` multiplexes **~63 actions** (`Ghostty.App.swift` handles 63 `GHOSTTY_ACTION_*` cases — new tab/split, goto/move tab, fullscreen, set-title, pwd, desktop-notification, open-url, clipboard, mouse-shape, search, progress-report, command-palette, …) — this action list is the exact work-list for the new frontend. `[02][03b]`
- **One patch file (`patches/ghostty-inject-output.patch`) adds two capabilities** to libghostty. Its logic is renderer-agnostic (it operates on `terminal.Terminal`/`Screen`, not on AppKit/Metal). The patch applies cleanly at the pinned commit, **but it adds its exports to `embedded.zig`'s C API** (the Metal-only embedded apprt that does not ship on Linux). So the Linux build cannot consume them "as-is": the **same renderer-agnostic bodies must be re-exposed against the GTK apprt's `core_surface`** (a small, mechanical port — identical `core_surface.io` / `renderer_state.terminal` targets, per `[03b]`). The two capabilities are MANDATORY for the tmux + remote features:
  1. **`ghostty_surface_inject_output(bytes,len)`** — feed raw bytes into the VT parser **bypassing the PTY**. This is how tmux control-mode `%output` is rendered. `[02][06]`
  2. **`ghostty_surface_remote_grid_reset/set_row/set_row_cells/set_cursor/set_cursor_ex`** — write fully-styled cells (fg/bg/underline color, 7 boolean attrs, 6 underline styles, cursor shape) **directly into the terminal screen** under the renderer mutex, with strict validators (row width == cols, ≤1000 rows, ≤250k cells). This is the remote engine's render path. `[02][07]`
- **Back-pressure invariant to preserve:** at most **one** in-flight `inject_output` call per surface (a coalescing injector), to avoid a libghostty `BlockingQueue(64)` deadlock; and tmux panes deliberately **avoid** `ghostty_surface_key`/`set_focus` for the same reason. These are engine-level constraints, not macOS quirks — **keep them**. `[02][06]`

### 4.2 tmux control-mode protocol contract

The Linux port reproduces this client (almost all of it is portable logic). `[06]`

- **Transport:** `/bin/sh -lc "tmux -CC attach-session -t '<name>'"` on an `openpty()` PTY; the SSH variant prepends `ssh -t`. (`openpty` is identical on Linux via glibc; `import Darwin` → `Glibc`.)
- **Handshake order:** consume the spontaneous `%begin/%end` greeting → `display-message -p ready` → `set-option -g extended-keys on` → `list-windows -F '#{window_id}\t#{window_name}\t#{window_layout}\t#{window_index}\t#{window_active}'` → **pause %output** for all panes via `refresh-client -A '%id:pause'`.
- **Block framing:** `%begin/%end/%error <ts> <id> <flags>` matched FIFO against a queue of pending commands; no nesting; mismatched ids inside a block = teardown.
- **`%output %<id> <octal>`** is decoded in **raw byte space** (preserving 0x80–0xFF and split UTF-8) and fed via `inject_output` (§4.1).
- **Events handled:** window add/close/renamed, session-window-changed (active window), window-pane-changed (active pane), layout-change, exit (~12 more parsed-but-ignored).
- **Deferred bootstrap ("capture at the right size"):** panes stay paused until every surface reports a grid size (or a 2 s timeout for hidden tabs); then `capture-pane -p -e` + cursor query → replay (`ESC[H ESC[2J` + CRLF-normalized + cursor restore) → `refresh-client -A '%id:continue'`.
- **Commands out:** `send-keys -t %<id> -H <hex>` (keystrokes; local ⌘/modifier keys stay app-side), `select-window`, `kill-window`, `new-window`, `split-window -h/-v`, `kill-pane`, `resize-pane -t %id -x C -y R`, `refresh-client -C @win:WxH`.
- **Layout mapping:** the tmux layout grammar `checksum,WxH,X,Y` with `{}` = horizontal and `[]` = vertical folds into a right-nested binary **split tree** with ratios clamped `[0.05, 0.95]`. `%layout-change` rebuilds **only on pane-set change** (ignoring tmux echoing the app's own resizes).
- **Resize model (as shipped):** per-surface size → debounced **`refresh-client -C`** per window (a per-pane `resize-pane` path exists but is not on the shipping subscription path).
- **Architecture note:** the hard ordering/buffering (layout-before-window-add, output-before-layout) lives in **pure value-type reducers** ("V2": workspace/window/pane runtimes, `handle(event)->[action]`) that port as-is; only the controller glue bound to the split tree + surface widget + reactivity needs rewriting.

### 4.3 Remote engine wire & bootstrap contracts

All of this is mirrored by the Go helper (`remotegrid/protocol.go`) and verified to match the Swift client byte-for-byte `[08]`. JSON uses Swift `Codable`'s enum encoding: a payload case encodes as `{"<case>":{"_0":<payload>}}`.

**Bootstrap line** (helper stdout, one line):
```
FANTASTTY_REMOTE port=<n> session=<64hex> key=<64hex> expires=<RFC3339> \
  helper_pid=<n> version=<v> arch=<a> quic_addr=<host:port|[v6]:port> \
  quic_cert_sha256=<64hex> quic_alpn=fantastty-remote-engine-v1
```
The client takes host:port from `quic_addr`, requires `session`/`key`/`quic_cert_sha256` to be 64-char lowercase hex, then **rewrites host to its own resolved advertise host** (because QUIC/UDP must reach the helper *directly*, not via the SSH tunnel). Advertise-host resolution: for a bare alias, `ssh -G` → `hostname`, probe `$SSH_CONNECTION` (server IP) and remote `hostname -I`, intersect with the client's local IPv4 networks (`getifaddrs`) to prefer a LAN address; an explicit override short-circuits. `[07]`

**Transport:** QUIC over UDP, ALPN **`fantastty-remote-engine-v1`**, TLS 1.3, **datagrams enabled** (`maxDatagramFrameSize=1200` on the client; helper allows up to 16383), idle ~2 m, keep-alive ~10 s. Helper cert = **ephemeral self-signed ECDSA P-256**; trust = **SPKI-SHA256 pin** only (no CA). Two channels on the connection: **reliable stream** = newline-delimited JSON; **datagram** = a single bare `paneDelta` JSON. `[07][08]`

**Attach:** first bytes on the first stream = `{"session":"<hex>","key":"<hex>"}\n`. Reject is a single `{"error":"<msg>"}` line.

**Server→client messages** (`RemoteWorkspaceMessage`):
- `workspaceSnapshot` `{workspaceID, layoutGeneration:u64, windows[], panes[]}` where `WorkspaceWindow {windowID:int, title, index:int?, isActive:bool, layout:string?}` (raw tmux layout) and `WorkspacePane {paneID:int, windowID:int, isActive:bool, frame:{x,y,columns,rows}}`.
- `paneKeyframe` `{workspaceID, paneID, paneGeneration:u64, keyframeID:u64, gridSize:{columns,rows}, rows:[GridRow], cursor:CursorState, activeScreen:"primary"|"alternate", datagramsEnabledAfterKeyframe:bool}`.
- `paneDelta` `{workspaceID, paneID, paneGeneration:u64, baseKeyframeID:u64, deltaSequence:u64, rowUpdates:[RowUpdate], cursor:CursorState?}`.
- `unsupportedPaneState` `{workspaceID, paneID, paneGeneration, reason, fallback}`.

**Row/cell encodings:** `GridRow` = full `{index, rowVersion:u64, cells:[GridCell]}` **or** compact `{index, rowVersion, text:"…"}` (one width-1 normal cell per scalar). `RowUpdate` = `{rowIndex, rowVersion, update}` where `update` ∈ `{"fullRow":{"_0":[GridCell]}}` | `{"fullRowText":{"_0":"…"}}` | `{"span":{baseRowVersion,startColumn,cells,clearToColumn?}}`. `GridCell` = `{text, width(1|2), style}` (width-2 ⇒ next cell is `{text:"",width:0}`). `CellStyle` = `{foreground,background,underlineColor (Color), bold,faint,italic,blink,inverse,invisible,strikethrough (bool), underline ∈ none|single|double|curly|dotted|dashed}`. `Color` ∈ `{"default":{}}` | `{"indexed":{"_0":u8}}` | `{"rgb":{red,green,blue}}`. `CursorState` = `{row,column,visible,shape ∈ block|bar|underline, cursorVersion:u64>0}`. `[07]`

**Client→server control** (newline-JSON on any client stream): `{"type":"requestKeyframe",…,"reason"}`, `{"type":"sendKeys",…,"data":"<base64>"}` (chunked ≤2048 B), `{"type":"resizePane",…,"columns","rows"}`, `{"type":"newWindow",…}`, `{"type":"selectWindow",…,"windowID"}`. `[07]`

**Grid state machine (MUST):** keyframe apply drops stale (wrong ws/pane, lower generation, ≤ current keyframeID), else validates (cols/rows>0, row count==rows, unique in-range indices, each row display-width==cols, cursor in-bounds, cursorVersion>0) and replaces state. Delta apply requires a prior keyframe, checks ws/pane/generation/baseKeyframe, enforces datagram viability, applies only rows with `rowVersion > current` (a `span` requires `baseRowVersion == current`), updates cursor only if `cursorVersion` increases. Results: `applied | dropped(reason) | needsKeyframe(reason)`. `[07]`

**Predictive-echo state machine (MUST, if echo enabled):** only single printable scalars (display width 1|2) and plain erase (0x7F/0x08) are eligible. Predictions start **hidden** until echo confidence is proven (authoritative cursor advances past a matching hidden prediction); thereafter render **visible** (faint+underline) after a ~50 ms latency threshold. Reconcile against every authoritative frame (prove a matching prefix, or **contradiction → clear + ~500 ms cooldown**, fail-closed if no timestamp). A ~250 ms no-ack timeout also clears+cooldowns. Refuse prediction unless `activeScreen==primary`, cursor visible, wide-cell boundaries preserved, and not crossing the last column. `[07]`

**Security model (MUST):** SSH is the only trust bootstrap; the cert pin and one-time key travel only over SSH. One-time keys = 32 random bytes (64 hex), 30 s TTL, single-use, bound to {session,workspace}. The **client** never persists them; the **helper** does store active keys on disk in its `registry.json` (`registry.go:67`, `keyring.go:18`) inside a 0700 owner-checked runtime dir, deleting each on consumption or 30 s expiry — so a key is briefly at rest on the host but never on the client. Helper-side: runtime dir `FANTASTTY_REMOTE_RUNTIME_DIR` / `$XDG_RUNTIME_DIR/...` / `/tmp/fantastty-remote-engine-<uid>` at 0700 (owner-checked), sockets 0600, **peer-UID checks via `SO_PEERCRED`** on the local control socket. Diagnostics redaction as in §3.6. `[07][08]`

**Reuse:** the Go helper is used **unchanged** (it is already a Linux program — the renderer is even `//go:build linux && cgo && ghostty_vt` and links `libghostty-vt`). The ~3k lines of Swift protocol/state/echo logic are `Sendable` value types that compile on Linux untouched (the one platform call, `wcwidth`, should prefer libghostty's unicode width for client/helper parity). The single hard rewrite is the **QUIC transport** (Apple Network.framework → a Linux QUIC lib) behind the existing `RemoteEngineTransport`/`RemoteEngineConnection` seam. `[07][08]`

### 4.4 Persistence file formats

All under the app data dir (macOS `~/.fantastty/`; Linux → XDG `$XDG_DATA_HOME/insanitty` recommended, with the Ghostty config read from `$XDG_CONFIG_HOME/ghostty/config`). JSON is pretty-printed, sorted-keys, ISO-8601 dates, atomic writes. `[04]`

- **`workspaces.json`** — array of `SessionMetadata`: `{id, workspaceID, name, noteEntries[{id,timestamp,content,tags[],source,revisions[{content,timestamp}]}], needsAttention, attentionFlaggedAt?, tags[], isArchived, archivedAt?, isTrashed, trashedAt?, ticketURL?, pullRequestURL?, attachment?, createdAt, modifiedAt, totalActiveSeconds}`. Decoder is migration-tolerant (every field `decodeIfPresent`).
- **`layout.json`** — one `LayoutSnapshot`: `{schemaVersion:1, workspaces:[{workspaceID, tabs:[{kind:"terminal"|"browser", url?}], selectedTabIndex, sessionType?, attachment}], selectedWorkspaceID, savedAt}`. Only `.attached` sessions; only browser tabs carry restorable content; the persisted attachment is normalized to `disconnected`/`attach`.
- **`ssh-hosts.json`** — array of saved SSH targets.
- **Enum encodings** the format depends on (Swift-synthesized): `TmuxHost` `{"local":{}}` | `{"ssh":{"_0":{hostname,user,port}}}`; `ConnectionState` `{"connecting":{}}|{"connected":{}}|{"reconnecting":{reason}}|{"disconnected":{reason}}`; `SessionType` hand-written `{"kind":"local"}|{"kind":"ssh",host,user,port}|{"kind":"sprite",spriteName}`.
- **Compatibility decision (open, §7):** these are Fantastty-private files. Whether insanitty must *read existing macOS state* determines whether the enum shapes are frozen or can be cleaned up. Per project rules, any back-compat is an explicit decision — default assumption is a **fresh format** unless Jesse wants cross-read.

### 4.5 Shell-integration escape sequences

- **Notes:** OSC 9 `\e]9;fantastty:note;<content>\a` (also `fantastty:ticket;<url>`, `fantastty:pr;<url>`), with tmux `\ePtmux;\e…\e\\` and GNU screen passthrough wrappers. `[05][06]`
- **pwd:** DCS-wrapped OSC 7 `kitty-shell-cwd://<host>/<path>` emitted from zsh `chpwd`/`precmd`. (See §3.12 caveat on auto-setup.) `[06]`

---

## 5. Platform mapping (macOS → Linux)

Framework usage in the macOS tree (by importing-file count): SwiftUI 47 · Foundation 44 · GhosttyKit 34 · AppKit 24 · Cocoa 8 · os/OSLog 10 · Combine 8 · WebKit 5 · UniformTypeIdentifiers 4 · UserNotifications 3 · Security 2 · Carbon 2 · Network 1 · Metal/MetalKit 2 · CryptoKit 1 · CoreText 1 · plus private CGS. `[09]`

| macOS dependency | Linux-native replacement | Severity |
|---|---|---|
| SwiftUI + AppKit/Cocoa (whole UI) | **GTK4 + libadwaita** (`AdwApplication`, `AdwNavigationSplitView`/`AdwOverlaySplitView`, `GtkListBox`, `GtkPaned`, `AdwHeaderBar`, `AdwDialog`/`AdwAlertDialog`, `AdwPreferencesPage`, `GtkEditableLabel`, `GtkPopoverMenu`+`GMenu`) | Large (UI rewrite) |
| libghostty Metal embedded path (C-ABI) | **Not portable as-is** — no Linux GL embedded backend exists. Reuse **Ghostty's GTK `GhosttySurface` widget** (GtkGLArea + Ghostty's OpenGL renderer) per `[03b]`; embed it as an opaque `GtkWidget`, hosting Ghostty's GTK `Application` | **High — gating** |
| Metal/MetalKit (app-owned) | **None needed** — libghostty owns rendering; only the inspector used app-Metal and it is stubbed out | Low |
| `WKWebView` (browser tabs) | **WebKitGTK** `WebKitWebView` (+ `webkit_web_view_get_snapshot`) | Medium |
| Keychain `SecItem*` (Linear token) | **libsecret / Secret Service** (`org.freedesktop.secrets`) | Low |
| `UserNotifications` (desktop notifications) | **libnotify / `GNotification`** (`org.freedesktop.Notifications`) | Low |
| Carbon `EnableSecureEventInput` (secure keyboard entry) | **No clean equivalent.** Wayland isolates input by design (goal mostly moot); X11 cannot. Keep the *indicator*, no-op the lockdown | Medium (product decision) |
| Private **CGS** Spaces (`CGSCopySpacesForWindows`, …) | No Wayland equivalent; reachable only via dead fullscreen code → **drop** | None (dead, §6) |
| Apple **Network.framework** QUIC | A Linux QUIC client lib: **quiche / msquic / lsquic / quinn / quic-go** (needs client datagrams, SPKI-pin verify callback, ALPN) | **High — biggest rewrite** |
| `Security` SPKI extraction + `CryptoKit.SHA256` | OpenSSL/rustls DER SPKI + `SHA256` (or **swift-crypto**, drop-in) | Low |
| Carbon `TIS*` keyboard layout | **xkbcommon** (and libghostty's own GTK key translation) | Low |
| `CoreText` | Pango/HarfBuzz/fontconfig (mostly inside libghostty) | Low |
| `Transferable`/`UTType`/`NSDraggingSession` (pane DnD) | `GtkDragSource`/`GtkDropTarget` + `GdkContentProvider`, mime `application/x-ghostty-surface-id` | Medium |
| `NSView.cacheDisplay` thumbnails | **FBO/`GdkTexture` readback** from the GL surface | **Medium — load-bearing UX** |
| `Combine` (`@Published`, `PassthroughSubject`, `Timer.publish`, `.debounce`) | **OpenCombine** (near-drop-in) **or** GObject signals + `g_timeout_add` | **High — pervasive, decide early** |
| SwiftUI `@AppStorage` / `UserDefaults` | `GSettings`/dconf or XDG config (or Foundation `UserDefaults` if staying in Swift) | Low |
| `os.Logger` | **swift-log** or `g_log`/journald | Low |
| `NSEvent` **local** monitor (idle/activity clock) | GTK per-surface event controllers (direct equivalent); Wayland `ext-idle-notify-v1` only if true system-idle is wanted | Low |
| `NSAppearance` + KVO (System theme) | **`AdwStyleManager`** + `org.freedesktop.appearance` portal (fallback if absent) | Medium |
| `NSSound.beep` / bell | `gtk_widget_error_bell` / **libcanberra** | Low |
| `NSWorkspace.open(url)` | `GtkUriLauncher` / `gtk_show_uri` / `xdg-open` | Low |
| `~/.fantastty/*`, `Bundle.main` | **XDG base dirs**; ship helper artifacts under `libexec`/`$XDG_DATA_DIRS` | Low |
| `posix_spawn`, `getifaddrs`, `openpty`, `wcwidth`, `SO_PEERCRED` | POSIX/glibc — **reuse as-is** | None |
| Go remote helper + `libghostty-vt` | **Reuse unchanged** (already builds linux-amd64/arm64) | None |

**Build/packaging** `[08]`: keep the Zig `libghostty-vt` build (host triple) and the native Go helper build; replace the xcframework with a **native libghostty (GTK4/EGL)** build, all Xcode/XcodeGen/codesign/notarize with a native toolchain, and DMG with **deb/rpm + Flatpak/AppImage** + `.desktop`/icon integration; CI moves to Linux runners (keep `setup-zig` 0.15.2, `setup-go`). Required toolchain: **Zig 0.15.2**, **GTK4 + libadwaita**, a QUIC lib, WebKitGTK, libsecret, libnotify.

---

## 6. Explicitly excluded / vestigial (do NOT port)

These exist in the macOS tree but are **unwired or dead**; "same feature set" does **not** include them, and porting them would be net-new work misrepresented as parity. `[01][06]`

- **Non-native fullscreen modes** (`Fullscreen.swift`, 458 lines, 4 modes incl. dock/menu hiding) — entirely unwired; the only fullscreen that works is the OS default. Linux: a single `GtkWindow.fullscreen()`; delete the rest (and the CGS Spaces code it gated).
- **Command palette** — in *Fantastty* the keybind action is unobserved and there is no palette UI; the feature does not exist there. (Note, however, that **Ghostty's GTK apprt ships a real command palette** — `class/command_palette.zig` — so under the recommended GTK-reuse path a palette is *available from the substrate*, not net-new; insanitty can choose to surface it. This is an opportunity, not a parity obligation.)
- **Manual global secure-input toggle** — a no-op stub with no menu item. (The *automatic* password-prompt secure-input via Carbon is real but has no Linux equivalent — see §5.)
- **`ghosttyNewWindow` / multi-window** — the app is single-window (`Window`, not `WindowGroup`); the new-window keybind is unobserved. Decide the Linux multi-window/tear-off story deliberately (§7) rather than assuming parity.
- **Over-broad entitlements** (camera, photos, calendars, address book, location; no sandbox key) — vestigial; the Flatpak manifest should request only what is actually used (network, and host access for ssh/tmux).
- **README over-claim:** "automatic" OSC-7 pwd tracking appears unwired (§3.12) — fix or stop promising it; do not faithfully reproduce a broken claim.

---

## 7. Open decisions (feed the implementation proposal)

1. **Implementation language.** Stay in **Swift** (maximizes reuse — split tree, session model, tmux client, remote protocol/echo all port near-verbatim via swift-corelibs-foundation; needs OpenCombine + GTK bindings + a QUIC binding) vs. **rewrite** in Rust/Vala/C/Zig (more ecosystem-native GTK + QUIC, but re-implements ~tens of thousands of lines of subtle, tested logic). This is the highest-leverage decision and gates everything below. *(Recommendation deferred to the proposal, informed by `[03b]`.)*
2. **Reactivity framework** (OpenCombine vs GObject signals vs Swift Observation) — pervasive; pick before lifting any view-model.
3. **libghostty embedding path** — embed libghostty behind our own GTK UI (needs a Linux GL embedded backend in Ghostty, possibly net-new Zig) vs. reuse Ghostty's GTK **surface widget** + renderer and own the chrome vs. fork the GTK app. **Gated on `[03b]`** (the source-verified investigation).
4. **QUIC client library** — quiche / msquic / lsquic / quinn / quic-go-as-lib; must support client datagrams (≥1200), SPKI-pin verify callback (no CA), ALPN, stream+datagram concurrency. Re-tune the `localizedDescription`-based failure classifier for the chosen lib.
5. **Thumbnails** — per-surface FBO readback vs. periodic GL grab vs. a degraded text preview; affects the sidebar, panel, and overview.
6. **On-disk compatibility** — fresh format (default) vs. cross-read the macOS files (freezes the enum schemas; needs explicit sign-off).
7. **Secure input** — confirm "keep the indicator, drop the lockdown" for the auto password-prompt secure-input feature (Carbon `EnableSecureEventInput` has no Linux equivalent; Wayland makes the goal largely moot). *(Idle/activity tracking is **not** an open risk — the macOS source uses a local, not global, event monitor that maps directly to GTK controllers.)*
8. **Multi-window / tear-off** — single-window (macOS parity) vs. native Linux multi-window; decides whether the pane tear-off signal becomes a real feature.
9. **Keymap** — a deliberate Ctrl/Super Linux keymap that avoids WM collisions, not a ⌘→Ctrl transliteration.

---

*End of spec. Subsystem detail: `docs/research/01`–`09`, `03b`. Implementation plan: `docs/IMPLEMENTATION-PROPOSAL.md`.*
