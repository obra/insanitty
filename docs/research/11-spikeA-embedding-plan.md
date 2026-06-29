# Spike-A: Embedding Ghostty's GTK terminal surface into insanitty

**Source:** Ghostty at commit `5d0a82ba` (Zig 0.15.2), checked out under
`scratchpad/ghostty-src`. All `file:line` refs are against that commit, repo-relative
to the Ghostty tree unless noted. Verified to build on this box with
`zig build -Doptimize=Debug -Dgtk-wayland=false -Dgtk-x11=true` → `zig-out/bin/ghostty`.

## Bottom line up front

- A `GhosttySurface` widget is **lazily self-bootstrapping**: parent a realized
  `GhosttySurface` into *any* `GtkWidget` container and the core terminal (PTY,
  termio, renderer thread) spins up automatically on the first GL resize
  (`surface.zig:3400-3403` → `initSurface`). The host does **not** have to wire the
  core surface by hand.
- The one hard prerequisite is the GObject **`Application` singleton**: `Surface`
  reaches `Application.default()` (= `gio.Application.getDefault()` cast to
  `GhosttyApplication`) for its allocator, core app, config, and winproto. So
  **`GhosttyApplication` must be the process's one `GApplication`.** insanitty must
  *not* create its own `Gtk/AdwApplication`; it uses the one the shim creates.
- Ghostty's `Application.run()` (`application.zig:477`) is a custom event loop that
  pumps `core_app.tick()` every iteration (`:552`). That tick is **mandatory** —
  the renderer thread requests redraws by posting `redraw_surface` to the core app
  mailbox, which `tick`→`drainMailbox`→`redrawSurface`→`gl_area.queueRender()`
  turns into an actual draw (`App.zig:252`, `surface.zig:822-824`). A plain
  `g_application_run` loop would never draw. So the spike **reuses Ghostty's run
  loop** rather than insanitty's own.
- The real obstacle is **build-time comptime selection**, not the widget. Two gates
  key off the artifact being an *executable*:
  1. `build_config.artifact` is derived from `builtin.output_mode`
     (`build_config.zig:83-98`); `.Lib` → `artifact=.lib` → `apprt.runtime=embedded`
     (`apprt.zig:42-49`), which is the Metal-only apprt **and** compiles the OpenGL
     renderer's dead embedded stub instead of the working GTK path.
  2. The GTK dependencies (`addGtkNg`, the glad GL loader, the gresource C file) are
     only added `if (step.kind != .lib)` (`SharedDeps.zig:593-609`).
  Both must be overridden so a *library* still compiles as the GTK apprt. This is
  the crux of "making it linkable" and is what the embedded `-Dapp-runtime=none`
  lib path (`main_c.zig`, hard-asserted to `apprt.embedded` at `main_c.zig:24`)
  cannot give us.
- **Spike-A = 4 tiny edits to Ghostty's build + 1 new Zig shim file + 1 new
  build.zig step**, producing `libghostty-gtk.so` + a 3-function C header. Estimated
  ~70 LoC of new Zig (shim), ~15 LoC of build.zig edits. No edits to `surface.zig`
  or `application.zig` are required.

---

## Q1 — App entry + Application construction

### How the GTK binary starts

`src/main.zig:5-16` dispatches to `main_ghostty.zig` (the `.ghostty` entrypoint).
`main_ghostty.zig:25` `pub fn main()` does, in order:

1. `state.init()` (`main_ghostty.zig:31`) — process-global state in
   `src/global.zig` (`GlobalState.init`, `global.zig:52`). Sets `state.alloc`
   (libc allocator or GPA, `global.zig:91-94`), parses any `+action` CLI
   (`global.zig:99`), crash handler, locale, and `state.resources_dir =
   apprt.runtime.resourcesDir(...)` (`global.zig:174`).
2. `const app: *App = try App.create(alloc)` (`main_ghostty.zig:103`) — the
   **core libghostty app** (`src/App.zig:76` `create` → `init`, `:89`). Builds the
   font grid set + mailbox; does **not** touch GTK.
3. `var app_runtime: apprt.App = undefined; try app_runtime.init(app, .{})`
   (`main_ghostty.zig:106-107`). `apprt.App` is the GTK `App` wrapper
   (`apprt/gtk/App.zig`). `App.init` (`App.zig:34`) calls
   `Application.new(self, core_app)` and stores `self.app` (`App.zig:43-45`).
4. `try app_runtime.run()` (`main_ghostty.zig:117`) → `App.run` (`App.zig:49`) →
   `self.app.run()` → `Application.run()`.

### What `Application.new` builds (`application.zig:243-428`)

