# 05 — Splits, Sidebar, Tab Bar, Notes, Settings & Overall UI/UX

## 1. Scope

### Files read in full (in-scope)
- `Fantastty/Splits/SplitTree.swift` (1362 lines) — the immutable split-tree model.
- `Fantastty/Splits/SplitView.swift` (196) — SwiftUI two-pane renderer + divider drag math.
- `Fantastty/Splits/SplitView.Divider.swift` (119) — divider widget, cursor, a11y.
- `Fantastty/Splits/TerminalSplitTreeView.swift` (257) — recursive tree → view, zoom, drag-to-split drop zones.
- `FantasttyTests/SplitLayoutPipelineTests.swift` (492) — pixel-allocation / tmux feedback-loop tests.
- `Fantastty/Views/Sidebar/SidebarView.swift` (245), `SidebarRowView.swift` (161), `SidebarThumbnailView.swift` (141), `NewSessionMenu.swift` (29).
- `Fantastty/Views/Terminal/TabBarView.swift` (104), `SessionDetailView.swift` (331), `TabThumbnailPanel.swift` (269), `WorkspaceOverviewView.swift` (112), `EditableToolbarTitle.swift` (73).
- `Fantastty/Views/Notes/SessionNotesPanel.swift` (862).
- `Fantastty/Views/Settings/SettingsView.swift` (108).
- `Fantastty/Views/Tmux/TmuxAttachSheet.swift` (214), `Views/SSH/SSHConnectionSheet.swift` (83), `Views/Sprite/SpriteConnectionSheet.swift` (176), `Views/Browser/BrowserTabView.swift` (125).

### Supporting files read (out of scope, for integration context)
- `Fantastty/Views/MainWindow.swift` (39) — `NavigationSplitView` host + sheet presentation.
- `Fantastty/App/AppCommands.swift` (198) — full keyboard-shortcut surface.
- `Fantastty/GhosttyBridge/SurfaceView+Transferable.swift` (59), `SurfaceDragSource.swift` (268), `Transferable+Extension.swift` (58), `SurfaceGrabHandle.swift` (41), `SurfaceView.swift` §200–260 — drag/drop + grab handle wiring.
- `Fantastty/Models/SessionManager.swift` (split/close/note routing excerpts), `Session.swift` §90–180 (notes/attention API), `SessionMetadata.swift` §1–40 + note helpers, `TerminalTab.swift` §1–110, `AppearanceMode.swift`, `Resources/shell-integration/fantastty.sh`.

### NOT covered
- Ghostty surface rendering internals (Metal/`SurfaceView_AppKit`, tmux control-mode wiring) — owned by other reports.
- `SessionManager`/`SessionMetadataStore` persistence internals, tmux/remote engine, Linear/Sprite service logic — referenced only where the UI depends on them.
- The vendored `vendor/ghostty` tree is **empty in this checkout** (only `GhosttyKit.xcframework` is consumed), so Ghostty's own GTK frontend could not be inspected directly; reuse claims about it are from the brief, not verified here.

---

## 2. What it does (behavior & features)

### 2.1 Splits (panes within a tab)
A tab's content is a **binary split tree** of terminal surfaces. User-facing behavior:

