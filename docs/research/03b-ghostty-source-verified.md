# Ghostty source verification for a native Linux port

**Source:** Ghostty pinned at commit `5d0a82ba337368f5632ffa6ce4d7c558fa2de9ff`
(checked out under `scratchpad/ghostty-src`).
All `file:line` citations below are against that commit. Paths are repo-relative
to the Ghostty source tree unless noted.

**Bottom line up front:**

- The **embedded C API (`libghostty` / `embedded.zig` / `ghostty.h`) is Metal-only
  on real rendering.** It accepts only macOS `nsview` / iOS `uiview` platform
  handles, and the OpenGL renderer's embedded path is an explicit stub the author
  labels "strictly broken for rendering." There is **no GL/EGL/Wayland/X11 embedded
  backend today.**
- Ghostty's **GTK surface widget *does* render with OpenGL** (GtkGLArea + the
  `OpenGL.zig` renderer) and is reasonably self-contained, but it is **coupled to
  Ghostty's GTK `Application` singleton** (allocator, core app, config, window-protocol
  helper) and is built in Zig/GObject, not exposed over the C ABI.
- `zig build` **can** emit a Linux shared library of the embedded core
  (`ghostty-internal.so` + `ghostty.h`), but that is the *same* Metal-only embedded
  apprt — it links but cannot render on Linux. A separate `libghostty-vt.so` exists
  but is terminal-parser-only (no renderer, no surface).
- **Recommendation: path (c) — the hybrid.** Reuse Ghostty's GTK `Surface` widget +
  GL renderer (already implemented and shipping) and own the window/tab/sidebar/split
  chrome. This avoids writing a brand-new embedded GL backend in Ghostty (which is
  what path (a) would require).

---

## Q1 — Embedded apprt renderer backends

### Renderer is chosen at **build time**, one per binary

`src/renderer.zig:36-42`:

```zig
/// The implementation to use for the renderer. This is comptime chosen
/// so that every build has exactly one renderer implementation.
pub const Renderer = switch (build_config.renderer) {
    .metal => GenericRenderer(Metal),
    .opengl => GenericRenderer(OpenGL),
    .webgl => WebGL,
};
```

There is **no runtime selection** between Metal and OpenGL — it is a comptime switch
on `build_config.renderer`.

`src/renderer/backend.zig:5-23` enumerates the backends and the default:

```zig
pub const Backend = enum { opengl, metal, webgl,
    pub fn default(target, wasm_target) Backend {
        if (target.cpu.arch == .wasm32) return .webgl; // browser
        if (target.os.tag.isDarwin()) return .metal;
        return .opengl;
    }
};
```

The renderer backend is a real `-D` build option: `src/build/Config.zig:161-165`
(`-Drenderer=<opengl|metal|webgl>`), defaulting via `Backend.default` above
(`src/build/Config.zig:27` default `.opengl`). It is plumbed to comptime via
`src/build_config.zig:43` (`pub const renderer = config.renderer`).

`src/renderer.zig:1-8` states the contract: renderers "assume that the renderer is
already setup (OpenGL has a context, Vulkan has a surface, etc.)" — i.e. the apprt,
not the renderer, owns context creation.

### The embedded `Platform` is macOS/iOS only — no GL/Wayland/X11 option

`src/apprt/embedded.zig:344-400`:

```zig
pub const Platform = union(PlatformTag) {
    macos: MacOS,
    ios: IOS,
    // If our build target for libghostty is not darwin then we do
    // not include macos support at all.
    pub const MacOS = if (builtin.target.os.tag.isDarwin()) struct {
        nsview: objc.Object,
    } else void;
    pub const IOS = if (builtin.target.os.tag.isDarwin()) struct {
        uiview: objc.Object,
    } else void;

    pub const C = extern union {           // the C ABI form
        macos: extern struct { nsview: ?*anyopaque },
        ios:   extern struct { uiview: ?*anyopaque },
    };
    ...
};
pub const PlatformTag = enum(c_int) { macos = 1, ios = 2 };
```

`ghostty_surface_config_s` (`Surface.Options`, `src/apprt/embedded.zig:425-465`)
carries only `platform_tag: c_int` + `platform: Platform.C` (the nsview/uiview union),
plus userdata/scale/font/working-dir/command/env. **There is no GL context handle, no
EGLDisplay/EGLSurface, no Wayland `wl_surface`, no X11 `Window`/`Drawable` field.**

