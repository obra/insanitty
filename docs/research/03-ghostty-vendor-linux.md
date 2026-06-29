# 03 — Vendored Ghostty: Linux/GTK frontend & libghostty C API reuse

> Assignment: how much of Ghostty's existing Linux/GTK frontend and libghostty C
> API can the Linux port reuse as its foundation? Should the port (a) embed
> libghostty behind our own GTK UI, (b) fork/extend Ghostty's GTK app, or (c)
> something else?

---

## 0. CRITICAL CAVEAT — the vendored submodule is NOT checked out

`inspo/fantastty/vendor/ghostty` is an **empty, uninitialized git submodule**. I did
**not** clone or fetch it (per instructions).

- `git submodule status` → `-5d0a82ba337368f5632ffa6ce4d7c558fa2de9ff vendor/ghostty`
  (leading `-` = uninitialized; directory has **0 files**).
- `.gitmodules`: path `vendor/ghostty`, url `https://github.com/ghostty-org/ghostty.git`.
- Pinned commit (gitlink in `git ls-tree HEAD`): **`5d0a82ba337368f5632ffa6ce4d7c558fa2de9ff`**.
- No Ghostty source, no `ghostty.h`, no built `GhosttyKit.xcframework`, and no `.zig`
  files exist anywhere in the repo outside the empty submodule (verified by `find`).

**Consequence:** I could not read `build.zig`, `build.zig.zon`, `src/apprt/gtk/`,
`src/renderer/`, or `include/ghostty.h` directly. Everything in this report is
reconstructed from artifacts that *are* present:

- `patches/ghostty-inject-output.patch` (diffs `include/ghostty.h` + `src/apprt/embedded.zig`)
- The Swift bridge in `Fantastty/GhosttyBridge/` (consumes the full `ghostty_*` C API)
- `Makefile`, `.github/workflows/build-and-release.yml`, `project.yml`

Claims that come from **general/public knowledge of Ghostty** (and are therefore
**unverified against commit `5d0a82ba`**) are explicitly tagged **[PUBLIC-UNVERIFIED]**.
These must be confirmed once the submodule is checked out. The pinned checkout is a
**2025-era post-1.0 Ghostty** (inference: Zig **0.15.2** required per CI, and the C
API includes iOS surfaces, key-tables, search, scrollbar, and progress-report actions).

---

## 1. Scope

**Files read in full or substantially (all under `inspo/fantastty/`):**

| File | Lines | What it gave us |
|---|---|---|
| `patches/ghostty-inject-output.patch` | 563 | Confirms `include/ghostty.h` + `src/apprt/embedded.zig`+`CAPI`; shows the two Fantastty-added C APIs and the Ghostty internals they touch |
| `Makefile` | 23 | The exact `zig build` invocation for the xcframework |
| `.github/workflows/build-and-release.yml` | ~50 read | **Zig 0.15.2**, Xcode 26.2, `make xcframework`, cache keys |
| `project.yml` | full | How GhosttyKit links into Xcode (static, `-lstdc++`, Carbon) |
| `Fantastty/GhosttyBridge/Ghostty.App.swift` | ~60-170, 490-619 read (of 89 KB) | `ghostty_runtime_config_s` wiring; the ~50-case action dispatch |
| `Fantastty/GhosttyBridge/Ghostty.Surface.swift` | 304 | Surface input/text/mouse API + the patched remote-grid API |
| `Fantastty/GhosttyBridge/Ghostty.Action.swift` | 174 | Action payload structs (color, url, progress, scrollbar, key-table…) |
| `Fantastty/GhosttyBridge/Ghostty.Package.swift` | 1-90 | `ghostty_info`, build mode, `ghostty_string_s` |
| `Fantastty/GhosttyBridge/SurfaceView.swift` | 700-760 | **Surface platform config: `nsview` handle + `scale_factor`** |
| `Fantastty/GhosttyBridge/SurfaceView_AppKit.swift` | 630-710 read (of 120 KB) | `ghostty_surface_new`, `set_size`, `set_content_scale` |
| `Fantastty/GhosttyBridge/Ghostty.Config.swift` | grep (of 32 KB) | The `ghostty_config_*` load/get API |
| `Fantastty/Models/ShellIntegration.swift` | grep (138) | Fantastty's own zsh OSC7 pwd integration |
| `Fantastty/Resources/shell-integration/fantastty.sh` | 40 | Fantastty's own `fantastty-note` (OSC 9) script |
| `Fantastty/GhosttyBridge/KeyboardLayout.swift`, `SecureInput.swift` | full / grep | Carbon (TIS, SecureEventInput) deps |

