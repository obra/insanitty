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
nonisolated(unsafe) var remoteActivePane = 0                           // pane to forward keystrokes to
nonisolated(unsafe) var pendingRemoteInput: [UInt8] = []              // keystrokes queued for the next fetch
let remoteLock = NSLock()
nonisolated(unsafe) var remoteRendered = false   // true once the remote workspace has painted once
nonisolated(unsafe) var remoteFetchInFlight = false           // a poll's fetch is running
nonisolated(unsafe) var remoteSession: RemoteQuicFetcher?     // the held-open connection (reused each poll)
nonisolated(unsafe) var lastRemoteTreeSig = ""               // layout signature; rebuild the tree only on change
nonisolated(unsafe) var lastRemoteAnsi: [Int: String] = [:]  // per-pane painted ANSI; re-inject only on change
nonisolated(unsafe) var workspaceCounter = 3 // 0..2 are created at startup
nonisolated(unsafe) var settingsURL = SettingsStore.defaultURL()
nonisolated(unsafe) var currentSettings = SettingsStore.load(from: SettingsStore.defaultURL())
nonisolated(unsafe) var workspacesURL = WorkspaceMetadataStore.defaultURL()
nonisolated(unsafe) var workspaceMeta = WorkspaceMetadataStore.load(from: WorkspaceMetadataStore.defaultURL())

/// Persist all workspace metadata (best-effort).
func saveWorkspaceMeta() { try? WorkspaceMetadataStore.save(workspaceMeta, to: workspacesURL) }

/// The persistence key for the selected workspace (`insanitty-ws-<index>`), or nil for the
/// non-persisted "remote (QUIC)" demo (index -1).
func currentWorkspaceID() -> String? {
    guard currentWorkspace >= 0, currentWorkspace < tiles.count else { return nil }
    let idx = tiles[currentWorkspace].index
    return idx >= 0 ? "insanitty-ws-\(idx)" : nil
}

/// Metadata for a workspace id, creating (and registering) a default if absent.
func metaFor(_ id: String) -> WorkspaceMetadata {
    if let m = workspaceMeta[id] { return m }
    let now = Date()
    let m = WorkspaceMetadata(workspaceID: id, createdAt: now, modifiedAt: now)
    workspaceMeta[id] = m
    return m
}

/// Consume `insanitty:` OSC 9 payloads (note/ticket/pr) from the shell integration onto the current
/// workspace's metadata. Returns true if consumed (ghostty then skips the desktop notification).
/// Invoked by the embedding lib on the GTK main thread.
let oscHandlerCb: @convention(c) (UnsafePointer<UInt8>?, Int) -> Bool = { ptr, len in
    guard let ptr = ptr, len > 0 else { return false }
    let body = String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    guard body.hasPrefix("insanitty:") else { return false }
    let id = currentWorkspaceID() ?? "insanitty-ws-0"
    var m = metaFor(id)
    if body.hasPrefix("insanitty:note;") {
        m.appendNote(content: String(body.dropFirst("insanitty:note;".count)), source: .terminal, at: Date())
    } else if body.hasPrefix("insanitty:ticket;") {
        m.ticketURL = String(body.dropFirst("insanitty:ticket;".count)); m.modifiedAt = Date()
    } else if body.hasPrefix("insanitty:pr;") {
        m.pullRequestURL = String(body.dropFirst("insanitty:pr;".count)); m.modifiedAt = Date()
    } else {
        return false
    }
    workspaceMeta[id] = m; saveWorkspaceMeta()
    if notesWorkspaceID == id { rebuildNotesList() }   // live-refresh the notes panel if open
    FileHandle.standardError.write(Data("insanitty: consumed OSC \(body.prefix(48))\n".utf8))
    return true
}

nonisolated(unsafe) var lastActiveTick = Date()

/// Accumulate focused time onto the active workspace (idle-excluded: only counts while the window
/// is the active window). A long gap (suspend, unfocus) is dropped so wall-clock isn't over-counted.
let activeTimeCb: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
    let now = Date(); let elapsed = now.timeIntervalSince(lastActiveTick); lastActiveTick = now
    guard let win = mainWindow, gtk_window_is_active(P(win)) != 0,
          let id = currentWorkspaceID(), elapsed > 0, elapsed < 30 else { return 1 }
    var m = metaFor(id); m.totalActiveSeconds += elapsed; workspaceMeta[id] = m
    saveWorkspaceMeta()
    return 1
}

/// Apply the appearance mode to the libadwaita chrome (sidebar/header bar light/dark). `.system`
/// follows the desktop preference; `.light`/`.dark` force it.
func applyAppearance(_ mode: AppearanceMode) {
    guard let mgr = adw_style_manager_get_default() else { return }
    switch mode {
    case .system: adw_style_manager_set_color_scheme(mgr, ADW_COLOR_SCHEME_DEFAULT)
    case .light:  adw_style_manager_set_color_scheme(mgr, ADW_COLOR_SCHEME_FORCE_LIGHT)
    case .dark:   adw_style_manager_set_color_scheme(mgr, ADW_COLOR_SCHEME_FORCE_DARK)
    }
}
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
    let label: OpaquePointer   // the sidebar name label (updated to show the attention marker)
    init(page: OpaquePointer, picture: OpaquePointer, livePaintable: OpaquePointer, name: String, index: Int, label: OpaquePointer) {
        self.page = page; self.picture = picture; self.livePaintable = livePaintable
        self.name = name; self.index = index; self.label = label
    }
}

/// Show/hide the ⚠ attention marker on a workspace's sidebar label.
func setTileAttention(_ tileIdx: Int, _ on: Bool) {
    guard tileIdx >= 0, tileIdx < tiles.count else { return }
    gtk_label_set_text(P(tiles[tileIdx].label), (on ? "\u{26A0} " : "") + tiles[tileIdx].name)
}
nonisolated(unsafe) var tiles: [WorkspaceTile] = []
nonisolated(unsafe) var sidebarList: OpaquePointer?
nonisolated(unsafe) var currentWorkspace = 0
nonisolated(unsafe) var overviewBox: OpaquePointer?   // Exposé overlay (hidden until toggled)
nonisolated(unsafe) var overviewFlow: OpaquePointer?  // the GtkFlowBox of workspace tiles
nonisolated(unsafe) var controlWorkspaces: [Int: ControlModeWorkspace] = [:]  // tmux index → control-mode workspace

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
/// The ControlModeWorkspace of the currently selected workspace, if it is tmux-backed.
func currentControlWorkspace() -> ControlModeWorkspace? {
    guard currentWorkspace >= 0, currentWorkspace < tiles.count else { return nil }
    return controlWorkspaces[tiles[currentWorkspace].index]
}

