// insanitty — local terminal workspace manager (real embedded Ghostty surfaces).
//
// Hosts Ghostty's GApplication via libghostty-gtk, then builds insanitty's own chrome:
// a sidebar of workspaces (GtkStackSidebar) and a GtkStack of pages, each page a live
// GhosttySurface terminal. Switching the sidebar switches workspaces.
//
// Build: scripts/build-app.sh. Run: build/insanitty (under a display, or headless via
// INSANITTY_SMOKE=1 + Xvfb + a WM + dbus-run-session — see scripts/run-app-headless.sh).
import CGhostty
import Foundation
#if canImport(Glibc)
import Glibc
#endif

nonisolated(unsafe) var gapp: OpaquePointer?

/// A live terminal pane that expands to fill its page.
func makeTerminal() -> OpaquePointer? {
    let term = OP(insanitty_surface_new())
    gtk_widget_set_hexpand(P(term), 1)
    gtk_widget_set_vexpand(P(term), 1)
    return term
}

func buildWindow() {
    let win = OP(adw_application_window_new(P(gapp)))
    gtk_window_set_default_size(P(win), 1100, 700)
    gtk_window_set_title(P(win), "insanitty")

    // Workspaces: one live terminal per stack page.
    let stack = OP(gtk_stack_new())
    gtk_stack_set_transition_type(P(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
    gtk_widget_set_hexpand(P(stack), 1)
    gtk_widget_set_vexpand(P(stack), 1)
    for i in 0..<3 {
        let name = WorkspaceName.generate()
        gtk_stack_add_titled(P(stack), P(makeTerminal()), "ws\(i)", name)
    }

    // Sidebar bound to the stack (click a workspace -> switch page).
    let sidebar = OP(gtk_stack_sidebar_new())
    gtk_stack_sidebar_set_stack(P(sidebar), P(stack))
    gtk_widget_set_size_request(P(sidebar), 220, -1)

    let content = OP(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0))
    gtk_box_append(P(content), P(sidebar))
    gtk_box_append(P(content), P(OP(gtk_separator_new(GTK_ORIENTATION_VERTICAL))))
    gtk_box_append(P(content), P(stack))

    // Header bar (AdwApplicationWindow has no default titlebar).
    let header = OP(adw_header_bar_new())
    adw_header_bar_set_title_widget(P(header), P(OP(gtk_label_new("insanitty"))))
    let toolbar = OP(adw_toolbar_view_new())
    adw_toolbar_view_add_top_bar(P(toolbar), P(header))
    adw_toolbar_view_set_content(P(toolbar), P(content))

    adw_application_window_set_content(P(win), P(toolbar))
    gtk_window_present(P(win))
}

setvbuf(stdout, nil, Int32(_IONBF), 0)
guard let a = insanitty_app_init() else {
    FileHandle.standardError.write(Data("insanitty: app_init failed\n".utf8)); exit(1)
}
gapp = OP(a)
buildWindow()

if ProcessInfo.processInfo.environment["INSANITTY_SMOKE"] != nil {
    let quit: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        insanitty_app_quit(); return 0
    }
    g_timeout_add(30000, quit, nil)
}
insanitty_app_run()
