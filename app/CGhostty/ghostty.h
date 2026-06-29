#ifndef INSANITTY_APP_CGHOSTTY_H
#define INSANITTY_APP_CGHOSTTY_H
/* GTK4 + libadwaita + WebKitGTK + the libghostty-gtk embedding C ABI, imported into Swift. */
#include <adwaita.h>
#include <webkit/webkit.h>
#include <insanitty.h>

/* GObject signal connect that performs the G_CALLBACK cast Swift can't express.
 * static inline so the app links it without a separate translation unit. */
typedef void (*ins_simple_cb)(void *instance, void *user_data);
static inline gulong ins_signal_connect(void *instance, const char *signal,
                                        ins_simple_cb cb, void *user_data) {
    return g_signal_connect_data(instance, signal, G_CALLBACK(cb), user_data, NULL, 0);
}

#include <pty.h>
#include <unistd.h>
#include <glib-unix.h>  /* g_unix_fd_add: watch the tmux pty master fd on the GTK main loop */

/* Spawn argv inside a fresh pseudo-terminal and return the master fd (or -1), writing the child
 * pid to *out_pid. forkpty() opens the pty in the parent, then in the child sets up the slave as
 * the controlling tty; the child then only execvp()s, so this is safe to call from a threaded
 * process. Used for `tmux -CC`, which requires a real tty (it refuses pipes). */
static inline int ins_pty_spawn(char *const argv[], pid_t *out_pid) {
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, NULL);
    if (pid < 0) return -1;
    if (pid == 0) {
        execvp(argv[0], argv);
        _exit(127); /* exec failed */
    }
    *out_pid = pid;
    return master;
}

#endif