Critically, on a non-Darwin target both arms collapse to `void`, and
`Platform.init` (`src/apprt/embedded.zig:373-391`) returns `error.UnsupportedPlatform`
for both `.macos` and `.ios`:

```zig
.macos => if (MacOS != void) ... else error.UnsupportedPlatform,
.ios   => if (IOS   != void) ... else error.UnsupportedPlatform,
```

So on Linux you cannot even *construct* an embedded `Surface` — there is no platform
variant that resolves to a non-void type. The C header mirrors this: `ghostty.h` only
defines `ghostty_platform_macos_s {nsview}` / `ghostty_platform_ios_s {uiview}` and tags
`GHOSTTY_PLATFORM_MACOS=1` / `GHOSTTY_PLATFORM_IOS=2`.

### Metal renderer is hardwired to the embedded nsview/uiview

`src/renderer/Metal.zig:64-106` — `Metal.init` reads the surface platform and only
understands embedded macOS/iOS, `@compileError` for anything else:

```zig
const info: ViewInfo = switch (apprt.runtime) {
    apprt.embedded => .{
        .scaleFactor = @floatCast(opts.rt_surface.content_scale.x),
        .view = switch (opts.rt_surface.platform) {
            .macos => |v| v.nsview,
            .ios   => |v| v.uiview,
        },
    },
    else => @compileError("unsupported apprt for metal"),
};
```

Metal then attaches its own `IOSurfaceLayer` to that NSView (`Metal.zig:108-119`).
So **libghostty's macOS rendering path is: host passes NSView → Metal creates the layer
→ Metal draws.** There is no equivalent path for a GL drawable.

### The OpenGL renderer's embedded path is an explicit, labeled stub

`src/renderer/OpenGL.zig:51-56` — `OpenGL.init` takes no surface/handle at all (it only
reads `opts.config.blending`); it assumes a context is already current.

The apprt-specific hooks are where it breaks for embedded:

`src/renderer/OpenGL.zig:162-187` (`surfaceInit`):

```zig
switch (apprt.runtime) {
    else => @compileError("unsupported app runtime for OpenGL"),
    apprt.gtk => try prepareContext(null),   // GTK: load glad from the current/global ctx
    apprt.embedded => {
        // TODO(mitchellh): this does nothing today to allow libghostty
        // to compile for OpenGL targets but libghostty is strictly
        // broken for rendering on this platforms.
    },
}
```

`src/renderer/OpenGL.zig:197-216` (`threadEnter`) repeats the same embedded stub with the
same "strictly broken for rendering on this platforms" comment.
`src/renderer/OpenGL.zig:237-249` (`displayRealized`) is GTK-only and `@compileError`s for
any other apprt.

