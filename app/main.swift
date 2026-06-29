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
nonisolated(unsafe) var remotePaneContainer: OpaquePointer?            // box holding the remote pane tree
nonisolated(unsafe) var remotePaneSurfaces: [Int: OpaquePointer] = [:] // remote pane id → surface
nonisolated(unsafe) var pendingFetcher: RemoteQuicFetcher?
let remoteLock = NSLock()
nonisolated(unsafe) var injectTries = 0
nonisolated(unsafe) var workspaceCounter = 3 // 0..2 are created at startup
// Track the live terminal surfaces we create so we can find the focused one for splitting.
nonisolated(unsafe) var surfaces = Set<OpaquePointer>()

/// One workspace's entry in the custom thumbnail sidebar (the "snapshots" feature).
/// `livePaintable` is a GtkWidgetPaintable tracking the page; while a workspace is the
/// visible one its thumbnail updates live, and we freeze it to a still image on switch-away.
final class WorkspaceTile {
    let page: OpaquePointer
    let picture: OpaquePointer
    let livePaintable: OpaquePointer
    let name: String
    let index: Int   // tmux session index, or -1 for the non-persisted "remote (QUIC)" demo
    init(page: OpaquePointer, picture: OpaquePointer, livePaintable: OpaquePointer, name: String, index: Int) {
        self.page = page; self.picture = picture; self.livePaintable = livePaintable
        self.name = name; self.index = index
    }
}
nonisolated(unsafe) var tiles: [WorkspaceTile] = []
nonisolated(unsafe) var sidebarList: OpaquePointer?
nonisolated(unsafe) var currentWorkspace = 0
nonisolated(unsafe) var overviewBox: OpaquePointer?   // Exposé overlay (hidden until toggled)
nonisolated(unsafe) var overviewFlow: OpaquePointer?  // the GtkFlowBox of workspace tiles
nonisolated(unsafe) var ctrlClient: TmuxControlClient?   // live tmux -CC client (demo workspace)
nonisolated(unsafe) var ctrlPaneSurfaces: [Int: OpaquePointer] = [:]  // tmux pane id → surface
nonisolated(unsafe) var ctrlTabView: OpaquePointer?        // AdwTabView: one tab per tmux window
nonisolated(unsafe) var ctrlWindowContainers: [Int: OpaquePointer] = [:]  // window id → pane-tree box
nonisolated(unsafe) var ctrlWindowPanes: [Int: Set<Int>] = [:]  // window id → its current panes

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

/// Add a workspace page to the stack and a live-thumbnail row to the custom sidebar.
@discardableResult
func registerWorkspace(_ page: OpaquePointer, name: String, id: String, index: Int) -> Int {
    guard let stack = mainStack, let list = sidebarList else { return -1 }
    gtk_stack_add_named(P(stack), P(page), id)

    let paintable = OP(gtk_widget_paintable_new(P(page)))!
    let pic = OP(gtk_picture_new())!
    gtk_picture_set_paintable(P(pic), P(paintable))
    gtk_picture_set_content_fit(P(pic), GTK_CONTENT_FIT_CONTAIN)
    gtk_widget_set_size_request(P(pic), 188, 116)

    let frame = OP(gtk_frame_new(nil))!
    gtk_frame_set_child(P(frame), P(pic))

    let label = OP(gtk_label_new(name))!
    gtk_widget_set_halign(P(label), GTK_ALIGN_START)
    gtk_label_set_ellipsize(P(label), PANGO_ELLIPSIZE_END)

    let box = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 4))!
    gtk_widget_set_margin_top(P(box), 6); gtk_widget_set_margin_bottom(P(box), 6)
    gtk_widget_set_margin_start(P(box), 8); gtk_widget_set_margin_end(P(box), 8)
    gtk_box_append(P(box), P(frame))
    gtk_box_append(P(box), P(label))

    let row = OP(gtk_list_box_row_new())!
    gtk_list_box_row_set_child(P(row), P(box))
    gtk_list_box_append(P(list), P(row))

    tiles.append(WorkspaceTile(page: page, picture: pic, livePaintable: paintable, name: name, index: index))
    return tiles.count - 1
}