- **Create a split**: `⌘D` splits right, `⌘⇧D` splits down (`AppCommands.swift:36-46`). Menu items disable themselves when a split isn't allowed (`canPerformSplitOnFocusedSurface`). New splits always start at **ratio 0.5** (`SplitTree.swift:542`). Note: in attached tmux workspaces the split is actually executed by tmux (`SessionManager.performSplit:1522`) and the app only renders the resulting layout; `splitPaneIDIfAllowed` only permits right/down splits to map onto a tmux pane, and split is disabled for remote-engine sessions and sessions without a control client (`SessionManager.swift:1543-1572`).
- **Resize**: drag the divider (`SplitView.swift:92-105`). Minimum pane size is **34 pt (~2 cell rows)** (`SplitView.swift:30`), enforced so a pane never collapses; ratio is also clamped to **0.1–0.9** in keyboard/programmatic resize (`SplitTree.swift:306-315`). Resize increments can snap to the cell grid (`resizeIncrements`, `SplitView.swift:115`).
- **Equalize**: **double-click the divider** (`SplitView.swift:64-66`) → `ghostty.splitEqualize`. Equalization weights each split by leaf count along its axis (`SplitTree.equalize`, `:678-729`).
- **Zoom**: a node can be "zoomed" to fill the whole tab area; `TerminalSplitTreeView` renders `tree.zoomed ?? tree.root` (`:33`). Driven by Ghostty `toggle_split_zoom`.
- **Focus navigation**: spatial (`up/down/left/right`) and ordinal (`previous/next`, wrapping). Spatial picks the nearest leaf by Euclidean distance between slot top-left corners (`SplitTree.swift:1026-1072`). Unfocused panes in a split dim with a translucent overlay (`SurfaceView.swift:223-231`).
- **Close**: closing a leaf promotes its sibling into the parent's place (`SplitTree.removing` / `Node.remove`, `:140-155`, `:597-633`); closing the last leaf closes the tab (`SessionManager.closeSurface:1278-1281`).
- **Drag-to-split (drop reorder)**: each pane shows a **grab handle** — a 10 pt strip at the pane top that reveals an `ellipsis` glyph on hover (`SurfaceGrabHandle.swift`). Dragging a pane onto another pane shows a **half-pane highlight overlay** indicating one of four drop zones (top/bottom/left/right), chosen by which edge the cursor is nearest via diagonal triangular regions (`TerminalSplitTreeView.swift:194-220`). Dropping moves the dragged surface out of its old position and re-inserts it as a new split at the destination (`SessionDetailView.handleSplitOperation:292-307`). Dropping on self is rejected; `Esc` cancels; releasing outside any window posts `ghosttySurfaceDragEndedNoTarget` (for "tear-off") (`SurfaceDragSource.swift:224-256`).
- **Persistence**: the tree is `Codable` (versioned, `version == 1`); the zoomed node is stored as a path and re-resolved on decode (`SplitTree.swift:346-396`).

### 2.2 Sidebar (workspace list)
- A `List` of workspaces (sessions) with single-selection bound to `selectedSessionID` (`SidebarView.swift:15`). Each row (`SidebarRowView`) shows: an **attention dot** (orange) + bold title when flagged, a **session-type icon** (local/ssh/sprite), title with truncation, tab-count badge `(n)` when >1 tab, SSH `user@host` or `sprite: name` subtitle, and a **"missing backing" warning triangle** when the tmux session is gone.
- **Drag-to-reorder** workspaces via `ForEach(...).onMove` (`SidebarView.swift:53-55`).
- **Hover actions** per row: toggle-attention bell, close (`SidebarRowView.swift:79-103`).
- **Context menu** per workspace: Show Overview, Edit Notes…, Flag/Clear Attention, Archive Workspace, Destroy Sprite… (sprite only, with confirm alert), Close Workspace (`SidebarRowView.swift:114-159`).
- **Tabs-in-sidebar mode** (`tabsInSidebar` setting): each workspace gets a manual disclosure chevron; expanding shows **live tab thumbnails** inline, indented (`SidebarView.swift:17-47`, `SidebarTabThumbnails`).
- **Archived / Trashed sections**: collapsible `Section`s (hidden by default behind `showArchived`/`showTrashed`), each row with Unarchive/Restore and Delete-Permanently (destructive, confirm alert) context items (`SidebarView.swift:57-106`).
- **Bottom bar** (`safeAreaInset`): "Archived (n)" and "Trashed (n)" eye-toggles, an **Empty Trash** button (confirm alert), and a **"New Workspace" menu** (New Workspace / New SSH Workspace… / Attach to tmux Session…) on `.regularMaterial` (`SidebarView.swift:110-183`).
- Destructive actions use `.alert` dialogs explaining permanence (`SidebarView.swift:184-217`).

### 2.3 Tab bar (tabs within a workspace)
- Shown only when a workspace has **>1 tab** (`SessionDetailView.swift:36`); a horizontal `ScrollView` of tab chips (`TabBarView.swift`). Each chip: type icon, title, close-on-hover/selected, selected styling (filled rounded rect + border). Trailing **"+" new-tab menu**: New Tab / New Browser Tab (`TabBarView.swift:25-43`).
- Tab keyboard surface (`AppCommands.swift`): `⌘T` new tab, `⌘B` new browser tab, `⌘⇧[` / `⌘⇧]` prev/next tab, `⌘1`–`⌘9` jump to tab, `⌘W` close tab.

