# 09 — Platform Dependency Audit (master) + Auxiliary Integrations

Scope of this report: (Part 1) the **whole-tree, framework-by-framework macOS dependency
audit** — the canonical "what makes Fantastty macOS-only and how to undo that" reference; and
(Part 2) deep-dives of the **auxiliary integrations**: Fly.io **Sprites**, WebKit **browser
tabs**, **Linear** API + **Keychain**, desktop **notifications**.

---

## 1. Scope

**Read in full:**
- `Fantastty/Models/SpriteManager.swift` (194 lines)
- `Fantastty/Views/Sprite/SpriteConnectionSheet.swift` (177)
- `Fantastty/Views/Browser/BrowserTabView.swift` (125)
- `Fantastty/Models/LinearService.swift` (244)
- `Fantastty/Models/ShellIntegration.swift` (138)
- `Fantastty/GhosttyBridge/CGS.swift` (82)
- `Fantastty/GhosttyBridge/KeyboardLayout.swift` (14)
- `Fantastty/GhosttyBridge/SecureInput.swift` (135)
- `Fantastty/App/main.swift` (11), `App/MickeyTermApp.swift` (22)
- `Fantastty/Info.plist`, `Fantastty/Fantastty.entitlements`
- `Fantastty/Models/SessionType.swift` (sprite/ssh command synthesis, l.40–70)

**Surveyed by grep across the entire `Fantastty/` tree (120 Swift files, ~32.3K LOC):** every
`import` statement; usage of `NS*`/`CA*`/`CG*`, `TIS*`/Carbon, `Sec*`/`kSec*`, `UN*`,
`WK*`/WebKit, `MTL*`/`MTK*`, `NW*`/QUIC, CryptoKit, `CTFont`, `UTType`, `Transferable`,
`AppIntents`, `Logger`/os, Combine, Darwin, filesystem/dir idioms, `UserDefaults`,
`Bundle.main`, `NSPasteboard`, `NSWorkspace`, drag/drop.

**Targeted reads** of the platform-sensitive sites in `RemoteEngineClient.swift` (QUIC + TLS
pin), `SurfaceView_AppKit.swift` (notifications, pasteboard, CTFont), `Ghostty.App.swift`
(notifications), `MetalView.swift`, `Ghostty.Inspector.swift`.

**NOT covered in depth** (belongs to sibling reports): the libghostty surface-embedding internals,
the tmux control-mode subsystem, the remote-engine wire protocol/QUIC behavior, and the SwiftUI→GTK
view-layer rewrite. This report enumerates their *framework* dependencies and Linux mappings but does
not re-derive their behavior.

---

## 2. What it does (behavior & features) — auxiliary integrations

### 2a. Fly.io Sprites (cloud-VM workspaces)
A workspace can be backed by a **Fly.io "Sprite"** — a remote cloud VM — instead of a local or SSH
shell. User-facing flow (`SpriteConnectionSheet`):
- Menu opens a "New Sprite Workspace" sheet. On appear it runs `sprite list` and shows the existing
  sprites in a selectable list, plus a name text field.
- If the `sprite` CLI is **not installed**, the sheet shows a "sprite CLI not found" message linking
  `https://fly.io/docs/sprites/` and hides the action buttons.
- **Connect**: creates a workspace whose session type is `.sprite(name:)`. The session's launch
  command is literally `sprite console -s "<name>"` (`SessionType.swift:53`), i.e. a *local* pty that
  shells into the cloud VM via the CLI. It is also tmux-wrapped (`spriteConsoleCommand`, l.67–70).
- **Create & Connect**: runs `sprite create [name]`, then connects to the returned/typed name.
- Sprites can be destroyed via `sprite destroy -s <name> -f`.
- Edge cases handled: empty CLI output, non-zero exit (surfaces stderr as `SpriteError.createFailed`),
  CLI-not-found guard on every operation, name defaulting when `create` prints nothing.

