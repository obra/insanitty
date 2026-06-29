#include "insanitty_bridge.h"

gulong ins_signal_connect(void *instance, const char *signal, ins_simple_cb cb, void *user_data) {
    return g_signal_connect_data(instance, signal, G_CALLBACK(cb), user_data, NULL, 0);
}
