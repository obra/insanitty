# 07 — Remote Engine: Client Side (Swift)

> Source root for all paths below: `inspo/fantastty/`.
> This report covers the macOS **client** of the remote engine: SSH bootstrap → helper
> deploy/launch → QUIC attach → message loop → structured-grid render → predictive echo →
> reconnect/fallback. The Go helper is read only far enough to pin the wire/CLI contract.

## 1. Scope

### Files read in full (client)
- `Fantastty/Models/RemoteEngineClient.swift` (2722 lines) — bootstrap, helper deploy, attach-line
  parse, QUIC transports (typed + legacy), reconnect loop, diagnostics, cert pinning, failure map.
- `Fantastty/Models/RemoteGridProtocol.swift` (335) — Codable wire contract.
- `Fantastty/Models/RemotePaneGridState.swift` (328) — keyframe/delta state machine + validation.
- `Fantastty/Models/RemoteWorkspaceRuntime.swift` (207) — workspace/pane routing → actions.
- `Fantastty/Models/RemoteWorkspaceBridge.swift` (1202) — runtime↔surface bridge, reattach render,
  predictive-echo scheduling, tmux-layout→split-tree mapping.
- `Fantastty/Models/RemotePredictiveEchoEngine.swift` (1119) — conservative local echo.
- `Fantastty/Models/RemoteGridSurfaceRenderer.swift` (191) — render plan + surface push.
- `docs/remote-engine.md` (39) — component overview & known limitations.

### Files read in part
- `tools/remote-engine-helper/helper/quic_service.go` (1431, full) — server attach/control/datagram.
- `tools/remote-engine-helper/helper/remotegrid/protocol.go` (677, full) — Go side of the wire format.
- `tools/remote-engine-helper/helper/main.go` (1189, ~930) — helper CLI, `serve` daemon, bootstrap line.
- `tools/remote-engine-helper/helper/internal/registry/registry.go` (798, key parts) — session/key store.
- `tools/remote-engine-helper/helper/internal/keyring/keyring.go` (121, full) — one-time keys.
- `patches/ghostty-inject-output.patch` (562, key parts) — the libghostty C API the renderer needs.
- `Fantastty/GhosttyBridge/Ghostty.Surface.swift` (lines 57-127) — C-API wrappers.
- `Fantastty/Models/TmuxControlMode/TmuxAttachmentInfo.swift` (164) — `SSHHostInfo`, transport enum.
- `FantasttyTests/RemoteGridProtocolTests.swift` (170 of 614) — JSON fixtures confirming wire shape.
- Consumer wiring in `Fantastty/Models/SessionManager.swift`, `SettingsView.swift`,
  `SurfaceView_AppKit.swift` (via a delegated read; line cites below).

### NOT covered
- tmux control-mode subsystem (separate report), tmux→remote-grid extraction inside the Go helper
  (`remotegrid/pane_model.go`, `ghosttyvt/renderer.go`, `tmux_workspace_source.go`).
- The live-gate operator harnesses (deliberately unshipped per `docs/remote-engine.md`).
- The Go `StreamPump` datagram-coalescing internals beyond what affects the client contract.

---

## 2. What it does (behavior & features)

The remote engine is the alternative transport to tmux control mode for an SSH-hosted tmux
workspace. A workspace's `TmuxAttachmentInfo.transport` is either `.tmuxControl` or `.remoteEngine`
(`TmuxControlMode/TmuxAttachmentInfo.swift:76`); the user picks "Remote engine" in the attach sheet
(`TmuxAttachSheet.swift:200`). When `.remoteEngine`, `SessionManager` runs the flow below instead of
spawning `ssh tmux -CC`.

**End-to-end user flow:**
1. **Bootstrap over SSH.** The app shells out to the system `ssh`/`scp` binaries to (a) probe the
   remote platform (`uname -s && uname -m`), (b) deploy a bundled Go helper + `libghostty-vt`
   shared lib into `~/.cache/fantastty/remote-engine/` if checksums don't already match, and (c)
   run `fantastty-helper launch-or-resume <workspaceID>`. The helper prints one line of attach
   material on stdout.
2. **Attach over QUIC.** The app opens a QUIC connection to the helper's advertised UDP host:port,
   pins the helper's TLS cert by SPKI-SHA256 (delivered in the SSH bootstrap line), then sends a
   one-time `{session,key}` attach request on the first stream.