### 2.4 Tab previews / overview (live thumbnails)
Three surfaces consume the same live snapshots:
- **Right thumbnail panel** (`TabThumbnailPanel`, 160 pt wide) — header "Tabs (n)", scrollable list of previews; toggled by a toolbar button; hidden in tabs-in-sidebar mode (`SessionDetailView.swift:64-68,113-124`).
- **Sidebar thumbnails** (`SidebarThumbnailView`) — used in tabs-in-sidebar mode.
- **Workspace Overview** (`WorkspaceOverviewView`) — an **Exposé-style `LazyVGrid`** (1–4 columns by tab count) shown when no tab is selected (`session.selectedTabID == nil`); tiles hover-scale 1.03 + shadow and animate selection. Toggled by the `square.grid.2x2` toolbar button (`SessionDetailView.swift:97-111`).
- Snapshots: terminal panes are composited via `TerminalThumbnailRenderer` (unions leaf frames, draws each surface's `asImage` onto a black canvas, resizes to target) (`TabThumbnailPanel.swift:6-80`); browser tabs use `WKWebView.takeSnapshot`. Refresh is **debounced 150 ms** off a per-tab `thumbnailRefreshes` publisher, **suspended during scroll** and when the session isn't active (`TabThumbnailPanel.swift:233-243`, `SidebarThumbnailView.swift:67-70`).

### 2.5 Notes panel
- Toggled by `⌘.` or the toolbar `doc.text` button; renders as a **material overlay dropping from the top** of the terminal area with rounded bottom corners + shadow (`SessionDetailView.swift:70-75`, `SessionNotesPanel.swift:79-84`).
- Contents: **time stats** (Open = wall-clock since creation; Active = accumulated active seconds, live-ticking each minute), optional **Linear ticket detail** (issue/project state, assignee, priority, sub-issues, progress bar — fetched async via `.task`), editable **Ticket URL / PR URL** fields with open-in-browser buttons, a **timestamped Notes Log**, an **add-note** field, and **tags** chips (`SessionNotesPanel.swift:86-273`).
- **Note entries** (`NoteEntryRow`): source icon+color (terminal=green, user=blue, system=orange), time (short on idle, full date on hover), inline `#tags`, a **revision-count button** that expands revision history, edit (double-click or pencil → inline `TextField`, commit on submit/blur, `Esc` cancels), delete (`SessionNotesPanel.swift:276-451`). Editing saves the prior content as a `NoteRevision`. Log auto-scrolls to the newest entry.
- **Escape-sequence-driven notes**: the bundled `fantastty-note` / `fn` shell function emits **OSC 9** `\e]9;fantastty:note;<content>\a` (with tmux `\ePtmux;…` and GNU screen passthrough variants) (`fantastty.sh`). Ghostty surfaces this; `SessionManager.handleSessionNote` appends it with `source: .terminal` and **flags the workspace for attention if it isn't the foreground one** (`SessionManager.swift:1662-1672`). Notes/URLs/tags persist in `SessionMetadata` (Codable). A second `SessionNotesPopover` variant exists for quick access (name + notes + save).

### 2.6 Settings
A grouped `Form` (`SettingsView.swift`): **Appearance** segmented picker (System/Light/Dark) that calls `AppearanceMode.applyCurrent()` and pushes the scheme into libghostty (`ghostty_app_set_color_scheme`); **Sidebar** toggle (tab thumbnails in sidebar); **Sessions** toggle (persistent tmux sessions, disabled + guidance text when tmux absent); **Remote Engine** predictive-echo toggle; **Integrations** Linear API-key `SecureField` (stored in Keychain). Fixed 450 pt width.

### 2.7 Connection sheets (modal dialogs), presented at the window level
- **SSHConnectionSheet** — host/user/port fields + "Remote engine" toggle; `Connect` disabled until host present; pure `connectionTarget(...)` maps to `.ssh` or `.remoteEngine` (`SSHConnectionSheet.swift`).
- **TmuxAttachSheet** — Local/SSH segmented picker; on SSH, `user@hostname:port` field + remote-engine toggle; **session discovery** runs on a detached task with `ProgressView`, a live filter field, and a list of sessions with window counts; sessions already attached are filtered out; Refresh re-discovers (`TmuxAttachSheet.swift`).
- **SpriteConnectionSheet** — detects the `sprite` CLI (shows install hint if missing); lists existing sprites (selectable), name field, "Create & Connect" (async create with overlay spinner + error text) and "Connect" (`SpriteConnectionSheet.swift`).
- All three are presented as `.sheet` from `MainWindow.swift:24-37`; `NewSessionMenu` / `AppCommands` flip the `show*Sheet` booleans on `SessionManager` (`⌘⇧K` SSH, `⌘⌥K` Sprite).

### 2.8 Browser tab
`BrowserTabView` — URL bar (back/forward/reload/open-in-system-browser + editable URL field that prepends `https://`), `WKWebView` content; navigation delegate updates tab title/URL (`BrowserTabView.swift`).

### 2.9 Editable toolbar title
`EditableToolbarTitle` — the workspace name in the toolbar is a borderless `NSTextField` that becomes editable on click; commit writes `session.name` (`EditableToolbarTitle.swift`, `SessionDetailView.swift:78-82`).

---

## 3. How it's built (architecture)

### 3.1 SplitTree — immutable value-type binary tree
`struct SplitTree<ViewType: NSView & Codable & Identifiable>` (`SplitTree.swift:4`). Core type:
```
indirect enum Node { case leaf(view), case split(Split{direction,ratio,left,right}) }
```
- **Value semantics**: every mutation (`inserting`, `removing`, `replacingNode`, `resizing`, `equalized`) returns a *new* tree; the recursive `replacingNode` rebuilds the spine because enums can't be mutated in place (`:551-593`). Leaf equality is **object identity** (`leftView === rightView`, `:1113`).
- **`Path`** (`[.left/.right]`) addresses nodes; used to (re)locate the zoomed node across encode/decode and to find the nearest parent split of a given axis during resize (`:276-291`).
- **`Spatial`** (`:45-64`, `:817-1106`) projects the logical tree into relative `CGRect` slots (either from real bounds or a synthetic grid where each leaf is 1×1) to power spatial focus navigation and edge-border tests.
- **`StructuralIdentity`** (`:1221-1361`) is a `Hashable` view of structure+leaf-identity **excluding ratios**; `TerminalSplitTreeView` applies it via `.id(node.structuralIdentity)` so SwiftUI rebuilds on structure change but not on every resize — a deliberate fix for an upstream Ghostty identity bug (`TerminalSplitTreeView.swift:38-43`).
- Conforms to `Sequence`/`Collection` over leaves. This file is **almost entirely platform-independent algorithm** (see §6).

### 3.2 Rendering pipeline
`TabContentView` → `TerminalSplitTreeView(tree, action)` → recursive `TerminalSplitSubtreeView`:
- `.leaf` → `TerminalSplitLeaf` wrapping `Ghostty.InspectableSurface` + drop target.
- `.split` → `SplitView(direction, Binding<ratio>, …) { left } { right }` where the ratio setter dispatches a `.resize` **operation** (not a binding mutation) back to the embedder (`TerminalSplitTreeView.swift:65-85`). The tree is immutable, so all mutations go through the `TerminalSplitOperation` enum (`resize`/`drop`) handled in `SessionDetailView.handleSplitOperation` (`:283-330`).
- `SplitView` is a pure SwiftUI `GeometryReader` layout: it computes `leftRect`/`rightRect`/`splitterPoint`, offsets two child frames in a `ZStack`, and overlays the `Divider` with a `DragGesture` (`SplitView.swift:40-162`). The divider has a 1 pt visible line and a 6 pt invisible hit-box, sets a resize pointer, and exposes an a11y adjustable action (`SplitView.Divider.swift`).

### 3.3 Drag & drop (pane reorder / split)
A bespoke bridge between SwiftUI DnD and AppKit dragging:
- **Source**: `SurfaceGrabHandle` → `SurfaceDragSource` → an `NSView`/`NSDraggingSource` (`SurfaceDragSource.swift`). It consumes `mouseDown` to avoid window-drag, starts an `NSDraggingSession` on `mouseDragged` with a 0.2-scaled snapshot as the drag image, monitors `Esc` (keyCode 53), and publishes the dragged surface id via the `DraggingSurfaceKey` SwiftUI `PreferenceKey`.
- **Payload**: `Ghostty.SurfaceView: Transferable` encodes the **16-byte UUID** under custom UTI `com.mitchellh.ghosttySurfaceId`; import resolves it back to the live view via `NSApp.delegate.ghosttySurface(id:)` (`SurfaceView+Transferable.swift`). `Transferable+Extension.swift` bridges `Transferable` → `NSPasteboardItem` with a **`DispatchSemaphore`** to satisfy AppKit's synchronous data-provider contract.
- **Target**: `SplitDropDelegate` (`DropDelegate`) computes the live drop zone on `dropEntered/Updated`, and on `performDrop` loads the `Transferable` async and dispatches a `.drop` operation (`TerminalSplitTreeView.swift:138-191`). A leaf hides its own drop zone while it is the one being dragged (`onPreferenceChange(DraggingSurfaceKey)`).

### 3.4 App shell, data flow, threading
- `MainWindow` = `NavigationSplitView { SidebarView } detail: { SessionDetailView }` (balanced style), with the three connection sheets attached (`MainWindow.swift`). `.id(session.id)` forces detail recreation on workspace switch.
- State flows through `@EnvironmentObject SessionManager` (sessions, selection, sheet flags, `notesExpanded`) and `@EnvironmentObject Ghostty.App`; per-row reactivity uses `@ObservedObject Session`/`TerminalTab` (`ObservableObject` with `@Published`/manual `objectWillChange`). Persisted UI prefs use `@AppStorage` (`tabsInSidebar`, `showArchivedSessions`, `appearance`, `persistentSessions`, predictive echo).
- Notes/attention/URLs/tags are **computed accessors over `SessionMetadata`** persisted through `SessionMetadataStore.shared` (`Session.swift:96-180`).
- Thumbnails: `TerminalTab.thumbnailRefreshes` is a Combine `PassthroughSubject<Void,Never>`; views `.onReceive(...debounce(150ms, RunLoop.main))`. Snapshot capture (`bitmapImageRepForCachingDisplay`/`cacheDisplay`) runs on the main actor; thumbnail assignment is dispatched to main.
- Keyboard surface lives entirely in `AppCommands` `Commands` (replacing `.newItem`, `.pasteboard`, `.windowArrangement`, `.windowSize`, plus custom `Workspace`/`Debug` menus). Copy/paste special-cases tmux panes by sending keys through the control client (`AppCommands.swift:49-71`).

---

## 4. Platform dependencies (macOS-specific)

**SwiftUI (AppKit-backed):** `NavigationSplitView`/`.navigationSplitViewStyle(.balanced)`; `List(selection:)` + `.listStyle(.sidebar)`; `.sheet`, `.alert`, `.contextMenu`, `Menu`/`.menuStyle(.borderlessButton)`/`.menuIndicator`; `.toolbar`/`ToolbarItem(.navigation/.primaryAction)`; `Form`/`.formStyle(.grouped)`; `Picker(.segmented)`; `SecureField`; `.safeAreaInset`; `GeometryReader`; `ScrollViewReader`; `LazyVGrid`/`LazyVStack`; `.onHover`; `.onDrop`/`DropDelegate`/`DropProposal`/`DropInfo`; `PreferenceKey`; `.background(.regularMaterial)` + `UnevenRoundedRectangle`; `@AppStorage`; `@FocusState`; `.keyboardShortcut`; `Commands`/`CommandGroup`/`CommandMenu`; `.accessibility*` adjustable actions; SF Symbols (`Image(systemName:)`) everywhere; `Color(nsColor:)` semantic colors (`controlBackgroundColor`, `selectedContentBackgroundColor`, `separatorColor`, `windowBackgroundColor`).

**AppKit:** `NSView` (the entire `SplitTree` `ViewType` constraint), `NSImage`/`NSColor`/`NSBezierPath`, `NSCursor` (`resizeLeftRight`/`resizeUpDown`/`openHand`/`closedHand`), `NSFont`, `NSTextField`+`NSTextFieldDelegate` (editable title), `NSToolbar`/`NSToolbarItem.isBordered`, `NSWorkspace.shared.open(url)`, `NSPasteboard`/`NSPasteboardItem`/`NSPasteboardItemDataProvider`, `NSItemProvider`, `NSDraggingSession`/`NSDraggingSource`/`NSDraggingItem`, `NSEvent.addLocalMonitorForEvents` (Esc keyCode 53), `NSTrackingArea`, `NSApplication`/`NSWindow` notifications (`didBecomeActive`, `didBecomeKey`), `NSAppearance(.aqua/.darkAqua)`, `bitmapImageRepForCachingDisplay`/`cacheDisplay` (NSView snapshot).

**WebKit:** `WKWebView`, `WKNavigationDelegate`, `WKSnapshotConfiguration`/`takeSnapshot`.

**CoreTransferable / UniformTypeIdentifiers:** `Transferable`, `DataRepresentation`, `UTType(exportedAs: "com.mitchellh.ghosttySurfaceId")`.

**Combine:** `PassthroughSubject`, `Timer.publish`, `.debounce`, `.onReceive` — **note Combine is Apple-proprietary and has no Linux build.**

**Foundation / OS:** `DateFormatter`/`ISO8601DateFormatter`, `NotificationCenter`, `UserDefaults`, `os.Logger`, `DispatchSemaphore`/`DispatchQueue`. (Most Foundation types exist on Linux via swift-corelibs-foundation; `os.Logger` does not.)

**GhosttyKit (C):** `ghostty_app_set_color_scheme`, `ghostty_surface_binding_action` — already cross-platform C API.

**Keychain:** Linear API key storage (via `LinearService`).

---

## 5. Linux mapping (GTK4 / libadwaita)

| macOS construct | Linux-native equivalent | Notes / risk |
|---|---|---|
| `NavigationSplitView` (.balanced) | `AdwOverlaySplitView` or `AdwNavigationSplitView` | Collapse/show + width semantics differ; sidebar behavior needs deliberate mapping. |
| `List(selection:)` + `.listStyle(.sidebar)` | `GtkListBox` (or `GtkListView`+selection model) in `AdwNavigationView` | No native row hover-action affordance; build with hover controllers. |
| `ForEach.onMove` (reorder) | `GtkListBox` + `GtkDragSource`/`GtkDropTarget` row reordering | No built-in `onMove`; implement reorder by hand. |
| `.contextMenu` | `GtkPopoverMenu` + `GMenu` via right-click `GtkGestureClick` | Straightforward. |
| `Menu`/`MenuButton` ("+", New Workspace) | `GtkMenuButton` + `GMenu` | Straightforward. |
| `.sheet` (connection dialogs) | `AdwDialog` presented modally (or `GtkWindow` modal) | Straightforward; forms map to `GtkEntry`/`GtkPasswordEntry`. |
| `.alert` (destructive confirms) | `AdwAlertDialog` | Direct fit. |
| `.toolbar` / titlebar | `AdwHeaderBar` | Window controls handled by compositor. |
| `EditableToolbarTitle` (`NSTextField` click-to-edit) | **`GtkEditableLabel`** in the header bar | Near-exact native analogue (label that edits on click). |
| `Form`/`.formStyle(.grouped)` + `Section` | `AdwPreferencesPage`/`AdwPreferencesGroup`/`AdwActionRow` | Settings map cleanly. |
| `Picker(.segmented)` (appearance) | `AdwToggleGroup` (libadwaita ≥1.7) or radio buttons | — |
| `SecureField` | `GtkPasswordEntry` | — |
| `SplitView` (GeometryReader two-pane) | **nested `GtkPaned`** (native draggable divider, cursor, min-size) *or* custom `GtkFixed` replicating the ratio math | GtkPaned is the natural fit but mapping the immutable `SplitTree` ratios ↔ paned positions needs a sync layer; see §7. |
| Divider cursor (`NSCursor.resize*`) | `GtkPaned` built-in, or `gdk_cursor_new_from_name("ew-resize"/"ns-resize")` | — |
| Grab handle cursor (`open/closedHand`) | `gdk_cursor_new_from_name("grab"/"grabbing")` | — |
| `Transferable`/`NSDraggingSession`/pasteboard | `GtkDragSource`+`GtkDropTarget` with `GdkContentProvider`; payload as custom mime `application/x-ghostty-surface-id` | Drag preview via `gtk_drag_source_set_icon(GdkPaintable)`; `Esc`-cancel is built in; the 4-zone geometry ports as-is. |
| `NSView` snapshot (`cacheDisplay`) for thumbnails | Render the surface's **GL FBO to a `GdkTexture`** (glReadPixels / render-to-texture) | **RISK** — no cheap widget-snapshot for a GL surface; live thumbnails need explicit framebuffer capture. |
| `WKWebView` + `takeSnapshot` | **WebKitGTK** `WebKitWebView` + `webkit_web_view_get_snapshot`; nav via `load-changed`/`notify::title`/`notify::uri` signals | Direct WebKitGTK analogue. |
| `.regularMaterial` blur + shadow + rounded corners | libadwaita/GTK CSS (`box-shadow`, `border-radius`); blur not native | Drop blur or fake it; cosmetic. |
| SF Symbols | Named icons from the icon theme (`Adwaita`/`symbolic`) or bundled symbolic SVGs | Need an icon mapping table. |
| `Color(nsColor: .semantic)` | libadwaita named/CSS theme colors | — |
| `@AppStorage`/`UserDefaults` | `GSettings` (GSchema) or XDG config file | Foundation `UserDefaults` also exists on Linux if staying in Swift. |
| `NSAppearance` + `ghostty_app_set_color_scheme` | `AdwStyleManager` color-scheme (`FORCE_LIGHT`/`PREFER_DARK`/`DEFAULT`) + same C call | — |
| `NSWorkspace.open(url)` | `GtkUriLauncher` / `gtk_show_uri` / `xdg-open` | — |
| Keychain (Linear key) | **libsecret / Secret Service** | — |
| `Combine` (`PassthroughSubject`, `Timer.publish`, `.debounce`) | **OpenCombine**, or GObject signals + `g_timeout_add` debounce | **RISK** — Combine has no Linux port; reactive plumbing must be replaced. |
| `os.Logger` | `swift-log` or `g_log` | — |
| `NotificationCenter` (bell/note/key routing) | GObject signals or a custom event bus (Foundation `NotificationCenter` also works on Linux) | — |
| `⌘`-based shortcuts | Remap to Linux idioms (Ctrl/Super) via `GtkShortcutController`/`GMenu` accels | The whole accelerator set needs re-design for Linux conventions. |

---

## 6. Reuse assessment

**Ports largely as-is (cross-platform Swift logic — keep if the port stays in Swift):**
- **`SplitTree.swift` in its entirety** — insert/remove/replace/equalize/resize, `Path`, `Spatial` navigation, Codable, `StructuralIdentity`. The only macOS coupling is the `ViewType: NSView` generic bound, leaf identity via `===`, and `view.bounds.size`/`view.frame` reads; replace `NSView` with the Linux surface-widget type (or an abstract `protocol SplitLeaf: AnyObject & Codable & Identifiable { var sizeForLayout: CGSize }`). This is the single most valuable reusable asset in the subsystem.
- **`TerminalSplitDropZone.calculate`** and the drop-overlay geometry — pure math.
- **`SplitView` pixel math** (`leftRect`/`rightRect`/min-size/cell-snap) and the whole **`SplitLayoutPipelineTests`** — pure functions; keep as the spec/oracle for whatever Linux layout backend is chosen (GtkPaned must reproduce the 34 pt min + cell-snap + 0.1–0.9 clamp to keep tmux layout stability the tests guard).
- **Nonisolated static helpers** in the sheets: `TmuxAttachSheet.parseHostString/filterSessions/attachmentInfo`, `SSHConnectionSheet.connectionTarget`, `TmuxLayoutParser` usage — pure, testable, reusable.
- **Note data model** (`SessionNoteEntry`/`NoteSource`/`NoteRevision`, Codable) and `formatDuration` — pure.
- The **OSC-9 note protocol** + `fantastty.sh` shell integration — already cross-platform (works over SSH/tmux/mosh); reuse verbatim.

**Must be rewritten (macOS UI glue):** every SwiftUI `View` body in scope (sidebar, tab bar, notes panel, settings, overview, sheets, browser), the toolbar/editable-title (`NSTextField`), the **entire drag/drop bridge** (`Transferable`/`NSDraggingSession`/pasteboard/`DraggingSurfaceKey`), thumbnail snapshotting (`cacheDisplay` → GL FBO capture), and the Combine-based refresh/timer plumbing.

**Reuse from Ghostty's own Linux/GTK frontend (per brief; not verifiable in this checkout — `vendor/ghostty` is empty here):** Ghostty's GTK apprt already provides a GL terminal **surface widget**, a **GtkPaned-based split** container, tab handling, and a config/color-scheme bridge. The port should build leaves on Ghostty's GTK Surface and likely lean on its paned splits for the divider/cursor/min-size mechanics — but Fantastty's `SplitTree` is **richer** than a plain paned tree (drag-to-split reorder, spatial focus nav, zoom-as-path, structural identity). Recommended: keep `SplitTree` as the model of record and drive a GtkPaned (or custom) view from it, rather than adopting Ghostty's split model wholesale. **The orchestrator should diff Fantastty's `SplitTree` against upstream Ghostty GTK's split implementation** to decide how much to inherit.

---

## 7. Open questions / risks

1. **Live GL thumbnails are load-bearing UX with no cheap Linux analogue.** Sidebar previews, the right thumbnail panel, and the Exposé overview all depend on `NSView.cacheDisplay` snapshots at a 150 ms debounce. On GTK/GL each terminal surface must be captured from its framebuffer (FBO readback) — a real performance/integration risk, especially for many tabs. Decide early: per-surface render-to-texture, periodic FBO grab, or a downgraded text-only preview.
2. **GtkPaned vs. custom layout.** `GtkPaned` gives free native dividers, cursors, and min-size, but the immutable `SplitTree` with arbitrary nesting + ratio clamps + cell-snap + double-click-equalize must be faithfully reproduced (the layout-pipeline tests exist precisely because pane collapse was a real bug). Mapping ratio↔paned-position bidirectionally (drag updates the model; model updates allocation) is the trickiest piece. A custom `GtkFixed` replicating `SplitView` math is the lower-risk-but-more-work alternative.
3. **Drag-to-split** (grab handle → 4-zone drop with live half-pane highlight, tear-off on out-of-window release) is a fully custom interaction. GTK DnD can express it, but the Transferable-by-UUID resolution, the `DraggingSurfaceKey` "hide my own drop zone" trick, and the drag-preview image all need re-implementation. Confirm the **tear-off** semantics (`ghosttySurfaceDragEndedNoTarget`) are even desired on Linux (single-window vs. multi-window model).
4. **Combine dependency.** `PassthroughSubject`/`Timer.publish`/`.debounce` and `@Published`/`@AppStorage` are pervasive in the reactive layer and have **no Linux Combine**. Choose OpenCombine vs. GObject signals + GLib timers before porting any view model.
5. **Keyboard convention clash.** The shortcut set is `⌘`-centric and overloads keys (`⌘K` = Clear Screen *and* New SSH via `⌘⇧K`; `` ⌘` `` hijacks window switch). Linux users expect Ctrl/Super and won't accept a `⌘` skin — the whole accelerator map needs redesign, and some bindings (`⌘`` ` workspace cycling) may conflict with the desktop environment.
6. **`NavigationSplitView` balanced/collapsing behavior** doesn't map 1:1 to `Adw*SplitView`; sidebar auto-collapse, minimum widths (`minWidth: 180` sidebar, `800×500` window), and the bottom `safeAreaInset` "New Workspace" bar need explicit reconstruction.
7. **Toolbar editable title**: `GtkEditableLabel` is a strong fit, but confirm it behaves well embedded in `AdwHeaderBar` (focus/commit-on-blur parity with the macOS `controlTextDidEndEditing` flow).
8. **Empty vendored Ghostty tree** in this checkout means reuse claims about Ghostty's GTK splits/surface widget are unverified here; the orchestrator must inspect the real upstream GTK apprt.
