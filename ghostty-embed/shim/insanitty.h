#pragma once
/* insanitty <-> Ghostty GTK embedding C ABI. See src/apprt/gtk/c_api.zig. */
#include <gtk/gtk.h>

/* Init libghostty + the GhosttyApplication; returns the process GApplication. */
GApplication *insanitty_app_init(void);

/* Create a live terminal surface widget (parent into any GtkWidget container). */
GtkWidget *insanitty_surface_new(void);

/* Like insanitty_surface_new but runs `cmd` (shell-expanded) — e.g. tmux attach. */
GtkWidget *insanitty_surface_new_command(const char *cmd);

/* Inject raw terminal output into a surface (bypassing the PTY): tmux %output / remote paint. */
void insanitty_surface_inject_output(GtkWidget *surface, const char *bytes, size_t len);

/* Run Ghostty's integrated loop (blocks; required for the terminal to render). */
void insanitty_app_run(void);

/* Request app shutdown. */
void insanitty_app_quit(void);
