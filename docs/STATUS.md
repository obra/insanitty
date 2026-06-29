# insanitty — Build Status

What is actually built and verified, vs. what's pending. Updated as Phase 0 progresses.

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
