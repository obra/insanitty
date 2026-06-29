// insanitty — application shell skeleton (Phase-0).
//
// Builds the GTK4/libadwaita window: a sidebar of workspaces and a split terminal area.
// Terminal panes are placeholders (CInsanitty stub) until the forked Ghostty GTK surface
// is wired (see Sources/CInsanitty + docs/IMPLEMENTATION-PROPOSAL.md §2, Spike A/B).
//
// Run with a display, or headless: `INSANITTY_SMOKE=1 xvfb-run -a .build/debug/insanitty`.
import CAdw
import CInsanitty
import InsanittyCore
import Foundation

// Single-threaded GTK main-loop state, read by @convention(c) callbacks.
nonisolated(unsafe) var application: OpaquePointer?

func buildMainWindow(app: OpaquePointer?) {
    let window = OP(adw_application_window_new(P(app)))
    gtk_window_set_default_size(P(window), 1000, 640)
    gtk_window_set_title(P(window), "insanitty")

    // Outer split: sidebar | content.
    let split = OP(gtk_paned_new(GTK_ORIENTATION_HORIZONTAL))
    gtk_paned_set_position(P(split), 220)

    // Sidebar: a list of (placeholder) workspaces, named via the ported generator.
    let sidebar = OP(gtk_list_box_new())
    gtk_widget_add_css_class(P(sidebar), "navigation-sidebar")
    for _ in 0..<6 {
        let row = OP(gtk_label_new(WorkspaceName.generate()))
        gtk_widget_set_halign(P(row), GTK_ALIGN_START)
        gtk_widget_set_margin_top(P(row), 6)
        gtk_widget_set_margin_bottom(P(row), 6)
        gtk_widget_set_margin_start(P(row), 12)
        gtk_list_box_append(P(sidebar), P(row))
    }
    let sidebarScroll = OP(gtk_scrolled_window_new())
    gtk_scrolled_window_set_child(P(sidebarScroll), P(sidebar))
    gtk_paned_set_start_child(P(split), P(sidebarScroll))

    // Content: two terminal surfaces in a vertical split (demonstrates the split tree).
    let termSplit = OP(gtk_paned_new(GTK_ORIENTATION_VERTICAL))
    gtk_paned_set_start_child(P(termSplit), P(OP(ins_ghostty_surface_new(nil, nil))))
    gtk_paned_set_end_child(P(termSplit), P(OP(ins_ghostty_surface_new(nil, nil))))
    gtk_paned_set_end_child(P(split), P(termSplit))

    adw_application_window_set_content(P(window), P(split))
    gtk_window_present(P(window))

    if ProcessInfo.processInfo.environment["INSANITTY_SMOKE"] != nil {
        // Headless self-terminate so CI can run the shell under Xvfb.
        let quit: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
            g_application_quit(P(application))
            return 0 // G_SOURCE_REMOVE
        }
        g_timeout_add(500, quit, nil)
    }
}

let activate: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in
    print("insanitty: ghostty backend wired = \(ins_ghostty_is_real() != 0)")
    buildMainWindow(app: application)
}

application = OP(adw_application_new("org.insanitty.Insanitty", G_APPLICATION_DEFAULT_FLAGS))
onSignal(application, "activate", activate)
let status = g_application_run(P(application), CommandLine.argc, CommandLine.unsafeArgv)
exit(status)