/// Persist the workspace list (names/indices/order), each workspace's browser-tab URLs, and
/// the selected workspace to the XDG layout file. The "remote (QUIC)" demo (index -1) is skipped.
func saveLayout() {
    var wss: [WorkspaceLayout] = []
    for tile in tiles where tile.index >= 0 {
        var urls: [String] = []
        if let tabView = OP(gtk_widget_get_last_child(P(tile.page))) {
            for i in 0..<adw_tab_view_get_n_pages(P(tabView)) {
                guard let page = OP(adw_tab_view_get_nth_page(P(tabView), i)),
                      let child = OP(adw_tab_page_get_child(P(page))),
                      let wvRaw = g_object_get_data(P(child), "insanitty-webview"),
                      let c = webkit_web_view_get_uri(P(OpaquePointer(wvRaw))) else { continue }
                urls.append(String(cString: c))
            }
        }
        wss.append(WorkspaceLayout(index: tile.index, name: tile.name, browserURLs: urls))
    }
    let sel = (currentWorkspace >= 0 && currentWorkspace < tiles.count) ? tiles[currentWorkspace].index : 0
    try? LayoutStore.save(AppLayout(workspaces: wss, selected: sel), to: LayoutStore.defaultURL())
}

/// Switch to workspace `idx`: freeze the outgoing thumbnail to a still image and put the
/// incoming workspace's live paintable back, so the visible workspace always updates live.
func selectWorkspace(_ idx: Int) {
    guard idx >= 0, idx < tiles.count, let stack = mainStack else { return }
    if idx != currentWorkspace, currentWorkspace >= 0, currentWorkspace < tiles.count {
        let out = tiles[currentWorkspace]
        if let frozen = OP(gdk_paintable_get_current_image(P(out.livePaintable))) {
            gtk_picture_set_paintable(P(out.picture), P(frozen))
            g_object_unref(raw(frozen))
        }
    }
    gtk_stack_set_visible_child(P(stack), P(tiles[idx].page))
    gtk_picture_set_paintable(P(tiles[idx].picture), P(tiles[idx].livePaintable))
    currentWorkspace = idx
    saveLayout()
}

/// Create a new tmux-backed workspace and switch to it (Ctrl+N).
func addWorkspace() {
    guard let list = sidebarList, let page = makeWorkspacePage(index: workspaceCounter) else { return }
    let idx = workspaceCounter
    workspaceCounter += 1
    let tileIdx = registerWorkspace(page, name: WorkspaceName.generate(), id: "ws\(idx)", index: idx)
    gtk_list_box_select_row(P(list), P(OP(gtk_list_box_get_row_at_index(P(list), Int32(tileIdx)))))
}

/// A flowbox tile in the overview was clicked → switch to that workspace and close the overview.
let overviewActivatedCb: @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, childPtr, _ in
    guard let childPtr = childPtr, let list = sidebarList else { return }
    let idx = Int(gtk_flow_box_child_get_index(P(childPtr)))
    if let bg = overviewBox { gtk_widget_set_visible(P(bg), 0) }
    if idx >= 0 { gtk_list_box_select_row(P(list), P(OP(gtk_list_box_get_row_at_index(P(list), Int32(idx))))) }
}

/// Build the Exposé overview overlay: a dimmed page over the content holding a scrollable
/// GtkFlowBox of workspace tiles. Hidden until toggled.
func buildOverview() -> OpaquePointer {
    let bg = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))!
    gtk_widget_add_css_class(P(bg), "background")
    gtk_widget_set_visible(P(bg), 0)

    let scroll = OP(gtk_scrolled_window_new())!
    gtk_widget_set_hexpand(P(scroll), 1); gtk_widget_set_vexpand(P(scroll), 1)
    let flow = OP(gtk_flow_box_new())!
    overviewFlow = flow
    gtk_flow_box_set_selection_mode(P(flow), GTK_SELECTION_NONE)
    gtk_flow_box_set_min_children_per_line(P(flow), 2)
    gtk_flow_box_set_max_children_per_line(P(flow), 4)
    gtk_flow_box_set_homogeneous(P(flow), 1)
    gtk_widget_set_halign(P(flow), GTK_ALIGN_CENTER); gtk_widget_set_valign(P(flow), GTK_ALIGN_CENTER)
    gtk_widget_set_margin_top(P(flow), 24); gtk_widget_set_margin_bottom(P(flow), 24)
    gtk_widget_set_margin_start(P(flow), 24); gtk_widget_set_margin_end(P(flow), 24)
    g_signal_connect_data(raw(flow), "child-activated", unsafeBitCast(overviewActivatedCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    gtk_scrolled_window_set_child(P(scroll), P(flow))
    gtk_box_append(P(bg), P(scroll))
    return bg
}

/// Toggle the Exposé overview. On show, (re)build a tile per workspace reusing the sidebar
/// picture's current paintable (live for the active workspace, the last still for visited ones).
func toggleOverview() {
    guard let bg = overviewBox, let flow = overviewFlow else { return }
    if gtk_widget_get_visible(P(bg)) != 0 { gtk_widget_set_visible(P(bg), 0); return }

    while let child = OP(gtk_widget_get_first_child(P(flow))) { gtk_flow_box_remove(P(flow), P(child)) }
    for tile in tiles {
        let pic = OP(gtk_picture_new())!
        gtk_picture_set_paintable(P(pic), P(OP(gtk_picture_get_paintable(P(tile.picture)))))
        gtk_picture_set_content_fit(P(pic), GTK_CONTENT_FIT_CONTAIN)
        gtk_widget_set_size_request(P(pic), 320, 200)
        let frame = OP(gtk_frame_new(nil))!
        gtk_frame_set_child(P(frame), P(pic))
        let label = OP(gtk_label_new(tile.name))!
        let box = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 6))!
        gtk_box_append(P(box), P(frame)); gtk_box_append(P(box), P(label))
        gtk_flow_box_append(P(flow), P(box))
    }
    FileHandle.standardError.write(Data("insanitty: overview shown (\(tiles.count) workspaces)\n".utf8))
    gtk_widget_set_visible(P(bg), 1)
}