func splitFocused(_ orientation: GtkOrientation) {
    // Control-mode workspaces split via tmux (`split-window`); the %layout-change response rebuilds
    // the pane tree, so the split is a real tmux pane that persists across restarts.
    if let cw = currentControlWorkspace(), let pane = cw.client.inputPane {
        cw.client.send("split-window -t %\(pane) -\(orientation == GTK_ORIENTATION_VERTICAL ? "v" : "h")")
        return
    }
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
func newTabInCurrentWorkspace() {
    // Control-mode workspaces add a tab via a tmux window (`new-window`); %window-add builds the tab.
    if let cw = currentControlWorkspace() { cw.client.send("new-window"); return }
    addTab(to: currentTabView())
}

/// Select the workspace `delta` rows away (wrapping), updating the sidebar selection.
func selectAdjacentWorkspace(_ delta: Int) {
    guard let list = sidebarList, !tiles.isEmpty else { return }
    let n = tiles.count
    let next = ((currentWorkspace + delta) % n + n) % n
    gtk_list_box_select_row(P(list), P(OP(gtk_list_box_get_row_at_index(P(list), Int32(next)))))
}

/// Select the next/previous tab in the current workspace's tab view.
func selectAdjacentTab(_ delta: Int) {
    guard let tabView = currentTabView() else { return }
    if delta > 0 { adw_tab_view_select_next_page(P(tabView)) } else { adw_tab_view_select_previous_page(P(tabView)) }
}

/// Close the current tab: a tmux window for control-mode workspaces (`kill-window`).
func closeCurrentTab() {
    if let cw = currentControlWorkspace() { cw.client.send("kill-window"); return }
    if let tabView = currentTabView(), let page = OP(adw_tab_view_get_selected_page(P(tabView))) {
        adw_tab_view_close_page(P(tabView), P(page))
    }
}

/// Close (archive) the current workspace.
func closeCurrentWorkspace() {
    guard currentWorkspace >= 0, currentWorkspace < tiles.count, tiles[currentWorkspace].index >= 0 else { return }
    archiveWorkspace(tmuxIndex: tiles[currentWorkspace].index, trash: false)
}

/// Toggle the attention flag on the current workspace (persisted + sidebar ⚠ marker).
func toggleCurrentAttention() {
    guard currentWorkspace >= 0, currentWorkspace < tiles.count, let id = currentWorkspaceID() else { return }
    var m = metaFor(id); m.needsAttention.toggle(); m.modifiedAt = Date()
    workspaceMeta[id] = m; saveWorkspaceMeta()
    setTileAttention(currentWorkspace, m.needsAttention)
}

/// Select the next workspace flagged for attention.
func selectNextFlaggedWorkspace() {
    guard let list = sidebarList, !tiles.isEmpty else { return }
    let n = tiles.count
    for off in 1...n {
        let i = (currentWorkspace + off) % n
        if tiles[i].index >= 0, workspaceMeta["insanitty-ws-\(tiles[i].index)"]?.needsAttention == true {
            gtk_list_box_select_row(P(list), P(OP(gtk_list_box_get_row_at_index(P(list), Int32(i))))); return
        }
    }
}

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

    // Right-click → archive/trash this workspace. Persisted workspaces only (not the remote demo).
    if index >= 0 {
        let rclick = OP(gtk_gesture_click_new())
        gtk_gesture_single_set_button(P(rclick), 3)
        g_signal_connect_data(raw(rclick), "pressed", unsafeBitCast(rowRightClickCb, to: GCallback.self),
                              UnsafeMutableRawPointer(bitPattern: index), nil, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(P(row), P(rclick))
    }

    tiles.append(WorkspaceTile(page: page, picture: pic, livePaintable: paintable, name: name, index: index, label: label))
    if index >= 0, workspaceMeta["insanitty-ws-\(index)"]?.needsAttention == true {
        setTileAttention(tiles.count - 1, true)   // restore a persisted attention flag
    }
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

/// Archive (or trash) a workspace: stamp its metadata, drop it from the active sidebar/layout, and
/// kill its tmux session. The notes + metadata survive in workspaces.json for a future restore view.
func archiveWorkspace(tmuxIndex: Int, trash: Bool) {
    guard let list = sidebarList, let arrayIdx = tiles.firstIndex(where: { $0.index == tmuxIndex }) else { return }
    let tile = tiles[arrayIdx]
    let id = "insanitty-ws-\(tmuxIndex)"
    var m = metaFor(id)
    if trash { m.setTrashed(true, at: Date()) } else { m.setArchived(true, at: Date()) }
    workspaceMeta[id] = m; saveWorkspaceMeta()

    if let row = OP(gtk_list_box_get_row_at_index(P(list), Int32(arrayIdx))) { gtk_list_box_remove(P(list), P(row)) }
    if let stack = mainStack { gtk_stack_remove(P(stack), P(tile.page)) }
    tiles.remove(at: arrayIdx)
    runDetached("tmux kill-session -t \(id) 2>/dev/null")

    currentWorkspace = -1   // skip the freeze-old step in selectWorkspace; nothing valid to freeze
    if !tiles.isEmpty {
        let sel = min(arrayIdx, tiles.count - 1)
        gtk_list_box_select_row(P(list), P(OP(gtk_list_box_get_row_at_index(P(list), Int32(sel)))))
    }
    saveLayout()
}

nonisolated(unsafe) var contextMenuTmuxIndex = -1
nonisolated(unsafe) var contextPopover: OpaquePointer?

let archiveClickCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in
    if let p = contextPopover { gtk_popover_popdown(P(p)) }
    archiveWorkspace(tmuxIndex: contextMenuTmuxIndex, trash: false)
}
let trashClickCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in
    if let p = contextPopover { gtk_popover_popdown(P(p)) }
    archiveWorkspace(tmuxIndex: contextMenuTmuxIndex, trash: true)
}
let popClosedCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { pop, _ in
    gtk_widget_unparent(P(pop))
    if raw(contextPopover) == raw(pop) { contextPopover = nil }
}