### 2b. WebKit browser tabs
A tab can be `kind == .browser` (`TerminalTab.webView: WKWebView?`, `TerminalTab.swift:31`). It renders
as a Chrome-less browser pane (`BrowserTabView`): a URL bar with **back / forward / reload** buttons,
an **"open in system browser"** button (`NSWorkspace.shared.open`, l.33), and a URL field that
auto-prefixes `https://` when the input has no scheme (l.69). Page **title** and **current URL** are
synced back to the tab model from navigation callbacks (used for the sidebar/tab label). The live
`WKWebView` is also snapshotted (`takeSnapshot`) to produce **tab/sidebar/overview thumbnails**
(`WorkspaceOverviewView.swift:106`, `TabThumbnailPanel.swift:261`, `SidebarThumbnailView.swift:122`).

### 2c. Linear integration
Parses `linear.app` URLs out of notes/text and renders rich ticket/project cards:
- `parseLinearURL` (l.74–93) recognizes issue URLs (`…/issue/TEAM-123`) and project URLs
  (`…/project/<uuid>`).
- `fetchIssue` / `fetchProject` call the **Linear GraphQL API**
  (`https://api.linear.app/graphql`, POST, `Authorization: <rawKey>`) and decode issue
  (identifier, title, state, assignee, priority, nested sub-issues) and project (name, progress,
  targetDate, first 20 issues) data. Results are cached in-memory for **300 s** (`cacheTTL`).
- The API key is entered in settings and persisted in the **macOS Keychain**; `apiKey` is published
  for the UI. Empty key deletes the stored item.

### 2d. Desktop notifications
Ghostty surfaces raise notifications (terminal bell / OSC 9 / OSC 777 "command finished" style). The app
**requests notification authorization** at startup (`Ghostty.App.swift:1525`) and posts
`UNNotificationRequest`s with title/body/sound (`SurfaceView_AppKit.swift:2101–2118`). Clicking a
notification is routed through `UNUserNotificationCenterDelegate` (`Ghostty.App.swift:2233–2243`,
`UNNotificationDefaultActionIdentifier`) to focus the originating surface/workspace.

### 2e. Secret storage (Keychain)
Only **one secret** is stored: the Linear API key, as a `kSecClassGenericPassword` item
(service `com.blainecook.fantastty`, account `linear-api-key`). The remote engine's `Security` import
is **not** keychain — it is TLS certificate-chain extraction for QUIC pinning (see §4).

---

## 3. How it's built (architecture) — auxiliary integrations

| Feature | Key type | Mechanism | Cross-platform? |
|---|---|---|---|
| Sprites | `SpriteManager` (singleton `ObservableObject`) | Foundation `Process`/`Pipe` shell-out to a `sprite` binary discovered by probing 4 paths; async on `DispatchQueue.global`; parses stdout lines into `SpriteInfo` | **Yes** — pure Foundation. Only the probe-path list and CLI availability are OS-specific |
| Browser | `WebViewRepresentable: NSViewRepresentable` + `Coordinator: WKNavigationDelegate` | Wraps a `WKWebView`, stores it on the tab model; navigation delegate syncs title/url; `takeSnapshot` for thumbnails | **No** — WebKit/AppKit-bound |
| Linear | `LinearService` (singleton `ObservableObject`) | `URLSession` async/await GraphQL; `JSONSerialization`; regex URL parse; in-memory TTL cache; `SecItemAdd/CopyMatching/Delete` for the key | **Mostly** — only Keychain is macOS-bound |
| Notifications | `Ghostty.App` + `SurfaceView_AppKit` | `UNUserNotificationCenter.current()`, `UNMutableNotificationContent`, delegate callbacks | **No** — UserNotifications-bound |

**Sprite probe paths** (`SpriteManager.swift:17–22`): `~/.local/bin/sprite`, `/usr/local/bin/sprite`,
`/opt/homebrew/bin/sprite`, `~/.fly/bin/sprite`. Three of four are already Linux-valid; only
`/opt/homebrew` is macOS-specific.

