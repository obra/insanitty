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
nonisolated(unsafe) var remoteSurface: OpaquePointer?
nonisolated(unsafe) var pendingGrid: Data?
let gridLock = NSLock()
nonisolated(unsafe) var injectTries = 0
nonisolated(unsafe) var workspaceCounter = 3 // 0..2 are created at startup
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

/// The AdwTabView of the currently visible workspace (the page box's last child).
func currentTabView() -> OpaquePointer? {
    guard let stack = mainStack,
          let page = OP(gtk_stack_get_visible_child(P(stack))) else { return nil }
    return OP(gtk_widget_get_last_child(P(page)))
}

/// New terminal tab in the current workspace.
func newTabInCurrentWorkspace() { addTab(to: currentTabView()) }

/// Create a new tmux-backed workspace and switch to it.
func addWorkspace() {
    guard let stack = mainStack else { return }
    let idx = workspaceCounter
    workspaceCounter += 1
    let page = makeWorkspacePage(index: idx)
    gtk_stack_add_titled(P(stack), P(page), "ws\(idx)", WorkspaceName.generate())
    gtk_stack_set_visible_child(P(stack), P(page))
}

/// New WebKitGTK browser tab in the current workspace (Fantastty has browser tabs).
func newBrowserTabInCurrentWorkspace() {
    guard let tabView = currentTabView() else { return }
    let web = OP(webkit_web_view_new())
    gtk_widget_set_hexpand(P(web), 1)
    gtk_widget_set_vexpand(P(web), 1)
    let html = "<html><body style='background:#1e1e2e;color:#cdd6f4;font-family:sans-serif;"
        + "padding:48px'><h1>insanitty browser</h1><p>A WebKitGTK browser tab, embedded "
        + "alongside terminal tabs.</p><p>INSANITTY-BROWSER-OK</p></body></html>"
    webkit_web_view_load_html(P(web), html, nil)
    let tabPage = OP(adw_tab_view_append(P(tabView), P(web)))
    adw_tab_page_set_title(P(tabPage), "Browser")
    adw_tab_view_set_selected_page(P(tabView), P(tabPage))
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

/// A "remote (QUIC)" workspace: an inert surface that insanitty paints by injecting a grid
/// fetched from the real remote-engine helper over QUIC (scripts/remote-grid-ansi.sh +
/// insanitty_surface_inject_output). Demonstrates the remote feature set inside the GUI.
func makeRemoteWorkspacePage() -> OpaquePointer? {
    let vbox = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
    let tabView = OP(adw_tab_view_new())
    gtk_widget_set_vexpand(P(tabView), 1)
    let tabBar = OP(adw_tab_bar_new())
    adw_tab_bar_set_view(P(tabBar), P(tabView))
    gtk_box_append(P(vbox), P(tabBar))
    gtk_box_append(P(vbox), P(tabView))
    let term = makeTerminal("sleep 2592000") // inert; content arrives via inject
    remoteSurface = term
    let box = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
    gtk_box_append(P(box), P(term))
    let page = OP(adw_tab_view_append(P(tabView), P(box)))
    adw_tab_page_set_title(P(page), "Remote (QUIC)")
    return vbox
}

/// Fetch the remote pane grid from the helper (over QUIC) on a background thread, then paint it
/// into the surface on the GTK main thread (`g_idle_add`). Fetching off the main loop keeps the
/// UI responsive while the helper completes its QUIC handshake — a synchronous fetch here would
/// freeze input handling for the duration.
func injectRemoteGrid() {
    guard remoteSurface != nil else { return }
    Thread.detachNewThread {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["scripts/remote-grid-ansi.sh", "insanitty-remote-gui"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard !data.isEmpty else { return }
            gridLock.lock(); pendingGrid = data; gridLock.unlock()
            g_idle_add(injectGridIdle, nil)
            FileHandle.standardError.write(Data("insanitty: injected \(data.count) bytes of remote grid\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("insanitty: remote fetch failed: \(error)\n".utf8))
        }
    }
}

/// Main-thread tail of injectRemoteGrid: paint the fetched grid into the remote surface.
let injectGridIdle: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
    gridLock.lock(); let data = pendingGrid; pendingGrid = nil; gridLock.unlock()
    if let data = data, let surface = remoteSurface {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            insanitty_surface_inject_output(P(surface), raw.bindMemory(to: CChar.self).baseAddress, data.count)
        }
    }
    return 0 // G_SOURCE_REMOVE
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
    gtk_stack_add_titled(P(stack), P(makeRemoteWorkspacePage()), "remote", "remote (QUIC)")

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
        if ctrl && (keyval == GDK_KEY_b || keyval == GDK_KEY_B) {
            newBrowserTabInCurrentWorkspace()
            return 1
        }
        if ctrl && (keyval == GDK_KEY_n || keyval == GDK_KEY_N) {
            addWorkspace()
            return 1
        }
        return 0
    }
    let keyctl = OP(gtk_event_controller_key_new())
    gtk_event_controller_set_propagation_phase(P(keyctl), GTK_PHASE_CAPTURE)
    g_signal_connect_data(raw(keyctl), "key-pressed", unsafeBitCast(keyCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(P(win), P(keyctl))

    gtk_window_present(P(win))

    // Once the remote surface has realized, fetch its grid from the helper (QUIC) + inject.
    // Re-inject a few times (the surface realizes slightly after the window maps).
    let injectCb: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        injectRemoteGrid()
        injectTries += 1
        return injectTries < 3 ? 1 : 0 // repeat up to 3x, ~3s apart
    }
    g_timeout_add(3000, injectCb, nil)
}

setvbuf(stdout, nil, Int32(_IONBF), 0)
// insanitty supplies its own window. Ghostty's embedding lib (artifact == .lib) already gates
// off its own default window (see the `embedded` check in the GTK Application), so there's
// nothing to configure here.
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
