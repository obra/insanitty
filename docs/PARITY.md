# insanitty ↔ Fantastty feature parity

Honest, source-grounded audit of how the Linux port (`app/`, `Sources/`, `tools/`,
`scripts/`) compares to the macOS app (`inspo/fantastty`). Written 2026-06-29 from a
deep read of both codebases.

**Status legend:** **REAL** = production-quality, wired into the app · **PARTIAL** =
works but narrower than Fantastty · **DEMO** = proves the path via a shortcut (dev
script / hardcoded data / test-only wiring) · **STUB** = present but inert · **ABSENT**
= not ported.

## Verdict

insanitty has a **real terminal-workspace-manager core** — live embedded Ghostty
terminals with true I/O, focus-aware splits, terminal tabs, a workspace sidebar, and
per-workspace tmux persistence of the primary shell — shipped as an installable `.deb`
with automatic CI builds. That core is genuine and non-trivial (it required embedding
Ghostty's GTK apprt as a shared library, which is novel work).

It does **not** have feature parity yet. The features that distinguish Fantastty —
the **remote engine in the GUI**, **full tmux control-mode** (windows↔tabs, panes↔splits,
layout restore), **session/layout persistence and metadata** (notes, tickets, attention,
active-time, archive/trash), **Linear**, **sprites**, **settings**, **theming**, and a
**real browser** — are demo, stub, or absent. By feature count insanitty covers roughly
a quarter of Fantastty's surface; by "time spent in the app" it covers the most-used
part (the terminal) and little of the differentiated part.

The sections below are the unvarnished detail.

## Terminal & window structure

| Fantastty | insanitty | Notes |
|---|---|---|
| Embedded libghostty terminal (Metal) | **REAL** (libghostty GTK, `app/main.swift` + `ghostty-embed/`) | Live PTY + GL renderer embedded via `libghostty-gtk.so`; real input→pty→shell→render verified (`e2e-scenario.sh`). |
| Workspace sidebar + switching | **REAL** (`buildWindow`, `GtkStack`+`GtkStackSidebar`) | Switching works. But workspace **list/names are regenerated every launch** — not persisted (Fantastty persists them in `layout.json`). |
| Terminal tabs | **REAL** (`addTab`, AdwTabView, Ctrl+T) | New tabs are plain shells (not tmux-backed → not persistent). |
| Splits / panes | **PARTIAL** (`splitFocused`, GtkPaned, Ctrl+D / Ctrl+Shift+D) | Real focus-aware GtkPaned tree. But splits are **local default shells**, not tmux panes; `SplitGeometry` (ported + tested) is **not used** — no min-size/ratio clamping. |
| Browser tabs (WebKit, persisted URL) | **REAL** (`newBrowserTabInCurrentWorkspace`, Ctrl+B) | WebKitGTK view with a nav bar (back/forward/reload + address entry → `webkit_web_view_load_uri`), title/URL sync. Loads live pages (`docs/images/e2e-6-browser.png`). URL *persistence* across restart still pending (no layout.json yet). |

## Sidebar snapshots, overview & browser  *(explicitly in the parity bar)*

| Fantastty | insanitty | Notes |
|---|---|---|
| **Sidebar snapshots** — each sidebar tab shows a **live thumbnail** of its content: terminal rendered to an image (`TerminalThumbnailRenderer`), browser via `WKSnapshotConfiguration`. The active session updates live (debounced 150 ms); inactive tabs show the last snapshot (`SidebarThumbnailView.swift`). | **REAL** (`registerWorkspace`/`selectWorkspace`, `app/main.swift`) | Custom `GtkListBox` sidebar; each workspace row is a `GtkPicture` of a `GtkWidgetPaintable` of the page — live for the active workspace, frozen to a `gdk_paintable_get_current_image` still on switch-away. Verified capturing the embedded Ghostty GL surface (`docs/images/sidebar-snapshots.png`). |
| **Workspace overview** — Exposé-style `LazyVGrid` of every tab in a workspace with live snapshots, hover-zoom, and click-to-select; adaptive column count (`WorkspaceOverviewView.swift`). | **REAL** (`buildOverview`/`toggleOverview`, `app/main.swift`) | A `GtkOverlay` + `GtkFlowBox` of workspace tiles (header grid button or Ctrl+O), reusing each workspace's current paintable; `child-activated` switches workspace. Verified headless (`docs/images/overview.png`). insanitty's grid is over workspaces; Fantastty's is over a workspace's tabs. |
| **Browser tabs** — real WebKit view with navigation + persisted URL. | **REAL** (`newBrowserTabInCurrentWorkspace`) | Nav bar (back/forward/reload) + address entry (`normalizeURL` → load or search) + live title/URL sync over a real WebKitWebView. Loads live pages over the network (`docs/images/e2e-6-browser.png`). URL persistence pending layout.json. |

## tmux integration

| Fantastty | insanitty | Notes |
|---|---|---|
| **tmux control mode (`-CC`)**: `TmuxControlClient`, protocol parser, V2 runtime, layout parser/mapper — windows↔tabs, panes↔splits, live layout sync | **PARTIAL — interactive single pane** (`TmuxControlParser`/`TmuxLayoutParser` + live `TmuxControlClient`, `app/TmuxControl.swift`) | Parser foundation (12 tests) **plus a live, interactive control client**: spawns `tmux -CC attach` in a PTY (`ins_pty_spawn`/`forkpty`), reads the protocol on the GTK main loop (`g_unix_fd_add`), renders a pane by injecting `%output` into a silent Ghostty surface, **and routes keystrokes back via `send-keys`** — typed input runs in the real session and the result paints back. Verified end to end (`scripts/e2e-tmux-control.sh`: type → send-keys → shell → %output → inject). Remaining: fan multiple windows→tabs + panes→splits via `%layout-change`→GtkPaned. The default workspaces still use plain `tmux new-session -A`. |
| Attach to existing session (local + SSH), `TmuxAttachSheet` | **ABSENT** | No attach UI. |
| SSH remote tmux (`ssh -t … tmux -CC`) | **ABSENT** | |
| `persistentSessions` toggle (default **off**), restore layout on launch | **PARTIAL** | tmux persistence is always-on for the primary shell and **verified** (`e2e-persistence.sh`: a process outlived an app kill, V1<V2<V3). But there is **no layout restore** — only the tmux server retains the shell; the app rebuilds a fresh default workspace set each launch. |

## Persistence & session metadata

Fantastty keeps everything under `~/.fantastty/`. insanitty now persists its **workspace
layout**; the richer per-workspace metadata is still absent.

| Fantastty (`~/.fantastty/…`) | insanitty | Notes |
|---|---|---|
| `layout.json` — workspace/tab arrangement, browser URLs, selected tab | **PARTIAL** (`AppLayout`/`LayoutStore`, `Sources/InsanittyCore/AppLayout.swift`) | Persists the workspace list (names/order/indices), each workspace's browser-tab URLs, and the selected workspace to `$XDG_STATE_HOME/insanitty/layout.json`; restored on launch (reattaches tmux by index, recreates browser tabs). Verified `scripts/e2e-layout-persistence.sh`. Not yet: terminal-tab/split layout within a workspace (needs tmux control mode). |
| `workspaces.json` — per-workspace metadata: name, notes (+revision history), tags, attention flag, `ticketURL`, `pullRequestURL`, `totalActiveSeconds`, archive/trash | **ABSENT** | |
| `ssh-hosts.json` (note: appears vestigial even in Fantastty) | **ABSENT** | |
| Idle-aware active-time tracking | **ABSENT** | |
| Archive / trash workspaces | **ABSENT** | |
| Session notes with edit history | **ABSENT** | |

## Remote engine (QUIC / SSH)

This is the most nuanced area and the most overstated in earlier notes. Breaking it apart:

| Capability | insanitty | Notes |
|---|---|---|
| Go remote-engine helper serving QUIC | **REAL (reused)** | Fantastty's own Go helper, compiled unchanged with libghostty-vt (`build-remote-helper.sh`). Serves QUIC on localhost. |
| Protocol + transport + security **proven** | **REAL but Go-side** (`e2e-remote-engine.sh`) | QUIC attach, SPKI cert-pin, one-time key, `workspaceSnapshot`+`paneKeyframe`, input, wrong-cert rejection all verified — **using the helper's own reference probes**. Zero insanitty client code runs in that test. |
| insanitty's **Swift** client wired into the GUI | **DEMO** (`makeRemoteWorkspacePage` → `remote-grid-ansi.sh`) | The "remote (QUIC)" workspace paints an inert surface from `Swift → bash → Go probe → Python → ANSI → inject`. One-shot paint (re-injected ≤3×), **read-only** (no input), no styled cells, no deltas. `e2e-remote-gui.sh` only asserts bytes were injected. |
| Native Swift QUIC client | **REAL but minimal & not in the app** (`tools/quic-client`) | Binds msquic, parses the helper's real `FANTASTTY_REMOTE` bootstrap line (`--bootstrap`, via the tested `RemoteBootstrapLine`), attaches, and decodes a `paneKeyframe` via `RemoteGridProtocol` (`scripts/e2e-native-quic.sh`). **Still connects with cert validation DISABLED** (`NO_CERTIFICATE_VALIDATION`) — SPKI pinning is the next step; no deltas, no input, no predictive echo; not invoked by `app/`. |
| Styled-cell remote render (`remote_grid_*` cell API) | **ABSENT in the GTK shim** | The high-fidelity inject API exists only in the **Metal-side** patch (`ghostty-inject-output.patch`); the GTK embedding shim exposes **raw-bytes inject only**. Re-homing it to GTK is the open "Spike B". |
| Predictive echo / input forwarding | **ABSENT** | The GUI remote path is read-only. |
| Decode layer interop-verified | **REAL** (`RemoteGridProtocol`, `RemoteGridProtocolTests`) | insanitty's Codable wire types decode a payload captured live from the helper over QUIC. The decode half is real; transport/render/input are not wired. |

## Integrations

| Fantastty | insanitty | Notes |
|---|---|---|
| OSC 9 `note;`/`ticket;`/`pr;` interception (fully wired, writes to `workspaces.json`) | **STUB** | `scripts/shell-integration/insanitty.sh` **emits** the OSC sequences, but nothing in `app/` **consumes** them. Emitter without a receiver. |
| Linear (`LinearService`: API + Keychain token + UI) | **TEST-ONLY** | `LinearURL.swift` parses issue/project URLs (tested) but is **wired to nobody** — no GraphQL, no token, no UI. |
| Sprites (external Fly.io `sprite` CLI) | **ABSENT** | |
| Notifications | **ABSENT** | |
| Theming (`ThemeManager`, `AppearanceMode`/dark mode) | **ABSENT** | The `.deb` bundles Ghostty's theme files, but insanitty has **no** theme selection or appearance UI. |
| Settings / preferences (`@AppStorage` keys) | **ABSENT** | No settings UI or config reading. |

## Keyboard shortcuts

**PARTIAL.** insanitty hardcodes Ctrl+D / Ctrl+Shift+D (split), Ctrl+T (tab), Ctrl+B
(browser), Ctrl+N (workspace) in one capture-phase handler — no rebinding, no config,
and not the full Fantastty `AppCommands` set.

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
