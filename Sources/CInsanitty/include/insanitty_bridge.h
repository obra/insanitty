#ifndef INSANITTY_BRIDGE_H
#define INSANITTY_BRIDGE_H

/* Small GObject helpers that are awkward to express through Swift's C importer
 * (the G_CALLBACK cast, variadic g_object_new). Keeps Swift call sites clean. */

#include <gtk/gtk.h>

typedef void (*ins_simple_cb)(void *instance, void *user_data);

/* Connect a plain (instance, user_data) callback to `signal` on `instance`. */
gulong ins_signal_connect(void *instance, const char *signal, ins_simple_cb cb, void *user_data);

#endif