3. **Render structured grid.** The helper streams `workspaceSnapshot`, `paneKeyframe`, `paneDelta`,
   and `unsupportedPaneState` messages (reliable stream + unreliable datagrams). The app builds a
   pane grid state per pane and pushes rows/cursor into a Ghostty `SurfaceView` (one per tmux pane).
   The workspace snapshot maps tmux windows→tabs and tmux pane layout→a split tree.
4. **Input + control.** Keystrokes in a remote surface are forwarded as `sendKeys`; resizes as
   `resizePane`; tab creation/selection as `newWindow`/`selectWindow`; missing/garbled frames as
   `requestKeyframe`.
5. **Predictive echo.** For plain printable keys (and backspace), the app optimistically paints a
   faint+underlined "tentative" cell locally, then reconciles against authoritative frames.
6. **Reconnect/resume.** On disconnect after at least one frame, the client re-bootstraps (new
   one-time key, possibly resuming the same long-lived helper session), reattaches, and requests
   fresh keyframes for every known pane. UI shows visible reconnecting/disconnected state.
7. **Fallback.** If startup fails *before any pane exists*, the workspace silently falls back to SSH
   tmux control mode. After panes exist, certain failures (pin mismatch, attach rejected) disconnect
   with a visible reason instead of falling back.

**Concrete rules / edge cases:**
- **Attach material is short-lived and single-use.** One-time key TTL = `30s`, session TTL = `8h`
  (`RemoteEngineClient.swift:657`). The key is consumed (deleted) on first QUIC attach; a reconnect
  needs a *new* key via a fresh `launch-or-resume`.
- **Cert pin is mandatory.** Peer auth is `.required`; a non-matching SPKI hash fails the connection
  and is surfaced as `REMOTE_ENGINE_QUIC_PIN_MISMATCH` (`:1057`).
- **Helper version/arch must match the bundled manifest exactly.** The deploy step re-checksums the
  remote copy and verifies the `--version` line equals `fantastty-helper version=<v> arch=<a>`
  (`:567`); a mismatch aborts with `REMOTE_ENGINE_HELPER_VERSION_MISMATCH`.
- **Supported hosts:** `linux/{x86_64,amd64,aarch64,arm64}` and `darwin/arm64` only
  (`:432`); anything else → `unsupported remote platform`.
- **Datagram viability gate.** A keyframe carries `datagramsEnabledAfterKeyframe`. Deltas that
  arrive *over a datagram* are rejected (→ keyframe request) until a keyframe has enabled them;
  reliable-delivered deltas are always accepted (`RemotePaneGridState.swift:85`).
- **Stale/forked frames are dropped, not applied.** Wrong workspace/pane, stale pane generation,
  stale keyframe, or stale delta sequence are silently dropped; generation-ahead or
  baseKeyframe/row-version mismatch trigger a keyframe request.
- **Resize mismatch self-heals.** If the local Ghostty surface size ≠ the frame's grid size, the
  client sends `resizePane` and requests a `resizeMismatch` keyframe rather than rendering a
  mismatched grid (`RemoteWorkspaceBridge.swift:523`).
- **Unsupported panes.** Helper can declare a pane unsupported (image protocol, glyph-glossary
  mutation, unsupported cell attribute, snapshot-extraction failure) with a fallback of
  `keepLastGoodKeyframe` or `blankWithDiagnostic`; the app fences that pane generation.
- **Predictive echo is deliberately conservative** (see §2 below and `docs/remote-engine.md:38`):
  suppressed for alternate-screen, invisible cursor / no output, paste, IME, escape sequences,
  mouse, focus loss, reattach, resize, and any authoritative mismatch; rolled back on contradiction
  with a cooldown.
- **Diagnostics are redacted.** The support bundle omits one-time keys, cert pins, raw typed input,
  pane contents, shell commands, and local paths (`RemoteEngineClient.swift:1653`).

---

## 3. How it's built (architecture)

