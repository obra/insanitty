#pragma once
/* insanitty <-> Ghostty GTK embedding C ABI. See src/apprt/gtk/c_api.zig. */
#include <gtk/gtk.h>

/* Init libghostty + the GhosttyApplication; returns the process GApplication. */
GApplication *insanitty_app_init(void);

/* Create a live terminal surface widget (parent into any GtkWidget container). */
GtkWidget *insanitty_surface_new(void);

/* Run Ghostty's integrated loop (blocks; required for the terminal to render). */
void insanitty_app_run(void);

/* Request app shutdown. */
void insanitty_app_quit(void);