The GObject is `GhosttyApplication`, an `adw.Application` subclass
(`application.zig:134` `Parent = adw.Application`; GType via
`gobject.ext.defineClass`, `:135-140`). `new` does the heavy global setup itself:

- `glib.logSetWriterFunc(...)` log funnel (`:251`).
- `CoreConfig.load(alloc)` → wrapped in a `Config` GObject (`:258`, `:367`).
- `adw.init()` (`:306`) and GTK env (`setGtkEnv`, `:296`).
- `gdk.Display.getDefault()` (`:337`) and **winproto** init
  (`winprotopkg.App.init(alloc, display, app_id, &config)`, `:345`) — the X11/Wayland
  abstraction; falls back to `.none` on error.
- CSS provider added to the display (`:372-377`).
- `gobject.ext.newInstance(Self, .{ .application_id, .flags, .resource_base_path })`
  (`:381-389`) — constructs the GObject; sets `resource_base_path` to
  `build_info.resource_path` so compiled-in resources load.
- Fills `Private` (`:394-405`): `rt_app`, `core_app`, `config`, `winproto`,
  `css_provider`, `global_shortcuts`, `saved_language`, `open_uri`.

`Application.default()` (`application.zig:230-233`) is just
`gobject.ext.cast(Self, gio.Application.getDefault().?).?`. The app is **set as the
process default inside the `startup` vfunc** (`application.zig:1303`
`gio.Application.setDefault(self)`), which GApplication fires on **first
`g_application_register()`**. `startup` (`:1294-1330`) also sets up the libxev
backend, style manager (light/dark), signal handlers, the action map, global
shortcuts (D-Bus), and shows any config-error dialog.

### What `Application.run` does (`application.zig:477-592`) — and why it matters

It is **not** `g_application_run`; it is a hand-rolled loop:

1. `glib.MainContext.default()` + `acquire` (`:482-483`).
2. `self.as(gio.Application).register(null, &err)` (`:502`) — fires `startup`
   (→ sets default) on the primary instance.
3. `if (config.@"initial-window") self.as(gio.Application).activate();` (`:529`) —
   this is what opens Ghostty's *own* window. The `activate` vfunc
   (`application.zig:1459`) ultimately calls `actionNewWindow`.
4. Loop `while (priv.running)` (`:548`): `glib.MainContext.iteration(ctx, 1)` then
   `try priv.core_app.tick(priv.rt_app)` (`:549-552`), plus quit-condition checks
   (`:554-590`).

`Application.wakeup` (`:1286-1289`) is only `glib.MainContext.wakeup(null)` — it
just breaks the blocking `iteration` so the surrounding loop runs `tick` again. This
is why the tick must live in a custom loop; a stock GApplication loop has no tick.

### Minimal sequence to stand up a working Application in our process

```
state.init()                         // global.zig:52   (alloc, resources_dir)
core_app = CoreApp.create(alloc)     // App.zig:76
rt_app.init(core_app, .{})           // apprt/gtk/App.zig:34 -> Application.new
rt_app.app.as(gio.Application).register(null, &err)   // fires startup -> setDefault
// ... now Application.default() works; create windows/surfaces ...
rt_app.run()                         // application.zig:477 loop (idempotent re-register)
```

With `initial-window = false` in config, step `run()` skips `activate()` (`:529`),
so **no Ghostty window opens** and the loop simply pumps tick for our surfaces.

---

## Q2 — Surface construction API

### The widget and its GType

`src/apprt/gtk/class/surface.zig:42-56`: `GhosttySurface` is an `adw.Bin` subclass
implementing `gtk.Scrollable`. GType via `getGObjectType =
gobject.ext.defineClass(Self, .{ .name = "GhosttySurface", .instanceInit = &init,
.classInit = &Class.init, ... })`. Helpers `as`/`ref`/`unref` at `:3582-3585`.

### Constructor

`Surface.new(overrides)` (`surface.zig:747-764`):

```zig
pub fn new(overrides: struct {
    command: ?configpkg.Command = null,
    working_directory: ?[:0]const u8 = null,
    title: ?[:0]const u8 = null,
}) *Self
```

It calls `gobject.ext.newInstance(Self, .{ .@"title-override" = ... })` and then
`Application.default().allocator()` (`:757`) to clone the overrides — **so the
Application must already be the default before `Surface.new` is called.** For the
spike, pass `.{}` (`Surface.new(.none)`).

### Config / parent: what it needs

- **Config:** auto-defaulted. `instanceInit` (`init`, `surface.zig:1784-1833`) does
  `if (priv.config == null) priv.config = Application.default().getConfig();`
  (`:1805-1807`). The host need not set a config for the spike.