### 3.1 Control/data flow
```
SessionManager (MainActor, owns one client per remote workspace)
  └─ RemoteEngineClient(workspaceID, materialProvider, transport, reconnectPolicy,
                        messageHandler, reattachHandler, stateHandler)
       materialProvider = SSHRemoteEngineBootstrapper.attachMaterial(...)
            ├─ RemoteEngineHelperDeployer.ensureDeployed()  → scp + ssh (posix_spawn)
            └─ ssh "<helper> launch-or-resume <ws>"        → "FANTASTTY_REMOTE ..." line
       transport       = RemoteEngineNWQUICTransport()      (Network.framework)
       messageHandler  → RemoteWorkspaceBridge.handle(msg, delivery)
       reattachHandler → RemoteWorkspaceBridge.handleReattach(ws)
       stateHandler    → SessionManager.applyRemoteEngineState()

RemoteWorkspaceBridge
  ├─ RemoteWorkspaceRuntime (per ws)   → [RemoteWorkspaceRuntimeAction]
  │      ├─ RemotePaneGridState (per pane) — keyframe/delta apply + validate
  │      └─ tmux-window→tab, layout→SplitTree<SurfaceView>
  ├─ RemotePredictiveEchoEngine (per pane) — local overlay
  └─ RemoteGridSurfaceRenderer → Ghostty.SurfaceView (libghostty C API)
```
`SessionManager` wires the bridge's outbound handlers back to the client:
`keyframeRequestHandler`/`paneInputHandler`/`paneResizeHandler` → the matching
`RemoteEngineClient` method (`SessionManager.swift:322-345`).

### 3.2 The reconnect loop (`RemoteEngineClient.run()`, `:1172`)
A single detached `Task` loops while not cancelled: `connecting`/`reconnecting` → call
`materialProvider()` (re-bootstrap each attempt) → `transport.connect()` with a 10s timeout box
(`:1250`) → install connection → if reattaching, call `reattachHandler` → `connected` → drain
`connection.messages` (an `AsyncThrowingStream`) on the MainActor → on end/throw, decide
`reconnecting` vs `disconnected` per `RemoteEngineReconnectPolicy` (`.forever`: 1s delay, unlimited;
`.once`: single attempt). Outbound control requests are serialized through a single FIFO `Task`
chain (`enqueueOutbound`, `:1320`); an outbound failure tears down the connection with a reason.
State is guarded by one `NSLock`; all user-facing handlers hop to `@MainActor`.

### 3.3 Bootstrap line contract (`RemoteEngineBootstrapLine.parse`, `:21`)
Helper prints (Go `bootstrapLine`, `main.go:215`):
```
FANTASTTY_REMOTE port=<n> session=<64hex> key=<64hex> expires=<RFC3339> \
  helper_pid=<n> version=<v> arch=<a> quic_addr=<host:port|[v6]:port> \
  quic_cert_sha256=<64hex> quic_alpn=fantastty-remote-engine-v1
```
The Swift parser ignores `port=` and takes host:port from `quic_addr`; requires `session`/`key`/
`quic_cert_sha256` to be 64-char lowercase hex; `expires` via ISO8601. After parse, the client
rewrites `host` to its own resolved **advertise host** (see §3.4) keeping the helper's port
(`:740`). Extra unknown fields are tolerated. Material fields: workspaceID, host, port, session,
key, expires, helperPID, helperVersion, helperArch, certSHA256, alpn (`:7`).

### 3.4 Advertise-host resolution (`:760`)
For a bare alias (no dots, not an IP), the client runs `ssh -G` to read `hostname`, then probes
`$SSH_CONNECTION` (field 3 = server IP) and `hostname -I` on the remote, intersecting against the
Mac's local IPv4 networks (via `getifaddrs`) to prefer a LAN address reachable by UDP. An explicit
`advertiseHostOverride` short-circuits this. This exists because QUIC/UDP must reach the helper
directly, unlike SSH-tunneled control mode.

### 3.5 Helper deployment (`RemoteEngineHelperDeployer.ensureDeployed`, `:508`)
`uname` probe → pick artifact label (`linux-amd64`/`linux-arm64`/`darwin-arm64`) → load
`Bundle.main/RemoteEngine/manifest.json` and verify local artifact SHA256 (`RemoteEngineHelperManifest`,
`:901`). Remote dir `~/.cache/fantastty/remote-engine` (`chmod 700`). If the remote helper+lib
checksums don't already match, `scp` both to `.tmp`, verify with `sha256sum -c -` (linux) /
`shasum -a 256 -c -` (darwin), `mv` into place, `chmod 700/600`, and for linux create
`libghostty-vt.so.0`→`.so.0.1.0` and `.so`→`.so.0` symlinks. Launch env: `env -u XDG_RUNTIME_DIR
FANTASTTY_REMOTE_ADVERTISE_HOST=<h> LD_LIBRARY_PATH|DYLD_LIBRARY_PATH=<lib> <helper>
launch-or-resume <ws> --ttl 8h --key-ttl 30s [--tmux-session <name>]`. SSH/scp run via `posix_spawn`
in `RemoteEngineProcessRunner` (`:187`).