**Also:** grepped the entire `Fantastty/` tree for every distinct `ghostty_*` symbol
(≈190 unique identifiers) to reconstruct the public C API surface.

**NOT covered (cannot, submodule empty):** `build.zig` / `build.zig.zon` internals,
`src/apprt/gtk/**`, `src/renderer/**`, `src/config/**`, `src/shell-integration/**`,
`src/terminal/**`, and the actual contents of `include/ghostty.h` beyond the ~130
lines shown in the patch. The macOS chrome (SwiftUI views, tmux/remote subsystems) is
out of scope for *this* report (covered by sibling reports).

---

## 2. What it does (behavior & features of the reusable substrate)

Two distinct, separately-shippable things live in the Ghostty tree. **They do not
share a frontend.**

### 2a. libghostty (the embeddable terminal engine) — what the macOS app reuses

libghostty is the terminal **engine** exposed as a C library: VT/escape parsing,
grid/screen model, scrollback, font discovery + shaping + glyph atlas, the GPU
renderer, terminal IO (PTY/exec), keybinding evaluation, and the config parser. An
embedder gets a **`surface`** (one terminal view) and feeds it input + lifecycle; the
engine owns a background **render thread** and **IO thread** and draws into a native
layer the embedder hands it. The embedder must implement a set of **callbacks**
(clipboard, wakeup) and a big **action handler** (the engine *requests* the host to
open tabs, set titles, show notifications, go fullscreen, etc.). This is exactly the
macOS embedding model and is the template for a "mirror on Linux" approach.

User-facing contract the engine provides to an embedder (verified from C API usage):
- A live terminal surface that renders itself, with selection, clipboard, IME/preedit,
  mouse reporting, scrollback, search, and the inspector (debug overlay).
- Full key handling incl. keybinding matching (`ghostty_surface_key_is_binding`,
  `ghostty_surface_binding_action`) and Ghostty's keybind grammar.
- Config parsing from Ghostty's own config files + CLI args, with typed getters and
  diagnostics, theme/color handling, and live reload.
- Splits as a first-class engine concept (`ghostty_surface_split*`) — though the host
  still owns the actual view geometry.

### 2b. The GTK app (`src/apprt/gtk`) — Ghostty's native Linux terminal **[PUBLIC-UNVERIFIED]**

Ghostty's *native* Linux build is a complete GTK4 + libadwaita terminal: windows,
tabs, splits, command palette, config, native clipboard, IME, notifications, an
OpenGL renderer, and bundled shell integration — all implemented **in Zig** inside
Ghostty, compiled directly into the `ghostty` binary. It does **not** go through the C
API; it *is* an `apprt` (application runtime) sibling of the embedded one. Reusing it
means **forking the Ghostty GTK app**, not linking a library. (Architecture asserted
from public knowledge of Ghostty; not verifiable against this empty checkout.)

---

## 3. How it's built (architecture)

### 3.1 The apprt abstraction (verified the embedded one exists; gtk inferred)

Ghostty abstracts its frontend behind an **apprt**. The patch operates directly on
**`src/apprt/embedded.zig`**, which contains a `pub const CAPI = struct { … }` that
`export fn ghostty_*`s the entire C API (patch lines 65-90, 447-558). So:

- **`embedded` apprt** = the libghostty C API surface. Targets **macOS + iOS** (see
  platform union below). **VERIFIED.**
- **`gtk` apprt** = native Linux frontend. **[PUBLIC-UNVERIFIED]**
- **`none`/headless** apprt for CLI/tests. **[PUBLIC-UNVERIFIED]**
- Build-time selection via a `-Dapp-runtime=` option. **[PUBLIC-UNVERIFIED]**

### 3.2 The embedding lifecycle (fully reconstructed from the Swift bridge)

```
ghostty_init(argc, argv)                         // process-global init; main.swift:5
  → ghostty_config_new() / _load_default_files /  // Ghostty.Config.swift:56-91
     _load_file / _load_cli_args / _load_recursive_files / _finalize
  → ghostty_app_new(&runtime_cfg, config)         // Ghostty.App.swift:95
  → ghostty_surface_new(app, &surface_cfg)        // SurfaceView_AppKit.swift:684
  ... per frame the ENGINE renders on its own thread (no draw call) ...
  ghostty_app_tick(app)   on wakeup, main thread  // Ghostty.App.swift:144
  ghostty_surface_free / ghostty_app_free         // teardown, main thread
```

**`ghostty_runtime_config_s`** (the host→engine callback table; Ghostty.App.swift:82-92):
`userdata`, `supports_selection_clipboard`, `wakeup_cb`, **`action_cb`**,
`read_clipboard_cb`, `confirm_read_clipboard_cb`, `write_clipboard_cb`,
`close_surface_cb`. This is the **entire** interface a *new* embedder (our Linux app)
would have to implement — it is small.

**`ghostty_surface_config_s`** (host→engine surface attach; SurfaceView.swift:724-758)
carries: `userdata`, **`platform_tag`** + **`platform`** union, **`scale_factor`**,
`font_size`, `working_directory`, `command`, `env_vars[]`, `wait_after_command`,
`context`. The platform union is the crux:

```swift
config.platform_tag = GHOSTTY_PLATFORM_MACOS
config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
    nsview: Unmanaged.passUnretained(view).toOpaque()))   // SurfaceView.swift:728-731
```

The host passes a **native view pointer** (`nsview` / `uiview`) and the engine's render
thread creates a `CAMetalLayer` on it and draws. **There is no `ghostty_surface_draw`
anywhere** (verified by grep) — the engine owns the render loop. Resize/DPI is pushed
in via `ghostty_surface_set_size` and `ghostty_surface_set_content_scale`
(SurfaceView_AppKit.swift:838, 1208).

### 3.3 The action dispatch (engine→host requests; Ghostty.App.swift:497-660+)

A single `action_cb(app, target, action)` multiplexes ~50 actions the host must honor.
Each carries a typed payload struct/enum (`ghostty_action_*_s`/`_e`). The host decides
how to realize them in its UI. Catalogued from the dispatch + symbol grep:

- **Window/tab/split lifecycle:** `QUIT`, `NEW_WINDOW`, `NEW_TAB`, `NEW_SPLIT`,
  `CLOSE_TAB`, `CLOSE_WINDOW`, `GOTO_TAB`, `MOVE_TAB`, `GOTO_SPLIT`, `GOTO_WINDOW`,
  `RESIZE_SPLIT`, `EQUALIZE_SPLITS`, `TOGGLE_SPLIT_ZOOM`.
- **Window state:** `TOGGLE_FULLSCREEN`, `FLOAT_WINDOW`, `TOGGLE_MAXIMIZE`,
  `TOGGLE_QUICK_TERMINAL`, `TOGGLE_VISIBILITY`, `TOGGLE_BACKGROUND_OPACITY`,
  `INITIAL_SIZE`, `RESET_WINDOW_SIZE`, `CELL_SIZE`.