/// Right-click a sidebar row → a popover with Archive / Move to Trash for that workspace.
let rowRightClickCb: @convention(c) (OpaquePointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void = { gesture, _, x, y, ud in
    contextMenuTmuxIndex = Int(bitPattern: ud)
    guard let widget = OP(gtk_event_controller_get_widget(P(gesture))) else { return }
    let pop = OP(gtk_popover_new())!
    let vbox = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 2))!
    for (label, cb) in [("Archive", archiveClickCb), ("Move to Trash", trashClickCb)] {
        let btn = OP(gtk_button_new_with_label(label))!
        gtk_button_set_has_frame(P(btn), 0)
        gtk_widget_set_halign(P(btn), GTK_ALIGN_FILL)
        g_signal_connect_data(raw(btn), "clicked", unsafeBitCast(cb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
        gtk_box_append(P(vbox), P(btn))
    }
    gtk_popover_set_child(P(pop), P(vbox))
    gtk_widget_set_parent(P(pop), P(widget))
    var rect = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
    gtk_popover_set_pointing_to(P(pop), &rect)
    g_signal_connect_data(raw(pop), "closed", unsafeBitCast(popClosedCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    contextPopover = pop
    gtk_popover_popup(P(pop))
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
    // Every workspace is a tmux control-mode session: tmux windows → tabs, tmux panes → splits,
    // so the within-workspace layout is owned by tmux and restored on relaunch.
    makeControlModeWorkspacePage(session: "insanitty-ws-\(index)", index: index)
}

/// An inert surface for a remote pane: rendered only by injected output (no shell of its own).
/// Ref-sunk so it survives re-parenting when the remote layout is (re)built.
/// Queue a keystroke for the remote pane; the next injectRemoteGrid fetch forwards it (sendKeys)
/// and asks for a fresh keyframe so the echoed result paints back.
let remoteKeyCb: @convention(c) (OpaquePointer?, guint, guint, GdkModifierType, UnsafeMutableRawPointer?) -> gboolean = { _, keyval, _, state, _ in
    guard let bytes = encodeTmuxKey(keyval: keyval, state: state) else { return 0 }
    remoteLock.lock(); pendingRemoteInput.append(contentsOf: bytes); remoteLock.unlock()
    // Predictive echo: paint the typed bytes into the active pane immediately, so input feels
    // instant; the next keyframe poll reconciles to the authoritative remote grid.
    if currentSettings.remotePredictiveEcho, let s = remotePaneSurfaces[remoteActivePane] {
        bytes.withUnsafeBytes { raw in
            insanitty_surface_inject_output(P(s), raw.bindMemory(to: CChar.self).baseAddress, bytes.count)
        }
    }
    return 1
}

func makeRemotePaneSurface() -> OpaquePointer? {
    guard let s = makeSilentTerminal() else { return nil }
    g_object_ref_sink(raw(s))
    let kc = OP(gtk_event_controller_key_new())
    gtk_event_controller_set_propagation_phase(P(kc), GTK_PHASE_CAPTURE)
    g_signal_connect_data(raw(kc), "key-pressed", unsafeBitCast(remoteKeyCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(P(s), P(kc))
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

/// Key pressed on a tmux -CC pane surface → forward to that workspace's active pane. The owning
/// ControlModeWorkspace is the controller's user_data, so each workspace routes to its own client.
let ctrlKeyCb: @convention(c) (OpaquePointer?, guint, guint, GdkModifierType, UnsafeMutableRawPointer?) -> gboolean = { _, keyval, _, state, ud in
    guard let ud = ud else { return 0 }
    let ws = Unmanaged<ControlModeWorkspace>.fromOpaque(ud).takeUnretainedValue()
    guard let pane = ws.client.inputPane, let bytes = encodeTmuxKey(keyval: keyval, state: state) else { return 0 }
    ws.client.sendKeys(pane: pane, bytes: bytes)
    return 1
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

/// One workspace driven by tmux control mode (`tmux -CC`): each tmux window is a tab, each tmux
/// pane a split surface. Owns the per-workspace control state (formerly global) so every workspace
/// can run its own session — splits become real tmux panes and the layout persists in tmux.
final class ControlModeWorkspace {
    let client: TmuxControlClient
    let tabView: OpaquePointer
    var windowContainers: [Int: OpaquePointer] = [:]
    var windowPanes: [Int: Set<Int>] = [:]
    var paneSurfaces: [Int: OpaquePointer] = [:]

    let sshTarget: String?
    let sshPort: Int?

    init(session: String, tabView: OpaquePointer, sshTarget: String? = nil, sshPort: Int? = nil) {
        client = TmuxControlClient(session: session)
        client.sshTarget = sshTarget
        client.sshPort = sshPort
        self.tabView = tabView
        self.sshTarget = sshTarget
        self.sshPort = sshPort
        client.surfaceForPane = { [unowned self] pane in
            if paneSurfaces[pane] == nil { paneSurfaces[pane] = makePaneSurface() }
            return paneSurfaces[pane]
        }
        client.onLayout = { [unowned self] window, tree in rebuildWindowPanes(window, tree) }
        client.onWindowClose = { [unowned self] window in closeWindowTab(window) }
    }

    /// Run a tmux query over the same transport (local or `ssh target`) and return stdout.
    func tmuxQuery(_ args: String) -> String {
        let prefix = sshTarget.map { "ssh \(sshPort.map { "-p \($0) " } ?? "")\($0) tmux" } ?? "tmux"
        return shellOutput("\(prefix) \(args)")
    }

    /// The default pane id (so keystrokes work before the first %output).
    func loadDefaultPane() {
        let paneRaw = tmuxQuery("list-panes -t \(client.session) -F '#{pane_id}' | head -1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if paneRaw.hasPrefix("%") { client.defaultPane = Int(paneRaw.dropFirst()) }
    }

    /// A silent pane surface whose keystrokes route to THIS workspace's client (user_data = self).
    func makePaneSurface() -> OpaquePointer? {
        guard let s = makeSilentTerminal() else { return nil }
        g_object_ref_sink(raw(s))
        let kc = OP(gtk_event_controller_key_new())
        gtk_event_controller_set_propagation_phase(P(kc), GTK_PHASE_CAPTURE)
        g_signal_connect_data(raw(kc), "key-pressed", unsafeBitCast(ctrlKeyCb, to: GCallback.self),
                              Unmanaged.passUnretained(self).toOpaque(), nil, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(P(s), P(kc))
        return s
    }

    /// Ensure a tab + pane-tree container exists for tmux window `window`; return its container.
    func ensureWindowTab(_ window: Int) -> OpaquePointer? {
        if let c = windowContainers[window] { return c }
        let box = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))!
        gtk_widget_set_vexpand(P(box), 1)
        windowContainers[window] = box
        let page = OP(adw_tab_view_append(P(tabView), P(box)))!
        adw_tab_page_set_title(P(page), "window @\(window)")
        return box
    }

    /// Lay out a tmux window's panes (its tab) as a GtkPaned tree of silent surfaces, reusing
    /// surfaces across relayouts so pane content persists.
    func rebuildWindowPanes(_ window: Int, _ tree: TmuxLayoutNode) {
        guard let container = ensureWindowTab(window) else { return }
        let newPanes = Set(tree.allPanes())
        let oldPanes = windowPanes[window] ?? []
        if newPanes == oldPanes { return }   // same panes, only sizes changed
        windowPanes[window] = newPanes
        for pane in oldPanes.union(newPanes) {
            if let s = paneSurfaces[pane], gtk_widget_get_parent(P(s)) != nil { gtk_widget_unparent(P(s)) }
        }
        while let old = OP(gtk_widget_get_first_child(P(container))) { gtk_box_remove(P(container), P(old)) }
        let widget = buildPaneTree(tree) { pane in
            if paneSurfaces[pane] == nil { paneSurfaces[pane] = makePaneSurface() }
            return paneSurfaces[pane]
        }
        if let widget = widget { gtk_box_append(P(container), P(widget)) }
        for pane in oldPanes.subtracting(newPanes) {
            if let s = paneSurfaces.removeValue(forKey: pane) {
                if gtk_widget_get_parent(P(s)) != nil { gtk_widget_unparent(P(s)) }
                g_object_unref(raw(s))
            }
        }
        FileHandle.standardError.write(Data("tmux-cc: window @\(window) → \(newPanes.count)-pane layout\n".utf8))
    }

    /// A tmux window closed → remove its tab and release its pane surfaces.
    func closeWindowTab(_ window: Int) {
        for pane in windowPanes[window] ?? [] {
            if let s = paneSurfaces.removeValue(forKey: pane) {
                if gtk_widget_get_parent(P(s)) != nil { gtk_widget_unparent(P(s)) }
                g_object_unref(raw(s))
            }
        }
        windowPanes.removeValue(forKey: window)
        if let container = windowContainers[window],
           let page = OP(adw_tab_view_get_page(P(tabView), P(container))) {
            adw_tab_view_close_page(P(tabView), P(page))
        }
        windowContainers.removeValue(forKey: window)
    }

    /// Query existing windows once (after attach) and build a tab per window from its layout.
    func buildExistingWindows() {
        for line in tmuxQuery("list-windows -t \(client.session) -F '#{window_id} #{window_layout}'")
            .split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].hasPrefix("@"), let window = Int(parts[0].dropFirst()),
                  let tree = TmuxLayoutParser.parse(String(parts[1])) else { continue }
            rebuildWindowPanes(window, tree)
        }
    }
}

/// Start a control-mode workspace's client once its container has realized, sizing tmux to it.
/// `user_data` is the ControlModeWorkspace (kept alive by `controlWorkspaces`).
let ctrlStartCb: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { ud in
    guard let ud = ud else { return 0 }
    let ws = Unmanaged<ControlModeWorkspace>.fromOpaque(ud).takeUnretainedValue()
    let w = Int(gtk_widget_get_width(P(ws.tabView))), h = Int(gtk_widget_get_height(P(ws.tabView)))
    if w > 0, h > 0 {
        ws.client.sizeCols = max(40, min(400, w / 8))   // ~8px per cell column
        ws.client.sizeRows = max(10, min(200, h / 17))  // ~17px per cell row
    }
    ws.client.start(); return 0
}

/// A tmux control-mode workspace: insanitty owns `tmux -CC` for `session`, mapping its windows to
/// tabs and panes to splits (so splits are real tmux panes and the layout persists in tmux).
/// `sshTarget` reaches the session over SSH; `create` (local only) makes the session if absent.
func makeControlModeWorkspacePage(session: String, index: Int, sshTarget: String? = nil,
                                  sshPort: Int? = nil, create: Bool = true) -> OpaquePointer? {
    if create, sshTarget == nil { runDetached("tmux new-session -A -d -s \(session)") }
    let vbox = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))!
    let tabView = OP(adw_tab_view_new())!
    gtk_widget_set_vexpand(P(tabView), 1)
    let tabBar = OP(adw_tab_bar_new())!
    adw_tab_bar_set_view(P(tabBar), P(tabView))
    gtk_box_append(P(vbox), P(tabBar))
    gtk_box_append(P(vbox), P(tabView))

    let ws = ControlModeWorkspace(session: session, tabView: tabView, sshTarget: sshTarget, sshPort: sshPort)
    controlWorkspaces[index] = ws
    ws.loadDefaultPane()
    ws.buildExistingWindows()
    g_timeout_add(1500, ctrlStartCb, Unmanaged.passUnretained(ws).toOpaque())
    return vbox
}

/// Attach to an existing tmux session (local, or remote via `target`/`port`) as a new workspace.
func attachWorkspace(session: String, sshTarget: String? = nil, sshPort: Int? = nil) {
    guard let list = sidebarList else { return }
    let idx = workspaceCounter; workspaceCounter += 1
    guard let page = makeControlModeWorkspacePage(session: session, index: idx, sshTarget: sshTarget, sshPort: sshPort, create: false) else { return }
    let label = sshTarget.map { "\($0):\(session)" } ?? session
    let tileIdx = registerWorkspace(page, name: label, id: "attach-\(idx)", index: idx)
    gtk_list_box_select_row(P(list), P(OP(gtk_list_box_get_row_at_index(P(list), Int32(tileIdx)))))
}

// MARK: - Attach picker (TmuxAttachSheet)

nonisolated(unsafe) var attachHostEntry: OpaquePointer?
nonisolated(unsafe) var attachList: OpaquePointer?
nonisolated(unsafe) var attachWindow: OpaquePointer?

/// The tmux command prefix for the attach picker's current host (local or `ssh …`).
func attachHostText() -> String {
    attachHostEntry.flatMap { gtk_editable_get_text(P($0)) }.map { String(cString: $0) } ?? ""
}

/// (Re)list tmux sessions for the entered host (local if blank) into the picker.
let attachRefreshCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in
    guard let list = attachList else { return }
    while let old = OP(gtk_widget_get_first_child(P(list))) { gtk_list_box_remove(P(list), P(old)) }
    let ssh = SSHTarget.parse(attachHostText())
    let prefix = ssh.map { "ssh \($0.port.map { "-p \($0) " } ?? "")\($0.target) tmux" } ?? "tmux"
    let out = shellOutput("\(prefix) list-sessions -F '#{session_name}:#{session_windows}' 2>/dev/null")
    var any = false
    for line in out.split(separator: "\n") {
        let parts = line.split(separator: ":").map(String.init)
        guard let name = parts.first, ssh != nil || (!name.hasPrefix("insanitty-ws-") && name != "insanitty-cc") else { continue }
        any = true
        let row = OP(adw_action_row_new())
        adw_preferences_row_set_title(P(row), name)
        if parts.count > 1 { adw_action_row_set_subtitle(P(row), "\(parts[1]) window(s)") }
        gtk_list_box_append(P(list), P(row))
    }
    if !any {
        let row = OP(adw_action_row_new()); adw_preferences_row_set_title(P(row), "No sessions found")
        gtk_list_box_append(P(list), P(row))
    }
}

/// Picked a session → attach it as a workspace and close the picker.
let attachRowCb: @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, rowPtr, _ in
    guard let row = rowPtr, let cstr = adw_preferences_row_get_title(P(row)) else { return }
    let name = String(cString: cstr)
    guard !name.isEmpty, name != "No sessions found" else { return }
    let ssh = SSHTarget.parse(attachHostText())
    attachWorkspace(session: name, sshTarget: ssh?.target, sshPort: ssh?.port)
    if let w = attachWindow { gtk_window_close(P(w)) }
}

/// Open the attach picker: list local/SSH tmux sessions and attach one as a workspace.
func openAttach() {
    let win = OP(adw_window_new())!
    attachWindow = win
    gtk_window_set_title(P(win), "Attach to tmux session")
    if let mw = mainWindow { gtk_window_set_transient_for(P(win), P(mw)); gtk_window_set_modal(P(win), 1) }
    gtk_window_set_default_size(P(win), 460, 480)
    let toolbar = OP(adw_toolbar_view_new())
    adw_toolbar_view_add_top_bar(P(toolbar), P(OP(adw_header_bar_new())))
    let vbox = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8))!
    for set in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom, gtk_widget_set_margin_start, gtk_widget_set_margin_end] { set(P(vbox), 8) }

    let hostBox = OP(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6))!
    let entry = OP(gtk_entry_new())!
    gtk_widget_set_hexpand(P(entry), 1)
    gtk_entry_set_placeholder_text(P(entry), "SSH host (user@host:port) — blank for local")
    attachHostEntry = entry
    g_signal_connect_data(raw(entry), "activate", unsafeBitCast(attachRefreshCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    let listBtn = OP(gtk_button_new_with_label("List"))!
    g_signal_connect_data(raw(listBtn), "clicked", unsafeBitCast(attachRefreshCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    gtk_box_append(P(hostBox), P(entry)); gtk_box_append(P(hostBox), P(listBtn))
    gtk_box_append(P(vbox), P(hostBox))

    let scroll = OP(gtk_scrolled_window_new())
    gtk_widget_set_vexpand(P(scroll), 1)
    let list = OP(gtk_list_box_new())!
    gtk_list_box_set_selection_mode(P(list), GTK_SELECTION_NONE)
    gtk_widget_add_css_class(P(list), "boxed-list")
    attachList = list
    g_signal_connect_data(raw(list), "row-activated", unsafeBitCast(attachRowCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    gtk_scrolled_window_set_child(P(scroll), P(list))
    gtk_box_append(P(vbox), P(scroll))

    adw_toolbar_view_set_content(P(toolbar), P(vbox))
    adw_window_set_content(P(win), P(toolbar))
    attachRefreshCb(nil, nil)   // initial local list
    gtk_window_present(P(win))
}

let attachBtnCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in openAttach() }

// MARK: - Sprites (Fly.io sprite CLI)

nonisolated(unsafe) var spriteWindow: OpaquePointer?
nonisolated(unsafe) var spriteList: OpaquePointer?
nonisolated(unsafe) var spriteNameEntry: OpaquePointer?

/// The resolved `sprite` CLI path, or nil if not installed.
func spriteCLIPath() -> String? {
    SpriteCommands.resolvePath(home: NSHomeDirectory()) { FileManager.default.isExecutableFile(atPath: $0) }
}

/// `sprite list` → trimmed, non-empty lines (sprite names).
func spriteListOutput() -> [String] {
    guard let path = spriteCLIPath(), let data = runProcess(path, SpriteCommands.listArgv) else { return [] }
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// Connect to a sprite as a new workspace: a control-mode tmux session whose pane runs the console.
func connectSprite(_ name: String) {
    guard let list = sidebarList, !name.isEmpty else { return }
    let path = spriteCLIPath() ?? "sprite"
    let session = "insanitty-sprite-\(name)"
    runDetached("tmux new-session -A -d -s \(session) '\(SpriteCommands.consoleCommand(spritePath: path, name: name))'")
    let idx = workspaceCounter; workspaceCounter += 1
    guard let page = makeControlModeWorkspacePage(session: session, index: idx, create: false) else { return }
    let tileIdx = registerWorkspace(page, name: "sprite:\(name)", id: "sprite-\(idx)", index: idx)
    gtk_list_box_select_row(P(list), P(OP(gtk_list_box_get_row_at_index(P(list), Int32(tileIdx)))))
}

/// (Re)list sprites into the picker (or a hint if the CLI is missing).
let spriteRefreshCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in
    guard let list = spriteList else { return }
    while let old = OP(gtk_widget_get_first_child(P(list))) { gtk_list_box_remove(P(list), P(old)) }
    let addHint: (String) -> Void = { text in
        let row = OP(adw_action_row_new()); adw_preferences_row_set_title(P(row), text); gtk_list_box_append(P(list), P(row))
    }
    guard spriteCLIPath() != nil else { addHint("sprite CLI not found — install the Fly.io sprite CLI"); return }
    let sprites = spriteListOutput()
    if sprites.isEmpty { addHint("No sprites — create one above"); return }
    for s in sprites {
        let row = OP(adw_action_row_new()); adw_preferences_row_set_title(P(row), s); gtk_list_box_append(P(list), P(row))
    }
}

/// Picked a sprite → connect it as a workspace.
let spriteRowCb: @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, rowPtr, _ in
    guard let row = rowPtr, let cstr = adw_preferences_row_get_title(P(row)) else { return }
    let name = String(cString: cstr)
    guard !name.contains("sprite CLI"), !name.hasPrefix("No sprites") else { return }
    connectSprite(name)
    if let w = spriteWindow { gtk_window_close(P(w)) }
}

/// Create a new sprite (`sprite create [name]`) and connect it.
let spriteCreateCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in
    guard let path = spriteCLIPath() else { return }
    let name = spriteNameEntry.flatMap { gtk_editable_get_text(P($0)) }.map { String(cString: $0) } ?? ""
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = runProcess(path, SpriteCommands.createArgv(name: trimmed.isEmpty ? nil : trimmed)) else { return }
    let created = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\n").last.map(String.init) ?? trimmed
    guard !created.isEmpty, created != "unknown" else { return }
    connectSprite(created)
    if let w = spriteWindow { gtk_window_close(P(w)) }
}

/// Open the sprites picker: create a sprite, or connect to an existing one.
func openSprites() {
    let win = OP(adw_window_new())!
    spriteWindow = win
    gtk_window_set_title(P(win), "Sprites")
    if let mw = mainWindow { gtk_window_set_transient_for(P(win), P(mw)); gtk_window_set_modal(P(win), 1) }
    gtk_window_set_default_size(P(win), 440, 460)
    let toolbar = OP(adw_toolbar_view_new())
    adw_toolbar_view_add_top_bar(P(toolbar), P(OP(adw_header_bar_new())))
    let vbox = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8))!
    for set in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom, gtk_widget_set_margin_start, gtk_widget_set_margin_end] { set(P(vbox), 8) }

    let createBox = OP(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6))!
    let entry = OP(gtk_entry_new())!
    gtk_widget_set_hexpand(P(entry), 1)
    gtk_entry_set_placeholder_text(P(entry), "New sprite name (optional)")
    spriteNameEntry = entry
    g_signal_connect_data(raw(entry), "activate", unsafeBitCast(spriteCreateCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    let createBtn = OP(gtk_button_new_with_label("Create & Connect"))!
    gtk_widget_add_css_class(P(createBtn), "suggested-action")
    g_signal_connect_data(raw(createBtn), "clicked", unsafeBitCast(spriteCreateCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    gtk_box_append(P(createBox), P(entry)); gtk_box_append(P(createBox), P(createBtn))
    gtk_box_append(P(vbox), P(createBox))

    let scroll = OP(gtk_scrolled_window_new())
    gtk_widget_set_vexpand(P(scroll), 1)
    let list = OP(gtk_list_box_new())!
    gtk_list_box_set_selection_mode(P(list), GTK_SELECTION_NONE)
    gtk_widget_add_css_class(P(list), "boxed-list")
    spriteList = list
    g_signal_connect_data(raw(list), "row-activated", unsafeBitCast(spriteRowCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    gtk_scrolled_window_set_child(P(scroll), P(list))
    gtk_box_append(P(vbox), P(scroll))

    adw_toolbar_view_set_content(P(toolbar), P(vbox))
    adw_window_set_content(P(win), P(toolbar))
    spriteRefreshCb(nil, nil)
    gtk_window_present(P(win))
}

let spritesBtnCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in openSprites() }

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
        if remoteRendered { return }   // the fixture is static — paint it once
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
    // Continuous streaming: connect once and HOLD the connection open, then re-poll it each tick so
    // the workspace auto-updates (the helper keeps its tmux client attached, so external output keeps
    // streaming). Queued keystrokes ride along. Skip if the previous poll is still running.
    remoteLock.lock()
    if remoteFetchInFlight { remoteLock.unlock(); return }
    remoteFetchInFlight = true
    remoteLock.unlock()
    Thread.detachNewThread {
        defer { remoteLock.lock(); remoteFetchInFlight = false; remoteLock.unlock() }
        // Steady state: reuse the held-open connection.
        if let session = remoteSession {
            remoteLock.lock(); let input = pendingRemoteInput; pendingRemoteInput = []; remoteLock.unlock()
            session.inputBytes = input
            session.repoll()
            session.inputBytes = []
            remoteLock.lock(); pendingFetcher = session; remoteLock.unlock()
            g_idle_add(remoteRenderIdle, nil)
            return
        }
        // First time: launch-or-resume the helper for a bootstrap, then connect + hold.
        let helper = FileManager.default.isExecutableFile(atPath: "build/fantastty-helper")
            ? "build/fantastty-helper" : "/tmp/fantastty-helper"
        // Opt in to a tmux-backed remote workspace (multi-pane + live input) by pointing at an
        // existing tmux session; otherwise the helper serves its default single-pane shell source.
        var launchArgs = ["launch-or-resume", "insanitty-remote-gui", "--ttl", "8h", "--key-ttl", "30s"]
        if let tmux = ProcessInfo.processInfo.environment["INSANITTY_REMOTE_TMUX"], !tmux.isEmpty {
            launchArgs += ["--tmux-session", tmux]
        }
        guard let bootData = runProcess(helper, launchArgs),
              let line = String(decoding: bootData, as: UTF8.self).split(separator: "\n")
                .map(String.init).first(where: { $0.hasPrefix("FANTASTTY_REMOTE ") }),
              let boot = try? RemoteBootstrapLine.parse(line) else {
            FileHandle.standardError.write(Data("insanitty: remote bootstrap failed\n".utf8)); return
        }
        let fetcher = RemoteQuicFetcher(bootstrap: boot)
        remoteLock.lock(); let input = pendingRemoteInput; pendingRemoteInput = []; remoteLock.unlock()
        fetcher.inputBytes = input   // workspaceID + inputPane are set inside fetch()
        guard fetcher.fetch(host: boot.host, port: boot.port, hold: true), !fetcher.keyframes.isEmpty else {
            fetcher.closeHeld(); return
        }
        fetcher.inputBytes = []
        remoteSession = fetcher
        remoteLock.lock(); pendingFetcher = fetcher; remoteLock.unlock()
        g_idle_add(remoteRenderIdle, nil)
    }
}

/// Main-thread tail of injectRemoteGrid: lay out the remote panes and paint each keyframe.
let remoteRenderIdle: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
    remoteLock.lock(); let fetcher = pendingFetcher; pendingFetcher = nil; remoteLock.unlock()
    if let fetcher = fetcher { renderRemoteWorkspace(fetcher); remoteRendered = true }
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

    // Rebuild the GtkPaned tree only when the layout / pane-set changes — otherwise the surfaces
    // stay put across polls (no flicker). A relayout forces a repaint of every pane.
    let sig = (layout ?? "leaf") + "|" + fetcher.keyframes.keys.sorted().map(String.init).joined(separator: ",")
    if sig != lastRemoteTreeSig {
        for (_, s) in remotePaneSurfaces where gtk_widget_get_parent(P(s)) != nil { gtk_widget_unparent(P(s)) }
        while let old = OP(gtk_widget_get_first_child(P(container))) { gtk_box_remove(P(container), P(old)) }
        let widget = buildPaneTree(tree) { pane in
            if remotePaneSurfaces[pane] == nil { remotePaneSurfaces[pane] = makeRemotePaneSurface() }
            return remotePaneSurfaces[pane]
        }
        if let widget = widget { gtk_box_append(P(container), P(widget)) }
        lastRemoteTreeSig = sig
        lastRemoteAnsi = [:]
        FileHandle.standardError.write(Data("insanitty: rendered \(fetcher.keyframes.count)-pane remote workspace (native QUIC)\n".utf8))
    }

    remoteActivePane = fetcher.snapshot?.panes.first(where: { $0.isActive })?.paneID
        ?? fetcher.keyframes.keys.sorted().first ?? 0

    // Paint only the panes whose content changed since the last poll. Skipping unchanged panes
    // avoids flicker AND lets a predictive-echo paint survive until the real keyframe differs.
    for (pane, kf) in fetcher.keyframes {
        guard let surface = remotePaneSurfaces[pane] else { continue }
        let ansiStr = RemoteGridRenderer.ansi(for: kf)
        if lastRemoteAnsi[pane] == ansiStr { continue }
        lastRemoteAnsi[pane] = ansiStr
        let ansi = Data(ansiStr.utf8)
        ansi.withUnsafeBytes { raw in
            insanitty_surface_inject_output(P(surface), raw.bindMemory(to: CChar.self).baseAddress, ansi.count)
        }
        if pane == remoteActivePane {
            let content = kf.rows.map { $0.cells.map { $0.text }.joined() }.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces).prefix(200)
            FileHandle.standardError.write(Data("insanitty: remote pane \(pane) content: \(content)\n".utf8))
        }
    }
}

/// Sidebar row selected → switch to that workspace.
let rowSelectedCb: @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, rowPtr, _ in
    guard let rowPtr = rowPtr else { return }
    selectWorkspace(Int(gtk_list_box_row_get_index(P(rowPtr))))
}