### 3.6 Wire protocol (`RemoteGridProtocol.swift`; Go `remotegrid/protocol.go`)
Messages are **newline-delimited JSON** on the reliable QUIC stream; **datagrams are a single
`paneDelta` JSON** (no newline). The JSON is Swift `Codable`'s enum encoding, which the Go helper
hand-mirrors. Enum-with-payload encodes as `{"<case>": {"_0": <payload>}}`; enum-with-labeled-payload
uses the labels.

**Top-level `RemoteWorkspaceMessage`** (`:330`):
- `{"workspaceSnapshot": {"_0": <WorkspaceSnapshot>}}`
- `{"paneKeyframe": {"_0": <PaneKeyframe>}}`
- `{"paneDelta": {"_0": <PaneDelta>}}`
- `{"unsupportedPaneState": {"_0": <UnsupportedPaneState>}}`
- Attach error (first line only): `{"error": "<msg>"}` → thrown as `RemoteEngineError.remote`
  (`RemoteEngineMessageLineDecoder.decodeLine`, `:1460`).

**WorkspaceSnapshot** `{workspaceID, layoutGeneration:u64, windows[], panes[]}`.
- `WorkspaceWindow` `{windowID:int, title, index:int?, isActive:bool, layout:string?}` —
  `layout` is a raw tmux layout string parsed by `TmuxLayoutParser`.
- `WorkspacePane` `{paneID:int, windowID:int, isActive:bool, frame:{x,y,columns,rows}}`.

**PaneKeyframe** `{workspaceID, paneID:int, paneGeneration:u64, keyframeID:u64,
gridSize:{columns,rows}, rows:[GridRow], cursor:CursorState, activeScreen:"primary"|"alternate",
datagramsEnabledAfterKeyframe:bool}`.

**PaneDelta** `{workspaceID, paneID, paneGeneration:u64, baseKeyframeID:u64, deltaSequence:u64,
rowUpdates:[RowUpdate], cursor:CursorState?}`.

**GridRow** has two encodings (`:109`): full `{index, rowVersion:u64, cells:[GridCell]}` or compact
`{index, rowVersion, text:"<string>"}` (one normal-style width-1 cell per scalar). Decoder accepts
both; the Go helper emits compact when every cell is width-1/normal-style.

**RowUpdate** `{rowIndex:int, rowVersion:u64, update:RowUpdateBody}` where body is one of (`:208`):
- `{"fullRow": {"_0": [GridCell]}}`
- `{"fullRowText": {"_0": "<string>"}}` (compact full-row; decode-only on Swift, emitted by Go compact path)
- `{"span": {baseRowVersion:u64, startColumn:int, cells:[GridCell], clearToColumn:int?}}`

**GridCell** `{text:string, width:int, style:CellStyle}`; width 1 or 2 (2 ⇒ next cell must be the
continuation `{text:"",width:0}`). **CellStyle** has `foreground/background/underlineColor` +
booleans `bold/faint/italic/blink/inverse/invisible/strikethrough` + `underline` enum
(`none|single|double|curly|dotted|dashed`). **Color** = `{"default":{}}` |
`{"indexed":{"_0":u8}}` | `{"rgb":{"red","green","blue"}}`.

**CursorState** `{row:int, column:int, visible:bool, shape:"block"|"bar"|"underline",
cursorVersion:u64}` — `cursorVersion` is required and must be > 0 (`RemoteGridProtocolTests:58`).

**UnsupportedPaneState** `{workspaceID, paneID, paneGeneration, reason, fallback}` with
reason ∈ {imageProtocol, glyphGlossaryMutation, unsupportedCellAttribute, snapshotExtractionFailure}
and fallback ∈ {keepLastGoodKeyframe, blankWithDiagnostic}.

**Client→helper control requests** (newline-JSON, sent on any client-opened stream; the helper
accepts the main bidi stream, additional bidi streams, and uni streams — `quic_service.go:376-413`):
- `{"type":"requestKeyframe","workspaceID","paneID","reason":"<string>"}`
- `{"type":"sendKeys","workspaceID","paneID","data":"<base64>"}` (Swift `Data`→base64; chunked at
  2048 bytes, `:1901`)
- `{"type":"resizePane","workspaceID","paneID","columns","rows"}`
- `{"type":"newWindow","workspaceID"}`
- `{"type":"selectWindow","workspaceID","windowID"}`
Attach request (first thing on first stream): `{"session":"<hex>","key":"<hex>"}\n`.

