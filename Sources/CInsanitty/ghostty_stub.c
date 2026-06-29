#include "insanitty_ghostty.h"

/*
 * Placeholder backend: lets the GTK shell build and run before the forked Ghostty
 * GTK surface is wired in. Each "surface" is a labelled box so the chrome (sidebar,
 * tabs, splits) is navigable. Replace this TU with the real Ghostty bridge.
 */

int ins_ghostty_init(GtkApplication *app) {
    (void)app;
    return -1; /* not wired yet */
}

GtkWidget *ins_ghostty_surface_new(const char *working_dir, const char *command) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_hexpand(box, TRUE);
    gtk_widget_set_vexpand(box, TRUE);
    gtk_widget_add_css_class(box, "card");

    const char *cmd = command ? command : "$SHELL";
    const char *dir = working_dir ? working_dir : "~";
    char *markup = g_strdup_printf(
        "<span size='small' alpha='60%%'>terminal surface (placeholder)\n%s in %s</span>",
        cmd, dir);
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label), markup);
    gtk_label_set_justify(GTK_LABEL(label), GTK_JUSTIFY_CENTER);
    gtk_widget_set_valign(label, GTK_ALIGN_CENTER);
    gtk_widget_set_vexpand(label, TRUE);
    g_free(markup);

    gtk_box_append(GTK_BOX(box), label);
    return box;
}

void ins_ghostty_surface_inject_output(GtkWidget *surface, const uint8_t *bytes, size_t len) {
    (void)surface; (void)bytes; (void)len;
}
void ins_ghostty_surface_remote_grid_reset(GtkWidget *surface, uint32_t cols, uint32_t rows) {
    (void)surface; (void)cols; (void)rows;
}
void ins_ghostty_surface_remote_grid_set_row_utf8(GtkWidget *surface, uint32_t row, const char *utf8) {
    (void)surface; (void)row; (void)utf8;
}
void ins_ghostty_surface_remote_grid_set_cursor(GtkWidget *surface, uint32_t row, uint32_t col, int visible) {
    (void)surface; (void)row; (void)col; (void)visible;
}

int ins_ghostty_is_real(void) { return 0; }
