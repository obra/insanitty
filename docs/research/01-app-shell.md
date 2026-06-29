# 01 — App Shell, Windowing, Lifecycle, Menus, Commands, Fullscreen, Secure Input

## 1. Scope

### Files read in full
| File | Lines | Notes |
|---|---|---|
| `Fantastty/App/main.swift` | 12 | Process entry point |
| `Fantastty/App/MickeyTermApp.swift` | 23 | SwiftUI `App` / `Scene` graph |
| `Fantastty/App/AppDelegate.swift` | 110 | `NSApplicationDelegate` lifecycle |
| `Fantastty/App/AppCommands.swift` | 198 | Main-menu / keyboard-shortcut tree |
| `Fantastty/Views/MainWindow.swift` | 39 | Root window content |
| `Fantastty/Views/Settings/SettingsView.swift` | 109 | Settings scene body (appearance picker) |
| `Fantastty/Models/AppearanceMode.swift` | 50 | Light/Dark/System preference |
| `Fantastty/GhosttyBridge/Fullscreen.swift` | 458 | 4 fullscreen styles (vendored, **unwired** — see §2) |
| `Fantastty/GhosttyBridge/FullscreenMode+Extension.swift` | 23 | Ghostty enum → `FullscreenMode` |
| `Fantastty/GhosttyBridge/CGS.swift` | 81 | Private CoreGraphics Spaces API |
| `Fantastty/GhosttyBridge/SecureInput.swift` | 135 | Carbon secure-input singleton |
| `Fantastty/GhosttyBridge/SecureInputOverlay.swift` | 68 | Lock-shield badge overlay |
| `Fantastty/GhosttyBridge/Cursor.swift` | 119 | Cursor hide/unhide counter + style map |
| `Fantastty/GhosttyBridge/AppInfo.swift` | 10 | "running in Xcode" probe |
| `Fantastty/GhosttyBridge/macOS26Compat.swift` | 67 | Forward-compat shims for macOS 26 APIs |
| `Fantastty/GhosttyBridge/MickeyTermCompat.swift` | 117 | Stubs for un-ported Ghostty app types |
| `Fantastty/GhosttyBridge/NSWindow+Extension.swift` | 82 | cgWindowId, screen-constrain, private tab-bar hit-testing |
| `Fantastty/GhosttyBridge/NSMenuItem+Extension.swift` | 11 | SF Symbol on menu item (macOS 26) |
| `Fantastty/GhosttyBridge/NSView+Extension.swift` | 221 | View-tree traversal, screenshot, hierarchy dump |
| `Fantastty/GhosttyBridge/NSEvent+Extension.swift` | 77 | NSEvent → `ghostty_input_key_s` |
| `Fantastty/GhosttyBridge/EventModifiers+Extension.swift` | 27 | SwiftUI ⇄ AppKit modifier flags |
| `Fantastty/GhosttyBridge/KeyboardShortcut+Extension.swift` | 53 | Shortcut → glyph string |
| `Fantastty/GhosttyBridge/NSAppearance+Extension.swift` | 31 | isDark + Ghostty-config appearance |
| `Fantastty/GhosttyBridge/CrossKit.swift` | 56 | AppKit/UIKit `OS*` typealiases |
| `Fantastty/GhosttyBridge/Backport.swift` | 119 | macOS 14/15 API backports |
| `Fantastty/Fantastty.entitlements` | 22 | Sandbox-style entitlements |
| `Fantastty/Info.plist` | 48 | Bundle keys, exported UTType |

### Read partially (for wiring/boundary only)
- `GhosttyBridge/Ghostty.App.swift` (89 KB) — only the action-dispatch switch and the `newWindow / newTab / toggleFullscreen / toggleCommandPalette / toggleSecureInput` handlers (~lines 500–1050, 1600–1640).
- `GhosttyBridge/SurfaceView_AppKit.swift` (120 KB) — only the secure-input scoping (`passwordInput`, lines 437–450, 720, 751–776) and the command-palette/focus-follows-mouse check (line 1337).
- `GhosttyBridge/Ghostty.Config.swift` — only `autoSecureInput` / `secureInputIndication` / `windowFullscreenMode` accessors.
- `Models/SessionManager.swift` — only `setupNotificationObservers()` (1322–1396) to map which Ghostty actions are actually consumed.