### 3.7 Grid state machine (`RemotePaneGridState`, `RemoteWorkspaceRuntime`)
`apply(keyframe)` (`RemotePaneGridState.swift:39`): drops stale (wrong ws/pane, lower generation,
≤ current keyframeID); else validates (cols/rows > 0, row count == rows, unique in-range row
indices, each row width == columns via `wcwidth`-based `displayWidth`, cursor in bounds,
cursorVersion > 0) and replaces state. `apply(delta)` (`:64`): requires a prior keyframe; checks
ws/pane/generation/baseKeyframe; enforces datagram viability; validates row updates; applies only
rows with `rowVersion > current` (span requires `baseRowVersion == current`); updates cursor only if
`cursorVersion` increases; bumps `lastDeltaSequence`. Returns `.applied | .dropped(reason) |
.needsKeyframe(reason)`. `RemoteWorkspaceRuntime.handle()` (`:16`) maps results to actions
(`applyWorkspaceSnapshot`, `renderPaneGrid`, `requestKeyframe`, `showUnsupportedPaneState`) and fences
unsupported pane generations. `handleReattach()` clears pane states and requests `noKeyframe` for all
panes.

### 3.8 Predictive echo (`RemotePredictiveEchoEngine`)
Pure value type. Only `directKey` (single printable scalar, display width 1 or 2) and
`plainEraseByte` (0x7F/0x08) are eligible (`:7`). New predictions start **hidden** until echo
confidence is proven (the authoritative cursor advances past a hidden prediction whose cell matches),
then subsequent predictions render as **visible** faint+underline overlays after `latencyThreshold`
(50ms). Reconciliation against each authoritative frame proves a matching prefix, or **contradicts**
→ `clear(.mismatch)` → cooldown (500ms; `.infinity` "fail-closed" if no timestamp). `noAckTimeout`
(250ms) without acknowledgement also clears + cooldowns. Backspace pops the last visible prediction
into an "erased pending" set reconciled separately. The engine refuses prediction unless
`activeScreen==.primary`, the cursor is visible, the overlay preserves wide-cell boundaries, and it
is not crossing the last column. Overlay is applied via `RemotePaneGridState.displayCopy(overlay:)`
which marks `tentativeRows` (`:135`). The bridge schedules overlay (re)renders with a timer
(`schedulePredictionRender`, `RemoteWorkspaceBridge.swift:964`) and rolls back to authoritative on
focus loss/reattach/mismatch.

### 3.9 Rendering (`RemoteGridSurfaceRenderer` → `RemoteGridSurface`)
`render()` builds a plan (bounds: ≤1000×1000, ≤250k cells, ≤4096 bytes/row, exact column-width
match) then for each row calls `surface.setRemoteGridRow(_:cells:)`, falling back to `text:` and
sanitized-ASCII `text:` forms; sets the cursor. The `RemoteGridSurface` protocol
(`RemoteGridSurfaceRenderer.swift:4`) is implemented by `Ghostty.SurfaceView.surfaceModel`, whose
methods call a **patched libghostty C API** (`Ghostty.Surface.swift:57-127`):
`ghostty_surface_remote_grid_reset/set_row/set_row_cells/set_cursor/set_cursor_ex` with
`ghostty_remote_grid_cell_s/style_s/color_s`. The bridge diffs against the last rendered identity
(grid size, generation, keyframeID, active screen) to choose full reset vs. per-row updates
(`renderIdentity`, `rowsToRender`).

### 3.10 QUIC transport (`RemoteEngineNWQUICTransport`, `:1751`) — **Network.framework**
Two implementations, chosen by `preferredConnectionMode()`:
- **macOS 26+ typed API** `RemoteEngineTypedQUICConnection` (`:1852`): uses
  `NetworkConnection<QUIC>`, `QUIC.Stream<QUICStream>`, `QUIC.Datagrams<QUICDatagram>`,
  `NWParametersBuilder.parameters { QUIC(alpn:).maxDatagramFrameSize(1200).tls.certificateValidator{…}
  .tls.peerAuthentication(.required) }`. Opens a stream, reads `connection.datagrams`, spawns reliable
  + datagram receive `Task`s.
- **Legacy** `RemoteEngineNWQUICConnection` (`:2168`): `NWConnection` + `NWProtocolQUIC.Options`
  (`direction=.bidirectional`, `maxDatagramFrameSize=1200`), with
  `sec_protocol_options_set_verify_block` for pinning; reliable via `connection.receive`, datagrams
  via `connection.receiveMessage`, sends via `.contentProcessed`.

Both decode reliable bytes with `RemoteEngineMessageLineDecoder` (split on `0x0A`) and datagrams as a
single `paneDelta`, yielding `RemoteEngineInboundMessage(message, delivery)` to the client's stream.

