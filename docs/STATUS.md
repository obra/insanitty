# insanitty — Build Status

What is actually built and verified, vs. what's pending. Updated as Phase 0 progresses.

## Running app + end-to-end test (2026-06-29)

**insanitty runs as a real local terminal workspace manager and passes an end-to-end
interaction test.** `app/` (built by `scripts/build-app.sh`, linking `libghostty-gtk`) hosts
Ghostty's `GApplication` and builds insanitty's own chrome: a header bar + a **sidebar of
workspaces** (names from the ported `WorkspaceName`) + a `GtkStack`, each page a **live
`GhosttySurface` terminal**. Clicking the sidebar switches workspaces.

`scripts/e2e-scenario.sh` drives the running app through its UI with `xdotool` (headless:
Xvfb + matchbox WM + `dbus-run-session`) and **passes**:
- **Scenario 1** — typed `echo …$((6*7))` into a terminal; the embedded zsh ran it and rendered
  `…-42` (`docs/images/e2e-1-typed-command.png`). Real input→pty→shell→render round-trip.
- **Scenario 2** — switched to a second workspace and typed in its own live terminal
  (`docs/images/e2e-2-second-workspace.png`).
- **Scenario 3** — `Ctrl+D` **split** the terminal into two independent live shells side by side
  (GtkPaned divider); typed a different command in each (`docs/images/e2e-3-split.png`).

- **Scenario 4** — `Ctrl+T` opened a new **tab** (AdwTabView) with its own live terminal
  (`docs/images/e2e-4-tabs.png`).

**Persistence** (`scripts/e2e-persistence.sh`, PASS) — each workspace's terminal runs
`tmux new-session -A -s insanitty-ws-N`, so its shell + child processes live in the tmux
server. The test starts a counter process in a workspace, **kills the app**, confirms the
counter kept advancing while the app was dead, relaunches, and confirms the workspace
**re-attached the same live session** (V1=8 < V2=18 < V3=42 across the kill). This is the
headline "sessions survive restart" feature, robustly verified (a process outlived the app).