### NOT covered (other subsystems' scope)
SurfaceView / Metal embedding, input encoding internals, tmux/remote engine, session persistence (`saveLayout`/`restoreTmuxSessions`), sidebar/workspace UI, notifications, the bulk of `Ghostty.App.swift` and `SurfaceView_AppKit.swift`.

---

## 2. What it does (behavior & features)

### Window model — single window, no native tabs
Fantastty is a **single-window** app. The scene graph (`MickeyTermApp.swift:8`) is one `Window("Fantastty", id: "main")` plus a `Settings { … }` scene — **not** a `WindowGroup`, so the user **cannot** open a second app window (no ⌘N-for-window, no "Merge All Windows", no native window tabs). The window is a `NavigationSplitView`: a sidebar of **workspaces** and a detail pane showing the selected workspace (`MainWindow.swift:8-21`), min size 800×500.

What the product calls "tabs" and "workspaces" are **pure SwiftUI/in-model constructs**, not AppKit windows/tabs:
- **Workspace** = a sidebar item (`sessionManager.sessions`), selected via `selectedSessionID`.
- **Tab** = a top-tab inside the selected workspace (`session.tabs`, `session.selectedTabID`).
- **Split** = a pane split inside a tab (handled by the surface/session subsystem).

### Menu bar & keyboard shortcuts (`AppCommands.swift`)
The app menu is built with SwiftUI `Commands`, replacing/extending the standard groups:

| Command | Shortcut | Action |
|---|---|---|
| New Tab | ⌘T | `createTab()` |
| New Browser Tab | ⌘B | `createBrowserTab()` (WebKit tab) |
| New Workspace | ⇧⌘N | `createSession()` |
| New SSH Workspace… | ⇧⌘K | opens SSH sheet |
| New Sprite Workspace… | ⌥⌘K | opens Fly.io Sprite sheet |
| Split Right / Down | ⌘D / ⇧⌘D | `newSplit(direction:)`, disabled when not splittable |
| Copy / Paste | ⌘C / ⌘V | routes to surface binding action; **Paste is tmux-aware** (sends keys to tmux pane if attached) |
| Select Next/Prev Tab | ⇧⌘] / ⇧⌘[ | within current workspace |
| Select Tab 1–9 | ⌘1…⌘9 | dynamic, first 9 tabs of current workspace |
| Select Next/Prev Workspace | ⌘` / ⇧⌘` | sidebar cycling (deliberately hijacks the system window-cycle key) |
| Toggle Notes | ⌘. | show/hide the notes panel |
| Clear Screen | ⌘K | `clearScreen()` |
| Close Tab | ⌘W | (note: ⌘W closes a *tab*, not the window) |
| Close Workspace | ⇧⌘W | `closeSession(id:)` |
| **Workspace menu**: Toggle Attention Flag (⇧⌘!), Clear All Attention Flags, Show Next Flagged (⌘!) | | attention-flag management |
| **Debug menu**: Test Bell (⌥⌘B), Simulate Bell (⌥⇧⌘B), Print Session Info | | developer/debug, ships in the menu |

All shortcuts are **hardcoded**; there is no user keybinding UI and no remapping. (libghostty has its own keybind config, but those bindings drive *terminal* actions, many of which are unwired here — see below.)

### Fullscreen — native works, everything else is dead code
`Fullscreen.swift` is a faithful copy of Ghostty's fullscreen engine with **4 modes** (`native`, `nonNative`, `nonNativeVisibleMenu`, `nonNativePaddedNotch`) implementing dock/menu hiding, notch padding, screen-change handling, and tab-group restore. **None of it is wired in Fantastty.** The Ghostty keybind action `GHOSTTY_ACTION_TOGGLE_FULLSCREEN` posts `Notification.ghosttyToggleFullscreen` (`Ghostty.App.swift:1019`), but **no object observes it** anywhere in the repo (confirmed: zero observers of `ghosttyToggleFullscreen`). So the bundled non-native fullscreen modes are unreachable. Plain **native green-button fullscreen still works** because it is the default AppKit behavior of a titled window — it doesn't need any of this code.

### Command palette — stubbed out
The Ghostty action `GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE` posts `.ghosttyCommandPaletteDidToggle` (`Ghostty.App.swift:1044`), but again **no observer exists** and **no command-palette View exists** in the project. `BaseTerminalController.commandPaletteIsShowing` is a stub returning `false` (`MickeyTermCompat.swift:17`). The brief's "command palette" therefore does **not** exist as a feature in Fantastty today.

### Secure keyboard entry — auto path works, manual toggle is a no-op
Two independent paths:
1. **Automatic (works).** When libghostty detects a password prompt it fires `GHOSTTY_ACTION_SECURE_INPUT` at the surface; if `macos-auto-secure-input` config is on, the handler sets `surfaceView.passwordInput = true` (`Ghostty.App.swift:1616-1626`). That `didSet` registers the surface as a *scoped* secure-input holder (`SurfaceView_AppKit.swift:439-450`), and the global `SecureInput` singleton calls Carbon `EnableSecureEventInput()`. Focus changes and surface teardown update/remove the scope (`SurfaceView_AppKit.swift:751-776`, `720`).
2. **Manual global toggle (no-op).** An app-targeted `GHOSTTY_ACTION_SECURE_INPUT` calls `appDelegate.setSecureInput(mode)` — which is an **empty stub** (`MickeyTermCompat.swift:115`). There is no "Secure Keyboard Entry" menu item. So the user-facing global toggle (referenced in the overlay's help text) is **not implemented**.

When secure input is active and `macos-secure-input-indication` is on, an animated lock-shield badge (`SecureInputOverlay.swift`) is overlaid top-right of the surface (`SurfaceView.swift:180-184`), with a popover explaining the feature.

### App lifecycle
- **Launch** (`AppDelegate.applicationDidFinishLaunching`): installs shell-integration scripts, wires Ghostty action observers into the SessionManager, then — if libghostty is `.ready` — **restores tmux sessions**, falling back to creating a fresh session. Applies the saved appearance and pushes the color scheme into libghostty. Under XCTest it skips all bootstrap unless `FANTASTTY_BOOTSTRAP_DURING_TESTS=1` (`AppDelegate.swift:23-30,36-39`).
- **Last window closed**: `applicationShouldTerminateAfterLastWindowClosed` returns **false** — the app stays running with no windows (dock-only), matching a session-survives-restart model.
- **Quit** (`applicationShouldTerminate`): flushes active-time stats, calls `sessionManager.saveLayout()`, tears down the appearance observer, returns `.terminateNow`.
- **Appearance**: KVO on `NSApp.effectiveAppearance`; in "system" mode a macOS light/dark switch re-pushes the Ghostty color scheme (`AppDelegate.swift:71-74`).

### Settings (⌘,)
A `Settings` scene renders a grouped `Form` (`SettingsView.swift`): appearance segmented picker (System/Light/Dark), "tabs in sidebar" toggle, persistent-sessions (tmux) toggle, remote predictive-echo toggle, and a Linear API-key row (stored in Keychain). Changing appearance both retints app chrome and re-pushes the libghostty color scheme.

### Dock / menu-bar affordances
**None beyond the standard menu bar.** No dock-tile badge, no `requestUserAttention` (no dock bounce), no `LSUIElement`, no `MenuBarExtra`/status item, no `setActivationPolicy` override. "Attention" is surfaced **only** as in-app sidebar flags driven by bell/command-finished notifications.

---

## 3. How it's built (architecture)

### Entry & scene graph
`main.swift` is a top-level script (no `@main`): it calls `ghostty_init(argc, argv)` and aborts on failure, then `FantasttyApp.main()`. `FantasttyApp` (SwiftUI `App`) attaches `AppDelegate` via `@NSApplicationDelegateAdaptor`, injects `appDelegate.ghosttyApp` and `appDelegate.sessionManager` as `environmentObject`s, and declares the single `Window` + `Settings` scenes plus the `.commands { AppCommands(...) }` block (`MickeyTermApp.swift`).

### Ownership
`AppDelegate` owns the three long-lived singletons: `Ghostty.App` (libghostty state), `SessionManager` (all workspaces/tabs/surfaces), and a process-wide `UndoManager`. `AppDelegate` conforms to `GhosttyAppDelegate` (surface-lookup-by-UUID, open-URL hook returning false).

### Command → action routing (two layers, important boundary)
There are **two** parallel command systems:
1. **SwiftUI menu commands** (`AppCommands.swift`) call `SessionManager` methods directly (`createTab`, `newSplit`, `selectNextSession`, …). This is the path that actually works for menu/keyboard.
2. **libghostty keybind actions** → `Ghostty.App` C callback → big `switch (action.tag)` (`Ghostty.App.swift:515`) → per-action `static` handler → `NotificationCenter` post → observed by `SessionManager.setupNotificationObservers()`.

Crucially, the SessionManager **only observes a subset**: `ghosttyNewTab`, `ghosttyCloseSurface`, `ghosttyNewSplit`, `ghosttyGotoTab`, `ghosttyFocusSplit`, `didEqualizeSplits`, `didResizeSplit`, `ghosttyBellDidRing`, `ghosttyCommandFinished` (`SessionManager.swift:1326-1395`). It does **not** observe `ghosttyNewWindow`, `ghosttyToggleFullscreen`, or `ghosttyCommandPaletteDidToggle` — those notifications are posted into the void. This is why new-window/fullscreen/command-palette terminal keybinds are inert while tab/split keybinds work.

### Fullscreen engine (vendored, dormant)
`FullscreenStyle` protocol + `FullscreenBase` (NSWindow fullscreen-notification observer) + `NativeFullscreen` / `NonNativeFullscreen` (+ 2 subclasses). Native mode toggles `window.toggleFullScreen` and tweaks `titlebarSeparatorStyle`. Non-native saves a `SavedState` (style mask, frame, toolbar, titlebar accessory VCs, tab-group position, dock/menu booleans), strips `.titled`/`.resizable`, hides dock/menu via `NSApplication` presentation options, and resizes to a manually-computed `fullscreenFrame` (it avoids `visibleFrame` because that lags an event-loop tick). The menu-hide decision consults macOS Spaces via the CGS private API (`Fullscreen.swift:423-440`) to avoid double-hiding on fullscreen spaces. Threading: enter/exit defer final frame-set to `DispatchQueue.main.async`.

### CGS private Spaces API (`CGS.swift`)
Four private symbols bound with `@_silgen_name`: `CGSMainConnectionID`, `CGSGetActiveSpace`, `CGSSpaceGetType`, `CGSCopySpacesForWindows`. Wrapped in Swift `CGSSpace`/`CGSSpaceMask`/`CGSSpaceType` value types. Used solely by `NonNativeFullscreen.SavedState` — i.e. only reachable through the dormant fullscreen path.

### SecureInput singleton (`SecureInput.swift`)
`ObservableObject` singleton holding `global: Bool` + a `scoped: [ObjectIdentifier: Bool]` map (object → focused). `desired = global || any scoped focused`. `apply()` only acts while `NSApp.isActive` and calls Carbon `EnableSecureEventInput()`/`DisableSecureEventInput()` to reach `desired`, publishing `enabled`. It **yields on app deactivation and reacquires on activation** (`didResignActive`/`didBecomeActive`) because secure input is a **global, stateful OS resource** that would otherwise lock out other apps. `@Published enabled` drives the SwiftUI overlay.

### Compatibility shims (key to the port story)
- `macOS26Compat.swift`: reimplements macOS-26-only APIs against current SDK — `NSScreen.displayID` (via `NSScreenNumber` device description), `NSScreen.hasDock` (frame ≠ visibleFrame), `NSApplication.acquire/releasePresentationOption` (insert/remove on `presentationOptions`), `NSWindow.hasTitleBar`, `NSWorkspace.defaultApplicationURL(forExtension:)`/`defaultTextEditor`.
- `MickeyTermCompat.swift`: **stubs for Ghostty app-layer types Fantastty did not port** — `BaseTerminalController` (NSWindowController-based; all members return nil/false), `TerminalWindow`/`HiddenTitlebarTerminalWindow`, `QuickTerminal*` enums, `QuickTerminalSize`, `InspectableSurface` (→ plain `SurfaceWrapper`, no inspector), `TerminalRestoreError`, and `AppDelegate` extension stubs (`checkForUpdates`, `toggleVisibility`, `toggleQuickTerminal`, `setSecureInput`, `syncFloatOnTopMenu`, `closeAllWindows`). These exist so the vendored `Ghostty.App.swift`/`SurfaceView_AppKit.swift` compile; most are dead paths.
- `Backport.swift`: centralizes macOS-14/15 fallbacks (`pointerStyle`, `pointerVisibility`, `onKeyPress`).

### Private AppKit tab-bar introspection (`NSWindow+Extension.swift:44-82`)
Reaches the private `NSTitlebarView` via KVC (`value(forKey: "titlebarView")`), finds the private `NSTabBar`/`NSTabButton` views by class-name string match, and hit-tests tab buttons at a screen point. Paired with `NSView+Extension.swift` class-name view-tree traversal helpers. This supports native-tab drag/hit detection — but since the app has no native window tabs, its reachability is questionable (likely used by vendored drag code).

### Glue extensions
- `NSEvent+Extension.swift`: builds `ghostty_input_key_s` from an `NSEvent`, including the "control/command never contribute to text translation" heuristic and PUA/function-key filtering for `ghosttyCharacters`.
- `EventModifiers+Extension.swift` / `KeyboardShortcut+Extension.swift`: SwiftUI⇄AppKit modifier bridging and shortcut→glyph rendering.
- `NSAppearance+Extension.swift` + `AppearanceMode.swift`: light/dark resolution and chrome tinting via `NSApp.appearance`.
- `Cursor.swift`: reference-counted `NSCursor.hide()`/`unhide()` plus a `CursorStyle`→`NSCursor` map (with macOS-15 `columnResize`/`rowResize` directional cursors).
- `CrossKit.swift`: `OSView`/`OSColor`/`OSViewRepresentable` typealiases hedging AppKit-vs-UIKit (only AppKit branch is active).

### Entitlements / bundle
`Fantastty.entitlements` requests: `automation.apple-events`, `device.audio-input`, `device.camera`, `network.client`, `personal-information.{addressbook,calendars,location,photos-library}`. **No `com.apple.security.app-sandbox` master key is present** in the entitlements (and no `ENABLE_APP_SANDBOX` in the pbxproj) — these read as a broad, partly-vestigial TCC/hardened-runtime set rather than an active sandbox profile; most (camera/photos/calendars/addressbook/location) have no obvious use in a terminal. `Info.plist`: `NSPrincipalClass=NSApplication`, empty `NSMainStoryboardFile`, local-network usage string, and an **exported UTType `com.mitchellh.ghosttySurfaceId`** (for surface drag-and-drop). Deployment target **macOS 15.0**; bundle id `com.blainecook.fantastty`.

---

## 4. Platform dependencies (macOS-specific)

**Frameworks/idioms**
- **SwiftUI app lifecycle**: `App`, `Scene`, `Window(id:)`, `Settings`, `Commands`/`CommandGroup`/`CommandMenu`, `@NSApplicationDelegateAdaptor`, `NavigationSplitView`, `.keyboardShortcut`, `@AppStorage`, `.sheet`, `.popover`.
- **AppKit**: `NSApplication`/`NSApplicationDelegate` (terminate/last-window hooks), `NSWindow` (`styleMask`, `toggleFullScreen`, `titlebarAccessoryViewControllers`, `toolbar`, `NSWindowTabGroup`, `titlebarSeparatorStyle`, `windowNumber`→`CGWindowID`), `NSScreen` (`frame`/`visibleFrame`/`safeAreaInsets`/`NSScreenNumber`), `NSApp.presentationOptions` (`autoHideDock`/`autoHideMenuBar`), `NSApp.effectiveAppearance` + KVO, `NSAppearance` (`aqua`/`darkAqua`), `NSCursor`, `NSMenuItem`, `NSEvent`/`NSEvent.ModifierFlags`, `NSAlert`, `NSImage(systemSymbolName:)` (SF Symbols), `NSPasteboard`.
- **Carbon (`HIToolbox`)**: `EnableSecureEventInput()` / `DisableSecureEventInput()` — secure keyboard entry.
- **CoreGraphics private (CGS)**: `CGSMainConnectionID`, `CGSGetActiveSpace`, `CGSSpaceGetType`, `CGSCopySpacesForWindows` — macOS **Spaces**; bound via `@_silgen_name` (undocumented, App-Store-hostile).
- **Private AppKit view classes** via KVC/string match: `NSThemeFrame`, `NSTitlebarView` (`"titlebarView"` key), `NSTabBar`, `NSTabButton`.
- **macOS 26 forward-compat targets**: `NSScreen.displayID/hasDock`, `NSApplication.acquire/releasePresentationOption`, `NSWindow.hasTitleBar`, `NSWorkspace.defaultApplicationURL`/`defaultTextEditor`.
- **OS services**: `os.Logger`/`OSLog`, `UserDefaults` (`@AppStorage`), `UNUserNotificationCenter` (delivered-notification cleanup on focus), Keychain (Linear key), `UTType`/exported UTI, app entitlements & code-signing, `NSApplicationMain` principal class.
- **Behavioral macOS assumptions**: green-button native fullscreen as default; menu bar owned by the focused app; secure input as a global OS toggle that must be yielded on deactivate; dock-resident background app after last window closes; SF-Symbol iconography; macOS Spaces semantics for menu-hide decisions; macOS coordinate system (bottom-left origin) in event handling.

---

## 5. Linux mapping

| macOS dependency | Linux-native equivalent | Notes / risk |
|---|---|---|
| SwiftUI `App`/`Window`/`Scene`, `NavigationSplitView` | **GTK4 + libadwaita**: `AdwApplication`, `GtkApplicationWindow`, `AdwNavigationSplitView`/`AdwOverlaySplitView` | Whole shell is a rewrite. Ghostty's own GTK frontend already does this. |
| SwiftUI `Commands`/menus + `.keyboardShortcut` | `GMenu`/`GMenuModel` + `GtkPopoverMenuBar` or header-bar menu button; `GtkShortcutController`/`GtkApplication.set_accels_for_action` | Linux apps usually favor a header-bar hamburger menu over a global menu bar. Map every ⌘ shortcut to a `GAction` accel (⌘→Super or Ctrl — see risk). |
| `NSApplicationDelegate` launch/terminate hooks | `GApplication` `activate`/`startup`/`shutdown` signals; `g_application_hold` for "stay alive with no window" | `applicationShouldTerminateAfterLastWindowClosed=false` ≈ hold the GApplication or run headless until re-shown. |
| Native green-button fullscreen | `GtkWindow.fullscreen()`/`unfullscreen()`, `fullscreened` property | Trivial; replaces both the AppKit default *and* the entire dormant `Fullscreen.swift`. |
| Non-native fullscreen + dock/menu hiding (`presentationOptions`) | Compositor fullscreen (Wayland `xdg-toplevel` fullscreen / X11 `_NET_WM_STATE_FULLSCREEN`); GTK handles panel/dock hiding | No menu bar to hide on Linux; most of this complexity disappears. |
| **CGS private Spaces API** | No portable equivalent. Wayland deliberately hides workspace/output topology; X11 has `_NET_CURRENT_DESKTOP`/EWMH | **Only needed to gate menu-hide; drop it entirely** on Linux. Not a real risk because the whole non-native path is unused. |
| Carbon `EnableSecureEventInput` | **No equivalent.** Wayland already isolates keyboard input per-surface (no global keylogging by other clients); X11 can `XGrabKeyboard` but it is not the same security guarantee | **RISK (mild):** the *security* feature is largely redundant on Wayland and unachievable on X11. Keep the password-prompt *indicator* overlay; the OS-level lockdown becomes a no-op (which matches Fantastty's already-stubbed manual toggle). |
| `NSCursor` hide/unhide + style map | `GdkCursor` (named cursors: `text`, `pointer`, `grab`, `grabbing`, `col-resize`, `row-resize`, `crosshair`, `not-allowed`); hide via blank cursor on the `GdkSurface` | Direct mapping; ref-count pattern ports as-is. |
| `NSApp.effectiveAppearance` KVO (light/dark) | **libadwaita `AdwStyleManager.dark` / `:color-scheme`**, or XDG desktop-portal `org.freedesktop.appearance color-scheme` over D-Bus | Clean equivalent; push scheme into libghostty same as today. |
| `NSAppearance` aqua/darkAqua chrome tint | libadwaita style manager `FORCE_LIGHT`/`FORCE_DARK`/`PREFER…` | Direct. |
| `@AppStorage`/`UserDefaults` | `GSettings` (with a schema) or a TOML/INI under `$XDG_CONFIG_HOME` | GSettings is the idiomatic choice. |
| Keychain (Linux key elsewhere) | **libsecret / Secret Service** (D-Bus) | Standard. |
| `UNUserNotificationCenter` | **libnotify / `GNotification`** (org.freedesktop.Notifications) | Standard. |
| SF Symbols on menu items | GTK named icons / `GThemedIcon` (icon theme), or bundled symbolic SVGs | Pick a freedesktop icon set. |
| `os.Logger`/OSLog | `g_log`/structured logging → journald, or stderr | Direct. |
| Dock background-app, no badge | Taskbar via `.desktop` file; optional Unity launcher badge / `GtkApplication` is enough | Linux DEs vary; "stay resident, no window" maps to a tray icon or just a held GApplication. |
| `NSEvent`→`ghostty_input_key_s`, modifier bridging | **XKB / GTK `GdkEvent`** key handling — Ghostty's GTK frontend already encodes keys via libghostty's C API | Reuse Ghostty GTK's key path; the macOS NSEvent glue is fully replaced. |
| Native NSWindow tab-bar KVC hacks | N/A (app has no real native tabs) | Drop entirely. |
| Exported UTType `ghosttySurfaceId` (drag-drop) | GTK drag-and-drop `GdkContentFormats` MIME type (`application/vnd.mitchellh.ghostty-surface-id`) | The plist already carries the MIME string. |
| Entitlements / sandbox | Flatpak manifest (`finish-args` permissions) or none | Map only the genuinely-used permissions (network, microphone if used); drop the vestigial camera/photos/calendars/addressbook/location. |

---

## 6. Reuse assessment

**Reusable cross-platform Swift/logic (port largely as-is):**
- `AppearanceMode` (`enum` + UserDefaults) — swap `NSApp.appearance` for libadwaita style-manager calls; the enum/state logic is portable.
- `SecureInput` *state machine* (singleton, scoped/global/desired, balance-on-activate) — the logic is sound; only the two Carbon calls become no-ops/stubs on Linux. Worth keeping as the indicator's source of truth.
- `Cursor` ref-count hide/unhide pattern (rebind `NSCursor`→`GdkCursor`).
- The **command set** itself (which actions exist, their shortcuts, enable/disable predicates) is a clean spec to re-express as `GAction`s. The *bindings* to `SessionManager` are platform-neutral.
- The exported surface-drag UTI/MIME contract.

**macOS glue that must be rewritten:**
- The entire SwiftUI scene graph + `AppDelegate` (→ GApplication/GTK).
- `AppCommands` menu construction (→ GMenu/accels).
- `NSEvent+Extension`, modifier/shortcut bridges, `NSAppearance+Extension`, `CrossKit` typealiases.
- All compat shims (`macOS26Compat`, `Backport`) — Linux-irrelevant.
- `NSWindow+Extension`/`NSView+Extension` private-API traversal — delete.

**Delete outright (dormant on macOS, no purpose on Linux):**
- `Fullscreen.swift` (4 modes) + `FullscreenMode+Extension` + `CGS.swift` — never wired; native fullscreen is one GTK call.
- `MickeyTermCompat` stubs — only exist to compile vendored Ghostty files.
- Private NSTabBar hit-testing.

**Reuse from Ghostty's own Linux/GTK frontend (vendored at `inspo/fantastty/vendor/ghostty`):**
- Window/tab/split scaffolding, GTK action wiring, key encoding, color-scheme integration, and native GTK fullscreen are **already implemented** there against the same libghostty C API. The port's app-shell should start from Ghostty-GTK and graft Fantastty's *workspace/sidebar/notes/remote* concepts on top, rather than re-deriving the AppKit shell. This is the single biggest reuse lever for this subsystem.

---

## 7. Open questions / risks

1. **Confirm intent of the dead code.** Fullscreen modes, command palette, and the libghostty new-window/secure-input-toggle actions are all unobserved/stubbed. Decide per-feature whether the Linux port should (a) implement them properly or (b) match current Fantastty behavior (only native fullscreen, no palette, no manual secure-input toggle). The product SPEC should state which.
2. **Command palette is a *missing* feature, not a port target.** If the product wants one, it must be designed fresh (GTK), not ported.
3. **Secure input has no real Linux analog.** Under Wayland the per-surface input isolation makes the *security* goal mostly moot; under X11 it's unachievable without `XGrabKeyboard` hacks. Recommend: keep the password-prompt **indicator** overlay, make the OS lockdown a no-op. Flag for a product decision.
4. **Keyboard-shortcut translation.** Every shortcut is ⌘-based and several deliberately hijack macOS chords (⌘` for workspace cycling, ⌘K for clear-screen which also collides with ⇧⌘K SSH). On Linux, ⌘→Super often conflicts with the window manager; many terminals use Ctrl+Shift. Need a deliberate Linux keymap, not a 1:1 translation.
5. **Single-window model.** Fantastty is intentionally one window with in-app workspaces/tabs. Confirm the Linux port keeps single-window (simpler, matches the workspace metaphor) vs. adopting GTK multi-window — affects the whole shell design.
6. **Stay-resident-after-last-window** behavior (`shouldTerminateAfterLastWindowClosed=false`) needs an explicit Linux story (held GApplication, tray icon, or true quit) since Linux DEs don't have the macOS "app without windows" concept.
7. **Entitlements are over-broad / partly vestigial** (camera, photos, calendars, addressbook, location, audio with **no app-sandbox master key**). Before writing a Flatpak manifest, audit which permissions are actually exercised anywhere in the app — likely only network (+ maybe microphone). Don't port the rest.
8. **macOS 26 forward-compat shims** indicate the codebase straddles SDK versions; none of that matters on Linux but signals the vendored Ghostty files are tracking a moving upstream — pin a known-good libghostty for the port.
