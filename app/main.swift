// insanitty — local terminal workspace manager (real embedded Ghostty surfaces).
//
// Hosts Ghostty's GApplication via libghostty-gtk, then builds insanitty's own chrome:
// a sidebar of workspaces (GtkStackSidebar) and a GtkStack of pages. Each page is a box
// holding a tree of live GhosttySurface terminals (split via GtkPaned).
//
// Shortcuts: Ctrl+D split right, Ctrl+Shift+D split down (Linux-keyed; Fantastty used ⌘D).
//
// Build: scripts/build-app.sh. Headless e2e: scripts/e2e-scenario.sh.
import CGhostty
import Foundation
#if canImport(Glibc)
import Glibc
#endif

nonisolated(unsafe) var gapp: OpaquePointer?
nonisolated(unsafe) var mainWindow: OpaquePointer?
nonisolated(unsafe) var mainStack: OpaquePointer?
// Track the live terminal surfaces we create so we can find the focused one for splitting.
nonisolated(unsafe) var surfaces = Set<OpaquePointer>()

/// A live terminal pane that expands to fill its slot. If `command` is given, the surface
/// runs it instead of the default shell (used for tmux-backed workspaces).
func makeTerminal(_ command: String? = nil) -> OpaquePointer? {
    let term: OpaquePointer?
    if let c = command {
        term = OP(c.withCString { insanitty_surface_new_command($0) })
    } else {
        term = OP(insanitty_surface_new())
    }
    gtk_widget_set_hexpand(P(term), 1)
    gtk_widget_set_vexpand(P(term), 1)
    if let t = term { surfaces.insert(t) }
    return term
}

func isPaned(_ w: OpaquePointer?) -> Bool {
    guard let w = w else { return false }
    return g_type_check_instance_is_a(P(w), gtk_paned_get_type()) != 0
}

/// Walk up from `start` to the nearest terminal surface we created.
func focusedSurface(from start: OpaquePointer?) -> OpaquePointer? {
    var cur = start
    while let c = cur {
        if surfaces.contains(c) { return c }
        cur = OP(gtk_widget_get_parent(P(c)))
    }
    return nil
}

/// Split the focused terminal: replace it with a GtkPaned holding it + a new terminal.
func splitFocused(_ orientation: GtkOrientation) {
    guard let win = mainWindow,
          let focus = OP(gtk_window_get_focus(P(win))),
          let surface = focusedSurface(from: focus),
          let parent = OP(gtk_widget_get_parent(P(surface))) else { return }

    g_object_ref(raw(surface))                 // keep it alive across re-parenting
    defer { g_object_unref(raw(surface)) }

    let paned = OP(gtk_paned_new(orientation))
    gtk_paned_set_resize_start_child(P(paned), 1)
    gtk_paned_set_resize_end_child(P(paned), 1)

    if isPaned(parent) {
        let startIsSurface = OP(gtk_paned_get_start_child(P(parent))) == surface
        if startIsSurface { gtk_paned_set_start_child(P(parent), nil) }
        else { gtk_paned_set_end_child(P(parent), nil) }
        gtk_paned_set_start_child(P(paned), P(surface))
        gtk_paned_set_end_child(P(paned), P(makeTerminal()))
        if startIsSurface { gtk_paned_set_start_child(P(parent), P(paned)) }
        else { gtk_paned_set_end_child(P(parent), P(paned)) }
    } else {
        // parent is the workspace page box
        gtk_box_remove(P(parent), P(surface))
        gtk_paned_set_start_child(P(paned), P(surface))
        gtk_paned_set_end_child(P(paned), P(makeTerminal()))
        gtk_box_append(P(parent), P(paned))
    }
}

/// A tab's content root: a box wrapping a terminal (which can split into a GtkPaned tree).
func makeSplitRoot(_ command: String? = nil) -> OpaquePointer? {
    let box = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
    gtk_box_append(P(box), P(makeTerminal(command)))
    return box
}