/// Header "Overview" button clicked → toggle the Exposé overview.
let overviewBtnCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in toggleOverview() }

/// Persist the current settings (best-effort).
func saveSettings() { try? SettingsStore.save(currentSettings, to: settingsURL) }

/// Appearance theme combo changed → apply live + persist.
let settingsThemeCb: @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { row, _, _ in
    let idx = Int(adw_combo_row_get_selected(P(row)))
    let mode = idx < AppearanceMode.allCases.count ? AppearanceMode.allCases[idx] : .system
    currentSettings.appearance = mode
    applyAppearance(mode)
    saveSettings()
}

/// A settings switch toggled → update the field tagged by user_data + persist.
let settingsSwitchCb: @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { row, _, ud in
    let active = adw_switch_row_get_active(P(row)) != 0
    switch Int(bitPattern: ud) {
    case 1: currentSettings.tabsInSidebar = active
    case 2: currentSettings.persistentSessions = active
    case 3: currentSettings.remotePredictiveEcho = active
    default: break
    }
    saveSettings()
}

/// A switch row bound to a settings field (selected by `tag`), initialized to `on`.
func makeSwitchRow(_ title: String, _ subtitle: String?, tag: Int, on: Bool) -> OpaquePointer? {
    let row = OP(adw_switch_row_new())!
    adw_preferences_row_set_title(P(row), title)
    if let subtitle = subtitle { adw_action_row_set_subtitle(P(row), subtitle) }
    adw_switch_row_set_active(P(row), on ? 1 : 0)
    g_signal_connect_data(raw(row), "notify::active", unsafeBitCast(settingsSwitchCb, to: GCallback.self),
                          UnsafeMutableRawPointer(bitPattern: tag), nil, GConnectFlags(rawValue: 0))
    return row
}