/// Turn what the user typed into the address bar into a URL: pass through anything with a
/// scheme, prefix a bare host with https://, otherwise search.
func normalizeURL(_ text: String) -> String {
    let t = text.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return "about:blank" }
    if t.contains("://") || t.hasPrefix("data:") || t.hasPrefix("about:") || t.hasPrefix("file:") { return t }
    if t.contains(".") && !t.contains(" ") { return "https://" + t }
    let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
    return "https://duckduckgo.com/?q=\(q)"
}

// Browser nav callbacks. The WebKitWebView is passed as the signal's user_data.
let browserBackCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, ud in
    if let ud = ud { webkit_web_view_go_back(P(OpaquePointer(ud))) }
}
let browserFwdCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, ud in
    if let ud = ud { webkit_web_view_go_forward(P(OpaquePointer(ud))) }
}
let browserReloadCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, ud in
    if let ud = ud { webkit_web_view_reload(P(OpaquePointer(ud))) }
}
/// Address-bar Enter: load what was typed into the web view (user_data).
let browserGoCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { entry, ud in
    guard let entry = entry, let ud = ud, let c = gtk_editable_get_text(P(entry)) else { return }
    webkit_web_view_load_uri(P(OpaquePointer(ud)), normalizeURL(String(cString: c)))
}
/// notify::title → keep the tab title (user_data = AdwTabPage) in sync with the page.
let browserTitleCb: @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { web, _, ud in
    guard let web = web, let ud = ud, let t = webkit_web_view_get_title(P(web)) else { return }
    adw_tab_page_set_title(P(OpaquePointer(ud)), t)
}
/// notify::uri → reflect the current URL back into the address bar (user_data = GtkEntry).
let browserUriCb: @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { web, _, ud in
    guard let web = web, let ud = ud, let u = webkit_web_view_get_uri(P(web)) else { return }
    gtk_editable_set_text(P(OpaquePointer(ud)), u)
}

/// Add a browser tab loading `url` to a workspace's tab view: a nav bar (back/forward/reload +
/// address entry) over a real WebKitWebView. The container is tagged with its web view so
/// saveLayout() can read the current URL for persistence.
func addBrowserTab(to tabView: OpaquePointer, url: String) {
    let web = OP(webkit_web_view_new())!
    gtk_widget_set_hexpand(P(web), 1)
    gtk_widget_set_vexpand(P(web), 1)

    let bar = OP(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6))!
    gtk_widget_set_margin_top(P(bar), 4); gtk_widget_set_margin_bottom(P(bar), 4)
    gtk_widget_set_margin_start(P(bar), 6); gtk_widget_set_margin_end(P(bar), 6)
    let back = OP(gtk_button_new_from_icon_name("go-previous-symbolic"))!
    let fwd = OP(gtk_button_new_from_icon_name("go-next-symbolic"))!
    let reload = OP(gtk_button_new_from_icon_name("view-refresh-symbolic"))!
    let entry = OP(gtk_entry_new())!
    gtk_widget_set_hexpand(P(entry), 1)
    gtk_entry_set_placeholder_text(P(entry), "Search or enter address")
    g_signal_connect_data(raw(back), "clicked", unsafeBitCast(browserBackCb, to: GCallback.self), raw(web), nil, GConnectFlags(rawValue: 0))
    g_signal_connect_data(raw(fwd), "clicked", unsafeBitCast(browserFwdCb, to: GCallback.self), raw(web), nil, GConnectFlags(rawValue: 0))
    g_signal_connect_data(raw(reload), "clicked", unsafeBitCast(browserReloadCb, to: GCallback.self), raw(web), nil, GConnectFlags(rawValue: 0))
    g_signal_connect_data(raw(entry), "activate", unsafeBitCast(browserGoCb, to: GCallback.self), raw(web), nil, GConnectFlags(rawValue: 0))
    for b in [back, fwd, reload, entry] { gtk_box_append(P(bar), P(b)) }

    let vbox = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))!
    gtk_box_append(P(vbox), P(bar))
    gtk_box_append(P(vbox), P(web))
    g_object_set_data(P(vbox), "insanitty-webview", raw(web))

    gtk_editable_set_text(P(entry), url)
    webkit_web_view_load_uri(P(web), url)

    let tabPage = OP(adw_tab_view_append(P(tabView), P(vbox)))
    adw_tab_page_set_title(P(tabPage), "Browser")
    adw_tab_view_set_selected_page(P(tabView), P(tabPage))
    g_signal_connect_data(raw(web), "notify::title", unsafeBitCast(browserTitleCb, to: GCallback.self), raw(tabPage), nil, GConnectFlags(rawValue: 0))
    g_signal_connect_data(raw(web), "notify::uri", unsafeBitCast(browserUriCb, to: GCallback.self), raw(entry), nil, GConnectFlags(rawValue: 0))
}