**Threading**: Sprites/Linear offload to background queues and marshal results to `@MainActor`/main; the
reactive surface is **Combine `@Published`** on the `ObservableObject`s (46 `@Published` sites tree-wide).

---

## 4. Platform dependencies (macOS-specific) — MASTER AUDIT

Framework inventory by number of importing Swift files (whole tree):

| Framework | Files | What the app actually uses it for |
|---|---:|---|
| **SwiftUI** | 47 | Entire view layer, `App`/`Scene`, `@Published`/`ObservableObject` binding, `Window`/`Settings` scenes |
| **Foundation** | 44 | `Process`, `Pipe`, `FileManager`, `URLSession`, `URLRequest`, `JSONSerialization`, `Data`/`Date`, `NotificationCenter`, regex — **cross-platform** |
| **GhosttyKit** | 34 | libghostty C API (`ghostty_init`, surfaces, input). C ABI — **cross-platform** |
| **AppKit** | 24 | `NSView`/`NSWindow`/`NSEvent`/`NSApplication`, `NSPasteboard`, `NSImage`, `NSColor`, `NSScrollView`, `NSMenu`, `NSDraggingSession`, `NSWorkspace`, `NSTextInputClient`, `NSCursor`, `NSScreen` |
| **Cocoa** | 8 | Same family (umbrella import) — `NSEvent`, `NSAppearance`, `NSImage`, secure input |
| **os** / **OSLog** | 9 / 1 | `os.Logger(subsystem:category:)` structured logging in ~10 model classes |
| **Combine** | 8 | `@Published`, `AnyCancellable`, `.sink`, `PassthroughSubject`, `objectWillChange` — reactive backbone |
| **WebKit** | 5 | `WKWebView`, `WKNavigationDelegate`, `takeSnapshot` (browser tabs + thumbnails) |
| **UniformTypeIdentifiers** | 4 | `UTType` for pasteboard/drag types + the custom `ghosttySurfaceId` UTI |
| **UserNotifications** | 3 | `UNUserNotificationCenter`, `UNMutableNotificationContent`, `UNNotificationRequest`, response delegate |
| **Darwin** | 3 | POSIX/libc (termios, sockets, byte order) in remote-engine + tmux client |
| **Security** | 2 | (a) Keychain `SecItem*` (Linear key); (b) `SecTrustCopyCertificateChain`/`SecCertificateCopyKey`/`SecKeyCopyExternalRepresentation` for QUIC TLS pinning |
| **CoreTransferable** | 2 | `Transferable` conformances for surface drag/drop |
| **Carbon** | 2 | (a) `TISCopyCurrentKeyboardInputSource`/`TISGetInputSourceProperty`/`kTISPropertyInputSourceID` (keyboard-layout ID); (b) `EnableSecureEventInput`/`DisableSecureEventInput` |
| **Network** | 1 | `NWConnection`, `NWEndpoint`, `NWParameters`, `NWProtocolQUIC`, `NWQUICConnection`, `sec_protocol_options_set_verify_block` — **QUIC client transport** |
| **MetalKit** / **Metal** | 1 / 1 | `MTKView` (renderer surface host); `MTLDevice`/`MTLCommandBuffer`/`MTLRenderPassDescriptor` (Ghostty inspector) |
| **CryptoKit** | 1 | `SHA256` over the server SPKI for certificate pinning |
| **CoreText** | 1 | `CTFont` (font metrics in the AppKit surface view) |
| **CoreGraphics** | 1 expl. | `CGFloat`/`CGRect`/`CGSize`/`CGPoint`/`CGWindowID` geometry pervasively; `CATransaction` |
| **AppIntents** | 1 | `KeyboardShortcut` synthesis for input triggers (`Ghostty.Input.swift`) |
| **UIKit** | 2 | Only inside `#if canImport(UIKit)` branches (iOS) — **dead code on the macOS/Linux target** |
| *private* **CGS** | — | `@_silgen_name` CoreGraphics-Services: `CGSMainConnectionID`, `CGSGetActiveSpace`, `CGSSpaceGetType`, `CGSCopySpacesForWindows` — macOS **Spaces** detection |