/// Open the preferences window: Appearance / Sidebar / Sessions / Remote Engine. Changes apply
/// and persist immediately (matching Fantastty's live SettingsView).
func openSettings() {
    let win = OP(adw_preferences_window_new())!
    if let mw = mainWindow { gtk_window_set_transient_for(P(win), P(mw)); gtk_window_set_modal(P(win), 1) }
    let page = OP(adw_preferences_page_new())!

    let appearance = OP(adw_preferences_group_new())!
    adw_preferences_group_set_title(P(appearance), "Appearance")
    let themeRow = OP(adw_combo_row_new())!
    adw_preferences_row_set_title(P(themeRow), "Theme")
    let model = OP(gtk_string_list_new(nil))
    for label in AppearanceMode.allCases.map({ $0.label }) { gtk_string_list_append(P(model), label) }
    adw_combo_row_set_model(P(themeRow), P(model))
    adw_combo_row_set_selected(P(themeRow), guint(AppearanceMode.allCases.firstIndex(of: currentSettings.appearance) ?? 0))
    g_signal_connect_data(raw(themeRow), "notify::selected", unsafeBitCast(settingsThemeCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    adw_preferences_group_add(P(appearance), P(themeRow))
    adw_preferences_page_add(P(page), P(appearance))

    let sidebar = OP(adw_preferences_group_new())!
    adw_preferences_group_set_title(P(sidebar), "Sidebar")
    adw_preferences_group_add(P(sidebar), P(makeSwitchRow("Show tab thumbnails in sidebar", nil, tag: 1, on: currentSettings.tabsInSidebar)))
    adw_preferences_page_add(P(page), P(sidebar))

    let sessions = OP(adw_preferences_group_new())!
    adw_preferences_group_set_title(P(sessions), "Sessions")
    adw_preferences_group_add(P(sessions), P(makeSwitchRow("Persistent terminal sessions", "Terminals run inside tmux; sessions survive app restarts.", tag: 2, on: currentSettings.persistentSessions)))
    adw_preferences_page_add(P(page), P(sessions))

    let remote = OP(adw_preferences_group_new())!
    adw_preferences_group_set_title(P(remote), "Remote Engine")
    adw_preferences_group_add(P(remote), P(makeSwitchRow("Predictive echo", "Show typed keys immediately, before the remote echoes them back.", tag: 3, on: currentSettings.remotePredictiveEcho)))
    adw_preferences_page_add(P(page), P(remote))

    adw_preferences_window_add(P(win), P(page))
    gtk_window_present(P(win))
}

let settingsBtnCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in openSettings() }

// MARK: - Session notes

nonisolated(unsafe) var notesList: OpaquePointer?
nonisolated(unsafe) var notesEntry: OpaquePointer?
nonisolated(unsafe) var notesWorkspaceID = ""

/// A note's timestamp as a short local date+time.
func noteTimeLabel(_ date: Date) -> String {
    let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
    return f.string(from: date)
}

/// Rebuild the notes list from the current workspace's metadata (oldest first; edits flagged).
func rebuildNotesList() {
    guard let list = notesList else { return }
    while let old = OP(gtk_widget_get_first_child(P(list))) { gtk_list_box_remove(P(list), P(old)) }
    let notes = workspaceMeta[notesWorkspaceID]?.notes ?? []
    if notes.isEmpty {
        let row = OP(adw_action_row_new())
        adw_preferences_row_set_title(P(row), "No notes yet")
        gtk_list_box_append(P(list), P(row))
        return
    }
    for note in notes {
        let row = OP(adw_action_row_new())
        adw_preferences_row_set_title(P(row), note.content)
        var subtitle = noteTimeLabel(note.timestamp)
        if !note.revisions.isEmpty { subtitle += "  · edited \(note.revisions.count)×" }
        adw_action_row_set_subtitle(P(row), subtitle)
        gtk_list_box_append(P(list), P(row))
    }
}

/// Append the typed note to the current workspace, persist, refresh the list.
let notesAddCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in
    guard let entry = notesEntry, let cstr = gtk_editable_get_text(P(entry)) else { return }
    let trimmed = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var m = metaFor(notesWorkspaceID)
    m.appendNote(content: trimmed, source: .user, at: Date())
    workspaceMeta[notesWorkspaceID] = m
    saveWorkspaceMeta()
    gtk_editable_set_text(P(entry), "")
    rebuildNotesList()
}

