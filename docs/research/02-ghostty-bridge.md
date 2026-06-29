# 02 — GhosttyBridge: terminal surface embedding, rendering, input, config

Subsystem: the Swift layer that talks to **libghostty** (the `GhosttyKit` C ABI). This is the
core terminal-engine integration boundary. A Linux port must reproduce this C API surface against
libghostty's native **GTK4 / OpenGL (EGL)** apprt instead of AppKit / Metal.

---

## 1. Scope

### Files read in full
| File | Lines | Role |
|---|---|---|
| `Fantastty/BridgingHeader.h` | 6 | Imports `VibrantLayer.h` only. Surprisingly does NOT include `ghostty.h` (that comes via the `GhosttyKit` module map in the xcframework). |
| `Fantastty/GhosttyBridge/Ghostty.App.swift` | 2254 | App lifecycle + the giant `action_cb` dispatcher (~60 action tags) + clipboard/wakeup callbacks. |
| `Ghostty.Surface.swift` | 303 | `Ghostty.Surface` value type wrapping `ghostty_surface_t`; text/key/mouse/remote-grid calls. |
| `Ghostty.Config.swift` | 816 | `Ghostty.Config` wrapping `ghostty_config_t`; ~70 typed config getters via `ghostty_config_get`. |
| `Ghostty.Input.swift` | 1314 | Key/mods/mouse enum bridging; W3C-keycode ↔ macOS-keycode table; `ghostty_input_*` mapping. |
| `Ghostty.Action.swift` | 173 | Swift structs for action payloads (color/url/progress/scrollbar/search/keytable). |
| `Ghostty.Command.swift` | 39 | `ghostty_command_s` → command-palette entry. |
| `Ghostty.Event.swift` | 15 | `ComparableKeyEvent` (NSEvent keyCode+flags). |
| `Ghostty.Shell.swift` | 19 | Shell escaping for drag/drop text. |
| `Ghostty.Inspector.swift` | 100 | `ghostty_inspector_*` bindings incl. Metal init/render. |
| `Ghostty.Error.swift` | 12 | Single `apiFailed` error. |
| `Ghostty.Package.swift` | 522 | `Ghostty` namespace, `ghostty_info`, `AllocatedString`, all `Notification.Name`s, C-type `Sendable` conformances. |
| `GhosttyDelegate.swift` | 10 | `Ghostty.Delegate` protocol (lookup surface by UUID). |
| `SurfaceView.swift` | 1297 | SwiftUI views (`SurfaceWrapper`, `SurfaceRepresentable`); **`SurfaceConfiguration.withCValue`** builds `ghostty_surface_config_s`. |
| `SurfaceView_AppKit.swift` | 2787 | The `NSView` subclass = the surface host. Input/IME/mouse/scroll/resize/Metal-layer ownership, `NSTextInputClient`, tmux input encoder. |
| `SurfaceScrollView.swift` | 407 | `NSScrollView` wrapper driving Ghostty's scrollback via `scroll_to_row` actions. |
| `SurfaceView+Image.swift` | 28 | Snapshot of surface as NSImage (drag preview). |
| `SurfaceView+Transferable.swift` | 58 | Surface drag UUID encoding. |
| `SurfaceDragSource.swift` | 268 | AppKit `NSDraggingSource` to drag a pane out to a new window. |
| `SurfaceGrabHandle.swift` | 41 | SwiftUI grab handle overlay. |
| `SurfaceProgressBar.swift` | 113 | OSC 9;4 progress bar UI. |
| `MetalView.swift` | 26 | Generic `MTKView` SwiftUI wrapper — **unused** in this fork. |
| `KeyboardLayout.swift` | 14 | `TISCopyCurrentKeyboardInputSource` (Carbon) layout ID. |
| `NSEvent+Extension.swift` | 77 | `ghosttyKeyEvent()` builds `ghostty_input_key_s` from NSEvent; `ghosttyCharacters`. |
| `MickeyTermCompat.swift` | 117 | **Fork stubs** — confirms inspector & controller architecture are not wired here. |
| `CGS.swift` | 81 | Private CoreGraphics Spaces API (used by quick-terminal/fullscreen, not the surface). |
| `Cursor.swift`, `OSColor+Extension.swift`, `CrossKit.swift`, `Backport.swift`, `SecureInput.swift`, `VibrantLayer.h/.m`, `AppInfo.swift`, `NSView+Extension.swift` | — | Supporting glue (cursor shapes, color conv, AppKit/UIKit typealiases, secure-input Carbon API). |
| `patches/ghostty-inject-output.patch` | 562 | Adds `ghostty_surface_inject_output` + the whole `ghostty_surface_remote_grid_*` API to libghostty. |