### App lifecycle / bundle / filesystem idioms
- **Entry point** (`main.swift`): calls libghostty `ghostty_init(argc, argv)` then `FantasttyApp.main()`.
  `FantasttyApp` is a SwiftUI `App` driven by `@NSApplicationDelegateAdaptor(AppDelegate.self)`
  (`MickeyTermApp.swift:4–5`). `NSPrincipalClass = NSApplication`, no storyboard.
- **`Bundle.main.bundleIdentifier`** — used as the os.Logger subsystem and the Keychain service string
  (constant `com.blainecook.fantastty`).
- **`Bundle.main.resourceURL`** (`RemoteEngineClient.swift:415`) — locates the **bundled Go remote-engine
  binary** shipped in `Resources/RemoteEngine/`.
- **`UserDefaults.standard`** — appearance mode, a few small prefs (`AppearanceMode.swift:25`,
  `SessionManager.swift:367–370`, `SurfaceView_AppKit.swift:1397`).
- **`Fantastty.entitlements`** — App Sandbox entitlements: `network.client`,
  `automation.apple-events`, audio-input, camera, addressbook, calendars, location, photos.
  (Most are unused-looking template grants; `network.client` + apple-events are the meaningful ones.)
- **`Info.plist`** — `UTExportedTypeDeclarations` registers the custom UTI
  `com.mitchellh.ghosttySurfaceId` used for surface drag/drop; `NSLocalNetworkUsageDescription` for
  the remote-engine LAN connections.
- **Data/config directory**: the app already centralizes on **`~/.fantastty/`** (theme, layout,
  SSH host store, session metadata, shell integration). Reached via
  `FileManager.default.homeDirectoryForCurrentUser` and `NSHomeDirectory()`. **No meaningful
  `~/Library` usage** other than the Keychain (which is accessed through the Security API, not by path).

---

## 5. Linux mapping

Severity key: **LOW** = mechanical/clean equivalent · **MED** = real work, well-trodden ·
**HIGH** = hard / risky / possibly no equivalent.