- **Parent core surface:** optional. `setParent(parent, ctx)` (`:781`) only seeds
  font-size/cwd inheritance for splits; a standalone surface skips it.

### How the core surface + pty come alive (the key mechanism)

The widget owns a `GtkGLArea` template child (`gl_area`, bound at
`surface.zig:3608`). Its `gl_resize` callback (`glareaResize`, `:3346`) fires when
GTK realizes+sizes the area. With no core surface yet, it calls `self.initSurface()`
(`:3400-3403`). `initSurface` (`:3411-3489`):

1. `gl_area.makeCurrent()` (`:3418`) — GTK provides/【makes current】the GL context.
2. `app = Application.default(); alloc = app.allocator()` (`:3426-3427`).
3. `app.core().addSurface(self.rt())` (`:3434`) — register in the global surface list.
4. `apprt.surface.newConfig(app.core(), priv.config.?.get(), priv.context)` (`:3438`).
5. `surface.init(alloc, &config, app.core(), app.rt(), &priv.rt_surface)` (`:3465`)
   — spins up the PTY/termio/renderer thread.
6. stores `priv.core_surface`, emits the `init` signal (`:3481`).

So **the only thing the host must do is parent a `GhosttySurface` into a realized,
sized container and let the main loop run.** `glareaRender` (`:3328-3344`) then calls
`surface.renderer.drawFrame(true)` whenever the GLArea is asked to redraw.

### Can it be parented into an arbitrary container? Yes.

`GhosttySurface` has **no hard dependency** on Ghostty's `Window`/`Tab`/`SplitTree`
(confirmed in `03b`). It is an `adw.Bin`, so `gtk_*_set_child` /
`adw_*_set_content` / `gtk_box_append` all accept it. It communicates upward purely
via signals.

### Signals a host must (or may) handle (`surface.zig:444-650`)

| Signal | When | Host action for spike |
|---|---|---|
| `close-request (bool process_active)` | child exited / user close | tear down / remove widget |
| `init` | core surface created | optional (focus, title) |
| `bell` | bell | optional |
| `present-request` | wants focus/raise | optional |
| `toggle-fullscreen`, `toggle-maximize` | keybind actions | optional |
| `clipboard-read` / `clipboard-write` | OSC-52 / paste | optional (Ghostty has a default dialog) |

For "one terminal renders," **none are strictly required**; wire `close-request`
for clean teardown.

---

## Q3 — Making it linkable

### Why the existing lib paths don't work

- `main_c.zig` (root of `GhosttyLib`) hard-asserts `apprt.runtime == apprt.embedded`
  (`main_c.zig:24`). `-Dapp-runtime=none` → `ghostty-internal.so` is the **Metal-only
  embedded** apprt (per `03b`). Unusable for a Linux terminal.
- `libghostty-vt` is parser-only. No surface/renderer.

### Two comptime gates that fight a GTK *library*

1. **Apprt + renderer selection keys off `builtin.output_mode`.**
   `build_config.artifact = Artifact.detect()` returns `.lib` for `output_mode ==
   .Lib` (`build_config.zig:83-98`). `apprt.runtime` then resolves to `embedded`
   (`apprt.zig:42-49`), and `renderer/OpenGL.zig` compiles its dead embedded stub
   instead of the GTK arm (`03b` Q1). A normal `b.addLibrary` therefore silently
   selects the wrong, non-rendering apprt. **`build_config.artifact` must be forced
   to `.exe`.** (`b.addObject`/`.Obj` is rejected by `detect()` too, `:93-96`.)

2. **GTK deps are exe-only.** `SharedDeps.add` adds `addGtkNg` (the gobject bindings,
   `gtk4`+`libadwaita-1` link, and the auto-registering `ghostty_resources.c`) and
   the static **glad** GL loader only inside `if (step.kind != .lib)`
   (`SharedDeps.zig:593-609`, GTK switch at `:605`). A library skips all of it.

`addGtkNg` (`SharedDeps.zig:619-754`) is exactly what we want linked: gobject modules
`adw/gdk/gio/glib/gobject/gtk/xlib` (`:632-644`), `gtk4` + `libadwaita-1` (`:647-648`),
optional `X11` + `gdk_x11` (`:650-657`), and the gresource C file (`:748-752`). The
gresource is produced by `glib-compile-resources --generate-source` →
`ghostty_resources.c` (`SharedDeps.zig:930-937`), whose `__attribute__((constructor))`
**auto-registers the GResource bundle (Blueprint `.ui` templates + CSS + icons) at
`.so` load**, satisfying `setTemplateFromResource` (`surface.zig:3598`). No manual
`g_resources_register` is needed as long as that C file is linked in.