Features working (Fantastty's full structure — workspace → tabs → splits → panes):
workspaces (sidebar + switching), **terminal + browser tabs** (Ctrl+T / Ctrl+B; AdwTabView +
WebKitGTK — `docs/images/e2e-6-browser.png`), **splits** (Ctrl+D right / Ctrl+Shift+D down,
focus-aware), **tmux-backed persistent sessions**, live terminals with interactive I/O.
Screenshots in `docs/images/`.
**Remote feature set — works end-to-end locally** (`scripts/e2e-remote-engine.sh`, PASS).
The Go helper (Fantastty's, reused unchanged) builds here with libghostty-vt (Go 1.25,
`scripts/build-remote-helper.sh`) and serves QUIC on 127.0.0.1 — **localhost is the host**, so
no separate LAN machine is needed. Using the helper's reference QUIC client (its probes):
1. **QUIC attach** (cert-pinned SPKI + one-time key) + **structured-grid render** pulled over
   QUIC (`workspaceSnapshot` + `paneKeyframe`, byte-for-byte matching SPEC §4.3);
2. **input** sent over QUIC reached the remote pane;
3. **cert pinning enforced** — a wrong SPKI is rejected (`CRYPTO_ERROR … SPKI SHA256`).
**And it's integrated into insanitty's GUI** (`scripts/e2e-remote-gui.sh`, PASS): a "remote
(QUIC)" workspace shows a grid the app **fetched over QUIC from the helper** and injected into a
surface via `insanitty_surface_inject_output` — `docs/images/e2e-7-remote-in-gui.png` shows the
live QUIC addr, SPKI cert pin, 80×24 grid, 24 rows received, rendered in the GUI.

So the remote protocol + QUIC transport + tmux→libghostty-vt server rendering + security all
function. **insanitty's Swift protocol layer is ported and interop-verified:**
`Sources/InsanittyCore/RemoteGridProtocol.swift` (the Codable wire types) decodes a payload
captured live from the helper over QUIC (`swift test` → `RemoteGridProtocolTests`, against
`Fixtures/remote-grid-payload.jsonl`). So the decode half of insanitty's remote client works
against the real server; remaining is the **Swift QUIC transport** (msquic binding — the Go
probe is the working reference) + predictive echo.

Not yet (deferred): the full tmux **control-mode** mapping (tmux windows↔tabs, panes↔splits
within ONE session per workspace — currently each workspace attaches its own session, splits
are local panes); notes/URLs/Linear/sprites; the **insanitty-side** Swift QUIC client.

## Verified on the dev box (2026-06-29)

Toolchain probed: Swift **6.3.2**, Zig **0.15.2**, GTK4 **4.14.5**, libadwaita **1.5.0**,
Go 1.22, tmux 3.4, clang 18, Xvfb. 16 cores / 60 GiB RAM, x86_64 / glibc 2.39, headless.

| Pillar | Result |
|---|---|
| **Swift on Linux** | ✅ Swift 6.3.2 compiles; Foundation/Codable work; `swift test` = **11/11 passing** (ported `WorkspaceName`, `RemoteBootstrapLine`, `SplitGeometry`). |
| **Ghostty engine builds (Zig)** | ✅ `zig build -Demit-lib-vt` → `libghostty-vt.so`. **And the full GTK frontend builds + runs**: `zig build -Doptimize=Debug -Dgtk-wayland=false -Dgtk-x11=true` → a 150 MB `ghostty` binary linking libgtk-4 + libadwaita-1; `ghostty +version` prints `1.3.2-HEAD-+5d0a82ba3` headless under Xvfb. The entire engine-reuse path (incl. the `GhosttySurface` widget) compiles on this box. |
| **Swift ↔ GTK4/libadwaita interop** | ✅ `spike-gtk-smoke` and the `insanitty` app shell **compile, link, and run headless under Xvfb**: GTK init, `AdwStyleManager`, a real `GtkPaned` widget tree, an `AdwApplicationWindow` with sidebar + split. (This validates report `10`'s recommended "Swift + direct C interop" approach.) |
| **SwiftPM + pkg-config** | ✅ builds; SwiftPM strips the stray `-mfpmath=sse`/`-pthread` cflags (warnings only). |
| **App shell skeleton** | ✅ `INSANITTY_SMOKE=1 xvfb-run -a .build/debug/insanitty` opens the window (sidebar of generated workspace names + split placeholders) and self-quits, exit 0. |

## Phase-0 spike status

| Spike | State |
|---|---|
| **D — SplitTree on GtkPaned** | Substrate proven (GtkPaned tree builds/runs); `SplitGeometry` oracle constants ported + tested. Remaining: rebind the full `SplitTree` leaf type. |
| **A — embed Ghostty GTK surface** | ✅ **DONE.** A live Ghostty terminal renders inside a Swift-hosted insanitty window (`docs/images/spike-a-embedded-terminal.png`). Built Ghostty's GTK apprt as `libghostty-gtk.so` with a 4-function C ABI (`patches/ghostty-gtk-embed.patch`, 103 insertions); the Swift host (`spikes/embed-a`) hosts Ghostty's `GApplication`, creates its own `AdwApplicationWindow`, and parents a live `GhosttySurface` running zsh. Verified headless on llvmpipe (EGL GL 3.2). See `ghostty-embed/`. |
| **B — re-home inject_output/remote_grid patch** | Pending the GTK Ghostty build (A). The patch (`patches/ghostty-inject-output.patch`) is verified to apply at the pinned commit; bodies are renderer-agnostic. |
| **C — msquic ↔ Go helper** | Pending: `msquic` not installed, and needs a LAN host running the helper. Bootstrap-line parser already ported + tested. |

## Ghostty GTK build recipe (verified on this box)

The distro toolchain isn't enough; the exact recipe that works:
- **blueprint-compiler ≥ 0.16** (0.20.4 used) installed via **meson** (apt's 0.12.0 fails on
  `1.5/*.blp`; a run-from-source copy reports version "uninstalled" → Ghostty's
  `InvalidVersion` build error). `scripts/setup-dev-env.sh` does the meson install.
- **gettext** (`msgfmt`), GTK4/libadwaita dev, webkitgtk/libsecret/libnotify dev.
- `zig build -Doptimize=Debug -Dgtk-wayland=false -Dgtk-x11=true` — X11-only avoids the
  `gtk4-layer-shell-0` lib (not in Ubuntu's default repos; build it from source to enable
  Wayland). X11 suits the headless Xvfb box.

## Installed during this session

webkitgtk-6.0, libsecret-1, libnotify, gettext, blueprint-compiler 0.20.4 (meson), meson+ninja.

## Still needed (later phases)

`msquic` (remote engine — build from https://github.com/microsoft/msquic; Spike C),
`gtk4-layer-shell` from source (only if a Wayland build is wanted). See `scripts/setup-dev-env.sh`.

## Environment limitations (not blockers, but shape what can be *run* here)

- **Headless** (no display/GPU): GTK runs under Xvfb with software GL (EGL/DRI3 warnings are
  benign). **GtkGLArea** terminal rendering (the actual Ghostty surface) needs working GL —
  untested here; a dev box with a display or a Mesa/llvmpipe GL setup is needed to *see* a
  terminal. Compilation/linking is unaffected.
- The forked Ghostty isn't vendored as a submodule yet; `scripts/build-ghostty.sh` documents
  the build. The research used a clone at commit `5d0a82ba` (Zig 0.15.2).