/// Add a terminal tab to a workspace's AdwTabView and select it.
func addTab(to tabView: OpaquePointer?, command: String? = nil) {
    let page = OP(adw_tab_view_append(P(tabView), P(makeSplitRoot(command))))
    adw_tab_page_set_title(P(page), "Terminal")
    adw_tab_view_set_selected_page(P(tabView), P(page))
}

/// New tab in the currently visible workspace (its AdwTabView is the page box's last child).
func newTabInCurrentWorkspace() {
    guard let stack = mainStack,
          let page = OP(gtk_stack_get_visible_child(P(stack))),
          let tabView = OP(gtk_widget_get_last_child(P(page))) else { return }
    addTab(to: tabView)
}

/// One workspace page: a tab bar over an AdwTabView of terminal tabs. The first tab is
/// backed by a per-workspace tmux session (`tmux new-session -A -s insanitty-ws-N`), so its
/// shell + scrollback + running programs survive app restarts ("persistent sessions").
func makeWorkspacePage(index: Int) -> OpaquePointer? {
    let vbox = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
    let tabView = OP(adw_tab_view_new())
    gtk_widget_set_vexpand(P(tabView), 1)
    let tabBar = OP(adw_tab_bar_new())
    adw_tab_bar_set_view(P(tabBar), P(tabView))
    gtk_box_append(P(vbox), P(tabBar))
    gtk_box_append(P(vbox), P(tabView))
    addTab(to: tabView, command: "tmux new-session -A -s insanitty-ws-\(index)")
    return vbox
}

func buildWindow() {
    let win = OP(adw_application_window_new(P(gapp)))
    mainWindow = win
    gtk_window_set_default_size(P(win), 1100, 700)
    gtk_window_set_title(P(win), "insanitty")

    let stack = OP(gtk_stack_new())
    mainStack = stack
    gtk_stack_set_transition_type(P(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
    gtk_widget_set_hexpand(P(stack), 1)
    gtk_widget_set_vexpand(P(stack), 1)
    for i in 0..<3 {
        gtk_stack_add_titled(P(stack), P(makeWorkspacePage(index: i)), "ws\(i)", WorkspaceName.generate())
    }

    let sidebar = OP(gtk_stack_sidebar_new())
    gtk_stack_sidebar_set_stack(P(sidebar), P(stack))
    gtk_widget_set_size_request(P(sidebar), 220, -1)

    let content = OP(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0))
    gtk_box_append(P(content), P(sidebar))
    gtk_box_append(P(content), P(OP(gtk_separator_new(GTK_ORIENTATION_VERTICAL))))
    gtk_box_append(P(content), P(stack))

    let header = OP(adw_header_bar_new())
    adw_header_bar_set_title_widget(P(header), P(OP(gtk_label_new("insanitty"))))
    let toolbar = OP(adw_toolbar_view_new())
    adw_toolbar_view_add_top_bar(P(toolbar), P(header))
    adw_toolbar_view_set_content(P(toolbar), P(content))
    adw_application_window_set_content(P(win), P(toolbar))

    // Ctrl+D / Ctrl+Shift+D split shortcuts (capture phase, so we see them before the surface).
    let keyCb: @convention(c) (OpaquePointer?, guint, guint, GdkModifierType, UnsafeMutableRawPointer?) -> gboolean = { _, keyval, _, state, _ in
        let ctrl = (state.rawValue & GDK_CONTROL_MASK.rawValue) != 0
        let shift = (state.rawValue & GDK_SHIFT_MASK.rawValue) != 0
        if ctrl && (keyval == GDK_KEY_d || keyval == GDK_KEY_D) {
            splitFocused(shift ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL)
            return 1
        }
        if ctrl && (keyval == GDK_KEY_t || keyval == GDK_KEY_T) {
            newTabInCurrentWorkspace()
            return 1
        }
        return 0
    }
    let keyctl = OP(gtk_event_controller_key_new())
    gtk_event_controller_set_propagation_phase(P(keyctl), GTK_PHASE_CAPTURE)
    g_signal_connect_data(raw(keyctl), "key-pressed", unsafeBitCast(keyCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(P(win), P(keyctl))

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
