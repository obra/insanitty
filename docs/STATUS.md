# insanitty — Build Status

What is actually built and verified, vs. what's pending. Updated as Phase 0 progresses.

## Verified on the dev box (2026-06-29)

Toolchain probed: Swift **6.3.2**, Zig **0.15.2**, GTK4 **4.14.5**, libadwaita **1.5.0**,
Go 1.22, tmux 3.4, clang 18, Xvfb. 16 cores / 60 GiB RAM, x86_64 / glibc 2.39, headless.

| Pillar | Result |
|---|---|
| **Swift on Linux** | ✅ Swift 6.3.2 compiles; Foundation/Codable work; `swift test` = **11/11 passing** (ported `WorkspaceName`, `RemoteBootstrapLine`, `SplitGeometry`). |
| **Ghostty engine builds (Zig)** | ✅ `zig build -Demit-lib-vt` produces `libghostty-vt.so` (+ `.a`, pkg-config) on this box. The hardest external dependency compiles. |
| **Swift ↔ GTK4/libadwaita interop** | ✅ `spike-gtk-smoke` and the `insanitty` app shell **compile, link, and run headless under Xvfb**: GTK init, `AdwStyleManager`, a real `GtkPaned` widget tree, an `AdwApplicationWindow` with sidebar + split. (This validates report `10`'s recommended "Swift + direct C interop" approach.) |
| **SwiftPM + pkg-config** | ✅ builds; SwiftPM strips the stray `-mfpmath=sse`/`-pthread` cflags (warnings only). |
| **App shell skeleton** | ✅ `INSANITTY_SMOKE=1 xvfb-run -a .build/debug/insanitty` opens the window (sidebar of generated workspace names + split placeholders) and self-quits, exit 0. |

## Phase-0 spike status

| Spike | State |
|---|---|
| **D — SplitTree on GtkPaned** | Substrate proven (GtkPaned tree builds/runs); `SplitGeometry` oracle constants ported + tested. Remaining: rebind the full `SplitTree` leaf type. |
| **A — embed Ghostty GTK surface** | **Blocked on this box:** the Ghostty *GTK frontend* build needs `blueprint-compiler` + `msgfmt` (gettext tools), which are not installed (and likely need apt). The C bridge (`Sources/CInsanitty`) and shim API are in place with a placeholder backend, so the shell runs today. |
| **B — re-home inject_output/remote_grid patch** | Pending the GTK Ghostty build (A). The patch (`patches/ghostty-inject-output.patch`) is verified to apply at the pinned commit; bodies are renderer-agnostic. |
| **C — msquic ↔ Go helper** | Pending: `msquic` not installed, and needs a LAN host running the helper. Bootstrap-line parser already ported + tested. |

## Not yet installed here (needed for later phases)

`msquic` (remote engine), `webkitgtk-6.0` (browser tabs), `libsecret-1` (Linear token),
`libnotify` (desktop notifications), `blueprint-compiler` + `gettext` bin (Ghostty GTK build).
See `scripts/setup-dev-env.sh`.

## Environment limitations (not blockers, but shape what can be *run* here)

- **Headless** (no display/GPU): GTK runs under Xvfb with software GL (EGL/DRI3 warnings are
  benign). **GtkGLArea** terminal rendering (the actual Ghostty surface) needs working GL —
  untested here; a dev box with a display or a Mesa/llvmpipe GL setup is needed to *see* a
  terminal. Compilation/linking is unaffected.
- The forked Ghostty isn't vendored as a submodule yet; `scripts/build-ghostty.sh` documents
  the build. The research used a clone at commit `5d0a82ba` (Zig 0.15.2).