- **Terminal/UX:** `SET_TITLE`, `PROMPT_TITLE`, `PWD`, `DESKTOP_NOTIFICATION`,
  `RING_BELL`, `MOUSE_SHAPE`, `MOUSE_VISIBILITY`, `MOUSE_OVER_LINK`, `OPEN_URL`,
  `PROGRESS_REPORT`, `COLOR_CHANGE`, `CONFIG_CHANGE`, `SECURE_INPUT`, `SCROLLBAR`,
  `START_SEARCH`/search totals, `KEY_TABLE` (modal keybinds), `TOGGLE_COMMAND_PALETTE`,
  `OPEN_CONFIG`, `RENDERER_HEALTH`, `INSPECTOR`/`RENDER_INSPECTOR`.

This catalogue **is** the work-list for any from-scratch GTK frontend that embeds
libghostty: ~50 actions to wire into native GTK behaviors.

### 3.4 Inspector is Metal-only (verified)

The debug inspector renders via `ghostty_inspector_metal_init` /
`ghostty_inspector_metal_render` — **the only render entry points in the C API are
Metal** (verified: no `_gl_`/`_opengl_`/`_egl_` symbols exist). This is concrete
evidence that the **embedded apprt's renderer wiring is currently Apple/Metal-only**.

### 3.5 Concurrency model

Engine runs background render + IO threads. The host drives `ghostty_app_tick()` on its
**main/UI thread** in response to `wakeup_cb` (which may fire from any thread). Action
callbacks and `ghostty_surface_free` arrive **synchronously on the main thread** — the
bridge explicitly forces teardown onto the main thread to avoid a use-after-free
(Ghostty.Surface.swift:27-40). A Linux port must replicate this: a GLib main-loop
source posting wakeups, all engine calls marshaled to the GTK main thread.

### 3.6 Fantastty's two patched C APIs (`patches/ghostty-inject-output.patch`)

Fantastty does **not** fork Ghostty; it surgically adds two C entry points to
`embedded.zig` (+ decls in `ghostty.h`), applied at build time and reverted after
(`Makefile:6,10`):

1. **`ghostty_surface_inject_output(surface, ptr, len)`** — pushes bytes straight into
   `surface.core_surface.io.processOutput()`, **bypassing the PTY**. Used to feed
   tmux-control-mode output into the emulator (patch:84-90).
2. **`ghostty_surface_remote_grid_*`** — a direct cell/row/cursor writer into the live
   terminal grid (`reset`, `set_row`, `set_row_cells`, `set_cursor[_ex]`), taking
   `ghostty_remote_grid_cell_s` (text+width+style). It locks `renderer_state.mutex`,
   mutates `terminal.Terminal`/`Screen`/`Page` directly, and wakes the render thread
   (patch:447-558). Used by the QUIC remote engine to paint server-sent grid frames
   without round-tripping through VT parsing.

**Why this matters for Linux:** these patches reach deep into Ghostty internals
(`terminal.*`, `Screen`, `Page.styles`, `renderer_state`, `renderer_thread.wakeup`).
They are **renderer-agnostic** (they touch the grid model, not Metal), so they should
port to a Linux/GL build of libghostty unchanged — **but only if libghostty itself can
be built and rendered on Linux** (see §7). The port inherits a hard dependency on
keeping these patches rebased against upstream Ghostty.

### 3.7 Build system (verified from Makefile + CI)

The macOS artifact is built by `make xcframework` (`Makefile:5-10`):

```
zig build -Doptimize=ReleaseFast \
          -Demit-xcframework=true \
          -Demit-macos-app=false \
          -Dxcframework-target=native
# → vendor/ghostty/macos/GhosttyKit.xcframework  (a STATIC lib; project.yml embed:false)
```

- **Zig version: `0.15.2`** — pinned in CI (`build-and-release.yml:34`) with the
  comment "*Must match minimum_zig_version in vendor/ghostty/build.zig.zon*". The exact
  `build.zig.zon` value is unreadable (submodule empty) but **0.15.2** is the value the
  project builds with.
