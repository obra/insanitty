# Ghostty patches

## `ghostty-inject-output.patch`

Carried verbatim from Fantastty. Adds two renderer-agnostic capabilities to libghostty
(operating on `core_surface.io` / `renderer_state.terminal`, not on any graphics API):

1. **`ghostty_surface_inject_output(bytes, len)`** — feed raw bytes into the VT parser,
   bypassing the PTY. Powers tmux control-mode `%output` rendering.
2. **`ghostty_surface_remote_grid_*`** (reset / set_row / set_row_cells / set_cursor) — write
   fully-styled cells directly into the terminal screen under the renderer mutex. Powers the
   QUIC remote-engine render path.

Verified to **apply cleanly** at Ghostty commit `5d0a82ba` (`git apply --check`, both hunks).

### Porting note (the one piece of real work)

The patch currently adds its exports to **`src/apprt/embedded.zig`'s C API** — the Metal-only
embedded apprt that does not ship on Linux. For insanitty's GTK-reuse path, the *same bodies*
must be re-exposed against the **GTK** apprt's `core_surface` (the targets are identical:
`core_surface.io.processOutput`, `renderer_state.terminal`). This is the mechanical Zig work
tracked by **Spike B**. See `docs/research/03b-ghostty-source-verified.md` and
`docs/SPEC.md §4.1`.