/// New browser tab in the current workspace (Ctrl+B), then persist the layout.
func newBrowserTabInCurrentWorkspace() {
    guard let tabView = currentTabView() else { return }
    addBrowserTab(to: tabView, url: "https://duckduckgo.com")
    FileHandle.standardError.write(Data("insanitty: browser tab opened\n".utf8))
    saveLayout()
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

/// An inert surface for a remote pane: rendered only by injected output (no shell of its own).
/// Ref-sunk so it survives re-parenting when the remote layout is (re)built.
func makeRemotePaneSurface() -> OpaquePointer? {
    guard let s = makeSilentTerminal() else { return nil }
    g_object_ref_sink(raw(s))
    return s
}

/// A "remote (QUIC)" workspace: insanitty fetches the remote workspace over QUIC (SPKI-pinned,
/// in-process) and maps its panes onto a GtkPaned tree of inert surfaces, painting each via
/// inject_output. The container is filled by injectRemoteGrid once the snapshot + keyframes arrive.
func makeRemoteWorkspacePage() -> OpaquePointer? {
    let vbox = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
    let tabView = OP(adw_tab_view_new())
    gtk_widget_set_vexpand(P(tabView), 1)
    let tabBar = OP(adw_tab_bar_new())
    adw_tab_bar_set_view(P(tabBar), P(tabView))
    gtk_box_append(P(vbox), P(tabBar))
    gtk_box_append(P(vbox), P(tabView))
    let box = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))!
    gtk_widget_set_vexpand(P(box), 1)
    remotePaneContainer = box
    let page = OP(adw_tab_view_append(P(tabView), P(box)))
    adw_tab_page_set_title(P(page), "Remote (QUIC)")
    return vbox
}

/// Run a shell command to completion (used to ensure the tmux control session exists).
func runDetached(_ command: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
}