### GObject type-registration requirement

`GhosttyApplication`/`GhosttySurface` GTypes are registered lazily by their
`getGObjectType` (`gobject.ext.defineClass`) on first use. Our shim calls
`Application.new` and `Surface.new`, both of which reach `newInstance` →
`getGObjectType`, so the types register on demand and the symbols are referenced
(not dead-stripped). No extra registration call is required. (`Surface`'s
`classInit` also `ensureType`s its overlay children, `surface.zig:3594-3597`.)

### Verdict

An `-Dapp-runtime=gtk` **library emit is feasible** but only after overriding the two
exe-only gates above. That is the smallest delta from the existing build.

---

## Q4 — The smallest possible Spike-A

Goal: **one real terminal rendering inside an insanitty-owned GTK window.** Cheapest
path = reuse Ghostty's `Application` + run loop; insanitty supplies the window and
parents one `GhosttySurface`.

### New file 1 — the C-ABI shim (Zig)

Create `scratchpad/ghostty-src/src/apprt/gtk/c_api.zig` (co-located so relative
imports are clean). ~70 LoC:

```zig
//! Minimal C ABI to embed the Ghostty GTK terminal surface into a host
//! GTK4 application (insanitty). The host owns its window/chrome; this owns
//! the libghostty App + GhosttyApplication singleton + run loop.
const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const gtk = @import("gtk");
const state = &@import("../../global.zig").state;
const CoreApp = @import("../../App.zig");
const apprt = @import("../../apprt.zig");
const Application = @import("class/application.zig").Application;
const Surface = @import("class/surface.zig").Surface;

var core_app: *CoreApp = undefined;
var rt_app: apprt.App = undefined;

/// Stand up global state, the core app, and the GhosttyApplication. Registers
/// the application so Application.default() works and templates resolve.
/// Returns the GApplication* the host uses to create its AdwApplicationWindow.
export fn insanitty_app_init() ?*anyopaque {
    state.init() catch return null;
    core_app = CoreApp.create(state.alloc) catch return null;
    rt_app.init(core_app, .{}) catch return null;
    var err: ?*glib.Error = null;
    if (rt_app.app.as(gio.Application).register(null, &err) == 0) {
        if (err) |e| e.free();
        return null;
    }
    return rt_app.app.as(gio.Application);
}

/// Create a terminal surface widget. Parent it into any GtkWidget container;
/// the terminal spawns lazily on first realize+resize. Returns GtkWidget*.
export fn insanitty_surface_new() ?*anyopaque {
    const surface = Surface.new(.none);
    return surface.as(gtk.Widget);
}

/// Run Ghostty's integrated event loop (pumps core_app.tick). Blocks until quit.
export fn insanitty_app_run() void {
    rt_app.run() catch |e| std.log.err("insanitty run failed: {}", .{e});
}

/// Optional: begin app shutdown from the host.
export fn insanitty_app_quit() void {
    rt_app.app.quit();
}
```

### New file 2 — the C header insanitty includes

`scratchpad/ghostty-src/include/insanitty.h`:

```c
#pragma once
#include <gtk/gtk.h>
GApplication *insanitty_app_init(void);
GtkWidget    *insanitty_surface_new(void);
void          insanitty_app_run(void);
void          insanitty_app_quit(void);
```

### Edit 1 — `src/build/Config.zig`: forceable artifact

Add a field near `:39` (Ghostty exe properties):

```zig
force_artifact_exe: bool = false,
```

and in `addOptions` (after `:539`):

```zig
step.addOption(bool, "force_artifact_exe", self.force_artifact_exe);
```

### Edit 2 — `src/build_config.zig:32`: honor the override

```zig
pub const artifact = if (options.force_artifact_exe) .exe else Artifact.detect();
```

(Default `false` for every existing build → unchanged behavior for exe and the
embedded lib.)

### Edit 3 — `src/build/SharedDeps.zig:593`: let a GTK lib get GTK deps

```zig
if (step.kind != .lib or self.config.app_runtime == .gtk) {
```

(Only changes behavior for an `app_runtime=gtk` library — our shim — adding glad +
`addGtkNg`. Embedded lib is `app_runtime=none`, exe is unchanged.)

### Edit 4 — `build.zig`: emit the shim lib

After the embedded-lib block (`build.zig:204`), add a step gated on a new
`-Dinsanitty-lib` option so the normal `ghostty` build is untouched:

```zig
if (b.option(bool, "insanitty-lib", "Build the insanitty GTK embedding lib") orelse false) {
    var shim_cfg = config;                 // copy of buildpkg.Config
    shim_cfg.force_artifact_exe = true;    // -> apprt.runtime = gtk, GL = gtk path
    const shim_deps = try buildpkg.SharedDeps.init(b, &shim_cfg);
    const shim = b.addLibrary(.{
        .name = "ghostty-gtk",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apprt/gtk/c_api.zig"),
            .target = shim_cfg.target,
            .optimize = shim_cfg.optimize,
        }),
        .use_llvm = true,
    });
    _ = try shim_deps.add(shim);           // core deps + (now) addGtkNg + glad + gresource
    b.installArtifact(shim);
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(
        b.path("include/insanitty.h"), "insanitty.h",
    ).step);
}
```

### Exact build invocation

```
cd scratchpad/ghostty-src
zig build -Doptimize=Debug -Dgtk-x11=true -Dgtk-wayland=false -Dapp-runtime=gtk -Dinsanitty-lib=true
```

Produces `zig-out/lib/libghostty-gtk.so` + `zig-out/include/insanitty.h`
(plus the normal `ghostty` exe + `zig-out/share/ghostty` resources — keep the latter,
insanitty points `GHOSTTY_RESOURCES_DIR` at it). insanitty links `-lghostty-gtk` (or
dlopens it) alongside its own `gtk4`/`libadwaita-1`.

### The runtime sequence insanitty (Swift) performs

```
GApplication *app = insanitty_app_init();          // registers; sets default
// build insanitty chrome owned by `app`:
GtkWidget *win = adw_application_window_new(GTK_APPLICATION(app));
// ... header bar / sidebar / split layout ...
GtkWidget *term = insanitty_surface_new();         // GhosttySurface
adw_application_window_set_content(ADW_APPLICATION_WINDOW(win), term); // or into a split
gtk_window_present(GTK_WINDOW(win));
insanitty_app_run();                               // blocks; pumps tick; terminal draws
```

Once the loop starts, GTK realizes the `GtkGLArea` → `glareaResize` →
`initSurface` spawns the PTY + renderer thread → renderer posts `redraw_surface` →
`core_app.tick` (inside the loop) drains it → `gl_area.queueRender()` →
`glareaRender` → `drawFrame`. A live shell renders in insanitty's window.

### Two hard requirements for the spike to behave

1. **insanitty must not create its own `Gtk/AdwApplication`.** There is exactly one
   process-default `GApplication`, and `Surface` demands it be the
   `GhosttyApplication` (`Application.default()` casts and unwraps,
   `application.zig:230-233`). insanitty builds windows *from* `app`.
2. **`initial-window = false`** in the Ghostty config so `Application.run()` does not
   open a Ghostty window (`application.zig:529`). insanitty's `AdwApplicationWindow`
   keeps the loop alive (it is a window of `app`, so the no-window quit branch at
   `:569-577` never fires; the shim also never calls `startQuitTimer`).

---

## Risks / open questions for the spike

- **GL context realize errors.** `initSurface` returns `error.GLAreaError` if
  `gl_area.makeCurrent()` fails (`surface.zig:3419-3424`) — the classic
  GTK GLArea/driver issue (gitlab GNOME #4950). Run under X11 first (already the
  verified config) before attempting Wayland.
- **Config-driven `initial-window`.** Spike depends on the user's Ghostty config
  setting `initial-window = false`. If we want zero external config, a 1-line patch
  to `application.zig:529` (gate `activate()` behind a shim flag/env) removes the
  dependency — note, not needed for the first proof.
- **Window close ≠ app quit.** Because `requested_window` stays false, closing
  insanitty's window does not stop `Application.run()` (`application.zig:569-577`).
  insanitty must drive shutdown via `insanitty_app_quit()` (exposed above) or
  `g_application_quit`.
- **Shared GTK/Adw runtime.** The `.so` links `gtk4`/`libadwaita-1` dynamically
  (`SharedDeps.zig:647-648`); insanitty links the same system libs — one copy at
  runtime. `adw.init()` is called once by `Application.new` (`:306`); insanitty must
  not re-init a second application.
- **`terminal_options.artifact`.** Terminal modules read a *separate* build option
  (`Config.terminalOptions`, `build/Config.zig:573`), independent of the forced
  `build_config.artifact`. It only tweaks kitty-image storage limits / test skips —
  not render correctness — so it can be left as the build wires it.
- **Thread model.** `must_draw_from_app_thread = true` (`apprt/gtk/App.zig:23`); GL
  draws happen on the main thread inside the run loop. insanitty must keep the
  GTK main thread = the thread that calls `insanitty_app_run()`.
```
