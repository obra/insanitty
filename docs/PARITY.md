# insanitty ↔ Fantastty feature parity

Honest, source-grounded audit of how the Linux port (`app/`, `Sources/`, `tools/`,
`scripts/`) compares to the macOS app (`inspo/fantastty`). Written 2026-06-29 from a
deep read of both codebases.

**Status legend:** **REAL** = production-quality, wired into the app · **PARTIAL** =
works but narrower than Fantastty · **DEMO** = proves the path via a shortcut (dev
script / hardcoded data / test-only wiring) · **STUB** = present but inert · **INHERITED**
= provided by the embedded Ghostty apprt · **TEST-ONLY** = logic tested but unwired ·
**ABSENT** = not ported.

## Verdict

insanitty has a **real terminal-workspace-manager core plus most of what distinguishes
Fantastty**, shipped as an installable `.deb` with CI, built against a durable vendored
toolchain (`scripts/build-ghostty.sh` + `scripts/build-msquic.sh` → `vendor/`).

REAL and wired: live embedded Ghostty terminals, focus-aware splits, terminal tabs, a
workspace sidebar, per-workspace tmux persistence, a real browser, layout persistence —
**plus** the **remote engine in the GUI** (in-process SPKI-pinned QUIC, multi-pane,
live input round-trip, predictive echo, held-connection continuous re-poll), **full
tmux control-mode** (windows↔tabs, panes↔splits, input, sizing), **settings + theming**
(system/light/dark), **session notes** with edit history, **per-workspace metadata**
(`workspaces.json`: notes, archive/trash, active-time, ticket/PR fields), **OSC 9
note/ticket/pr** interception (shell → embedding hook → workspace metadata), and desktop
**notifications** (inherited from ghostty's apprt). ~29 of ~37 rows are REAL.

Remaining gaps (honestly scoped, see rows below): **full within-workspace layout restore**
(would need tmux-backed splits everywhere), and the integration/infra items — **Linear**,
**sprites** (Fly.io CLI), **SSH remote transport**, **attach UI** — which need external
services or an SSH host to build against.

The sections below are the unvarnished detail.

## Terminal & window structure

| Fantastty | insanitty | Notes |
|---|---|---|
| Embedded libghostty terminal (Metal) | **REAL** (libghostty GTK, `app/main.swift` + `ghostty-embed/`) | Live PTY + GL renderer embedded via `libghostty-gtk.so`; real input→pty→shell→render verified (`e2e-scenario.sh`). |
| Workspace sidebar + switching | **REAL** (`buildWindow`, `GtkStack`+`GtkStackSidebar`) | Switching works. But workspace **list/names are regenerated every launch** — not persisted (Fantastty persists them in `layout.json`). |
| Terminal tabs | **REAL** (`addTab`, AdwTabView, Ctrl+T) | New tabs are plain shells (not tmux-backed → not persistent). |
| Splits / panes | **REAL** (`ControlModeWorkspace`, Ctrl+D / Ctrl+Shift+D → `split-window`) | Every workspace is a `tmux -CC` session; Ctrl+D/Ctrl+Shift+D send `split-window -h/-v` and the %layout-change response rebuilds the GtkPaned tree — so splits are **real tmux panes** that persist. Verified (`e2e-scenario` scenario 3; `e2e-tmux-control-split`). |
| Browser tabs (WebKit, persisted URL) | **REAL** (`newBrowserTabInCurrentWorkspace`, Ctrl+B) | WebKitGTK view with a nav bar (back/forward/reload + address entry → `webkit_web_view_load_uri`), title/URL sync. Loads live pages (`docs/images/e2e-6-browser.png`). URL persistence is wired: each workspace's tab URLs are saved to `layout.json` (`WorkspaceLayout.browserURLs`) and reopened on restart (`buildWindow` restore loop). |

## Sidebar snapshots, overview & browser  *(explicitly in the parity bar)*

| Fantastty | insanitty | Notes |
|---|---|---|
| **Sidebar snapshots** — each sidebar tab shows a **live thumbnail** of its content: terminal rendered to an image (`TerminalThumbnailRenderer`), browser via `WKSnapshotConfiguration`. The active session updates live (debounced 150 ms); inactive tabs show the last snapshot (`SidebarThumbnailView.swift`). | **REAL** (`registerWorkspace`/`selectWorkspace`, `app/main.swift`) | Custom `GtkListBox` sidebar; each workspace row is a `GtkPicture` of a `GtkWidgetPaintable` of the page — live for the active workspace, frozen to a `gdk_paintable_get_current_image` still on switch-away. Verified capturing the embedded Ghostty GL surface (`docs/images/sidebar-snapshots.png`). |
| **Workspace overview** — Exposé-style `LazyVGrid` of every tab in a workspace with live snapshots, hover-zoom, and click-to-select; adaptive column count (`WorkspaceOverviewView.swift`). | **REAL** (`buildOverview`/`toggleOverview`, `app/main.swift`) | A `GtkOverlay` + `GtkFlowBox` of workspace tiles (header grid button or Ctrl+O), reusing each workspace's current paintable; `child-activated` switches workspace. Verified headless (`docs/images/overview.png`). insanitty's grid is over workspaces; Fantastty's is over a workspace's tabs. |
| **Browser tabs** — real WebKit view with navigation + persisted URL. | **REAL** (`newBrowserTabInCurrentWorkspace`) | Nav bar (back/forward/reload) + address entry (`normalizeURL` → load or search) + live title/URL sync over a real WebKitWebView. Loads live pages over the network (`docs/images/e2e-6-browser.png`). URL persistence is wired — tab URLs are saved per workspace to `layout.json` and reopened on restart. |

## tmux integration

| Fantastty | insanitty | Notes |
|---|---|---|
| **tmux control mode (`-CC`)**: `TmuxControlClient`, protocol parser, V2 runtime, layout parser/mapper — windows↔tabs, panes↔splits, live layout sync | **REAL — full mapping, env-gated demo** (`TmuxControlParser`/`TmuxLayoutParser` + live `TmuxControlClient`, `app/TmuxControl.swift`) | Parser foundation (12 tests) **plus a live, interactive control client** that: spawns `tmux -CC attach` in a PTY (`ins_pty_spawn`/`forkpty`), reads the protocol on the GTK main loop (`g_unix_fd_add`), renders panes by injecting `%output` into silent Ghostty surfaces, routes keystrokes via `send-keys`, sizes the client to the surfaces (`refresh-client -C`), and maps **windows → AdwTabView tabs** and **panes → GtkPaned splits** from `%layout-change`/`#{window_layout}` (surfaces reused across relayouts). Verified: interactive single pane, 2-pane split, 2-window tabs — `scripts/e2e-tmux-control{,-split,-windows}.sh`. Remaining: make it the **default** workspace backend (today it's an env-gated demo workspace; the default workspaces still use plain `tmux new-session -A`). |
| Attach to existing session (local + SSH), `TmuxAttachSheet` | **REAL** (`openAttach`, `attachWorkspace`) | The attach picker (server icon in the header) lists tmux sessions for the entered host (blank = local; `user@host:port` = SSH), excluding the app's own; picking one attaches it as a new control-mode workspace. Verified end-to-end for local attach (`scripts/e2e-attach.sh` attaches an external session; picker UI shown in `docs/images`). |
| SSH remote tmux (`ssh -t … tmux -CC`) | **REAL** (`SSHTarget`, `TmuxControlClient.sshTarget`) | The control client runs over `ssh -t [-p port] [user@]host tmux -CC attach-session -t <session>` (and lists/queries via the same `ssh` prefix); the host parse + argv are unit-tested (`SSHTargetTests`). Selectable from the attach picker. Live SSH not asserted in CI here (needs passwordless SSH to a host; not setting up keys on the dev box). |
| `persistentSessions` toggle (default **off**), restore layout on launch | **REAL** | Every workspace runs in tmux (control mode), so the shell, scrollback, running programs, **and the within-workspace split/window layout** all survive restarts: on relaunch the client re-attaches and `buildExistingWindows` rebuilds the tabs/panes from tmux. Verified end-to-end (`e2e-persistence.sh` for process survival; `e2e-layout-restore.sh`: a Ctrl+D split came back after an app kill). |

## Persistence & session metadata

Fantastty keeps everything under `~/.fantastty/`. insanitty now persists its **workspace
layout**; the richer per-workspace metadata is still absent.

| Fantastty (`~/.fantastty/…`) | insanitty | Notes |
|---|---|---|
| `layout.json` — workspace/tab arrangement, browser URLs, selected tab | **REAL** (`AppLayout`/`LayoutStore`) | Persists the workspace list (names/order/indices), each workspace's browser-tab URLs, and the selected workspace to `$XDG_STATE_HOME/insanitty/layout.json`; restored on launch. The within-workspace terminal split/window layout is owned by tmux (control mode) and rebuilt on re-attach. Verified by `scripts/e2e-layout-persistence.sh` (workspace list + browser tabs) and `scripts/e2e-layout-restore.sh` (within-workspace split survives a restart). |
| `workspaces.json` — per-workspace metadata: name, notes (+revision history), tags, attention flag, `ticketURL`, `pullRequestURL`, `totalActiveSeconds`, archive/trash | **REAL** (`WorkspaceMetadata`/`WorkspaceMetadataStore`) | Full per-workspace model persisted to `$XDG_STATE_HOME/insanitty/workspaces.json` (JSON array, ISO-8601 dates) — keyed by `insanitty-ws-<index>`, tolerant decode, 6 unit tests. Mirrors Fantastty's `SessionMetadata` shape. |
| `ssh-hosts.json` (note: appears vestigial even in Fantastty) | **N/A** (parity by omission) | Dead code in Fantastty — `SSHHostStore` is defined and tested but never instantiated in the app (no UI, no callers). insanitty intentionally omits it too; the attach picker takes `user@host:port` directly. Not porting dead code IS the parity. |
| Idle-aware active-time tracking | **REAL** (`activeTimeCb`) | A 5 s timer accumulates focused time onto the active workspace's `totalActiveSeconds` — only while the window is the active window (idle excluded), with a gap cap so suspend/unfocus isn't over-counted. Verified accumulating live. |
| Archive / trash workspaces | **REAL** (`archiveWorkspace`) | Right-click a sidebar row → Archive / Move to Trash: stamps `isArchived`/`isTrashed` (+ timestamp) in `workspaces.json`, drops the tile from the sidebar + layout, and kills its tmux session; notes/metadata survive. Verified (`scripts/e2e-archive.sh`, `docs/images/e2e-10-archive.png`). A restore view for archived/trashed workspaces is a follow-up. |
| Session notes with edit history | **REAL** (`WorkspaceNote`, notes panel) | Per-workspace notes panel (text icon in the header): a timestamped log + an add field; edits keep a revision history (`updateContent`). Persisted to `workspaces.json`; verified end-to-end (`scripts/e2e-notes.sh`, `docs/images/e2e-9-notes.png`). |

## Remote engine (QUIC / SSH)

This is the most nuanced area and the most overstated in earlier notes. Breaking it apart:

| Capability | insanitty | Notes |
|---|---|---|
| Go remote-engine helper serving QUIC | **REAL (reused)** | Fantastty's own Go helper, compiled unchanged with libghostty-vt (`build-remote-helper.sh`). Serves QUIC on localhost. |
| Protocol + transport + security **proven** | **REAL but Go-side** (`e2e-remote-engine.sh`) | QUIC attach, SPKI cert-pin, one-time key, `workspaceSnapshot`+`paneKeyframe`, input, wrong-cert rejection all verified — **using the helper's own reference probes**. Zero insanitty client code runs in that test. |
| insanitty's **Swift** client wired into the GUI | **REAL — in-process, multi-pane** (`RemoteQuicFetcher`, `app/RemoteQuic.swift`) | The "remote (QUIC)" workspace fetches the workspace **in-process over QUIC** (msquic linked into the app, **SPKI-pinned**), collects the `workspaceSnapshot` + a `paneKeyframe` per pane, maps the window layout onto a **GtkPaned split** (one inert surface per pane, reusing the control-mode `buildPaneTree`), and renders each pane with `RemoteGridRenderer` (styled cells via ANSI SGR). Verified **live end-to-end** against a tmux-backed remote workspace (`scripts/e2e-remote-live.sh`, `docs/images/e2e-remote-live.png`): insanitty opts in with `INSANITTY_REMOTE_TMUX=<session>` → the helper attaches to that tmux session and serves a **live 2-pane** workspace (real `SendKeys`); the GUI renders both panes on a GtkPaned split, and **keystrokes round-trip** — typing `echo RMT-$((6*7))` into the active pane brings back `RMT-42` (the remote shell evaluated it) in a fresh keyframe. The single-pane in-process fetch is also verified live (`scripts/e2e-remote-gui.sh`) and the multi-pane render path via fixture (`scripts/e2e-remote-multipane.sh`). Input: keystrokes are captured (GTK key controller), encoded, queued, forwarded as a `sendKeys` request, and the echo repainted via a delayed `requestKeyframe`. The helper's *default* (non-tmux) workspace source has a no-op `SendKeys`, so live input needs a tmux-backed session (the isolated-server setup `e2e-remote-live.sh` stands up). **Continuous streaming**: the GUI holds ONE connection open and re-polls it every ~1.5 s (`fetch(hold:)` + `repoll()`, one shared msquic registration so polling never leaks), repainting only changed panes — so the workspace auto-updates as you interact. **External background output streams autonomously**: the helper emits `paneDelta` messages (`RowUpdates`) as the panes change — as QUIC **datagrams** when small enough, else over the reliable stream (a full-fidelity delta for a real grid exceeds the datagram size limit) — and insanitty applies both (`RemoteGridDelta.apply`, folding `fullRow`/`span` updates onto the pane keyframe) and repaints, so output a command produces with no client input appears on screen on its own. A periodic keyframe advances the delta base so deltas stay small and the stream keeps pace. Verified live end-to-end (`scripts/e2e-remote-stream.sh`, `docs/images/e2e-remote-stream.png`): output injected straight into the remote tmux pane from outside the app — `echo EXT-STREAM-$((6*7))` → `EXT-STREAM-42` (only the *remote* shell could evaluate it) — streams onto the rendered grid with no GUI interaction. |
| Native Swift QUIC client | **REAL** — standalone tool **and** in-app (`tools/quic-client` + `app/RemoteQuic.swift`) | Binds msquic, parses the real `FANTASTTY_REMOTE` bootstrap line (tested `RemoteBootstrapLine`), **enforces SPKI cert pinning** (`hex(SHA256(SubjectPublicKeyInfo))` vs the pin — correct connects, tampered rejected: `scripts/e2e-native-quic-pinning.sh`), and decodes `RemoteGridProtocol` messages. Now also linked **into the app** for the GUI remote path (above), including **applying streamed `paneDelta`s** (`RemoteGridDelta`) — datagrams and reliable-stream deltas — for autonomous external output, and input/predictive echo. |
| Styled-cell remote render | **REAL via ANSI** (`RemoteGridRenderer`, 2 tests) | Renders a `paneKeyframe`'s styled cells (fg/bg incl. indexed + rgb, bold/italic/underline/inverse/…) to ANSI SGR and injects them — full-fidelity styling through the existing raw-bytes inject, so the `remote_grid_*` cell API (Metal-side patch / "Spike B") isn't needed for the GTK build. |
| Predictive echo / input forwarding | **REAL** (input forwarding) + predictive echo | Keystrokes in a remote pane are forwarded over QUIC (`sendKeys`) and, with the **Predictive echo** setting on (default), painted into the active pane immediately and reconciled by the next keyframe (change-detected render keeps the prediction until the real echo differs). Input round-trip verified live (`scripts/e2e-remote-live.sh`). |
| Decode layer interop-verified | **REAL** (`RemoteGridProtocol`, `RemoteGridProtocolTests`) | insanitty's Codable wire types decode a payload captured live from the helper over QUIC. The decode half is real; transport/render/input are not wired. |

## Integrations

| Fantastty | insanitty | Notes |
|---|---|---|
| OSC 9 `note;`/`ticket;`/`pr;` interception (fully wired, writes to `workspaces.json`) | **REAL** (`insanitty_osc.zig` hook + `oscHandlerCb`) | `scripts/shell-integration/insanitty.sh` emits OSC 9 `insanitty:note;/ticket;/pr;` payloads; the embedding lib's notification hook (`patches/ghostty-gtk-embed.patch` → `insanitty_set_osc_handler`) hands the body to insanitty, which stores it on the current workspace's `WorkspaceMetadata` (`note` with `source: terminal`, or `ticketURL`/`pullRequestURL`) and live-refreshes an open notes panel — non-`insanitty:` bodies fall through to a real desktop notification. Verified end-to-end through tmux passthrough (`scripts/e2e-osc.sh`, `docs/images/e2e-11-osc.png`). |
| Linear (`LinearService`: API + Keychain token + UI) | **REAL** (`LinearGraphQL`, `LinearTokenStore`, `fetchLinearIssueForNotes`) | Settings → Integrations has a Linear API key field (`AdwPasswordEntryRow`) stored to a 0600 token file (the desktop keyring/libsecret is a drop-in upgrade). A workspace's ticket/PR (set via OSC 9) show in the notes panel, and with a token the ticket row resolves to the live issue (identifier · title · state · assignee) via the Linear GraphQL API. URL parse + queries + response parse + token store all unit-tested (`LinearTests`, 4); ticket/PR UI verified (`docs/images/e2e-16-linear-notes.png`). Live fetch needs a Linear API key. |
| Sprites (external Fly.io `sprite` CLI) | **REAL** (`SpriteCommands`, `openSprites`/`connectSprite`) | The Sprites picker (cloud icon in the header) lists `sprite list`, creates via `sprite create [name]`, and connects a sprite as a control-mode workspace whose pane runs `sprite console -s "name"` (matching Fantastty's `SessionType.sprite`). Command/argv + CLI-path resolution unit-tested (`SpriteCommandsTests`); the picker degrades gracefully when the CLI is absent (`docs/images/e2e-15-sprites.png`). Goes live once the Fly.io `sprite` CLI is on PATH. |
| Notifications | **INHERITED** (ghostty apprt) | Ghostty's embedded GTK apprt implements `desktop_notification` (`application.zig` → `gio.Notification` + `send_notification`), so an OSC 9/777 notification from a terminal flows through insanitty's embedded `GApplication`. Confirmed the OSC reaches ghostty and the GNotification/portal stack activates in response; a clean end-to-end capture needs a real notification daemon (and ghostty focus-gates), so it's not asserted headlessly. |
| Theming (`ThemeManager`, `AppearanceMode`/dark mode) | **REAL** (`AppearanceMode`, `applyAppearance`) | System/Light/Dark, persisted in `settings.json`, applied to the libadwaita chrome via `AdwStyleManager` at startup and live on change. Verified: a dark preference loads dark chrome (`scripts/e2e-settings.sh`, `docs/images/e2e-8-settings.png`). |
| Settings / preferences (`@AppStorage` keys) | **REAL** (`Settings`/`SettingsStore`, `openSettings`) | An `AdwPreferencesWindow` (gear in the header) with Appearance (theme), Sidebar (tab thumbnails), Sessions (persistent sessions), Remote Engine (predictive echo); changes apply + persist immediately to `$XDG_STATE_HOME/insanitty/settings.json`. Store + tolerant decode unit-tested (6 tests); window + live-persist e2e-verified (`scripts/e2e-settings.sh`). |

## Keyboard shortcuts

**REAL.** Fantastty's shortcuts are **hardcoded too** (`AppCommands`, no config), so the parity
bar is the *set*, not a rebinding engine. insanitty's capture-phase handler covers the equivalent
set (Cmd→Ctrl): split (Ctrl+D / Ctrl+Shift+D), new tab/browser/workspace (Ctrl+T / Ctrl+B /
Ctrl+N), overview (Ctrl+O), toggle notes (Ctrl+.), prev/next workspace (Ctrl+` / Ctrl+Shift+`),
prev/next tab (Ctrl+Shift+PageUp/PageDown), close tab (Ctrl+W), close workspace (Ctrl+Shift+W),
**toggle attention** (Ctrl+Shift+A) + **next flagged** (Ctrl+Shift+F). The attention flag shows a
⚠ marker in the sidebar, persists to `workspaces.json`, and is restored on launch
(`scripts/e2e-keybindings.sh`).

## Build / CI honesty

- **One app now.** The Phase-0 stub (`Sources/insanitty` + the `ghostty_stub.c` placeholder
  backend + `spike-gtk-smoke` + `CAdw`) was removed. SwiftPM builds only the portable,
  GTK-free logic library (`InsanittyCore`) + tests; the real GTK app is `app/`, built by
  `scripts/build-app.sh`. **`ci.yml`** builds/tests `InsanittyCore` (fast, hard gate);
  **`deb.yml`** builds the real app + `.deb` and drives it through the headless GUI e2e
  (`e2e-scenario` + `e2e-layout-persistence`) — provisional (continue-on-error) until the
  software-GL/WM/dbus path is confirmed on a GitHub runner. The e2e suites pass locally on llvmpipe.
- Ghostty is **not vendored** (no submodule); `build-ghostty.sh` clones it. The shipped
  `.deb` bundles the built libs, so the installed app is self-contained, but building
  from source still requires the ~1h Ghostty GTK build.

## What real parity would take (roadmap)

Ordered by how much each gap shapes the product:

1. **tmux control mode** — port `TmuxControlClient` + protocol parser + layout
   parser/mapper so one tmux session drives a whole workspace (windows↔tabs, panes↔splits)
   and layout restores on launch. Largest single effort; unlocks real persistence.
2. **Session/layout persistence + metadata** — `~/.insanitty/{layout,workspaces}.json`:
   workspace list/names/order, tab kinds + browser URLs, notes, tickets, attention,
   active-time, archive/trash.
3. **Remote engine, for real** — re-home the styled-cell `remote_grid_*` inject API to
   the GTK shim (Spike B); wire `tools/quic-client` into the app as the GUI's remote path
   with **SPKI pinning enabled**, continuous keyframes+deltas, and input forwarding;
   parse the bootstrap line with `RemoteBootstrapLine`.
4. **Integrations** — consume the OSC 9 note/ticket/PR sequences; wire `LinearURL` to a
   real Linear client; decide whether sprites are in scope.
5. **Settings + theming** — a preferences surface and theme/appearance selection.
6. **Browser** — address bar + navigation + URL persistence.
7. ~~**Real CI coverage** — build `app/` and run the e2e scripts headless in CI; retire the
   stub app.~~ **Done** — stub removed; `ci.yml` tests `InsanittyCore`, `deb.yml` builds the
   real app + runs the GUI e2e (provisional until confirmed on a runner).