| macOS dependency | Linux-native replacement | Sev |
|---|---|---|
| **SwiftUI** (whole view layer) | **GTK4 + libadwaita** (`Gtk.Application`, `Adw.ApplicationWindow`, widgets). Full UI rewrite — owned by the UI-layer report. | HIGH (effort) |
| **AppKit / Cocoa** widgets | GTK4 per-widget: `NSView`→`GtkWidget`, `NSWindow`→`GtkWindow`/`GdkSurface`, `NSScrollView`→`GtkScrolledWindow`, `NSTextField`→`GtkEntry`/`GtkText`, `NSAlert`→`AdwAlertDialog`, `NSMenu`/`NSMenuItem`→`GMenu`/`GtkPopoverMenu`, `NSCursor`→`GdkCursor`, `NSColor`→`GdkRGBA`, `NSImage`→`GdkTexture`/`GdkPixbuf`, `NSScreen`→`GdkMonitor`, `NSEvent`→`GdkEvent` + `GtkEventController*`, `NSTrackingArea`→`GtkEventControllerMotion`, `NSTextInputClient`→`GtkIMContext` | HIGH (volume, but mechanical) |
| **`NSApplication`/`@NSApplicationDelegateAdaptor`** lifecycle | `GApplication`/`GtkApplication` (`activate`, `startup`, `open` signals); single-instance via `G_APPLICATION_HANDLES_OPEN` | MED |
| **`NSWorkspace.shared.open(url)`** | `gtk_show_uri()` / `g_app_info_launch_default_for_uri()` (xdg-open under the hood) | LOW |
| **`NSPasteboard`** (clipboard) | `GdkClipboard` (GTK4) over the Wayland `wl_data_device` / X11 selections; the custom `ghosttySelection` type → a custom MIME type | LOW–MED |
| **`NSDraggingSession`/`NSDraggingSource`/`NSItemProvider` + `Transferable`/`UTType`** (surface DnD) | GTK4 DnD: `GtkDragSource`/`GtkDropTarget` + **`GdkContentProvider`**; UTIs → MIME types via **GIO `GContentType`**; the `ghosttySurfaceId` UTI → an `application/vnd.mitchellh.ghostty-surface-id` MIME type (already declared in Info.plist) | MED |
| **WebKit `WKWebView`** | **WebKitGTK** `WebKitWebView` (`libwebkitgtk-6.0`, GTK4). `load_uri`, `go_back`/`go_forward`/`reload`; `WKNavigationDelegate` → `"load-changed"`/`notify::title`/`notify::uri` signals; `takeSnapshot` → `webkit_web_view_get_snapshot()` (async). Runs out-of-process via **WebKitWebProcess** automatically. | LOW–MED |
| **Keychain `SecItem*`** (Linear key) | **libsecret** (Secret-Service over D-Bus → gnome-keyring / KWallet). `kSecClassGenericPassword{service,account}` → a `SecretSchema` with `service`+`account` string attributes; `secret_password_store/lookup/clear_sync`. | LOW |
| **UserNotifications `UN*`** | **libnotify** (`NotifyNotification`) **or** `GNotification` via `g_application_send_notification()` → **org.freedesktop.Notifications** D-Bus. Click routing → notification `"activated"` signal / `GNotification` default action. No authorization prompt needed (portal handles it under Flatpak). | LOW |
| **Network `NWConnection`/`NWProtocolQUIC`** (remote engine) | **No `Network.framework` on Linux.** Replace the QUIC client with a C/Rust QUIC lib — **quiche** (Cloudflare), **ngtcp2** (+ OpenSSL/wolfSSL), **msquic**, **lsquic**, or **quinn** (Rust via FFI). The Go helper already speaks QUIC server-side (quic-go). | **HIGH (RISK)** |
| **`sec_protocol_options_set_verify_block` + `SecTrust*`/`SecKey*` + CryptoKit SPKI pin** | The chosen QUIC lib's TLS verify callback (OpenSSL/BoringSSL `X509`); SPKI extraction via `i2d_X509_PUBKEY` + **swift-crypto** `SHA256` (drop-in for CryptoKit on Linux). | MED (tied to QUIC rewrite) |
| **CryptoKit `SHA256`** | **swift-crypto** (`import Crypto`) — Apple's cross-platform package (BoringSSL-backed). Source-compatible. | LOW |
| **Carbon `TIS*`** (keyboard-layout ID) | **xkbcommon** (`xkb_keymap` layout name) and/or Wayland `wl_keyboard` keymap; under GTK, `gdk_display`/`GdkDevice` layout info. Used only to label the active layout. | LOW–MED |
| **Carbon `EnableSecureEventInput`** (anti-keylogger during password entry) | **No clean Linux equivalent.** Wayland already isolates keyboard input per-client (the threat is largely absent by design); X11 has *no* equivalent (other clients can grab the keyboard). Likely **drop the feature** and document the platform difference. | **MED–HIGH (RISK)** |
| **Metal / MetalKit** (`MTKView`, inspector `MTL*`) | **OpenGL/EGL.** libghostty's **native Linux/GTK frontend already ships an OpenGL renderer** + `GtkGLArea` surface host — reuse it instead of porting the Metal path. | LOW–MED (reuse) |
| **CoreText `CTFont`** | **fontconfig + FreeType + HarfBuzz + Pango.** In practice grid text rendering is **libghostty's** own font stack (already Linux-native); the `CTFont` sites are in the AppKit surface host being replaced. | LOW |
| **CoreGraphics geometry** (`CGRect/CGSize/CGPoint/CGFloat`) + `CATransaction` | GTK uses `graphene_rect_t`/`cairo`/`Gsk` geometry; `CATransaction` (implicit-animation batching) → GTK frame-clock / `GtkSnapshot`. Pervasive but trivial structs. | LOW–MED |
| **AppIntents `KeyboardShortcut`** | GTK accelerators: `GtkShortcut`/`gtk_accelerator_parse`, `GtkShortcutController`. | LOW |
| **Combine** (`@Published`/`ObservableObject`/`sink`) | **OpenCombine** (Swift package, Linux-supported) for near-drop-in reuse, **or** rework to GObject `notify::`/signals if the model layer is rewritten in GTK idiom. | LOW (OpenCombine) |
| **os.Logger / OSLog** | **swift-log** (`Logging`), or GLib `g_log_structured` / journald. The `subsystem/category` pattern maps to logger labels. | LOW |
| **Foundation** | **swift-corelibs-foundation** on Linux: `Process`, `Pipe`, `FileManager`, `URLSession`, `JSONSerialization`, `NotificationCenter`, regex all present. Watch for known gaps (some `URLSession` config, `FileManager` attribute edges). | LOW |
| **Darwin** | `Glibc` module (termios, sockets, `htonl` etc.). | LOW |
| **`UserDefaults`** | **GSettings** (dconf schema) for the idiomatic path, or a keyfile in `$XDG_CONFIG_HOME`. | LOW |
| **`Bundle.main` resources / bundleIdentifier** | No app bundle on Linux: ship the Go remote-engine binary in `libexec`/`$XDG_DATA_DIRS` (or `GResource`); replace `bundleIdentifier` with a compile-time app-ID constant. | LOW–MED |
| **`~/.fantastty` / `NSHomeDirectory`** | Works as-is on Linux, but **idiomatic** is XDG: `$XDG_CONFIG_HOME/fantastty` (`~/.config`), `$XDG_DATA_HOME/fantastty` (`~/.local/share`), `$XDG_STATE_HOME`, `$XDG_CACHE_HOME`. Recommend XDG with `~/.fantastty` as fallback. | LOW |
| *private* **CGS Spaces** (`CGSCopySpacesForWindows`, active-space type) | **No equivalent.** macOS "Spaces" has no Wayland counterpart; X11 has partial `_NET_WM_DESKTOP`/`_NET_CURRENT_DESKTOP` (EWMH virtual desktops). Used for fullscreen/space detection — **drop or stub** on Linux. | **MED (RISK)** |
| **App Sandbox entitlements** | No macOS sandbox; for distribution use **Flatpak portals** (network is default-on; secrets/notifications via portals). | LOW |
| **`sprite` / `flyctl` CLI** | Fly's tooling is cross-platform; `sprite` is installable on Linux (the `~/.local/bin` & `~/.fly/bin` probe paths are already Linux-style). Add Linux paths, drop `/opt/homebrew`. | LOW |