/// Run a shell command and return its stdout (used to query tmux for the control pane id).
func shellOutput(_ command: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// A silent terminal surface: its shell discards input and emits nothing, so the surface renders
/// ONLY bytes injected into it — used as a tmux control-mode pane.
func makeSilentTerminal() -> OpaquePointer? {
    makeTerminal("stty raw -echo 2>/dev/null; exec cat >/dev/null")
}

/// Encode a GDK keypress into the bytes tmux expects (sent via `send-keys -H`): printable
/// characters, Enter/Tab/Backspace/Escape, Ctrl-letters, and the arrow keys.
func encodeTmuxKey(keyval: guint, state: GdkModifierType) -> [UInt8]? {
    let ctrl = (state.rawValue & GDK_CONTROL_MASK.rawValue) != 0
    if keyval == GDK_KEY_Return || keyval == GDK_KEY_KP_Enter { return [0x0D] }
    if keyval == GDK_KEY_BackSpace { return [0x7F] }
    if keyval == GDK_KEY_Tab { return [0x09] }
    if keyval == GDK_KEY_Escape { return [0x1B] }
    if keyval == GDK_KEY_Up { return [0x1B, 0x5B, 0x41] }
    if keyval == GDK_KEY_Down { return [0x1B, 0x5B, 0x42] }
    if keyval == GDK_KEY_Right { return [0x1B, 0x5B, 0x43] }
    if keyval == GDK_KEY_Left { return [0x1B, 0x5B, 0x44] }
    let uni = gdk_keyval_to_unicode(keyval)
    guard uni != 0, let scalar = Unicode.Scalar(uni) else { return nil }
    if ctrl, scalar.value >= 0x40, scalar.value < 0x7F { return [UInt8(scalar.value & 0x1F)] }
    return Array(String(scalar).utf8)
}

/// Key pressed on the tmux -CC surface → forward to the control session's active pane.
let ctrlKeyCb: @convention(c) (OpaquePointer?, guint, guint, GdkModifierType, UnsafeMutableRawPointer?) -> gboolean = { _, keyval, _, state, _ in
    guard let client = ctrlClient, let pane = client.inputPane,
          let bytes = encodeTmuxKey(keyval: keyval, state: state) else { return 0 }
    client.sendKeys(pane: pane, bytes: bytes)
    return 1
}

/// A silent control-mode pane surface (renders only injected output) with a key controller that
/// forwards keystrokes to the active pane. Ref-sunk so it survives re-parenting across relayouts.
func makeControlPaneSurface() -> OpaquePointer? {
    guard let s = makeSilentTerminal() else { return nil }
    g_object_ref_sink(raw(s))
    let kc = OP(gtk_event_controller_key_new())
    gtk_event_controller_set_propagation_phase(P(kc), GTK_PHASE_CAPTURE)
    g_signal_connect_data(raw(kc), "key-pressed", unsafeBitCast(ctrlKeyCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(P(s), P(kc))
    return s
}

/// Build the widget for a pane layout: a leaf → its surface (via `surfaceFor`), a split → a
/// (nested) GtkPaned. Shared by tmux control mode and the remote workspace.
func buildPaneTree(_ node: TmuxLayoutNode, _ surfaceFor: (Int) -> OpaquePointer?) -> OpaquePointer? {
    switch node {
    case .leaf(let pane):
        return surfaceFor(pane)
    case .horizontal(let kids):
        return buildPaned(GTK_ORIENTATION_HORIZONTAL, kids, surfaceFor)
    case .vertical(let kids):
        return buildPaned(GTK_ORIENTATION_VERTICAL, kids, surfaceFor)
    }
}

/// Fold an N-ary split into nested binary GtkPaned widgets.
func buildPaned(_ orientation: GtkOrientation, _ kids: [TmuxLayoutNode], _ surfaceFor: (Int) -> OpaquePointer?) -> OpaquePointer? {
    guard var acc = kids.first.flatMap({ buildPaneTree($0, surfaceFor) }) else { return nil }
    for kid in kids.dropFirst() {
        let paned = OP(gtk_paned_new(orientation))!
        gtk_paned_set_resize_start_child(P(paned), 1); gtk_paned_set_resize_end_child(P(paned), 1)
        gtk_paned_set_start_child(P(paned), P(acc))
        gtk_paned_set_end_child(P(paned), P(buildPaneTree(kid, surfaceFor)))
        acc = paned
    }
    return acc
}

/// Ensure a tab + pane-tree container exists for tmux window `window`; return its container.
func ensureWindowTab(_ window: Int) -> OpaquePointer? {
    if let c = ctrlWindowContainers[window] { return c }
    guard let tabView = ctrlTabView else { return nil }
    let box = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))!
    gtk_widget_set_vexpand(P(box), 1)
    ctrlWindowContainers[window] = box
    let page = OP(adw_tab_view_append(P(tabView), P(box)))!
    adw_tab_page_set_title(P(page), "window @\(window)")
    return box
}

/// Lay out a tmux window's panes (its tab) as a GtkPaned tree of silent surfaces, reusing
/// surfaces across relayouts (kept alive by the dict's ref) so pane content persists.
func rebuildWindowPanes(_ window: Int, _ tree: TmuxLayoutNode) {
    guard let container = ensureWindowTab(window) else { return }
    let newPanes = Set(tree.allPanes())
    let oldPanes = ctrlWindowPanes[window] ?? []
    if newPanes == oldPanes { return }   // same panes, only sizes changed
    ctrlWindowPanes[window] = newPanes
    // Detach this window's surfaces (the dict keeps them alive), then drop the old tree.
    for pane in oldPanes.union(newPanes) {
        if let s = ctrlPaneSurfaces[pane], gtk_widget_get_parent(P(s)) != nil { gtk_widget_unparent(P(s)) }
    }
    while let old = OP(gtk_widget_get_first_child(P(container))) { gtk_box_remove(P(container), P(old)) }
    let widget = buildPaneTree(tree) { pane in
        if ctrlPaneSurfaces[pane] == nil { ctrlPaneSurfaces[pane] = makeControlPaneSurface() }
        return ctrlPaneSurfaces[pane]
    }
    if let widget = widget { gtk_box_append(P(container), P(widget)) }
    // Release surfaces for panes that closed in this window.
    for pane in oldPanes.subtracting(newPanes) {
        if let s = ctrlPaneSurfaces.removeValue(forKey: pane) {
            if gtk_widget_get_parent(P(s)) != nil { gtk_widget_unparent(P(s)) }
            g_object_unref(raw(s))
        }
    }
    FileHandle.standardError.write(Data("tmux-cc: window @\(window) → \(newPanes.count)-pane layout\n".utf8))
}

/// A tmux window closed → remove its tab and release its pane surfaces.
func closeWindowTab(_ window: Int) {
    for pane in ctrlWindowPanes[window] ?? [] {
        if let s = ctrlPaneSurfaces.removeValue(forKey: pane) {
            if gtk_widget_get_parent(P(s)) != nil { gtk_widget_unparent(P(s)) }
            g_object_unref(raw(s))
        }
    }
    ctrlWindowPanes.removeValue(forKey: window)
    if let tabView = ctrlTabView, let container = ctrlWindowContainers[window],
       let page = OP(adw_tab_view_get_page(P(tabView), P(container))) {
        adw_tab_view_close_page(P(tabView), P(page))
    }
    ctrlWindowContainers.removeValue(forKey: window)
}

/// A "tmux -CC" workspace: insanitty owns the `tmux -CC` control session and renders its pane by
/// injecting the control protocol's %output into a silent surface (TmuxControlClient). A live
/// demonstration of tmux control mode; env-gated (INSANITTY_TMUX_CC) so it stays out of the way.
func makeControlModeWorkspacePage() -> OpaquePointer? {
    runDetached("tmux new-session -A -d -s insanitty-cc")
    let vbox = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))!
    let tabView = OP(adw_tab_view_new())!
    gtk_widget_set_vexpand(P(tabView), 1)
    let tabBar = OP(adw_tab_bar_new())!
    adw_tab_bar_set_view(P(tabBar), P(tabView))
    gtk_box_append(P(vbox), P(tabBar))
    gtk_box_append(P(vbox), P(tabView))

    // Each tmux window becomes a tab; ensureWindowTab() fills this AdwTabView on demand.
    ctrlTabView = tabView

    let client = TmuxControlClient(session: "insanitty-cc")
    // Query the session's pane id so keystrokes work before the first %output arrives.
    let paneRaw = shellOutput("tmux list-panes -t insanitty-cc -F '#{pane_id}' | head -1")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if paneRaw.hasPrefix("%") { client.defaultPane = Int(paneRaw.dropFirst()) }
    client.surfaceForPane = { pane in
        if ctrlPaneSurfaces[pane] == nil { ctrlPaneSurfaces[pane] = makeControlPaneSurface() }
        return ctrlPaneSurfaces[pane]
    }
    client.onLayout = { window, tree in rebuildWindowPanes(window, tree) }
    client.onWindowClose = { window in closeWindowTab(window) }
    ctrlClient = client

    // Build a tab per existing tmux window from its layout (windows → tabs, panes → splits).
    for line in shellOutput("tmux list-windows -t insanitty-cc -F '#{window_id} #{window_layout}'")
        .split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].hasPrefix("@"), let window = Int(parts[0].dropFirst()),
              let tree = TmuxLayoutParser.parse(String(parts[1])) else { continue }
        rebuildWindowPanes(window, tree)
    }

    // Start the control client once the surfaces have realized; it then injects tmux output.
    // Estimate the window's cell size from the realized container so tmux sizes panes to match.
    let startCb: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        if let c = ctrlTabView {
            let w = Int(gtk_widget_get_width(P(c))), h = Int(gtk_widget_get_height(P(c)))
            if w > 0, h > 0 {
                ctrlClient?.sizeCols = max(40, min(400, w / 8))   // ~8px per cell column
                ctrlClient?.sizeRows = max(10, min(200, h / 17))  // ~17px per cell row
            }
        }
        ctrlClient?.start(); return 0
    }
    g_timeout_add(1500, startCb, nil)
    return vbox
}

