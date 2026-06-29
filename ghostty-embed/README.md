# ghostty-embed — embedding Ghostty's GTK terminal surface

**Spike A: PROVEN.** A live Ghostty terminal renders inside an insanitty-owned GTK window.
See `docs/images/spike-a-embedded-terminal.png`.

insanitty embeds Ghostty's GTK `GhosttySurface` widget (the only renderer that works on
Linux) by building Ghostty's GTK apprt as a **shared library with a tiny C ABI**, then linking
it from the (Swift) host. The host hosts Ghostty's `GApplication`, creates its own windows, and
parents live surfaces into them.

## The C ABI (`shim/insanitty.h`)

```c
GApplication *insanitty_app_init(void);   // init libghostty + GhosttyApplication; returns the app
GtkWidget    *insanitty_surface_new(void); // a live terminal surface (parent into any container)
void          insanitty_app_run(void);     // Ghostty's integrated loop (required to render)
void          insanitty_app_quit(void);
```

Implemented by `shim/insanitty_c_api.zig` (lives at Ghostty's `src/` level so its module root
matches the exe). The surface is lazily self-bootstrapping: parent it, run the loop, and it spawns
the PTY + renderer on first GL realize.

## The Ghostty fork delta (`../patches/ghostty-gtk-embed.patch`)

103 insertions, applies on Ghostty `5d0a82ba`:
- `src/insanitty_c_api.zig` + `include/insanitty.h` — the shim.
- `src/apprt.zig` — a `.lib` built with `-Dapp-runtime=gtk` selects the **GTK** apprt (not the
  Metal-only embedded one). This is the key trick: a GTK-apprt *library* instead of an exe.
- `src/build/SharedDeps.zig` — let that library get the GTK deps (glad, gobject bindings,
  gresource) that are otherwise exe-only.
- `build.zig` — a `-Dinsanitty-lib` step emitting `libghostty-gtk.so` + the header (with
  `use_llvm = true`; the self-hosted backend crashes on Ghostty).

## Build

```sh
# In a Ghostty checkout (5d0a82ba) with the patch applied, blueprint-compiler >= 0.16,
# Zig 0.15.2 (see ../scripts/setup-dev-env.sh):
zig build -Doptimize=Debug -Dgtk-x11=true -Dgtk-wayland=false -Dapp-runtime=gtk -Dinsanitty-lib=true
# -> zig-out/lib/libghostty-gtk.so + zig-out/include/insanitty.h
```

## Run the embed spike (`../spikes/embed-a`)

```sh
swiftc -I CEmbed -I <ghostty>/zig-out/include main.swift \
  $(pkg-config --cflags-only-I libadwaita-1 | sed 's/-I/-Xcc -I/g') \
  -L <ghostty>/zig-out/lib -lghostty-gtk $(pkg-config --libs libadwaita-1) \
  -Xlinker -rpath -Xlinker <ghostty>/zig-out/lib -o embed-a

# Needs initial-window=false (so Ghostty doesn't open its own window) and a session bus:
mkdir -p cfg/ghostty && echo "initial-window = false" > cfg/ghostty/config
XDG_CONFIG_HOME=$PWD/cfg GHOSTTY_RESOURCES_DIR=<ghostty>/zig-out/share/ghostty \
  dbus-run-session -- ./embed-a     # under a display (or Xvfb + a WM headless)
```

Verified headless on llvmpipe: the surface creates an EGL OpenGL 3.2 context, spawns a zsh,
and renders (the shell's prompt set the window title `jesse@magic-kingdom: …`).

## Next (Spike B)

Re-home the `inject_output` / `remote_grid_*` patch bodies against this GTK build's
`core_surface` and expose them through this same shim, so tmux control mode and the QUIC remote
engine can drive the embedded surface. See `../patches/README.md`.