### 3.11 Security model
- **Trust bootstrap = SSH.** The cert pin and one-time key are delivered only over the SSH channel.
- **Cert pinning by SPKI-SHA256** of the helper's P-256 cert. `certificateSPKISHA256(trust:)`
  (`:2698`) extracts the leaf via `SecTrustCopyCertificateChain` → `SecCertificateCopyKey` →
  `SecKeyCopyExternalRepresentation` (expects the 65-byte uncompressed EC point, `0x04` prefix),
  prepends a hardcoded P-256 `SubjectPublicKeyInfo` ASN.1 DER prefix, and SHA256s it. This exactly
  reproduces Go's `x509.MarshalPKIXPublicKey` + SHA256 (`quic_service.go:1371`).
- **One-time keys**: 32 random bytes → 64 hex, minted with 30s TTL, consumed (deleted) on attach,
  bound to `{session, workspace}` (`keyring.go`, `registry.ConsumeKey`). Not persisted by the app.
- **Diagnostics redaction** (`:1653`) and the doc's redaction contract (`docs/remote-engine.md:26`).
- **Runtime dir safety** (helper side): `FANTASTTY_REMOTE_RUNTIME_DIR` / `$XDG_RUNTIME_DIR/...` /
  `/tmp/fantastty-remote-engine-<uid>`, 0700, owner-checked; sockets 0600; peer-UID checks
  (`registry.go:116`, `ErrPeerUIDMismatch`).

### 3.12 Concurrency
Client state under one `NSLock`; a single `run()` Task; serial outbound Task chain; per-connection
receive Tasks. Handlers (`messageHandler`/`reattachHandler`/`stateHandler`) run on `@MainActor`.
`RemotePaneGridState`/`Runtime`/`PredictiveEchoEngine`/all protocol types are `Sendable` value types
(pure logic, trivially portable). `RemoteWorkspaceBridge` is a reference type driven from the
MainActor; render closures use `MainActor.assumeIsolated`.

---

## 4. Platform dependencies (macOS-specific)

| Area | API / idiom | Where |
|---|---|---|
| **QUIC transport (typed)** | `NetworkConnection<QUIC>`, `QUIC`, `QUIC.Stream<QUICStream>`, `QUIC.Datagrams<QUICDatagram>`, `NWParametersBuilder`, `.tls.certificateValidator`, `.tls.peerAuthentication`, `#available(macOS 26.0,*)` | `:1758`, `:1852-1963` |
| **QUIC transport (legacy)** | `NWConnection`, `NWProtocolQUIC.Options`, `NWParameters(quic:)`, `NWEndpoint`, `sec_protocol_options_set_verify_block`, `.contentProcessed` | `:2168-2431` |
| **Cert pinning / trust** | `Security`: `sec_trust_t`, `sec_trust_copy_ref`, `SecTrustCopyCertificateChain`, `SecCertificateCopyKey`, `SecKeyCopyExternalRepresentation`, `SecCertificate`, `CFError` | `:2581-2722` |
| **Hashing** | `CryptoKit.SHA256` (artifact checksums + SPKI pin) | `:2679`, `:2721` |
| **Process spawn (ssh/scp)** | Darwin `posix_spawn`, `posix_spawn_file_actions_*`, `pipe`, `waitpid`, `kill`, `strdup` | `:187-345` |
| **Local-network probe** | `getifaddrs`/`freeifaddrs`, `sockaddr_in`, `IFF_UP`/`IFF_LOOPBACK`, `AF_INET` | `:787-820` |
| **Text width** | `Darwin.wcwidth` | `RemoteGridProtocol.swift:93` |
| **Bundle/resources** | `Bundle.main.resourceURL` (bundled helper artifacts) | `:415` |
| **Grid surface sink** | libghostty C API `ghostty_surface_remote_grid_*` + `ghostty_surface_inject_output` (added by `patches/ghostty-inject-output.patch`), `ghostty_surface_size_s`, `GhosttyKit` module, AppKit `Ghostty.SurfaceView` | `Ghostty.Surface.swift:57`, `RemoteWorkspaceBridge.swift:762` |
| **Settings** | `@AppStorage`/`UserDefaults` key `remotePredictiveEchoEnabled`, SwiftUI `Toggle` | `SettingsView.swift:8,60` |
| **Scheduling** | `DispatchQueue.main.asyncAfter`, Combine `$surfaceSize.debounce(...).sink` | `RemoteWorkspaceBridge.swift:128,802` |