/// Open the per-workspace notes panel: a scrolling log of timestamped notes plus an add field.
func openNotes() {
    guard let wsID = currentWorkspaceID() else { return }
    notesWorkspaceID = wsID
    let name = currentWorkspace < tiles.count ? tiles[currentWorkspace].name : wsID
    let win = OP(adw_window_new())!
    gtk_window_set_title(P(win), "Notes — \(name)")
    if let mw = mainWindow { gtk_window_set_transient_for(P(win), P(mw)); gtk_window_set_modal(P(win), 1) }
    gtk_window_set_default_size(P(win), 440, 520)

    let toolbar = OP(adw_toolbar_view_new())
    adw_toolbar_view_add_top_bar(P(toolbar), P(OP(adw_header_bar_new())))
    let vbox = OP(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8))!
    for set in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom, gtk_widget_set_margin_start, gtk_widget_set_margin_end] { set(P(vbox), 8) }

    let scroll = OP(gtk_scrolled_window_new())
    gtk_widget_set_vexpand(P(scroll), 1)
    let list = OP(gtk_list_box_new())!
    gtk_list_box_set_selection_mode(P(list), GTK_SELECTION_NONE)
    gtk_widget_add_css_class(P(list), "boxed-list")
    notesList = list
    gtk_scrolled_window_set_child(P(scroll), P(list))
    gtk_box_append(P(vbox), P(scroll))

    let addBox = OP(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6))!
    let entry = OP(gtk_entry_new())!
    gtk_widget_set_hexpand(P(entry), 1)
    gtk_entry_set_placeholder_text(P(entry), "Add a note…")
    g_signal_connect_data(raw(entry), "activate", unsafeBitCast(notesAddCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    notesEntry = entry
    let addBtn = OP(gtk_button_new_with_label("Add"))!
    gtk_widget_add_css_class(P(addBtn), "suggested-action")
    g_signal_connect_data(raw(addBtn), "clicked", unsafeBitCast(notesAddCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    gtk_box_append(P(addBox), P(entry)); gtk_box_append(P(addBox), P(addBtn))
    gtk_box_append(P(vbox), P(addBox))

    adw_toolbar_view_set_content(P(toolbar), P(vbox))
    adw_window_set_content(P(win), P(toolbar))
    rebuildNotesList()
    gtk_window_present(P(win))
}

let notesBtnCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in openNotes() }

/// Persist the layout when the window is closing (returns PROPAGATE so the close proceeds).
let closeRequestCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> gboolean = { _, _ in
    saveLayout(); saveWorkspaceMeta(); return 0
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
        registerWorkspace(makeControlModeWorkspacePage(session: "insanitty-cc", index: -2)!, name: "tmux -CC", id: "ctrl", index: -2)
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

    // Test hook: attach a session on startup (what the attach picker does), e.g.
    // INSANITTY_ATTACH=name or INSANITTY_ATTACH=user@host:port/name — avoids clicking near live sessions.
    if let spec = ProcessInfo.processInfo.environment["INSANITTY_ATTACH"], !spec.isEmpty {
        if let slash = spec.lastIndex(of: "/"), let ssh = SSHTarget.parse(String(spec[..<slash])) {
            attachWorkspace(session: String(spec[spec.index(after: slash)...]), sshTarget: ssh.target, sshPort: ssh.port)
        } else {
            attachWorkspace(session: spec)
        }
    }

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
    let notesBtn = OP(gtk_button_new_from_icon_name("accessories-text-editor-symbolic"))!
    gtk_widget_set_tooltip_text(P(notesBtn), "Workspace notes")
    g_signal_connect_data(raw(notesBtn), "clicked", unsafeBitCast(notesBtnCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    adw_header_bar_pack_start(P(header), P(notesBtn))
    let attachBtn = OP(gtk_button_new_from_icon_name("network-server-symbolic"))!
    gtk_widget_set_tooltip_text(P(attachBtn), "Attach to a tmux session (local or SSH)")
    g_signal_connect_data(raw(attachBtn), "clicked", unsafeBitCast(attachBtnCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    adw_header_bar_pack_start(P(header), P(attachBtn))
    let spritesBtn = OP(gtk_button_new_from_icon_name("cloud-symbolic"))!
    gtk_widget_set_tooltip_text(P(spritesBtn), "Sprites (Fly.io)")
    g_signal_connect_data(raw(spritesBtn), "clicked", unsafeBitCast(spritesBtnCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    adw_header_bar_pack_start(P(header), P(spritesBtn))
    let settingsBtn = OP(gtk_button_new_from_icon_name("emblem-system-symbolic"))!
    gtk_widget_set_tooltip_text(P(settingsBtn), "Settings")
    g_signal_connect_data(raw(settingsBtn), "clicked", unsafeBitCast(settingsBtnCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    adw_header_bar_pack_end(P(header), P(settingsBtn))
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
        if ctrl && keyval == GDK_KEY_period { openNotes(); return 1 }                         // toggle notes
        if ctrl && keyval == GDK_KEY_grave { selectAdjacentWorkspace(shift ? -1 : 1); return 1 }  // prev/next workspace
        if ctrl && shift && keyval == GDK_KEY_Page_Down { selectAdjacentTab(1); return 1 }
        if ctrl && shift && keyval == GDK_KEY_Page_Up { selectAdjacentTab(-1); return 1 }
        if ctrl && shift && (keyval == GDK_KEY_w || keyval == GDK_KEY_W) { closeCurrentWorkspace(); return 1 }
        if ctrl && (keyval == GDK_KEY_w || keyval == GDK_KEY_W) { closeCurrentTab(); return 1 }
        if ctrl && shift && (keyval == GDK_KEY_a || keyval == GDK_KEY_A) { toggleCurrentAttention(); return 1 }
        if ctrl && shift && (keyval == GDK_KEY_f || keyval == GDK_KEY_F) { selectNextFlaggedWorkspace(); return 1 }
        return 0
    }
    let keyctl = OP(gtk_event_controller_key_new())
    gtk_event_controller_set_propagation_phase(P(keyctl), GTK_PHASE_CAPTURE)
    g_signal_connect_data(raw(keyctl), "key-pressed", unsafeBitCast(keyCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(P(win), P(keyctl))
    g_signal_connect_data(raw(win), "close-request", unsafeBitCast(closeRequestCb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))

    gtk_window_present(P(win))

    // Poll the remote helper: fetch + render until the workspace has painted once (the surface
    // realizes slightly after the window maps), then idle until keystrokes are queued — each fetch
    // forwards queued input and repaints the echoed result. injectRemoteGrid early-returns when
    // rendered with nothing pending, so the steady-state poll is just a flag check.
    let injectCb: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        injectRemoteGrid(); return 1
    }
    g_timeout_add(1500, injectCb, nil)

    // Accumulate active (focused) time onto the current workspace.
    lastActiveTick = Date()
    g_timeout_add(5000, activeTimeCb, nil)
}

setvbuf(stdout, nil, Int32(_IONBF), 0)
// insanitty supplies its own window. Ghostty's embedding lib (artifact == .lib) already gates
// off its own default window (see the `embedded` check in the GTK Application), so there's
// nothing to configure here.
guard let a = insanitty_app_init() else {
    FileHandle.standardError.write(Data("insanitty: app_init failed\n".utf8)); exit(1)
}
gapp = OP(a)
insanitty_set_osc_handler(oscHandlerCb)
applyAppearance(currentSettings.appearance)
buildWindow()

if ProcessInfo.processInfo.environment["INSANITTY_SMOKE"] != nil {
    let quit: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
        insanitty_app_quit(); return 0
    }
    g_timeout_add(30000, quit, nil)
}
insanitty_app_run()