**Conclusion (Q1):** The embedded C API is **Metal-only for actual rendering**. You can
*compile* libghostty with `-Drenderer=opengl`, but the embedded GL backend does nothing
(by the author's own admission), and the embedded surface config has no way to receive a
GL context, Wayland surface, or X11 window. OpenGL is wired and working **only** for the
GTK apprt, where `GtkGLArea` provides and makes-current the context.

---

## Q2 — GTK surface-widget embeddability

> The big GTK files were catalogued by a sub-investigation; the load-bearing coupling
> claims below were re-verified directly against the source.

### What the surface widget is

`src/apprt/gtk/class/surface.zig:42-56` — the terminal surface is a **GObject class
`GhosttySurface` that subclasses `adw.Bin`** and implements `gtk.Scrollable`:

```zig
pub const Surface = extern struct {
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const Implements = [_]type{gtk.Scrollable};
    pub const getGObjectType = gobject.ext.defineClass(Self, .{ .name = "GhosttySurface", ... });
```

(There is also a thin `src/apprt/gtk/Surface.zig` that is the `apprt.Surface` interface
type the core passes to the renderer; the actual widget/logic lives in
`class/surface.zig`, ~150 KB.)

### How it renders (OpenGL via GtkGLArea, draws on the main thread)

- It owns a **`GtkGLArea`**: `src/apprt/gtk/class/surface.zig:623` (`gl_area: *gtk.GLArea`),
  bound as a template child.
- The GL-area signals are wired to renderer lifecycle:
  - `glareaRender` → `surface.renderer.drawFrame(true)` —
    `src/apprt/gtk/class/surface.zig:3328-3344`.
  - `glareaResize` lazily creates the core surface on first realize+resize
    (`:3346`+), then drives `sizeCallback`.
  - realize/unrealize call `renderer.displayRealized()` / `displayUnrealized()`.
- Context management is GTK's: `gl_area.makeCurrent()` before init, and the renderer
  loads glad from the already-current context (`OpenGL.zig:241` `prepareContext(null)`).
  Note `OpenGL.zig:204-209`: GTK does the actual GL draws/texture syncs **on the main
  thread**, because "GTK doesn't support threaded OpenGL"; the renderer thread only sets
  up state.

So the surface widget is essentially a **thin GtkGLArea wrapper**; all GL code lives in
`renderer/OpenGL.zig`, reached through the generic `Renderer` interface.

### Input, IME, clipboard

- **Keyboard / xkb:** event controllers in `class/surface.zig` (key handling around
  `:1240-1463`) feeding the shared encoder in `src/apprt/gtk/key.zig` (xkb keysym/dead-key
  handling, ~16 KB).
- **IME:** `im_context: *gtk.IMMulticontext` (`class/surface.zig:658`); preedit/commit
  wired (e.g. `filterKeypress` at `:1303`, `setCursorLocation` at `:1262`, reset at
  `:1450`). `setClientWidget` is set on realize.
- **Clipboard:** read/write + OSC-52 in `class/surface.zig` (clipboard request/set paths),
  with a confirmation dialog in `class/clipboard_confirmation_dialog.zig`.

### Coupling: how tied is it to Ghostty's own Window/Tab/Split?

The widget has **no hard dependency on the GTK `Window`/`Tab`/`SplitTree` classes** — it
emits signals (`close-request`, `present-request`, `toggle-fullscreen`,
`toggle-maximize`, `bell`, `clipboard-read/write`, `menu`, `init`) that a host container
is expected to handle. The containment hierarchy is just GTK boxes:
`Window` = `adw.ApplicationWindow` (`class/window.zig:35`) ⊃ `Tab` = `gtk.Box`
(`class/tab.zig:22`) ⊃ `SplitTree` = `gtk.Box` (`class/split_tree.zig:23`) ⊃ scrolled
window ⊃ `Surface`. A host could supply its own chrome and parent the `Surface` directly.

**But** the widget is hard-coupled to the GTK **`Application` singleton**
(`Application.default()`, an `adw.Application` subclass in `class/application.zig`). Verified
call sites in `class/surface.zig`:

- `:757`, `:921`, `:958`, `:1923` `Application.default().allocator()` — its allocator.
- `:1387` `Application.default().winproto()` — window-protocol helper for key encoding.
- `:1929` `Application.default().core().deleteSurface(self.rt())` — global surface registry.
- `:1806` falls back to `Application.default().getConfig()` when no `Config` is set.

`class/application.zig` owns the shared services: core app (libghostty `App`), config,
`winproto` (X11/Wayland abstraction), global shortcuts (D-Bus), CSS providers, URI portal.
So a host embedding the `Surface` widget must **either instantiate Ghostty's GTK
`Application` (or a compatible GObject that answers `default()`), or refactor the widget to
inject allocator/core-app/config/winproto** instead of reaching for the singleton.

### Feature catalog already implemented by the GTK apprt (don't rebuild)

| Feature | Location |
|---|---|
| Window (adw.ApplicationWindow, headerbar/tabs/fullscreen) | `class/window.zig` (~72 KB) |
| Tabs | `class/tab.zig` |
| Splits / panes (tree, paned dividers, focus nav, resize) | `class/split_tree.zig` (~47 KB) |
| Config load/reload + CSS | `class/config.zig`, `class/config_errors_dialog.zig` |
| Clipboard + paste confirmation | `class/surface.zig`, `class/clipboard_confirmation_dialog.zig` |
| Close confirmation | `class/close_confirmation_dialog.zig` |
| Command palette | `class/command_palette.zig` (~25 KB) |
| Search overlay | `class/search_overlay.zig` |
| Resize / key-state overlays | `class/resize_overlay.zig`, `class/key_state_overlay.zig` |
| IME + xkb key encoding | `class/surface.zig`, `src/apprt/gtk/key.zig` |
| Window-protocol abstraction (X11 + Wayland: blur, SSD/CSD, fractional scale) | `src/apprt/gtk/winproto/`, `winproto.zig` |
| Single-instance / D-Bus IPC | `src/apprt/gtk/ipc/`, `ipc.zig` |
| Global shortcuts (D-Bus) | `class/global_shortcuts.zig` |
| Desktop notifications, URI portal | `class/surface.zig`, `src/apprt/gtk/portal/` |
| Inspector (Dear ImGui) | `class/inspector_window.zig`, `class/imgui_widget.zig` |
| cgroup / single-process-per-surface, flatpak, gsettings | `cgroup.zig`, `flatpak.zig`, `gsettings.zig` |

**Conclusion (Q2):** The GTK `Surface` is a render-complete, GL-backed terminal widget that
is *reusable* and not bolted to Ghostty's Window/Tab/Split, but it expects Ghostty's GTK
`Application` singleton to exist. Embedding it in your own chrome is feasible **inside a
Ghostty-Application-derived process** (or after a modest dependency-injection refactor of
the widget). It is Zig/GObject, not exposed via the C ABI.

---

## Q3 — Linux libghostty build artifact

### Two different "libghostty" things — keep them straight

1. **`libghostty-vt`** — terminal **VT parser/state machine only**. Root source
   `src/lib_vt.zig` imports `terminal/main.zig` and re-exports `osc`/`dcs`/`apc`/`page`/
   `color`/… — **no renderer, no apprt, no surface** (`src/lib_vt.zig:1-50`). Built with
   `-Demit-lib-vt`; emits `libghostty-vt.so` + `libghostty-vt.a` + headers under
   `include/ghostty/` + pkg-config (`build.zig:116-153`). `CMakeLists.txt` is a thin wrapper
   that just shells out to `zig build -Demit-lib-vt` (`CMakeLists.txt:1-7,69-70`). This is
   cross-platform and renderer-agnostic, but it is **not** an embeddable terminal *widget* —
   you'd write your own renderer/IO around it.

2. **`GhosttyLib` (the embedded full-GUI core)** — root source `src/main_c.zig` → exposes
   `embedded.zig`'s `ghostty.h` C API (the same API the macOS app and Fantastty use). On
   macOS this is wrapped into `GhosttyKit.xcframework`. **On non-Darwin it is installed as a
   plain shared lib + header.**

### Does `zig build` emit a Linux `libghostty.so` + `ghostty.h`?

Yes — but it is the **Metal-only embedded core** from Q1. `build.zig:176-204`:

```zig
if (config.app_runtime != .none) {            // GTK (default on Linux)
    if (config.emit_exe) { exe.install(); resources.install(); ... }   // -> `ghostty` binary
} else if (!config.emit_lib_vt) {             // app-runtime=none -> embedded libghostty
    const lib_shared = try buildpkg.GhosttyLib.initShared(b, &deps);
    const lib_static = try buildpkg.GhosttyLib.initStatic(b, &deps);
    if (!config.target.result.os.tag.isDarwin()) {
        lib_shared.installHeader();                 // installs include/ghostty.h
        ... else {
            lib_shared.install("ghostty-internal.so");
            lib_static.install("ghostty-internal.a");
        }
    }
}
```

`GhosttyLib.initShared` builds a dynamic library from `src/main_c.zig`
(`src/build/GhosttyLib.zig:71-89`), `installHeader` installs `include/ghostty.h`
(`:215-222`), and the Linux artifact is named `ghostty-internal.so` (`:268-273`) with a
pkg-config file. (The "internal" name + the comment at `build.zig:186-188` — *"This is NOT
libghostty … just the glue between Ghostty GUI on macOS and the full Ghostty GUI core"* —
signal it is not meant as a public Linux embedding API.)

So **(a) embeddable libghostty shared lib on Linux:**
`zig build -Dapp-runtime=none` (and not `-Demit-lib-vt`) →
`zig-out/lib/ghostty-internal.so` + `zig-out/include/ghostty.h`. It links, but per Q1 the
embedded apprt renders only with Metal; the OpenGL embedded path is the stub. So this `.so`
is **not usable for a real Linux terminal** without first implementing an embedded GL backend.

**(b) the GTK app:** the default on Linux. `src/apprt/runtime.zig:14-24` defaults
`app-runtime` to `.gtk` for linux/freebsd; `emit_exe` defaults to `!emit_lib_vt`
(`src/build/Config.zig:359-363`). So plain `zig build` (optionally
`-Dapp-runtime=gtk -Doptimize=ReleaseFast`) produces the standalone `ghostty` binary +
resources. `emit_xcframework` is forced false off-Darwin (`src/build/Config.zig:448`).

### Versions and key system dependencies

- **Zig:** `build.zig.zon:6` → `.minimum_zig_version = "0.15.2"`. `build.zig:13-17` enforces
  it via `requireZig`. (PACKAGING.md still uses a stale "0.14.0" *example*; the authoritative
  value is the `.zon`'s `0.15.2`.)
- **GTK4 + libadwaita:** the GTK build links `gtk4` and `libadwaita-1`
  (`src/build/SharedDeps.zig:647-648`), optional `X11` (`:651`, `-Dgtk-x11`) and Wayland
  (`:660`, `-Dgtk-wayland`; `src/build/Config.zig:208-217`). GObject bindings map
  `gtk→gtk4`, `adw→adw1`, `gdkx11→gdkx114` (`SharedDeps.zig:632-638`).
  - GTK version floor is feature-gated at runtime: `class/application.zig:935` /
    `:2882-2893` use `gtk_version.runtimeAtLeast(4,14,0)`, `(4,16,0)`, `(4,18,0)` — i.e.
    GTK **4.14** is the effective baseline with progressive enhancement above it.
  - libadwaita is gated `1.3`–`1.5` (`src/apprt/gtk/adw_version.zig:104-122`:
    `supportsBanner`=1.3, `supportsTabOverview/SwitchRow/ToolbarView`=1.4,
    `supportsDialogs`=1.5), so **libadwaita 1.4+** is the practical floor.
  - The flatpak CI/build targets `org.gnome.Platform` **runtime-version "50"**
    (`flatpak/com.mitchellh.ghostty.yml:2-3`) — a much newer GNOME than the minimum.
- **Other system deps** (Zig packages, can be system-integrated): freetype/freetype2,
  harfbuzz, fontconfig, oniguruma, glslang + spirv-cross (shader translation),
  zlib/libpng, plus the OpenGL loader (`pkg/opengl`, glad). See
  `src/build/SharedDeps.zig:183-339` and `build.zig.zon:65-101`.
- Reference build line (from `PACKAGING.md:80-87`):
  `zig build --prefix /usr --system <cache> -Doptimize=ReleaseFast -Dcpu=baseline`.

---

## Patch verification — `ghostty-inject-output.patch`

**Applies cleanly at this commit.** From a clean checkout at `5d0a82ba`:

```
$ git apply --check --verbose ghostty-inject-output.patch
Checking patch include/ghostty.h...
Checking patch src/apprt/embedded.zig...
Hunk #1 succeeded at 18 (offset 1 line).
Hunk #2 succeeded at 1824 (offset -1 lines).
exit=0
```

Both hunks verify (small offsets, no fuzz failures). Target context confirmed present:

- `include/ghostty.h:1129-1130` has `ghostty_surface_text` immediately followed by
  `ghostty_surface_preedit` — the patch inserts the new decls between them.
- `src/apprt/embedded.zig:1818-1824` is `ghostty_surface_text` (ending
  `surface.textCallback(ptr[0..len]);`), and `:1828` is `ghostty_surface_preedit` — the
  patch inserts the new `export fn`s into the `CAPI` struct between them.

**The patched functions operate on renderer-agnostic terminal state — they would work on a
GL build.** Reading the patch body:

- `ghostty_surface_inject_output` → `surface.core_surface.io.processOutput(...)` — feeds the
  VT parser directly (bypassing the PTY). Pure core/termio, no graphics API.
- `ghostty_surface_remote_grid_*` lock `core_surface.renderer_state.mutex` and mutate
  `core_surface.renderer_state.terminal` (`terminal.Screen` / `Page` / `Cell` / `Style` /
  `CursorStyle`), then `renderer_thread.wakeup.notify()` to schedule a redraw. All of this is
  the backend-independent terminal grid + the renderer *thread* wakeup, none of it touches
  Metal or OpenGL.

**Important caveat:** these functions are added to **`embedded.zig`'s `CAPI`**, i.e. the
Metal-only embedded apprt. The *logic* is renderer-agnostic and would compile/run under a GL
build, but it only ships inside `ghostty-internal.so` / the xcframework — which on Linux
cannot render (Q1). If the port takes path (c) (GTK widget reuse), this same logic would need
to be re-exposed against the GTK build's core surface (trivial to port: identical
`core_surface.io` / `renderer_state.terminal` targets), not consumed from `embedded.zig`.

---

## Recommendation

**Choose (c): the hybrid — reuse Ghostty's GTK `Surface` widget + OpenGL renderer, own the
window / tab / sidebar / split chrome.**

Why, given the source:

- **Path (a) "embed libghostty.so behind our own GTK UI, mirroring macOS" is not viable today
  on Linux.** The embedded apprt is structurally Metal-only: the `Platform` union accepts only
  `nsview`/`uiview` (`embedded.zig:344-400`), and the OpenGL embedded backend is an explicit
  no-op stub the author calls "strictly broken for rendering" (`OpenGL.zig:172-176`,
  `:211-215`). Picking (a) means **first writing a Linux GL embedded backend inside Ghostty**
  (see work breakdown below) — a non-trivial upstream change that doesn't exist yet.
- **Path (b) "fork the whole GTK app in Zig" works but is the heaviest.** You inherit and must
  own Ghostty's `Application`/`Window`/`Tab`/`SplitTree` GObject code and do all feature work
  in Zig against it, with a continual rebase burden against upstream. You'd be fighting their
  window/tab/split chrome rather than building your own.
- **Path (c) leverages the one renderer path that is actually implemented for Linux** — the
  GTK GtkGLArea + `OpenGL.zig` pipeline (`surface.zig:3328-3344`, `OpenGL.zig:162-187` GTK
  arm). You reuse the `Surface` widget (terminal rendering, xkb input, IME, clipboard, OSC-52)
  and bypass the Window/Tab/Split classes, supplying your own chrome and connecting to the
  widget's signals (`close-request`, `present-request`, `toggle-fullscreen`, …). It avoids the
  embedded-GL backend work entirely.

### Concrete work each path entails

**Path (c) — recommended:**
- Stand up (or stub) a Ghostty GTK `Application` so `Application.default()` answers — it owns
  the core libghostty `App`, config, and `winproto`. Cheapest: subclass/instantiate their
  `adw.Application`. Cleaner long-term: refactor `class/surface.zig` to inject
  allocator/core-app/config/winproto instead of `Application.default()` (the coupling is a
  finite set of call sites: `surface.zig:757,921,958,1387,1806,1923,1929,…`). Estimate: ~50–150
  LoC of Zig touch-up if you go the injection route, near-zero if you reuse their Application.
- Build your own window/tab/sidebar/split chrome (GTK4/libadwaita) and parent the
  `GhosttySurface` widgets into it; wire the widget signals to your chrome.
- Re-expose the inject-output / remote-grid logic against the GTK build's core surface (port
  the patch's bodies; they target `core_surface.io` / `renderer_state.terminal`, which are
  identical in the GTK build).