---

## 6. Reuse assessment

**Ports essentially as-is (cross-platform Swift, no macOS API):**
- `SpriteManager` — pure Foundation `Process`/`Pipe`. Only fix: probe-path list
  (`SpriteManager.swift:17–22`) should add `/usr/bin`, keep `~/.local/bin`/`~/.fly/bin`, drop
  `/opt/homebrew`. The connection itself (`sprite console -s "<name>"`) is a plain local command.
- `LinearService` minus Keychain — `URLSession` + `JSONSerialization` + regex parsing + TTL cache are
  all swift-corelibs-foundation. Only the three `SecItem*` calls (l.208–243) need a libsecret backend
  behind the same `saveAPIKey/loadAPIKey/deleteAPIKey` interface.
- `ShellIntegration` — writes zsh ZDOTDIR-proxy + OSC-7 DCS-passthrough scripts into `~/.fantastty`.
  Entirely shell/Foundation; **no macOS deps**. (`fantastty.sh` resource ships as-is.)
- `SessionType` command synthesis (ssh/sprite/local) — string-building only.
- The model/persistence layer broadly (theme, layout, session metadata) — Foundation + Combine; reusable
  with **OpenCombine**.

**Must be rewritten (macOS glue):**
- The entire SwiftUI/AppKit view layer (browser URL bar included — but its *logic* is trivial; the
  `WebViewRepresentable` becomes a `WebKitWebView` host).