### Not covered (out of scope / belongs to other subsystems)
- The remote-grid **model** types (`RemoteGridCell`, `RemoteCellStyle`, `RemoteGridColor`, `RemoteCursorState`, `RemoteGridSurface` protocol, `RemotePaneInput`) live in `Fantastty/Models/RemoteGrid*.swift` — the remote-engine subsystem. The bridge only exposes the C entry points they call.
- `tmux` control client (`TmuxControlClient`), `SplitTree`, `BaseTerminalController`, window/tab controllers, `AppDelegate` — referenced but defined elsewhere.
- libghostty's own Zig internals (the vendored `vendor/ghostty/ghostty/` dir is empty here — it ships as a prebuilt `GhosttyKit.xcframework`), so the Zig side is visible only through the patch.

---

## 2. What it does (behavior & features)

This subsystem is the contract between the app and the terminal engine. User-facing behaviors it provides:

- **Live terminal panes.** Each pane is a libghostty *surface* embedded in an `NSView`. libghostty owns rendering (Metal), the PTY, the VT parser, scrollback, selection, fonts, ligatures, and shaping. The app just hosts the view and pumps input/size/focus.
- **Full keyboard input** including: Unicode text, control chars, function/arrow/nav keys, modifiers (incl. left/right-sided), `option-as-alt` translation, key sequences (multi-key bindings), key tables (named binding modes), and dead-key / IME composition (Korean, Japanese, dictation) via macOS marked-text.
- **Mouse**: press/release for 11 buttons, motion (with mouse-reporting / capture awareness), high-precision + momentum scroll, pressure / force-click → QuickLook dictionary lookup, focus-follows-mouse, hover-link detection.
- **Native scrollback scrollbar** mapped onto Ghostty's viewport (drag scroller → `scroll_to_row`).
- **Config-driven appearance**: background color/opacity/blur, split divider/unfocused-dim colors, window decorations, titlebar, cursor, scrollbar, resize-overlay, quick-terminal geometry, macOS icon, secure input, auto-update — all read live from the Ghostty config and hot-reloaded.
- **Terminal actions** surfaced to the UI through `NotificationCenter`: new window/tab/split, goto/move/close tab, goto/resize/equalize/zoom split, fullscreen, command palette, desktop notifications (incl. **Fantastty's custom OSC-9 signals** for session notes / ticket URLs / PR URLs), bell, title set/prompt, pwd tracking, clipboard read/write confirmation (OSC 52), progress reports, color changes, renderer-health, undo/redo, secure input, mouse shape/visibility, open-URL, readonly mode, search (find bar), command-finished (shell integration).
- **Drag a pane out** to reorder or create a new window (snapshot drag image).
- **Clipboard** with paste-safety confirmation and OSC-52 read/write prompts; macOS Services + accessibility (VoiceOver reads screen contents).
- **tmux / remote panes** (the headline Fantastty feature): a surface can be put in a mode where its child process is `cat > /dev/null` and content is **injected** out-of-band (`ghostty_surface_inject_output`, or the structured `remote_grid` API), while keystrokes are **re-routed** to a tmux control client / QUIC stream instead of the local PTY (`AttachedTmuxInputEncoder` / `AttachedTmuxInputRouter`).

### Rules / edge cases worth carrying into the SPEC
- Cmd-keyed events never trigger `keyUp` via the responder chain, so a **local event monitor** catches `.keyUp` (and `.leftMouseDown` for focus-without-consume). (`SurfaceView_AppKit.swift:667`)
- `performKeyEquivalent` must let a Cmd binding flow through the AppKit menu/responder chain *first* (so user rebindings win), then re-dispatch to `keyDown` if unhandled — identity is tracked by **event timestamp** because NSEvent identity doesn't survive Swift. (`SurfaceView_AppKit.swift:1537–1686`)
- Control chars and PUA function-key codepoints are stripped from the `text` field — libghostty encodes those itself. (`NSEvent+Extension.swift:55`)
- Surface teardown (`ghostty_surface_free`) must run **synchronously on the main thread** or callbacks race into a freed `SurfaceView` userdata (use-after-free). (`Ghostty.Surface.swift:27`)
- For tmux/remote panes, keystrokes must NOT go through `ghostty_surface_key` (it enqueues onto a `BlockingQueue` that can deadlock when the inject queue saturates), and `ghostty_surface_set_focus` is likewise skipped. (`SurfaceView_AppKit.swift:764`, `:1782`)

---

## 3. How it's built (architecture)

### 3.1 Object model & ownership
```
Ghostty.App  (ObservableObject, one per process)
  ├─ owns ghostty_app_t  (ghostty_app_new / _free)
  ├─ holds Ghostty.Config (ghostty_config_t)
  └─ userdata = Unmanaged.passUnretained(self)  ← passed into runtime cfg

Ghostty.SurfaceView : NSView  (one per pane; the userdata for the surface)
  └─ surfaceModel: Ghostty.Surface  (final class, wraps ghostty_surface_t)
        userdata = Unmanaged.passUnretained(view)  ← set in surface config
```
- The **`SurfaceView` (NSView) is the surface userdata**, so every C callback round-trips:
  `ghostty_surface_userdata(surface)` → `Unmanaged<SurfaceView>` (`Ghostty.App.swift:486–493`).
- `Ghostty.Surface` is a thin `Sendable` wrapper; all its methods are `@MainActor`. `unsafeCValue` exposes the raw `ghostty_surface_t`.

### 3.2 Surface creation / sizing / feeding / destruction
- **Create**: `SurfaceConfiguration.withCValue(view:)` (`SurfaceView.swift:724`) builds a `ghostty_surface_config_s`:
  - `userdata = nsview ptr`; `platform_tag = GHOSTTY_PLATFORM_MACOS`; `platform = ghostty_platform_macos_s(nsview: <ptr>)`; `scale_factor = NSScreen.main.backingScaleFactor`; plus `font_size`, `working_directory`, `command`, `initial_input`, `wait_after_command`, `env_vars[]` (`ghostty_env_var_s`), and `context` (`GHOSTTY_SURFACE_CONTEXT_{WINDOW,TAB,SPLIT}`). Then `ghostty_surface_new(app, &cfg)` (`SurfaceView_AppKit.swift:683`).
- **Size**: `sizeDidChange` → `convertToBacking` → `ghostty_surface_set_size(w,h)` in **backing pixels**, then reads back `ghostty_surface_size()` (`ghostty_surface_size_s`: width/height px, columns, rows, cell_width_px, cell_height_px). Content scale on DPI change: `ghostty_surface_set_content_scale(xScale,yScale)` from `viewDidChangeBackingProperties` (`SurfaceView_AppKit.swift:1178–1213`). Display/vsync: `ghostty_surface_set_display_id` on screen change (`:1128`).
- **Feed input**: see §3.4.
- **Destroy**: `inspectorVisible=false` → `ghostty_inspector_free`; `Ghostty.Surface.deinit` → main-thread `ghostty_surface_free`.

### 3.3 Metal rendering integration — **libghostty owns the layer**
This is the key architectural fact: **the app does NOT create a `CAMetalLayer`, run an `MTKView`, or issue any draw calls for the terminal.** It hands libghostty the bare `NSView` pointer via `ghostty_platform_macos_s(nsview:)`, and libghostty's embedded apprt installs its own `CAMetalLayer` as the view's backing layer and drives all drawing from its **own renderer thread** (vsync via `CVDisplayLink`, hence `ghostty_surface_set_display_id`). Evidence: there is zero `CAMetalLayer` / `makeBackingLayer` / `wantsLayer=true` / `MTKView` usage anywhere in the surface path (grep-confirmed). `MetalView.swift` (an `MTKView` wrapper) exists but is unused. The Swift side's only responsibilities are: give libghostty the view, tell it the **backing size** (`set_size`), the **content scale** (`set_content_scale`), the **display id** (vsync), and keep `layer?.contentsScale` synced to defeat the compositor double-scaling (`SurfaceView_AppKit.swift:1192–1199`).

The **only** place the app drives Metal itself is the **inspector**: `ghostty_inspector_metal_init(device)` and `ghostty_inspector_metal_render(commandBuffer, descriptor)` (`Ghostty.Inspector.swift:80–98`) — these take an `MTLDevice` / `MTLCommandBuffer` / `MTLRenderPassDescriptor` from an app-owned `MTKView`. **But the inspector host view is stubbed out in this fork** ("we don't support the inspector in Fantastty", `MickeyTermCompat.swift:80`), so this path is currently dormant.

### 3.4 Input flow (control flow)
`keyDown` (`SurfaceView_AppKit.swift:1401`) is the heart:
1. Compute translation mods via `ghostty_surface_key_translation_mods` (handles `option-as-alt`), build a possibly-new `NSEvent`.
2. `keyTextAccumulator = []`, then `interpretKeyEvents([event])` → AppKit IME → either `insertText` (commit/compose) or `doCommand(by:)`.
3. After IME, build `ghostty_input_key_s` via `NSEvent.ghosttyKeyEvent()` (`NSEvent+Extension.swift:12`) — sets `action`, `keycode`, `mods`, `consumed_mods` (heuristic: ctrl/cmd never translate text), `unshifted_codepoint`, and `text`.
4. `keyAction()` → `ghostty_surface_key(surface, key_ev)` (`:1790`). Preedit synced via `ghostty_surface_preedit` (`:2464`).
- Marked-text / IME: `NSTextInputClient` conformance (`:2230`) — `setMarkedText`/`unmarkText` → `ghostty_surface_preedit`; `firstRect(forCharacterRange:)` → `ghostty_surface_ime_point` for caret placement; `selectedRange`/`attributedSubstring` → `ghostty_surface_read_selection` + `ghostty_surface_quicklook_font` (CTFont).
- `flagsChanged` (`:1688`) decodes left/right modifier press/release from keyCode + `NX_DEVICER*KEYMASK`.
- Mouse: `mouseDown/Up`, `otherMouse*`, `rightMouse*` → `ghostty_surface_mouse_button(state,button,mods)`; `mouseMoved/Dragged/Entered/Exited` → `ghostty_surface_mouse_pos(x, frame.height-y, mods)` (note Y-flip to top-left origin, `-1/-1` on exit); `scrollWheel` → `ghostty_surface_mouse_scroll` with a packed `ghostty_input_scroll_mods_t` (precision bit + 3-bit momentum, `Ghostty.Input.ScrollMods`); `pressureChange` → `ghostty_surface_mouse_pressure`.
- **tmux/remote routing**: when `tmuxPaneID != nil` and the key isn't a local Cmd binding, `keyAction` diverts to `AttachedTmuxInputEncoder` which produces raw bytes (control bytes, UTF-8, or hand-built **xterm escape sequences** — CSI/SS3/CSI-u for arrows, Home/End, F-keys, modified Enter/Tab/BS/Esc) and ships them via `sendPaneInput` instead of `ghostty_surface_key` (`SurfaceView_AppKit.swift:8–296`, `:1735–1831`).

### 3.5 App callbacks (`ghostty_runtime_config_s`, `Ghostty.App.swift:82`)
Six C callbacks, dispatched from libghostty (possibly off-main):
- `wakeup_cb` → `DispatchQueue.main.async { ghostty_app_tick() }` (`:457`).
- `action_cb` → `App.action()` (`:497`) — a **~60-case switch** on `action.tag` × `target.tag` (`GHOSTTY_TARGET_APP`/`SURFACE`). Most cases just re-post a `NotificationCenter` notification to the relevant `SurfaceView`; a handful return a bool to signal "performable" (goto_split/tab, resize_split, undo/redo, prompt_title, open_url, present_terminal). This is the **single biggest porting surface** for UI wiring.
- `read_clipboard_cb` / `confirm_read_clipboard_cb` / `write_clipboard_cb` → `NSPasteboard`, with OSC-52 confirmation dialogs; completes via `ghostty_surface_complete_clipboard_request`.
- `close_surface_cb` → posts `ghosttyCloseSurface`.
- `supports_selection_clipboard: true` (the app claims X11-style selection-clipboard support — interesting, since that's a Linux concept; on macOS it maps to a private `NSPasteboard`).

### 3.6 Config (`Ghostty.Config`, `Ghostty.Config.swift`)
Load order (`loadConfig`, `:56`): `ghostty_config_new` → `ghostty_config_load_default_files` (or `_load_file`) → `ghostty_config_load_cli_args` (skipped under Xcode) → `ghostty_config_load_recursive_files` → a **Fantastty theme overlay** file (`_load_file`) → `ghostty_config_finalize`. Diagnostics via `ghostty_config_diagnostics_count` / `_get_diagnostic`. Every typed property is a `ghostty_config_get(cfg, &out, key, keyLen)` keyed by **string name** (e.g. `"background-opacity"`, `"window-decoration"`), returning bool/int/double/`UnsafePointer<Int8>`/`ghostty_config_color_s`/`ghostty_config_color_list_s`/`ghostty_config_command_list_s`/`ghostty_config_quick_terminal_size_s`. Hot reload: `ghostty_app_update_config` / `ghostty_surface_update_config`; clone for ownership via `ghostty_config_clone`. Keybinding lookup: `ghostty_config_trigger(action)` → `ghostty_input_trigger_s` → SwiftUI `KeyboardShortcut`.

### 3.7 The patch (`ghostty-inject-output.patch`) — what capability it adds
Patches `include/ghostty.h` + `src/apprt/embedded.zig` to add **two** capabilities used by the tmux/remote subsystems:
1. **`ghostty_surface_inject_output(surface, ptr, len)`** — feeds raw bytes straight into `surface.core_surface.io.processOutput(...)`, i.e. into the VT parser **bypassing the PTY**. This is how tmux control-mode output (which arrives over a control connection, not a pty) is rendered by a real Ghostty terminal. (`patch:84–90`)
2. **The `remote_grid` API** (`reset`, `set_row`, `set_row_cells`, `set_cursor`, `set_cursor_ex`) — writes **structured cells directly into the terminal screen** (`terminal.Screen` pins/pages/styles), locking `renderer_state.mutex`, validating UTF-8 width / column counts, staging styles (`page.styles.add`), and waking the renderer (`renderer_thread.wakeup.notify`). It carries full style: fg/bg/underline color (`default`/`indexed`/`rgb`), bold/faint/italic/blink/inverse/invisible/strikethrough, 6 underline styles, cursor shape (block/bar/underline). This is the wire model for the **QUIC remote engine's** structured grid/keyframe/delta rendering with predictive local echo. Swift side: `Ghostty.Surface.resetRemoteGrid/setRemoteGridRow/setRemoteGridCursor` (`Ghostty.Surface.swift:55–127`) marshals `ghostty_remote_grid_cell_s` arrays. The validators (`remoteGridRowDisplayWidth`, `remoteGridCellsDisplayWidth`) **reject** any row whose display width ≠ terminal columns, rows > 1000, cells > 250k, etc. — a hard invariant the Linux port must keep byte-for-byte.

### 3.8 Threading
- libghostty has its own renderer + IO threads. Swift callbacks may arrive off-main; the code defensively `DispatchQueue.main.async`es published mutations. `wakeup_cb` always bounces to main before `app_tick`. Surface free is forced onto main. `@MainActor` guards the `Ghostty.Surface`/`Ghostty.Inspector` methods.

---

## 4. Platform dependencies (macOS-specific)

**C ABI surface (must be reproduced — this is the whole point).** Full enumerated `ghostty_*` function set the bridge calls:

- *App*: `ghostty_app_new`, `_free`, `_tick`, `_set_focus`, `_keyboard_changed`, `_needs_confirm_quit`, `_update_config`, `_userdata`; `ghostty_info`; `ghostty_string_free`.
- *Config*: `ghostty_config_new`, `_free`, `_clone`, `_load_file`, `_load_default_files`, `_load_cli_args`, `_load_recursive_files`, `_finalize`, `_diagnostics_count`, `_get_diagnostic`, `_get`, `_trigger`, `_open_path`.
- *Surface lifecycle/config*: `ghostty_surface_config_new`, `ghostty_surface_new`, `_free`, `_update_config`, `_inherited_config`, `_request_close`, `_app`, `_userdata`.
- *Surface size/render*: `_set_size`, `_size`, `_set_content_scale`, `_set_display_id`.
- *Surface input*: `_key`, `_key_is_binding`, `_key_translation_mods`, `_text`, `_preedit`, `_mouse_button`, `_mouse_pos`, `_mouse_scroll`, `_mouse_pressure`, `_mouse_captured`, `_set_focus`, `_ime_point`.
- *Surface actions/state*: `_binding_action`, `_split`, `_split_focus`, `_split_resize`, `_split_equalize`, `_needs_confirm_quit`, `_process_exited`.
- *Surface text/selection/clipboard*: `_read_text`, `_free_text`, `_read_selection`, `_has_selection`, `_quicklook_word`, `_quicklook_font`, `_complete_clipboard_request`.
- *Inspector*: `ghostty_surface_inspector`, `ghostty_inspector_free`, `_set_focus`, `_set_content_scale`, `_set_size`, `_mouse_button`, `_mouse_pos`, `_mouse_scroll`, `_key`, `_text`, `_metal_init`, `_metal_render`.
- *Patched*: `ghostty_surface_inject_output`, `ghostty_surface_remote_grid_reset/_set_row/_set_row_cells/_set_cursor/_set_cursor_ex`.
- *Runtime cfg callbacks*: `wakeup_cb`, `action_cb`, `read_clipboard_cb`, `confirm_read_clipboard_cb`, `write_clipboard_cb`, `close_surface_cb`.

**Apple frameworks / idioms the *glue* depends on:**
- **AppKit**: `NSView` (the surface host, first-responder, tracking areas), `NSEvent` (keyCode, `modifierFlags`, `characters(byApplyingModifiers:)`, `momentumPhase`, `hasPreciseScrollingDeltas`, `pressure`/`stage`), `NSTextInputClient` (marked text / IME), `NSScrollView`/`NSScroller`/`NSClipView` (scrollback UI), `NSDraggingSource`/`NSDraggingDestination`/`NSPasteboard`, `NSCursor`, `NSAlert`, `NSWorkspace`, `NSScreen.backingScaleFactor`, `NSApplication` activation notifications, `NSAppearance`.
- **Metal/QuartzCore**: `CAMetalLayer` (created by libghostty), `CATransaction`, `layer.contentsScale`; `MTLDevice`/`MTLCommandBuffer`/`MTLRenderPassDescriptor`, `MTKView` (inspector only). The private `compositingFilter` `plusD`/`plusL` blend modes in `VibrantLayer.m`.
- **Carbon / HIToolbox**: `TISCopyCurrentKeyboardInputSource` / `TISGetInputSourceProperty` (`KeyboardLayout.swift`); `EnableSecureEventInput`/`DisableSecureEventInput` (`SecureInput.swift`); `NX_DEVICER*KEYMASK` IOKit masks for sided modifiers.
- **Private CoreGraphics**: `CGSMainConnectionID`/`CGSGetActiveSpace`/`CGSSpaceGetType`/`CGSCopySpacesForWindows` (`CGS.swift`, Spaces detection).
- **Other**: `UserNotifications` (`UNUserNotificationCenter`), `CoreText` (`CTFont` from `quicklook_font`), `CoreTransferable`/`UTType`, `AppIntents` (key/mouse enums as `AppEnum`), `os.Logger`, `TISInputSource` keyboard-change notification.
- **The macOS keycode table** (`Ghostty.Input.Key.keyCode`, `:979`) hard-codes Apple virtual keycodes (`0x00`=A …) mapped to Ghostty's W3C key names — derived from Ghostty's `src/input/keycodes.zig`.

---

## 5. Linux mapping

The decisive simplifier: **libghostty already has a native GTK4 + OpenGL apprt** (its primary platform). The Linux port should target that apprt instead of re-implementing the macOS embedding. Concrete mapping:

| macOS dependency | Linux-native equivalent |
|---|---|
| `ghostty_platform_macos_s(nsview:)` + libghostty-owned `CAMetalLayer` | `ghostty_platform_gtk_s` / GTK apprt: hand libghostty a **`GtkGLArea`** (or it manages an EGL surface on a `GdkSurface`). Rendering = **OpenGL/EGL via GTK**, libghostty still owns it. **No Metal.** |
| `MTKView` + `ghostty_inspector_metal_*` (inspector) | The inspector renders via OpenGL in the GTK apprt — but it's **stubbed off in this fork anyway**, so lowest priority. |
| `NSView` surface host, first responder, tracking areas | `GtkWidget` (likely `GtkGLArea` inside a container); `GtkEventControllerKey`/`Motion`/`Scroll`/`GestureClick` for events; focus via `GtkWidget` focus. |
| `NSEvent` keycodes + hard-coded Apple keycode table | **XKB** (`xkb_state`, evdev/`GdkKeyEvent` hardware keycodes). libghostty's GTK frontend already does W3C-keycode translation from XKB — **reuse it**; the macOS keycode table is dead weight on Linux. |
| `NSTextInputClient` marked text / IME; `ime_point` | **IBus / GTK `GtkIMContext`** (`gtk_im_context_filter_keypress`, `preedit-changed`, `commit`); `ghostty_surface_preedit` / `ghostty_surface_ime_point` stay the same — only the IME *source* changes. |
| `option-as-alt`, sided mods (`NX_DEVICER*`) | XKB modifier state gives left/right Alt/Shift/Ctrl/Super directly; `ghostty_surface_key_translation_mods` is platform-agnostic and stays. |
| `NSScrollView`/`NSScroller` scrollback UI | `GtkScrolledWindow` + `GtkScrollbar`, or a custom overlay scrollbar; same `scroll_to_row` / scrollbar-action contract. |
| `NSPasteboard` + OSC-52 + selection clipboard | **Wayland/X11 clipboard via GTK `GdkClipboard`**; the `supports_selection_clipboard: true` flag and **PRIMARY selection** are *native* on Linux (this part gets simpler). |
| `NSDraggingSource`/`Destination` (pane drag-out) | GTK4 **`GtkDragSource`/`GtkDropTarget`** + content providers; snapshot preview via `gtk_widget_paintable_new`. |
| `NSCursor` shapes (`setCursorShape`) | `GdkCursor` named cursors (`text`, `pointer`, `grab`, `ew-resize`, …) — straightforward 1:1. |
| `EnableSecureEventInput` (secure input) | **No clean equivalent** — Linux has no global secure-input mode. RISK / likely drop (or best-effort via input-method grab). |
| `TISCopyCurrentKeyboardInputSource` layout id | XKB layout name (`xkb_keymap_layout_get_name`); feed to `ghostty_app_keyboard_changed`. |
| Private `CGS*` Spaces API | Wayland: no global "spaces" concept (compositor workspaces aren't queryable the same way); X11 `_NET_*` EWMH hints. Mostly relevant to quick-terminal, not the surface — low priority / RISK. |
| `UNUserNotificationCenter` | **libnotify / D-Bus `org.freedesktop.Notifications`**; the Fantastty OSC-9 signal interception (`fantastty:note;`/`ticket;`/`pr;`) is pure string parsing — ports as-is. |
| `CTFont` from `quicklook_font` for IME/QuickLook attr strings | Pango/`PangoFontDescription`; or skip — QuickLook dictionary lookup has no Linux analog (RISK, likely drop force-click→define). |
| `CAMetalLayer.contentsScale` / `backingScaleFactor` | GDK fractional scaling (`gdk_surface_get_scale_factor` / `gdk_surface_get_scale`); feed to `ghostty_surface_set_content_scale`. `set_display_id` → GDK monitor for vsync. |
| `MTLDevice` vsync via `CVDisplayLink` | GTK frame clock (`gtk_widget_add_tick_callback`) / EGL swap interval; handled inside libghostty's GTK renderer. |
| `os.Logger` | `g_log` / structured logging / stderr. |
| `AppIntents` (Shortcuts) enums | No equivalent; drop (or map to a D-Bus/CLI action interface). |

---

## 6. Reuse assessment

**Ports largely as-is (cross-platform logic):**
- The entire **C ABI call discipline** — the set of `ghostty_*` calls, their argument marshaling, the `userdata` round-trip pattern, the load-order of config, the runtime-config callback structure. The *function names and semantics are identical* on the GTK apprt; only the platform-tag struct (`macos` → `gtk`) and a handful of macOS-only actions change.
- `Ghostty.Config` typed getters: every `ghostty_config_get(key)` is platform-independent (just drop the `macos-*` keys). ~700 lines reuse with light pruning.
- `Ghostty.Action`, `Ghostty.Command`, `Ghostty.Surface` (remote-grid marshaling), the action-tag → notification dispatch *structure* (the body changes, the skeleton doesn't).
- `Ghostty.Input` **enum bridging** (Key/Mods/MouseButton/Momentum/ScrollMods ↔ `ghostty_input_*`) — the *enum tables* are reusable; the **macOS keycode column is replaced** by XKB-derived codes (and libghostty's GTK frontend already provides that translation, so it can largely be dropped).
- `AttachedTmuxInputEncoder` (escape-sequence generation) is **pure byte logic** keyed on keyCode/characters/mods — needs its keyCode table swapped to XKB/GDK but the escape-sequence builders (CSI/SS3/CSI-u) port verbatim. High-value reuse for the remote/tmux feature.
- The **patch** (`inject_output` + `remote_grid`) is libghostty Zig and is **platform-agnostic** — it must be re-applied to the same vendored libghostty regardless of apprt. The Linux build pipeline must carry this patch.

**Must be rewritten (macOS glue):**
- `SurfaceView_AppKit.swift` (2787 lines) — the entire `NSView`/`NSTextInputClient`/event-handler host → a `GtkGLArea`-based widget with GTK event controllers + `GtkIMContext`. This is the **single largest rewrite**.
- `SurfaceScrollView.swift`, `SurfaceDragSource.swift`, `SurfaceGrabHandle.swift`, `MetalView.swift`, `Cursor.swift`, `SecureInput.swift`, `CGS.swift`, `KeyboardLayout.swift`, `VibrantLayer`, `NSEvent+Extension.swift` — all AppKit/Carbon/Metal-specific.
- The `action_cb` *handlers* (~1700 lines of `Ghostty.App.swift`) — logic is reusable but every body touches AppKit (`NSApp`, `NSWindow`, `NSAlert`, `NSWorkspace`, notifications consumed by AppKit controllers). Rewrite against GTK windows/the new controller layer.

**Can be reused from Ghostty's own Linux frontend:**
- libghostty's **GTK4 apprt + OpenGL renderer** (the embedding, IME, XKB key translation, clipboard, cursor) is exactly the reference for replacing `SurfaceView_AppKit`. The Linux port should study `apprt/gtk` in the vendored source rather than reinventing the surface host.

---

## 7. Open questions / risks

1. **GTK apprt C API parity.** This report enumerates the macOS-used `ghostty_*` symbols. The GTK apprt may expose a *different* embedding entry-point (it historically embeds via its own `gtk` apprt rather than a `ghostty_platform_gtk_s` passed to `ghostty_surface_new`). **Action: verify whether libghostty exposes the same embedded-surface C API for GTK, or whether the Linux port must link the GTK apprt and drive it differently.** This is the biggest unknown for the whole port.
2. **The patch must be re-applied and kept in lockstep.** `inject_output` + `remote_grid` touch `terminal.Screen`/`Page`/`Style` internals. If the Linux build uses a different libghostty pin, the patch may not apply. The remote-grid validators encode hard invariants (width==cols, 1000-row/250k-cell caps) the remote engine relies on — porting them wrong silently breaks remote rendering.
3. **`BlockingQueue` deadlock avoidance.** The macOS code explicitly avoids `ghostty_surface_key`/`set_focus` for tmux panes to dodge a libghostty queue deadlock under inject saturation (`:764`, `:1782`). The same hazard exists on Linux; the routing logic must be preserved.
4. **IME fidelity.** macOS marked-text composition is mature here (Korean/Japanese/dictation edge cases, keyboard-layout-change-mid-composition). GTK `GtkIMContext`/IBus has different semantics (preedit ownership, commit timing). Risk of regressions in CJK input; budget real testing.
5. **Secure input, QuickLook/force-click, macOS Spaces** have **no clean Linux equivalent** — confirm with product whether they're dropped (likely yes) vs. need a substitute.
6. **Selection clipboard / PRIMARY.** macOS fakes it via a private pasteboard; Linux has real PRIMARY selection. This is an *opportunity* (more native) but the OSC-52 confirmation-dialog flow and `supports_selection_clipboard` semantics must be re-validated.
7. **Coordinate systems.** macOS is Y-up (bottom-left origin); the code flips Y for mouse pos and IME rects (`frame.height - y`). GTK/Wayland are Y-down (top-left) — Ghostty's native coords are top-left, so the Linux port should *remove* the flips, not copy them. Easy to get subtly wrong.
8. **Fractional/HiDPI scaling.** macOS `backingScaleFactor` is integer-ish; Wayland fractional scaling (1.25/1.5) is messier and must feed `set_content_scale` correctly or text renders blurry/misaligned.
9. **Inspector** is stubbed in this fork — decide whether the Linux port revives it (GTK GL inspector) or leaves it out; the C bindings exist either way.