- You are working in **Zig/GObject**, building against Ghostty as a source tree, with Zig
  0.15.2, GTK 4.14+, libadwaita 1.4+.

**Path (a) — only if you specifically need the C-ABI embedding model:** the missing Ghostty
Zig work is roughly:
1. Add Linux platform variant(s) to the embedded `Platform` union + `Platform.C` extern union +
   `PlatformTag` + `ghostty.h` (e.g. carry an `EGLDisplay`/`EGLSurface`, or a native
   Wayland/X11 handle, or a "caller keeps a GL context current" contract).
   (`embedded.zig:344-400`, `Surface.Options:425-465`, `ghostty.h`.)
2. Implement embedded GL context/lifecycle in `OpenGL.zig` — replace the stubs in
   `surfaceInit`/`threadEnter` (`:162-216`) and add an embedded `displayRealized` path
   (`:237-249`), including make-current + buffer-swap. The GTK apprt offloads draws to the main
   thread because "GTK doesn't support threaded OpenGL" (`OpenGL.zig:204-209`); an embedded GL
   path would similarly drive draws from the host via the existing `ghostty_surface_draw`
   entry (`embedded.zig:1691` → `core_surface.draw()`).
3. Decide context ownership: either ship EGL creation inside libghostty (new dep + Wayland/X11
   glue, mirroring what Metal does with the NSView) or define a "host provides current GL
   context + does swap" contract and document it.
4. Build with `-Dapp-runtime=none -Drenderer=opengl`; the artifact path (`ghostty-internal.so` +
   `ghostty.h`) already exists (`build.zig:194-203`).
   This is real renderer + apprt engineering in someone else's Zig codebase, with ongoing
   upstream-merge cost — exactly what path (c) sidesteps.

**Net:** (c) is the feasible path with today's source; it reuses the working Linux GL renderer
and the entire GTK input/clipboard/IME stack, at the cost of the `Application` singleton coupling
and working in Zig rather than over the C ABI. (a) is possible but front-loads a brand-new
embedded GL backend in Ghostty that does not exist at commit `5d0a82ba`.