/// Run a process (optionally feeding stdin) and return its stdout, or nil on failure.
func runProcess(_ path: String, _ args: [String], stdin: String? = nil) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let outPipe = Pipe(); p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
    let inPipe = Pipe(); if stdin != nil { p.standardInput = inPipe }
    do { try p.run() } catch { return nil }
    if let stdin = stdin {
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        inPipe.fileHandleForWriting.closeFile()
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data
}

/// Fetch the remote workspace by driving insanitty's OWN remote stack on a background thread —
/// launch-or-resume the helper for the bootstrap line, then connect in-process over QUIC
/// (SPKI-pinned) and collect the snapshot + pane keyframes — and on the GTK main thread map the
/// panes onto GtkPaned splits, painting each keyframe via inject_output. No subprocess for QUIC.
func injectRemoteGrid() {
    guard remotePaneContainer != nil else { return }
    // Test hook: render a jsonl fixture of remote messages instead of connecting, to exercise the
    // multi-pane mapping (the live multi-pane path needs the helper's --tmux-session, unavailable here).
    if let fixture = ProcessInfo.processInfo.environment["INSANITTY_REMOTE_FIXTURE"] {
        Thread.detachNewThread {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: fixture)) else { return }
            let fetcher = RemoteQuicFetcher()
            fetcher.loadFixture(data)
            guard !fetcher.keyframes.isEmpty else { return }
            remoteLock.lock(); pendingFetcher = fetcher; remoteLock.unlock()
            g_idle_add(remoteRenderIdle, nil)
        }
        return
    }
    Thread.detachNewThread {
        let helper = FileManager.default.isExecutableFile(atPath: "build/fantastty-helper")
            ? "build/fantastty-helper" : "/tmp/fantastty-helper"
        guard let bootData = runProcess(helper,
                ["launch-or-resume", "insanitty-remote-gui", "--ttl", "8h", "--key-ttl", "30s"]),
              let line = String(decoding: bootData, as: UTF8.self).split(separator: "\n")
                .map(String.init).first(where: { $0.hasPrefix("FANTASTTY_REMOTE ") }),
              let boot = try? RemoteBootstrapLine.parse(line) else {
            FileHandle.standardError.write(Data("insanitty: remote bootstrap failed\n".utf8)); return
        }
        let fetcher = RemoteQuicFetcher(bootstrap: boot)
        guard fetcher.fetch(host: boot.host, port: boot.port), !fetcher.keyframes.isEmpty else {
            FileHandle.standardError.write(Data("insanitty: native QUIC fetch failed\n".utf8)); return
        }
        remoteLock.lock(); pendingFetcher = fetcher; remoteLock.unlock()
        g_idle_add(remoteRenderIdle, nil)
    }
}

