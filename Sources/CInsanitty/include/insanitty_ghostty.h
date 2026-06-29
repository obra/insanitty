#ifndef INSANITTY_GHOSTTY_H
#define INSANITTY_GHOSTTY_H

/*
 * insanitty ↔ Ghostty GTK bridge — C API the Swift app calls to obtain and drive
 * terminal surfaces.
 *
 * STATUS: stub implementation (insanitty_ghostty_stub.c). The real implementation
 * links the forked Ghostty GTK build and:
 *   - hosts Ghostty's GTK `Application` singleton (so `Application.default()` answers),
 *   - constructs `GhosttySurface` widgets and returns them as plain `GtkWidget*`,
 *   - re-exposes the `ghostty_surface_inject_output` + `ghostty_surface_remote_grid_*`
 *     capabilities (patches/) against the GTK apprt's `core_surface`.
 * See docs/SPEC.md §4.1 and docs/research/03b-ghostty-source-verified.md.
 */

#include <gtk/gtk.h>
#include <stdint.h>
#include <stddef.h>

/* Host Ghostty's GTK Application for this process. Returns 0 on success.
 * Stub: returns -1 (not yet wired) so callers fall back to placeholder surfaces. */
int ins_ghostty_init(GtkApplication *app);

/* Create a terminal surface widget running `command` (NULL = user's shell) in
 * `working_dir` (NULL = home). Returns a GtkWidget* to parent into our chrome.
 * Stub: returns a labelled placeholder widget so the shell is navigable today. */
GtkWidget *ins_ghostty_surface_new(const char *working_dir, const char *command);

/* Feed raw bytes into the surface's VT parser, bypassing the PTY (tmux %output). */
void ins_ghostty_surface_inject_output(GtkWidget *surface, const uint8_t *bytes, size_t len);

/* Structured remote-grid render path (QUIC remote engine). */
void ins_ghostty_surface_remote_grid_reset(GtkWidget *surface, uint32_t cols, uint32_t rows);
void ins_ghostty_surface_remote_grid_set_row_utf8(GtkWidget *surface, uint32_t row, const char *utf8);
void ins_ghostty_surface_remote_grid_set_cursor(GtkWidget *surface, uint32_t row, uint32_t col, int visible);

/* True once the real Ghostty backend is wired (stub: 0). */
int ins_ghostty_is_real(void);

#endif