- `WebViewRepresentable`/`Coordinator` → WebKitGTK host + signal handlers.
- Notifications glue (`Ghostty.App`/`SurfaceView_AppKit` UN* sites) → libnotify/GNotification.
- Keychain backend → libsecret.
- `SecureInput` (Carbon) → drop/stub.
- `CGS.swift` (Spaces) → drop/stub.
- `KeyboardLayout` (TIS) → xkbcommon.
- The QUIC client transport + TLS-pin verify in `RemoteEngineClient` → C/Rust QUIC lib + OpenSSL
  verify callback (keep swift-crypto for the SHA256 pin).

**Reuse from Ghostty's own Linux/GTK frontend (do NOT re-port the Metal path):**
- The **OpenGL renderer** and **`GtkGLArea` surface embedding** — replaces `MetalView`/`MTKView` and the
  AppKit `SurfaceView` host wholesale.
- libghostty's **font stack** (fontconfig/HarfBuzz) — replaces the `CTFont` sites.
- GTK keyboard/input/IME plumbing — informs the `NSEvent`/`NSTextInputClient` replacement.

---

## 7. Open questions / risks

1. **QUIC client transport (HIGH).** `Network.framework`'s QUIC is Apple-only and the remote engine is
   a headline feature. Picking and integrating a Linux QUIC stack (quiche / ngtcp2 / msquic / quinn) is
   the single biggest *non-UI* port risk, including re-implementing the **SPKI certificate-pinning**
   verify callback (`sec_protocol_options_set_verify_block` → OpenSSL/BoringSSL X509 verify). Sibling
   remote-engine report should own the lib selection; flagging it here for the master risk list.
2. **`sprite` CLI availability on Linux (LOW–MED).** Confirm the Fly.io Sprites CLI ships a Linux build
   and that `sprite console`/`list`/`create`/`destroy` have identical syntax. The Swift wrapper is fine;
   the dependency is the external binary.
3. **Secure keyboard entry (MED–HIGH).** No Linux equivalent to `EnableSecureEventInput`. Decide:
   silently drop, or expose a documented "not available on Linux" state. Wayland's per-client input
   isolation makes the *risk* it mitigates much smaller; X11 cannot mitigate it at all.
4. **macOS Spaces detection (MED).** `CGS` Spaces logic has no Wayland analogue. Determine what feature
   depends on it (fullscreen/active-space behavior) before deciding stub vs. EWMH-on-X11.
5. **Combine strategy (LOW, but decide early).** OpenCombine gives near-zero-churn reuse of the
   `@Published`/`ObservableObject` model layer; a GObject rewrite is cleaner GTK-idiom but costs churn.
   This choice ripples through every model file (8 import sites, 46 `@Published`).
6. **swift-corelibs-foundation parity (LOW–MED).** Validate `URLSession` (Linear HTTPS), `Process`
   (sprite/tmux), and `FileManager` behave identically on Linux — these are load-bearing and
   occasionally have subtle gaps.
7. **Config dir convention.** Keep `~/.fantastty` (works, minimal churn) vs. move to XDG (idiomatic).
   Recommend XDG with `~/.fantastty` fallback; note the shell-integration scripts hard-code
   `~/.fantastty/...` paths and would need updating in lockstep.
