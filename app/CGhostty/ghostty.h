#ifndef INSANITTY_APP_CGHOSTTY_H
#define INSANITTY_APP_CGHOSTTY_H
/* GTK4 + libadwaita + the libghostty-gtk embedding C ABI, imported into Swift. */
#include <adwaita.h>
#include <insanitty.h>

/* GObject signal connect that performs the G_CALLBACK cast Swift can't express.
 * static inline so the app links it without a separate translation unit. */
typedef void (*ins_simple_cb)(void *instance, void *user_data);
static inline gulong ins_signal_connect(void *instance, const char *signal,
                                        ins_simple_cb cb, void *user_data) {
    return g_signal_connect_data(instance, signal, G_CALLBACK(cb), user_data, NULL, 0);
}

#endif