Note: SSH credentials are **not** in the macOS Keychain — auth is delegated entirely to the system
`/usr/bin/ssh` (agent/keys). The only crypto secrets the app handles are the ephemeral cert pin and
one-time key, neither persisted.

---

## 5. Linux mapping

| macOS dependency | Linux-native replacement | Notes / risk |
|---|---|---|
| **Network.framework QUIC** (typed + `NWConnection`) | A Linux QUIC client lib: **quiche** (Cloudflare, C/Rust, C API), **msquic**, **lsquic**, or Go's **quic-go** (the helper already uses it). | **Largest single rewrite.** No GTK/Wayland equivalent; this is a library choice. The helper is `quic-go`; mirroring with quiche/msquic from a Swift-on-Linux or C/Rust client is clean. Need: ALPN `fantastty-remote-engine-v1`, client datagrams enabled, custom cert verification (skip CA, pin SPKI). |
| `sec_protocol`/`Security` SPKI pin | Extract leaf cert DER from the QUIC lib's verify callback; SHA256 of `SubjectPublicKeyInfo` via **OpenSSL** (`i2d_PUBKEY`/`X509_get_X509_PUBKEY`) or Rust `rustls`/`x509-parser`. | Straightforward; the hashed bytes are identical to Go's `RawSubjectPublicKeyInfo`. The Swift hand-rolled P-256 SPKI prefix is unnecessary on Linux (use the lib's DER SPKI directly). |
| `CryptoKit.SHA256` | OpenSSL `SHA256`, libgcrypt, or Rust `sha2`. | Trivial. |
| `posix_spawn` ssh/scp | Same `posix_spawn`/`fork+exec`, GLib `g_spawn_async_with_pipes`, or just keep `posix_spawn` (POSIX, already cross-platform). | Trivial; `ssh`/`scp` exist on Linux. |
| `getifaddrs` local-net probe | `getifaddrs` is **POSIX/Linux-native** (glibc). | Reuse as-is. |
| `Darwin.wcwidth` | glibc `wcwidth` (set `LC_CTYPE`), or reuse Ghostty's `unicode.table.width` (the patch already does). | Prefer the libghostty unicode table for parity with the helper. |
| `ghostty_surface_remote_grid_*` C API | **Reuse identically** — apply the same `patches/ghostty-inject-output.patch` to the vendored ghostty when building libghostty for Linux. The Zig impl writes into `terminal.Terminal`/`terminal.Style` (cross-platform), not AppKit. | The Linux renderer (GTK/OpenGL) is also a libghostty consumer, so the patched C API drives the same surface. **Key reuse win.** |
| `Bundle.main.resourceURL` for helper artifacts | XDG: ship helper+lib under `/usr/lib/insanitty/remote-engine/` (or `$XDG_DATA_DIRS`); load `manifest.json` the same way. | Easy; helper already builds `linux-amd64/arm64`. |
| `@AppStorage`/`UserDefaults` toggle | `GSettings`/`Gio.Settings` or a config file under `$XDG_CONFIG_HOME`. | Easy. |
| `DispatchQueue.main`/Combine timers | GLib main loop `g_timeout_add` / GTK tick callbacks; Combine `$surfaceSize` → GTK size-allocate signal. | Easy; logic is in portable structs. |
| AppKit `Ghostty.SurfaceView` embedding | GTK4 `GtkGLArea` widget hosting the Ghostty OpenGL renderer (Ghostty's own GTK apprt), with the same `remotePaneInputHandler`/`tmuxPaneID` shims. | Surface-embedding work is shared with the non-remote port; the remote bridge only needs `reset/setRow/setCursor/resize/size`. |

No Linux blocker has *no* equivalent. The one hard, opinion-shaped choice is the **QUIC client
library** (see §7).

---

## 6. Reuse assessment

**Ports almost as-is (pure Swift value logic; or rebuild in the port's language with identical
semantics):**
- The entire **wire protocol** (`RemoteGridProtocol.swift`) and its decoders
  (`RemoteEngineMessageLineDecoder`, datagram/reliable frame decoders). The JSON shape is fully
  specified in §3.6 and mirrored by the Go helper.
- The **grid state machine** (`RemotePaneGridState`), **runtime routing**
  (`RemoteWorkspaceRuntime`), **predictive echo** (`RemotePredictiveEchoEngine`), and **render plan**
  (`RemoteGridSurfaceRenderer`) — all `Sendable` structs with no platform imports except
  `Darwin.wcwidth` (one call) and the `RemoteGridSurface` protocol boundary. If the port keeps
  Swift, these compile on swift-corelibs-foundation untouched. If not, they are a precise spec.
- The **bootstrap-line parser**, **advertise-host logic**, **helper-deploy/checksum logic**, and
  **failure→user-reason mapping** (`RemoteEngineFailurePresentation`) — Foundation + POSIX only.
- The **reconnect/outbound-queue/diagnostics** machinery — Foundation + `NSLock`/`Task`.

**Must be rewritten (macOS glue):**
- The **QUIC connection classes** (`RemoteEngineTypedQUICConnection`, `RemoteEngineNWQUICConnection`)
  — replace Network.framework with a Linux QUIC lib behind the existing `RemoteEngineTransport` /
  `RemoteEngineConnection` protocols (these protocols are the clean seam; `:924-947`).
- The **cert-pin extraction** (`certificateSPKISHA256`) — reimplement against the QUIC lib's verify
  callback (simpler than the macOS version since the lib gives DER SPKI directly).
- The **surface adapter** in `Ghostty.Surface.swift` (AppKit) — re-point at the GTK surface, same C
  calls.
- The **settings/diagnostics surfacing** (`@AppStorage`, SwiftUI `Toggle`, diagnostic logging) → GTK.

**Reused from Ghostty's own Linux frontend / vendored ghostty:**
- The **`ghostty_surface_remote_grid_*` + `ghostty_surface_inject_output` C API** (the patch) — the
  same patched libghostty serves the GTK/OpenGL renderer. This is the renderer the remote engine
  pushes into; no separate "remote renderer" exists.
- The **Go helper itself is unchanged** — it already builds `linux-amd64`/`linux-arm64`. The Linux
  client speaks the same protocol to the same binary.

---

## 7. Open questions / risks

1. **QUIC library choice (highest risk).** Network.framework has no Linux analog; the port must
   select and integrate a QUIC client (quiche / msquic / lsquic / quic-go) supporting: client-sent
   **unreliable datagrams**, custom SPKI **cert pinning** (verify callback, no CA chain), ALPN, and
   stream + datagram concurrency. The macOS client sets `maxDatagramFrameSize=1200`; confirm the
   chosen lib negotiates datagrams ≥ that with the `quic-go` helper (helper advertises
   `EnableDatagrams`, idle 2m, keep-alive 10s; constant `remoteQUICMaxDatagramFrameSize=16383`). The
   `RemoteEngineTransport`/`RemoteEngineConnection` protocol seam makes this swap localized but the
   library work is real.
2. **Same-connection QUIC migration is explicitly NOT a contract** (`docs/remote-engine.md:37`):
   the product behavior is *app-layer pinned reconnect with visible reconnect/resume state*. The
   Linux client should replicate the reconnect loop (new one-time key each attempt) rather than rely
   on QUIC connection migration — keeps library requirements lower.
3. **libghostty patch must be carried.** The Linux build must apply `patches/ghostty-inject-output.patch`
   (or upstream it) when building `libghostty`/`libghostty-vt`; without it the remote-grid C API and
   the helper's `libghostty-vt` snapshot path don't exist. Verify the patch still applies to the
   vendored ghostty revision used for the Linux build.
4. **Swift-on-Linux vs. rewrite.** Decide whether to keep the portable Swift logic (needs
   swift-corelibs-foundation + the QUIC binding) or re-implement these ~3k lines of state-machine/
   predictive-echo logic in the port's language. Keeping Swift maximizes reuse; the predictive-echo
   engine especially is subtle and well-tested (`RemotePredictiveEchoEngineTests.swift`, 1458 lines).
5. **`wcwidth` parity.** macOS `Darwin.wcwidth` vs glibc `wcwidth` vs Ghostty's unicode table can
   disagree on emoji/CJK widths; grid validation rejects width mismatches, which would surface as
   spurious keyframe requests. Prefer the libghostty unicode width for client/helper parity.
6. **`localizedDescription`-based failure classification.** `RemoteEngineFailurePresentation.presenting`
   (`:979`) string-matches error text to pick failure codes and fallback eligibility. Network.framework
   error strings differ from a Linux QUIC lib's, so this mapping must be re-tuned on Linux or the
   fallback/disconnect decision will misfire.
7. **Advertise-host heuristics assume LAN reachability.** The UDP path needs a directly reachable
   helper address; the `ssh -G` + `$SSH_CONNECTION` + `hostname -I` probing (`:760`) is reused
   verbatim but its assumptions (no NAT between client and helper UDP port) are a deployment risk
   independent of platform.