/// Main-thread tail of injectRemoteGrid: lay out the remote panes and paint each keyframe.
let remoteRenderIdle: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
    remoteLock.lock(); let fetcher = pendingFetcher; pendingFetcher = nil; remoteLock.unlock()
    if let fetcher = fetcher { renderRemoteWorkspace(fetcher) }
    return 0 // G_SOURCE_REMOVE
}

/// Map the remote workspace's panes (the active window's layout) onto a GtkPaned tree of inert
/// surfaces, then inject each pane's keyframe (rendered to ANSI).
func renderRemoteWorkspace(_ fetcher: RemoteQuicFetcher) {
    guard let container = remotePaneContainer else { return }
    let windows = fetcher.snapshot?.windows ?? []
    let layout = (windows.first(where: { $0.isActive }) ?? windows.first)?.layout
    let tree: TmuxLayoutNode
    if let layout = layout, let parsed = TmuxLayoutParser.parse(layout) {
        tree = parsed
    } else if let pane = fetcher.keyframes.keys.sorted().first {
        tree = .leaf(pane: pane)   // no usable layout → a single pane
    } else { return }

    for (_, s) in remotePaneSurfaces where gtk_widget_get_parent(P(s)) != nil { gtk_widget_unparent(P(s)) }
    while let old = OP(gtk_widget_get_first_child(P(container))) { gtk_box_remove(P(container), P(old)) }
    let widget = buildPaneTree(tree) { pane in
        if remotePaneSurfaces[pane] == nil { remotePaneSurfaces[pane] = makeRemotePaneSurface() }
        return remotePaneSurfaces[pane]
    }
    if let widget = widget { gtk_box_append(P(container), P(widget)) }

    for (pane, kf) in fetcher.keyframes {
        guard let surface = remotePaneSurfaces[pane] else { continue }
        let ansi = Data(RemoteGridRenderer.ansi(for: kf).utf8)
        ansi.withUnsafeBytes { raw in
            insanitty_surface_inject_output(P(surface), raw.bindMemory(to: CChar.self).baseAddress, ansi.count)
        }
    }
    FileHandle.standardError.write(Data("insanitty: rendered \(fetcher.keyframes.count)-pane remote workspace (native QUIC)\n".utf8))
}

/// Sidebar row selected → switch to that workspace.
let rowSelectedCb: @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, rowPtr, _ in
    guard let rowPtr = rowPtr else { return }
    selectWorkspace(Int(gtk_list_box_row_get_index(P(rowPtr))))
}

/// Header "Overview" button clicked → toggle the Exposé overview.
let overviewBtnCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in toggleOverview() }