- The xcframework links `-lstdc++` and `Carbon.framework` (project.yml), confirming
  libghostty pulls in C/C++ deps (consistent with Ghostty's vendored libs).
- **Build flags for (b) GTK Linux app and (c) a Linux libghostty `.so` are NOT
  observable here** — `-Demit-macos-app`/`-Demit-xcframework`/`-Dxcframework-target`
  are macOS-oriented. The GTK app and a shared-lib target exist in Ghostty's `build.zig`
  **[PUBLIC-UNVERIFIED]**; their exact flags must be read from the checked-out source.
  Notably, `-Demit-xcframework`/`xcframework-target=native` is the macOS packaging step;
  a Linux embed would instead want libghostty emitted as a `.so`/`.a` + `ghostty.h`,
  which **[PUBLIC-UNVERIFIED]** the build system supports but is unconfirmed here.

---

## 4. Platform dependencies (macOS-specific) in the embedding glue

The reusable engine is cross-platform, but the **macOS glue around it** is Apple-bound.
The Linux port rewrites all of this:

- **Renderer attach:** `CAMetalLayer` on an `NSView`, passed as `nsview` in
  `ghostty_platform_macos_s` (SurfaceView.swift:729-732). The engine's render thread is
  **Metal** for the embedded path (inspector is Metal-only — §3.4).
- **Surface host:** `NSView` subclass (`SurfaceView_AppKit.swift`, 120 KB) — tracking
  areas, `NSEvent` key/mouse encoding, drag-and-drop, `backingScaleFactor`.
- **Keyboard layout:** `Carbon`/HIToolbox — `TISCopyCurrentKeyboardInputSource`,
  `TISGetInputSourceProperty` (KeyboardLayout.swift); fed to
  `ghostty_app_keyboard_changed`.
- **Secure input:** Carbon `EnableSecureEventInput`/`DisableSecureEventInput`
  (SecureInput.swift) — services the `SECURE_INPUT` action.
- **Clipboard:** `NSPasteboard` (NSPasteboard+Extension.swift) services the clipboard
  callbacks; `supports_selection_clipboard:true` is set but macOS has no PRIMARY
  selection, so it's effectively a stub there.
- **Notifications:** `UNUserNotification` for `DESKTOP_NOTIFICATION`.
- **App model:** `NSApplication` focus/active notifications → `ghostty_app_set_focus`;
  `main.swift` calls `ghostty_init` with `CommandLine` argv.
- **Launch source / app bundle:** `GHOSTTY_MAC_LAUNCH_SOURCE` env, `.app` bundle layout.

---

## 5. Linux mapping (for the embedding glue)

| macOS dependency | Linux-native equivalent |
|---|---|
| `CAMetalLayer` on `NSView`, Metal render thread | **GTK4 `GtkGLArea`** (or a raw Wayland/EGL surface) + Ghostty's **OpenGL** renderer backend **[PUBLIC-UNVERIFIED that embedded path can target GL]** — see §7 RISK |
| `NSView` surface host | `GtkWidget` subclass / `GtkGLArea`; events from GTK `EventControllerKey`/`-Motion`/`-Scroll` |
| Carbon TIS keyboard layout | **XKB** (`xkbcommon`); GTK `Gdk.Keymap`/`GdkDevice`; feed `ghostty_app_keyboard_changed` |
| Carbon `EnableSecureEventInput` | **No clean equivalent** — but this is a macroOS anti-keylogger feature; on Linux treat `SECURE_INPUT` action as a no-op (LOW risk, not a real gap). |
| `NSPasteboard` | **GTK `Gdk.Clipboard`** (CLIPBOARD) **and `Gdk.Display.primary_clipboard`** (PRIMARY) — Linux *does* have a selection clipboard, so `supports_selection_clipboard` becomes meaningful |
| `UNUserNotification` | **libnotify / `org.freedesktop.Notifications` (D-Bus)**, via `GNotification` |
| `NSApplication` focus | GTK `GtkApplication`/`GtkWindow` focus signals → `ghostty_app_set_focus` |
| `ghostty_app_tick` on main thread driven by `wakeup_cb` | **GLib main loop** source; `g_idle_add`/custom `GSource` posting from `wakeup_cb` |
| `.app` bundle / launch-source env | XDG dirs, `.desktop` file, standard argv |
| Config dir `~/.fantastty/...`, `~/Library`-style paths | `$XDG_CONFIG_HOME` / `$XDG_DATA_HOME` |

Most of these are routine and already solved inside Ghostty's own GTK apprt — which is
the strongest argument for reusing that code (§6).

---

## 6. Reuse assessment & the strategic recommendation

There are three viable foundations. The macOS app is a proof-of-existence for the
**embed** pattern, but the macOS app got Metal "for free"; the Linux port does not get
GL "for free" through the *embedded* C API today.

### Path (a) — Embed libghostty behind our own GTK UI (mirror the macOS app)

**Reuses:** libghostty engine (VT, grid, fonts/shaping, renderer, config, keybinds);
the *exact* embedding model the macOS app already drives; both Fantastty patches port
unchanged (renderer-agnostic). Our UI/sidebar/tmux/remote/Linear/notes logic is
frontend-agnostic and sits above the C API just as it does on macOS.

**Costs / blockers:**
- **THE blocker:** the embedded apprt's renderer + platform union are **macOS/iOS +
  Metal only** (verified: `ghostty_platform_macos_s`/`_ios_s`, Metal-only inspector, no
  GL symbols). To embed on Linux you must **extend `embedded.zig` + the renderer** to
  accept a Linux surface handle (Wayland/EGL or a `GtkGLArea`) and drive the **OpenGL**
  renderer. Ghostty *has* a GL renderer (used by the GTK app), so the GPU code exists —
  but wiring it to the *embedded* surface path is **net-new Zig work inside Ghostty**,
  of unknown size, and is the central unknown of this whole port.
- You re-implement ~50 action handlers + clipboard/notify/keymap glue in GTK (routine,
  but it's the same work Ghostty's GTK apprt already did).
- Ongoing rebase burden for the two patches + any GL-embed patch against upstream.

**Verdict:** cleanest *architecture* (our app stays a thin shell over a stable C API,
identical to macOS), but its viability hinges entirely on the GL-embed question in §7.

### Path (b) — Fork/extend Ghostty's GTK app

**Reuses:** EVERYTHING Linux-native for free — GTK4/libadwaita windows, tabs, splits,
clipboard (incl. PRIMARY), IME, notifications, OpenGL renderer, shell integration,
config UI. Zero renderer risk.

**Costs:** Fantastty's value (workspaces, tmux control-mode, QUIC remote engine, notes,
Linear, browser tabs, sprites — ~32 K lines of Swift) would have to be re-expressed
**in Zig inside Ghostty's widget tree**, or bolted on via IPC. You inherit Ghostty's
release cadence and a permanent heavy fork. The macOS app deliberately did **not** do
this (it set `-Demit-macos-app=false` and built its own chrome) — strong signal that a
full UI fork is the wrong shape for a feature-rich product like Fantastty.

**Verdict:** lowest *terminal* risk, highest *product* cost and worst long-term
maintainability. Not recommended as the primary path.

### Path (c) — Hybrid: reuse Ghostty's GTK **surface widget**, own the chrome **[RECOMMENDED to evaluate first]**

The macOS app embeds a single self-rendering terminal **view** (`SurfaceView`) and owns
all chrome around it. The GTK analog: extract/reuse **just Ghostty's GTK terminal
surface widget** (the `GtkGLArea`-backed view that the gtk apprt already renders into
with OpenGL) as an embeddable `GtkWidget`, and build Fantastty's window/sidebar/tabs/
splits/notes/remote UI as our own GTK4 app around it. This gets the **GL renderer for
free** (sidestepping the §7 blocker) while keeping our chrome and feature logic ours.

**Reuses:** Ghostty's GL renderer + GTK surface + IME/clipboard/keymap glue (already
Linux-native), plus the engine. **Cost/unknown:** whether the gtk apprt's surface can
be instantiated standalone and embedded in a foreign widget tree, and how its
window/tab/split actions are wired (they may assume Ghostty's own window manager). This
is the key thing to test against the checked-out source.

### Bottom line

- **First action: check out commit `5d0a82ba` and answer the two §7 questions.** They
  decide everything.
- If Ghostty's **GTK surface widget is reusably embeddable** → **path (c)**: best
  blend of free-GL + native-Linux glue + our own feature-rich chrome.
- Else if the **embedded apprt can be taught a GL/Linux surface** at acceptable cost →
  **path (a)**: cleanest architecture, identical to macOS, both patches port as-is.
- **Avoid path (b)** as the primary plan; only its renderer/glue code is worth
  harvesting (which (c) does anyway).
- Independent of path: the **action catalogue (§3.3)**, the **runtime/surface config
  shapes (§3.2)**, and the **two patches (§3.6)** are the concrete, already-known
  reusable interface contracts the Linux frontend will code against.

---

## 7. Open questions / risks

1. **[BLOCKER] Can libghostty's *embedded* surface render on Linux via OpenGL/EGL?**
   The embedded C API is Metal/macOS/iOS-only today (verified). Does `embedded.zig` (or
   a build flag) already support a Linux/GL surface, or is that unbuilt? This single
   question gates path (a). *Resolve by reading `src/apprt/embedded.zig`,
   `src/renderer/`, and the platform union in `include/ghostty.h` once checked out.*

2. **[BLOCKER] Is Ghostty's GTK terminal *surface widget* standalone-embeddable?**
   Path (c) depends on instantiating just the `GtkGLArea` terminal view inside our own
   widget tree without dragging in Ghostty's whole window/tab manager. *Resolve by
   reading `src/apprt/gtk/`.*

3. **Does Ghostty's `build.zig` emit a Linux libghostty `.so`/`.a` + `ghostty.h`?**
   The observable flags are macOS xcframework packaging only. The shared-lib/GTK-app
   targets and their flags are [PUBLIC-UNVERIFIED]. *Read `build.zig`.*

4. **Patch rebase durability.** Both Fantastty C-API patches mutate deep Ghostty
   internals (`terminal.Terminal`, `Screen`, `Page.styles`, `renderer_state`). They are
   pinned to commit `5d0a82ba`. Upstreaming `ghostty_surface_inject_output` /
   `remote_grid_*` (or vendoring a Ghostty fork) should be decided early to bound the
   maintenance tax — the Linux port needs the **same** two patches.

5. **Zig toolchain.** Confirmed requirement is **Zig 0.15.2**; the build needs a Zig
   toolchain in CI/dev (not just GTK/Cairo). Cross-arch (`linux-amd64`/`arm64`) builds
   of libghostty + GL renderer are [PUBLIC-UNVERIFIED] but expected to work.

6. **Shell integration overlap (minor).** Ghostty ships its own bash/zsh/fish/elvish
   shell integration [PUBLIC-UNVERIFIED]. Fantastty layers its **own** thin scripts on
   top: `fantastty.sh` adds `fantastty-note`/`fn` via OSC 9 (`Resources/shell-integration/
   fantastty.sh`), and `ShellIntegration.swift` installs a **ZDOTDIR proxy** that chains
   the user's zsh dotfiles then sources an OSC7 pwd reporter (`Models/ShellIntegration.swift`).
   These are cross-platform shell scripts and port to Linux **as-is**; they do *not*
   conflict with Ghostty's integration (different OSCs), but on Linux we should decide
   whether to also adopt Ghostty's bundled integration or keep only Fantastty's. Low risk.

7. **iOS surfaces in the C API** (`ghostty_platform_ios_s`) confirm the embedded apprt
   is multi-platform-aware in principle — mild positive signal that adding a Linux
   platform tag is *conceivable*, but says nothing about the GL renderer wiring (#1).