/// Persist the layout when the window is closing (returns PROPAGATE so the close proceeds).
let closeRequestCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> gboolean = { _, _ in
    saveLayout(); return 0
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

    // Custom sidebar: a scrollable list of live workspace thumbnails (the "snapshots" feature).
    let list = OP(gtk_list_box_new())
    sidebarList = list
    gtk_list_box_set_selection_mode(P(list), GTK_SELECTION_SINGLE)
    g_signal_connect_data(raw(list), "row-selected", unsafeBitCast(rowSelectedCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))

    // Restore the persisted workspaces (names, order, browser-tab URLs), reattaching each
    // tmux session by index; otherwise start with three fresh workspaces.
    let saved = LayoutStore.load(from: LayoutStore.defaultURL())
    if let saved = saved, !saved.workspaces.isEmpty {
        for ws in saved.workspaces {
            let page = makeWorkspacePage(index: ws.index)!
            registerWorkspace(page, name: ws.name, id: "ws\(ws.index)", index: ws.index)
            if let tabView = OP(gtk_widget_get_last_child(P(page))) {
                for url in ws.browserURLs { addBrowserTab(to: tabView, url: url) }
            }
        }
        workspaceCounter = (saved.workspaces.map { $0.index }.max() ?? 2) + 1
    } else {
        for i in 0..<3 {
            registerWorkspace(makeWorkspacePage(index: i)!, name: WorkspaceName.generate(), id: "ws\(i)", index: i)
        }
    }
    // The "remote (QUIC)" demo is always present and never persisted.
    registerWorkspace(makeRemoteWorkspacePage()!, name: "remote (QUIC)", id: "remote", index: -1)
    // Optional live tmux control-mode demo workspace (kept out of normal launches).
    if ProcessInfo.processInfo.environment["INSANITTY_TMUX_CC"] != nil {
        registerWorkspace(makeControlModeWorkspacePage()!, name: "tmux -CC", id: "ctrl", index: -2)
    }

    let sidebarScroll = OP(gtk_scrolled_window_new())
    gtk_scrolled_window_set_policy(P(sidebarScroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
    gtk_scrolled_window_set_child(P(sidebarScroll), P(list))
    gtk_widget_set_size_request(P(sidebarScroll), 220, -1)
    var selPos = tiles.firstIndex(where: { $0.index == (saved?.selected ?? 0) }) ?? 0
    // When the tmux -CC demo is enabled, open on it so it realizes immediately.
    if ProcessInfo.processInfo.environment["INSANITTY_TMUX_CC"] != nil, let last = tiles.indices.last {
        selPos = last
    }
    gtk_list_box_select_row(P(list), P(OP(gtk_list_box_get_row_at_index(P(list), Int32(selPos)))))

    let content = OP(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0))
    gtk_box_append(P(content), P(sidebarScroll))
    gtk_box_append(P(content), P(OP(gtk_separator_new(GTK_ORIENTATION_VERTICAL))))
    gtk_box_append(P(content), P(stack))

    // Overlay the Exposé overview on top of the content (hidden until toggled).
    let overlay = OP(gtk_overlay_new())!
    gtk_overlay_set_child(P(overlay), P(content))
    let overview = buildOverview()
    overviewBox = overview
    gtk_overlay_add_overlay(P(overlay), P(overview))

    let header = OP(adw_header_bar_new())
    adw_header_bar_set_title_widget(P(header), P(OP(gtk_label_new("insanitty"))))
    let overviewBtn = OP(gtk_button_new_from_icon_name("view-grid-symbolic"))!
    gtk_widget_set_tooltip_text(P(overviewBtn), "Overview (Ctrl+O)")
    g_signal_connect_data(raw(overviewBtn), "clicked", unsafeBitCast(overviewBtnCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    adw_header_bar_pack_start(P(header), P(overviewBtn))
    let toolbar = OP(adw_toolbar_view_new())
    adw_toolbar_view_add_top_bar(P(toolbar), P(header))
    adw_toolbar_view_set_content(P(toolbar), P(overlay))
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
        if ctrl && (keyval == GDK_KEY_o || keyval == GDK_KEY_O) {
            toggleOverview()
            return 1
        }
        return 0
    }
    let keyctl = OP(gtk_event_controller_key_new())
    gtk_event_controller_set_propagation_phase(P(keyctl), GTK_PHASE_CAPTURE)
    g_signal_connect_data(raw(keyctl), "key-pressed", unsafeBitCast(keyCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(P(win), P(keyctl))
    g_signal_connect_data(raw(win), "close-request", unsafeBitCast(closeRequestCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))

    gtk_window_present(P(win))

    // Once the remote surface has realized, fetch its grid from the helper (QUIC) + inject.
    // Re-inject a few times (the surface realizes slightly after the window maps).
    let injectCb: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        injectRemoteGrid()
        injectTries += 1
        return injectTries < 6 ? 1 : 0 // re-fetch ~6x, 3s apart (picks up remote layout changes)
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
