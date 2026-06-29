# 08 — Remote-Engine Helper (Go) & Build/Packaging/CI

> Scope assignment: (A) the remote-engine helper (Go, `tools/remote-engine-helper/helper/`)
> — the server side that already runs on Linux remote hosts; (B) the build/packaging/CI system.
> Key question: is the Go helper **reusable as-is on Linux** (it already targets Linux), and what
> exactly must the Linux client speak to it?

---

## 1. Scope

### Files read in full (Go helper — Scope A)
- `tools/remote-engine-helper/helper/main.go` (1190) — CLI surface, `serve` daemon, control socket, bootstrap line
- `tools/remote-engine-helper/helper/quic_service.go` (1431) — QUIC server/client, TLS/cert, attach auth, datagram writer
- `tools/remote-engine-helper/helper/remotegrid/protocol.go` (678) — wire types (keyframe/delta/snapshot/cell/etc.)
- `tools/remote-engine-helper/helper/remotegrid/pane_model.go` (608) — keyframe/delta state machine
- `tools/remote-engine-helper/helper/remotegrid/latest_reliable_outbox.go` (351) — reliable last-value-wins outbox
- `tools/remote-engine-helper/helper/remotegrid/latest_delta_outbox.go` (260) — datagram coalescing outbox
- `tools/remote-engine-helper/helper/ghosttyvt/renderer.go` (687) — **cgo bridge to libghostty-vt**
- `tools/remote-engine-helper/helper/ghosttyvt/doc.go` (3), `renderer_factory_ghosttyvt.go` (12), `renderer_factory_unavailable.go` (15)
- `tools/remote-engine-helper/helper/internal/engine/stream_pump.go` (926) — reliable/datagram flow control & reconciliation
- `tools/remote-engine-helper/helper/internal/engine/workspace.go` (490) — workspace orchestration, `PaneRenderer` interface
- `tools/remote-engine-helper/helper/internal/registry/registry.go` (798) — session store, locking, peercred validation
- `tools/remote-engine-helper/helper/internal/registry/peercred_linux.go` (27) — `SO_PEERCRED`
- `tools/remote-engine-helper/helper/internal/keyring/keyring.go` (121) — one-time attach keys
- `tools/remote-engine-helper/helper/internal/artifact/manifest.go` (46) — artifact selection + checksum verify
- `tools/remote-engine-helper/helper/tmuxcc/{stream.go (75), model.go (502), output.go (76), output_buffer.go (82)}` — tmux control-mode parser
- `tools/remote-engine-helper/helper/tmux_workspace_source.go` (183), `tmux_workspace_process.go` (791) — tmux control-mode driver
- `tools/remote-engine-helper/helper/workspace_source.go` (456) — multi-client fan-out hub
- `tools/remote-engine-helper/helper/workspace_messages.go` (183), `tmux_smoke.go` (382, header read) — bootstrap smoke harness
- `go.mod` / `go.sum` — dependency pins

### Files read in full (build/packaging/CI — Scope B)
- `Makefile` (22), `project.yml` (47), `scripts/build-release.sh` (111)
- `tools/remote-engine-helper/package_app_artifacts.sh` (121), `verify_app_artifacts.py` (73)
- `.github/workflows/build-and-release.yml`, `doc/GITHUB_ACTIONS_SETUP.md`, `scripts/add_to_xcode.py`
  (via a dedicated sub-investigation, cross-checked against the small files read directly)

### NOT covered
- `*_test.go` (read selectively for behavior confirmation, not line-by-line).
- The macOS Swift client implementation of the protocol was investigated by a parallel agent;
  its findings are folded into §2/§7. The full vendored Ghostty Zig source is an **uninitialized
  submodule** (`vendor/ghostty`, pinned `5d0a82ba…`), so `libghostty-vt`'s internal Zig build is
  inferred from the build invocations, not read.

---

## 2. What it does (behavior & features)

The helper is a **single self-contained Go binary** (`fantastty-helper`) that the macOS app deploys to
an SSH host and runs there. It turns a tmux session on the remote host into a **structured terminal
grid streamed over QUIC** to the client, with input flowing back. It is the entire server side of the
"remote engine" feature and it is **Linux-native today** (the rendering path only compiles on Linux).

### CLI surface (`main.go:159`)
- `--version` → `fantastty-helper version=<v> arch=<goarch>`.
- `launch-or-resume <workspace> [--tmux-session N] --ttl D --key-ttl D` — **the entry point the app
  calls over SSH.** Idempotent: resumes an existing live session for the workspace or starts a new
  `serve` daemon. Prints one **bootstrap line** (the handshake) to stdout (`main.go:215`):
  ```
  FANTASTTY_REMOTE port=<udpHealthPort> session=<id> key=<oneTimeKey> expires=<RFC3339>
     helper_pid=<pid> version=<v> arch=<goarch> quic_addr=<host:port>
     quic_cert_sha256=<spkiHex> quic_alpn=fantastty-remote-engine-v1
  ```
- `serve --workspace --session --ttl --runtime-dir --ready-file [--tmux-session]` — the long-lived
  daemon (spawned internally, detached via `setsid`; not called by the user). `main.go:664`.
- `shutdown --session <id>` — SIGTERM the daemon, kill its private tmux session, drop the registry row.
- `cleanup-dry-run` — audit stale private tmux sockets (reports actions, removes nothing).
- Probe verbs used by integration tests: `attach-probe`, `message-probe`, `quic-probe`,
  `quic-reconnect-probe`, `input-probe`. These exercise the real attach/QUIC/input pipeline.

### User-facing contract / behaviors
- **Persistence & resume.** A workspace maps to a tmux session that survives client disconnects and
  helper restarts of the *client*. Sessions have a TTL; while ≥1 client is attached the session is
  pinned, and when the last client detaches an **idle TTL** countdown starts (`registry.go:383`,
  `main.go:118`). Expired idle sessions are pruned and their tmux killed.
- **External vs private tmux.** With `--tmux-session NAME` the helper attaches the host's **default
  tmux server** (`tmux -C attach-session -t NAME`) — i.e. it can front an existing user tmux session.
  Without it, the helper runs a **private tmux server** on its own socket
  (`tmux -f /dev/null -S <socket> -C new-session -A -s fantastty-remote-<workspace>`)
  (`tmux_workspace_process.go:79`).
- **Multiple simultaneous clients.** One workspace session fans out to many attached QUIC clients;
  all receive the same keyframes/deltas (`workspace_source.go` `engineWorkspaceSource`).
- **Live grid streaming.** Each tmux pane's raw output is fed through a headless Ghostty VT engine to
  produce a cell grid; the client receives a full **keyframe** (snapshot) then incremental **deltas**.
- **Input, resize, window ops.** Client can `sendKeys`, `resizePane`, `requestKeyframe`, `newWindow`,
  `selectWindow`. Keystrokes are injected via tmux `send-keys -H <hex>` (`tmux_workspace_process.go:475`).
- **Flow control & repaint.** tmux `%pause`/`%continue` (set via `pause-after=1`) is honored: a paused
  pane is continued and a fresh keyframe recaptured so the client never desyncs (`:350`–`:418`).
- **Graceful degradation.** Panes Ghostty can't represent (image protocols, unsupported attributes,
  snapshot failures) emit an `unsupportedPaneState` message instead of corrupt grid (`protocol.go:350`).
- **Security:** one-time attach keys (consumed on first use), TLS cert **public-key pinning**, and a
  local control socket gated by `SO_PEERCRED` UID match. Runtime state is per-UID, mode `0700`.

---

## 3. How it's built (architecture)

### 3.1 End-to-end data flow (server side)
```
tmux (-C control mode)
  │  %output / %layout-change / %window-* notifications (stdout)
  ▼
tmuxcc.Model.ApplyLine ──► tmuxcc.Action {WorkspaceSnapshot | PaneOutput | PaneFlow}   (model.go:75)
  │
  ▼
engine.Workspace.Handle ──► drives PaneRenderer per pane                               (workspace.go:58)
  │                              │
  │                              ▼
  │                       ghosttyvt.Renderer  (cgo → libghostty-vt: vt_write + render_state)
  │                              │  produces RenderUpdate {Keyframe | Delta | Unsupported}
  │                              ▼
  │                       remotegrid.PaneModel  (keyframe/delta state machine)          (pane_model.go)
  ▼
LatestReliableOutbox (snapshots, keyframes, unsupported, delta-fallbacks)              (latest_reliable_outbox.go)
LatestDeltaOutbox    (coalesced pane deltas)                                           (latest_delta_outbox.go)
  │
  ▼
engineWorkspaceSource  (fan-out hub; retains current state for late joiners)           (workspace_source.go)
  │  PublishReliable / PublishDatagrams to each subscribed StreamPump
  ▼
engine.StreamPump  (per-connection; reliable vs datagram scheduling + reconciliation)  (stream_pump.go)
  │  reliable → QUIC stream (newline-delimited JSON);  datagrams → QUIC datagrams
  ▼
QUIC connection (quic-go)  ──────────────────────────────────────────────►  client    (quic_service.go)
```

### 3.2 The ghosttyvt renderer — **confirmed: it links libghostty-vt** (`ghosttyvt/renderer.go:1`)
Build constraint `//go:build linux && cgo && ghostty_vt`; cgo preamble
`#cgo pkg-config: libghostty-vt` / `#include <ghostty/vt.h>`. It runs a **headless Ghostty terminal
emulator** (no GPU, no display) purely as a VT state machine + cell-grid extractor:
- `ghostty_terminal_new` / `_free` — a terminal with `cols`/`rows`, `max_scrollback=0` (`:147`).
- `ghostty_terminal_vt_write(term, bytes, len)` — feed raw PTY bytes through the VT parser (`:211`).
- `ghostty_render_state_new` / `_update(state, term)` — snapshot the live grid (`:160`,`:235`).
- Row/cell iterators (`ghostty_render_state_row_iterator_*`, `_row_cells_*`) extract per-cell grapheme
  UTF-8, width (narrow/wide/spacer), SGR style (bold/italic/underline styles/inverse/…), and
  fg/bg/underline colors (default/palette/RGB) (`:274`–`:564`).
- Cursor position/visibility/shape and **active screen (primary/alternate)** are read from the render
  state / terminal (`:566`,`:650`).
The extracted cells are pushed into a `remotegrid.PaneModel` via `SetRow`/`SetCursor`/`SetActiveScreen`,
which diffs against the previous frame to emit a **keyframe** (when structural — resize/screen-switch —
or first frame) or a **delta** (dirty rows + cursor). This is the same terminal engine the macOS app
uses locally, reused here only for its grid model.

> The Linux app would link the **same `libghostty-vt`** for its *own* local rendering needs, and the
> helper artifact for Linux is exactly the one the macOS build already produces. No new VT work.

### 3.3 The QUIC service (`quic_service.go`)
- **Library:** `github.com/quic-go/quic-go v0.60.0` (pure-Go QUIC; `go.mod`). Other deps:
  `golang.org/x/sys v0.45.0` (peercred/flock/signals), `golang.org/x/crypto`, `golang.org/x/net`
  (indirect, pulled by quic-go). Go **1.25.0**.
- **ALPN:** `fantastty-remote-engine-v1` (`quic_service.go:32`). `MinVersion: TLS 1.3`.
- **Cert / pinning (the trust model):** on startup the server generates an **ephemeral ECDSA P-256
  self-signed cert** (CN/DNS `fantastty-remote-engine`, IP `127.0.0.1`, 24 h validity) (`:1371`). It
  advertises `sha256(SubjectPublicKeyInfo)` hex as `quic_cert_sha256`. The client sets
  `InsecureSkipVerify: true` but supplies a `VerifyPeerCertificate` that recomputes the SPKI SHA-256
  and rejects on mismatch (`:1342`). So trust = **leaf public-key pin delivered out-of-band via the
  SSH bootstrap line**, not a CA. No private key ever leaves the host.
- **Datagrams enabled** (`EnableDatagrams: true`), `MaxIdleTimeout 2m`, `KeepAlivePeriod 10s`
  (`:1363`). Max datagram frame size constant 16383; pump caps payloads at **1200 bytes**
  (`stream_pump.go:16`) and falls back to a reliable delta when over.
- **Listen address:** `0.0.0.0:0` (ephemeral UDP port). The advertised host comes from
  `FANTASTTY_REMOTE_ADVERTISE_HOST`, else falls back to `127.0.0.1` (`:1414`, `main.go:762`). **How
  the client reaches that UDP port is a deployment concern — see §7.**
- **Connection lifecycle** (`handleRemoteQUICConnection`, `:279`):
  1. Accept conn → accept first **bidirectional stream** (the attach/control stream).
  2. Read one JSON line `{"session":…,"key":…}` (≤4096 B) and **consume the one-time key**
     (`consumeRemoteAttachKey`, `:575`), validating it belongs to this workspace+session. On failure
     write `{"error":…}\n` and close.
  3. `Lifecycle.ClientAttached()` (refcount; cancels idle timer; bumps registry `active_clients`).
  4. Build a `StreamPump` (reliable writer = the stream; datagram writer = the conn). Datagrams start
     **paused**. `SubscribeKeyframes` queues initial keyframes.
  5. **Ordering invariant:** flush reliable first (initial keyframe(s) land on the stream), *then*
     `ResumeDatagrams()` and flush again. The client is guaranteed a reliable keyframe **before** any
     datagram delta — the "reliable keyframe barrier" verified by `quic-reconnect-probe`.
  6. Concurrently serve client requests arriving on the attach stream **and** on any additional
     bidi/uni streams the client opens (`:376`,`:397`). *(In practice the real Swift client opens
     exactly **one** bidirectional stream and uses it for the attach request, all commands, and all
     server→client reliable messages; the extra acceptors are unused by it.)*
- **Datagram writer coalescing** (`remoteQUICDatagramWriter`, `:161`): pending datagrams are keyed by
  `(workspaceID, paneID)` and merged with `LatestDeltaOutbox` so only the freshest delta per pane is on
  the wire. On `DatagramTooLargeError` the delta (and any pending deltas that depend on it — same pane
  generation/base keyframe + overlapping row versions) is **promoted to the reliable channel** to keep
  the client consistent (`:708`,`:821`).

### 3.4 Protocol — full enumeration (the Linux-client contract)

**Framing.** Two channels on one QUIC connection:
- **Reliable** = a QUIC stream carrying **newline-delimited JSON** objects.
- **Unreliable** = QUIC **datagrams**, each a single compact-JSON `paneDelta`.

**Encoding is Swift-`Codable`-shaped** (definitive proof the wire format targets the Swift client):
enums encode as a single-key object with associated values under `_0`, e.g.
`{"paneKeyframe":{"_0":{…}}}`, `{"indexed":{"_0":N}}`, `{"fullRow":{"_0":[…cells]}}`,
`{"span":{…}}`, `{"default":{}}`, `{"rgb":{"red":…}}`. The Go side hand-writes these via custom
`MarshalJSON` (`protocol.go:41`, `:585`, `:418`).

**Server → client (reliable stream lines)** — envelope key selects the case (`protocol.go:585`):

| Envelope key | Go type | Key fields | Meaning |
|---|---|---|---|
| `workspaceSnapshot` | `WorkspaceSnapshot` | `workspaceID`, `layoutGeneration`, `windows[]`, `panes[]` | Layout: windows (`windowID`,`title`,`index`,`isActive`,`layout`) + panes (`paneID`,`windowID`,`isActive`,`frame{x,y,columns,rows}`). |
| `paneKeyframe` | `PaneKeyframe` | `workspaceID`,`paneID`,`paneGeneration`,`keyframeID`,`gridSize`,`rows[]`,`cursor`,`activeScreen`,`datagramsEnabledAfterKeyframe` | Full grid snapshot for a pane. |
| `paneDelta` | `PaneDelta` | `workspaceID`,`paneID`,`paneGeneration`,`baseKeyframeID`,`deltaSequence`,`rowUpdates[]`,`cursor?` | Incremental update (also sent reliably as the too-large fallback). |
| `unsupportedPaneState` | `UnsupportedPaneState` | `workspaceID`,`paneID`,`paneGeneration`,`reason`,`fallback` | Pane can't be rendered; `reason ∈ {imageProtocol, glyphGlossaryMutation, unsupportedCellAttribute, snapshotExtractionFailure}`, `fallback ∈ {keepLastGoodKeyframe, blankWithDiagnostic}`. |
| `error` | `{"error":string}` | — | Attach/handshake rejection; closes the connection. |

**Server → client (datagrams)** — a single compact `paneDelta` (`MarshalCompactPaneDelta`,
`protocol.go:263`); rows that are all-normal width-1 cells compress to `fullRowText` (`{"_0":"…"}`)
to save bytes. Compact deltas are *not* enveloped (raw object on the datagram).

**Row update body** (`RowUpdate.update`, `protocol.go:374`) is one of:
- `fullRow` → `{"_0":[GridCell…]}` (whole row).
- `fullRowText` → `{"_0":"…"}` (compact whole row; datagram-only output, accepted on input).
- `span` → `{"baseRowVersion","startColumn","cells":[…],"clearToColumn?"}` (partial, version-checked).

**Cell / style / color types** (`protocol.go:85`–`173`): `GridCell{text,width,style}`;
`CellStyle{foreground,background,underlineColor,bold,faint,italic,underline,blink,inverse,invisible,
strikethrough}`; `Color` is `{"default":{}} | {"indexed":{"_0":u8}} | {"rgb":{"red","green","blue"}}`;
`UnderlineStyle ∈ none/single/double/curly/dotted/dashed`; `CursorState{row,column,visible,shape,
cursorVersion}` with `shape ∈ block/bar/underline`; `activeScreen ∈ primary/alternate`.

**Client → server (JSON line on a stream)** — `remoteClientRequest` (`quic_service.go:145`,`:468`):

| `type` | Fields | Effect |
|---|---|---|
| `requestKeyframe` | `workspaceID`,`paneID`,`reason?` | Force a fresh keyframe (resync). |
| `sendKeys` | `workspaceID`,`paneID`,`data` (base64 bytes) | Inject keystrokes (→ tmux `send-keys -H`). |
| `resizePane` | `workspaceID`,`paneID`,`columns`,`rows` | Resize pane (→ tmux resize). |
| `newWindow` | `workspaceID` | tmux `new-window`. |
| `selectWindow` | `workspaceID`,`windowID` | tmux `select-window -t @N`. |

The **attach handshake** itself is the first client→server line: `{"session":…,"key":…}`.

**Versioning / consistency model** (critical for a correct client): `paneGeneration` bumps on
structural change (resize, primary↔alternate) and forces a new keyframe; `keyframeID` identifies a
keyframe; deltas carry `baseKeyframeID` + monotonically increasing `deltaSequence`; each row has a
`rowVersion`; `span` updates carry `baseRowVersion` that must equal the client's current row version or
the span is rejected. A client applies a delta only if `paneGeneration` matches and `baseKeyframeID`
≥ its keyframe; otherwise it must wait for / request a fresh keyframe (mirrors `PaneModel.ApplyDelta`,
`pane_model.go:234`). `layoutGeneration` orders workspace snapshots; `cursorVersion` orders cursor
updates.

### 3.4a Cross-check vs the Swift client `RemoteGridProtocol` — **verified match**
The parallel investigation of the macOS client (`Fantastty/Models/RemoteGridProtocol.swift` +
`RemoteEngineClient.swift`) confirms the Go server's wire format matches the Swift client on **every
message type, field name, framing rule, and version field**. The client's structs (`RemotePaneKeyframe`,
`RemotePaneDelta`, `RemoteWorkspaceSnapshot`, `RemoteUnsupportedPaneState`, `RemoteGridCell`,
`RemoteCellStyle`, `RemoteGridColor`, `RemoteRowUpdateBody`, `RemoteCursorState`, …) decode exactly the
JSON the Go side emits, including the compact `text`/`fullRowText` row forms and the `{"<case>":{"_0":…}}`
enum envelope. The hard constraints worth pinning for a re-implementation:
- **One bidi control stream**, NDJSON, carries attach + all commands + all reliable messages.
  **Datagrams are server→client only and carry a bare (un-enveloped) `RemotePaneDelta`**; the client
  never sends datagrams. Both sides cap datagrams at **1200 bytes** (client `maxDatagramFrameSize=1200`;
  server `MaxDatagramPayloadBytes=1200`).
- The client **ignores datagram deltas unless** the governing keyframe set
  `datagramsEnabledAfterKeyframe:true` — the server's `PaneModel` always sets it true on keyframes
  (`pane_model.go:78`), and the StreamPump's reliable-keyframe-before-datagram barrier guarantees the
  keyframe arrives first.
- **`cursorVersion` is mandatory** in every emitted `RemoteCursorState` (Swift decode fails without it);
  the Go side always includes it (not `omitempty`). ✓
- **Cert must be EC P-256.** The client's pin check (`certificateSPKISHA256`) only accepts a 65-byte
  uncompressed P-256 public key and reconstructs the P-256 SPKI DER before hashing. The Go server
  generates an **ECDSA P-256** cert (`quic_service.go:1372`) → they match. A Linux client must do the
  same SPKI-SHA256-over-P-256 pin.
- `sendKeys.data` is **base64** bytes, chunked ≤2048 B by the client (server request read limit is
  64 KiB, so chunks fit). `resizePane` is flattened (`columns`,`rows`). Attach is the first stream line
  `{"session","key"}` with **no `type`**; rejection is a bare `{"error":"…"}` line.
- The client treats `requestKeyframe.reason` as a stringified enum
  (`noKeyframe|baseKeyframeMismatch|generationMismatch|rowVersionMismatch|datagramsDisabled|
  malformedKeyframe|malformedDelta|resizeMismatch|staleGeneration`); the Go server passes `reason`
  through opaquely (does not branch on it).

### 3.5 tmux control mode (`tmuxcc/`, `tmux_workspace_process.go`)
- Drives tmux in **control mode** (`-C`, not `-CC`) over a child process's stdin/stdout. Initial state
  is bootstrapped synchronously via `list-windows`/`list-panes` (format strings give id/layout/active/
  alternate/cursor/scroll-region) plus `capture-pane -peqJN -S -2000` to seed scrollback, cursor and
  alternate-screen state into the renderer (`tmux_workspace_process.go:520`,`:626`).
- The parser (`tmuxcc/model.go`) handles `%output`/`%extended-output` (octal-escaped payload → raw
  bytes, `output.go:57`), `%window-add/-renamed/-close`, `%layout-change` (regex-parses
  `COLSxROWS,X,Y,%PANE` frames, `model.go:392`), `%window-pane-changed`, `%session-window-changed`,
  `%pause`/`%continue`. A `PaneOutputBuffer` holds output for panes not yet present in a layout
  snapshot (bounded 1024).
- Commands written back to tmux stdin: `send-keys -t %N -H <hex…>` / `Enter`, `resize-pane`,
  `refresh-client -C cols,rows -f pause-after=1`, `refresh-client -A '%N:continue'`, `new-window`,
  `select-window -t @N`, `detach-client`.

### 3.6 Security & state (`registry/`, `keyring/`)
- **Runtime dir** (XDG-aware): `$FANTASTTY_REMOTE_RUNTIME_DIR` → `$XDG_RUNTIME_DIR/fantastty-remote-engine`
  → `/tmp/fantastty-remote-engine-<uid>` (`registry.go:116`). Must be a **non-symlink dir, mode `0700`,
  owned by euid**; all files validated for symlink/perm/owner (`:665`,`:685`).
- **Registry** = `registry.json` guarded by an **`flock` (LOCK_EX)** lock file; writes are atomic
  (temp + `fsync` + rename + dir `fsync`) (`:192`,`:717`). Records hold workspace, tmux session, PID,
  ports, socket path, QUIC addr+cert SHA, expiry, `active_clients`, and embedded one-time keys.
- **One-time attach keys** (`keyring.go`): 32-byte crypto-random hex, per-session, TTL'd, **deleted on
  first consume** (`Consume`, `:72`). `launch-or-resume` mints a fresh key each call.
- **Local control socket** (`ctl-<id>.sock`, mode `0600`): every connection is checked with
  **`SO_PEERCRED`** (`peercred_linux.go` → `unix.GetsockoptUcred`) and rejected unless the peer UID ==
  helper euid (`main.go:957`, `registry.go:655`). Used for `health` / `tmux-smoke` / `workspace-messages`.
- A separate **UDP health** socket on `127.0.0.1` answers `health <session>` with `ok` (`main.go:1022`).

### 3.7 Concurrency model
Per-connection goroutines (attach stream reader + extra stream/uni-stream acceptors + datagram sender);
a `StreamPump` runs two goroutines (`runReliable`/`runDatagrams`) with fine-grained mutexes and an
`atomic.Bool` datagram-pause gate. The fan-out hub serializes publication with a sequence + `sync.Cond`
so all subscribers see messages in a consistent order. The registry serializes all mutations under
flock. This is robust, idiomatic Go — **no platform-specific concurrency**.

---

## 4. Platform dependencies (the helper is *already* Linux-targeted)

This subsystem is the one place in Fantastty that is **already a Linux program**. Its "platform
dependencies" are Linux/POSIX, not macOS:
- **cgo + libghostty-vt** via `pkg-config libghostty-vt` and `<ghostty/vt.h>`; the renderer file is
  gated `//go:build linux && cgo && ghostty_vt` (`ghosttyvt/renderer.go:1`). The non-Linux build path
  returns `errRemoteRendererUnavailable` (`renderer_factory_unavailable.go`), so the **darwin-arm64
  helper that the build also produces cannot actually render** — it exists for probes/smoke only.
- **`golang.org/x/sys/unix`**: `SO_PEERCRED`/`GetsockoptUcred` (`peercred_linux.go`), `Flock`,
  `Kill`, `SIGTERM`. `peercred_unsupported.go` is the non-Linux stub.
- **`syscall.SysProcAttr{Setsid:true}`** to daemonize `serve` (`main.go:868`); `syscall.Stat_t.Uid`
  for owner checks; Unix-domain sockets; `SIGTERM`/`SIGINT` handling.
- **`tmux` binary** on PATH (`exec.LookPath("tmux")`, `main.go:825`) — a hard runtime dependency.
- **XDG_RUNTIME_DIR** convention for per-user runtime state.

There is **nothing macOS-specific** in the helper. The only Apple coupling is *external*: the macOS
app is what deploys and launches it (and what consumes the protocol).

---

## 5. Linux mapping

For the helper itself there is essentially **nothing to map** — it is the Linux side already:
- libghostty-vt: built for `x86_64-linux-gnu` / `aarch64-linux-gnu` today (see §6). The Linux app
  links the same `.so`.
- `SO_PEERCRED`, `flock`, `setsid`, Unix sockets, `XDG_RUNTIME_DIR`, `SIGTERM` are all native Linux.
- tmux is the same cross-platform process dependency.

The mapping work is on the **client** side (the new Linux GUI app must *speak this protocol*), and on
**how the helper is built/packaged/shipped** (§6). The Linux client must implement:
1. **SSH bootstrap:** run `fantastty-helper launch-or-resume <workspace> --ttl … --key-ttl …` on the
   host (after deploying the right `linux-<arch>` artifact + its `libghostty-vt.so`), parse the
   `FANTASTTY_REMOTE …` line.
2. **QUIC client** — **RISK / required rewrite.** The macOS client uses **Apple's Network.framework
   QUIC** (`NetworkConnection<QUIC>` on macOS 26+, `NWConnection` + `NWProtocolQUIC` on older), which
   has **no Linux equivalent**. The Linux client must adopt a Linux QUIC library: `quinn` (Rust),
   `msquic`, `lsquic`, `quiche`, or **`quic-go`** (the same library the helper already vendors, if the
   client is Go). It must support **datagrams** (`maxDatagramFrameSize=1200`), ALPN
   `fantastty-remote-engine-v1`, TLS 1.3, and **leaf-SPKI-SHA256 pinning over an EC P-256 key** with
   otherwise-skipped CA verification. Reconnect is app-layer (re-dial + re-attach + drop pane state +
   request fresh keyframes), **not** QUIC connection migration.
3. **Attach handshake:** open a bidi stream, send `{"session","key"}\n`, then read newline-JSON +
   datagrams.
4. **Grid model + reconciliation:** apply keyframes/deltas with the generation/keyframeID/rowVersion
   rules from §3.4 (the Go `remotegrid.PaneModel` `ApplyKeyframe`/`ApplyDelta` is a ready reference and
   is even **symmetric** — it can decode as well as encode). Render the resulting cell grid with
   libghostty/GTK.
5. **Input/resize/window requests** as JSON lines; predictive local echo is purely client-side.

No Linux equivalent is *missing*; the only **RISK** is reachability of the QUIC UDP port (§7).

---

## 6. Build / packaging / CI (Scope B)

### 6.1 Two distinct libghostty consumers
- **App (local terminals):** `GhosttyKit.xcframework` — the full libghostty with Metal renderer +
  ObjC/Swift bindings. Built from Zig: `Makefile:5`
  `cd vendor/ghostty && zig build -Doptimize=ReleaseFast -Demit-xcframework=true
  -Demit-macos-app=false -Dxcframework-target=native`, copied to `xcframework/` and **statically
  linked** (`project.yml:43`, `embed:false`). A patch `patches/ghostty-inject-output.patch` (21 KB)
  is applied first; it adds `ghostty_surface_inject_output()` and a `ghostty_remote_grid_*` C API to
  libghostty.
- **Helper (remote rendering):** `libghostty-vt` (headless VT, no GPU). Built per target with
  `zig build -Demit-lib-vt=true -Dtarget=<triple> -Doptimize=ReleaseFast --prefix <dir>`
  (`package_app_artifacts.sh:46`), producing `lib/libghostty-vt.so.0.1.0` (Linux) /`.dylib` (macOS),
  a `share/pkgconfig/libghostty-vt.pc`, and `<ghostty/vt.h>`.
- **Zig version: 0.15.2** (pinned in CI to match `vendor/ghostty/build.zig.zon`'s
  `minimum_zig_version`). `vendor/ghostty` is an **uninitialized submodule** pinned to commit
  `5d0a82ba…` of `github.com/ghostty-org/ghostty`.

### 6.2 Helper artifact pipeline (`tools/remote-engine-helper/package_app_artifacts.sh`)
Three targets (`:116`): `linux-amd64` (`x86_64-linux-gnu`), `linux-arm64` (`aarch64-linux-gnu`),
`darwin-arm64` (`aarch64-macos`). For each:
1. Build `libghostty-vt` (above).
2. **Cross-compile the cgo Go helper using Zig as the C toolchain** (`:52`):
   ```
   CGO_ENABLED=1 GOOS=<> GOARCH=<> CC="zig cc -target <triple>"
   PKG_CONFIG_LIBDIR=<install>/share/pkgconfig PKG_CONFIG_PATH=
   go build -tags ghostty_vt -ldflags "-X main.version=<ver> -X main.arch=<arch>" -o fantastty-helper .
   ```
   `version` defaults to `git rev-parse --short HEAD`.
3. Lay out `<label>/fantastty-helper` (chmod 700) + `<label>/lib/<libname>` (chmod 600); SHA-256 both.
4. `write_manifest` emits `manifest.json` = `{version, artifacts{label:{os,arch,helper,helper_sha256,
   library,library_sha256}}}`. Output dir defaults to `Fantastty/Resources/RemoteEngine/`
   (bundled into the app; only `.gitkeep` is committed, the rest is gitignored & built at package time).
- **Verification** (`verify_app_artifacts.py`): reads `…/Resources/RemoteEngine/manifest.json`, rejects
  absolute/`..` paths, confirms each helper+library exists and **recomputes SHA-256 == manifest**.
- **Runtime selection** (`internal/artifact/manifest.go`): the app picks the artifact by remote `uname`
  (`x86_64|amd64 → linux-amd64`, `aarch64|arm64 → linux-arm64`) and `Manifest.Verify` checks
  version/arch/checksum before trusting a deployed helper.

### 6.3 macOS app build, signing, packaging (to be replaced wholesale on Linux)
- **XcodeGen** (`project.yml`) generates `Fantastty.xcodeproj`; a hand-added pbxproj run-script phase
  *"Package RemoteEngine Artifacts"* runs the helper packaging when
  `FANTASTTY_PACKAGE_REMOTE_ENGINE_ARTIFACTS=1`, ordered before the Resources copy. `scripts/add_to_xcode.py`
  mutates the pbxproj (Swift files, test target).
- **Release** (`scripts/build-release.sh`): `xcodebuild` Release → verify artifacts → `codesign
  --verify --deep --strict` → notarize app+DMG via `xcrun notarytool submit --keychain-profile
  fantastty-notarize --wait` + `xcrun stapler staple` → `hdiutil create -format UDZO` DMG.
- **CI** (`.github/workflows/build-and-release.yml`): `macos-15`, Xcode 26.2, **`mlugg/setup-zig@v2`
  0.15.2**, `setup-go` from helper `go.mod`; `submodules: recursive`; caches `xcframework/`; imports a
  Developer ID cert into a temp keychain; signs with hardened runtime + timestamp; **notarizes & cuts
  a `gh release` only on `v*` tags**. Six Apple secrets (`DEVELOPER_ID_APPLICATION` + password,
  `DEVELOPER_ID_NAME`, `APPLE_ID`, `APPLE_ID_PASSWORD`, `APPLE_TEAM_ID`).

### 6.4 What a Linux build system must REPLACE vs KEEP

**KEEP almost unchanged (already cross-platform / Linux-first):**
- The **Zig `libghostty-vt` build** (`-Demit-lib-vt=true`), Zig 0.15.2 — on a native Linux build you
  build for the host triple and pkg-config against the install prefix.
- The **Go remote helper** — on Linux this is a *native* build (`CGO_ENABLED=1 -tags ghostty_vt`,
  `CC=zig cc` or system clang/gcc, pkg-config to libghostty-vt). All QUIC/tmux/remotegrid logic is
  portable. **Reusable as-is.**
- `package_app_artifacts.sh` + `verify_app_artifacts.py` — useful as-is for cross-building the helper
  artifacts the Linux app deploys to *remote* hosts; only the output/verify **path**
  (`…/Contents/Resources/RemoteEngine`) must change to the Linux resource location (e.g.
  `/usr/share/<app>/remote-engine` or `$XDG_DATA_DIRS`).
- The `patches/ghostty-inject-output.patch` (platform-agnostic).

**REPLACE (macOS-only):**
1. **`GhosttyKit.xcframework`** → native libghostty for Linux. The xcframework/Metal/AppKit bindings
   are macOS-only; on Linux libghostty's frontend is the **GTK4 apprt + OpenGL/EGL**. Either embed
   libghostty-vt + a custom GPU frontend or build Ghostty's GTK app.
2. **Entire Xcode toolchain** — `xcodebuild`, XcodeGen/`project.yml`/pbxproj, `add_to_xcode.py`,
   `BridgingHeader.h`, `Carbon.framework`, `.entitlements`, `Info.plist`. Replace with Meson/CMake/
   `zig build`/Make. (The SwiftUI/AppKit app shell itself is a separate, much larger rewrite — out of
   this report's scope.)
3. **Signing/notarization** — `codesign`/`notarytool`/`stapler`/keychain/secrets → optional GPG or
   distro package signing.
4. **Packaging** — DMG (`hdiutil`/`ditto`) → `.deb`/`.rpm`/**Flatpak**/**AppImage**; `.app` bundle
   layout → FHS (`/usr/bin`, `/usr/lib`, `/usr/share/<app>`).
5. **Desktop integration (new)** — `.desktop` file, MIME, **hicolor icon theme** (source PNGs exist in
   `Fantastty/Assets.xcassets/AppIcon.appiconset/`).
6. **CI** — swap `macos-15` → `ubuntu-*`, drop Xcode/signing/notarize/DMG, **keep setup-zig 0.15.2 +
   setup-go**, run the native build + `package_app_artifacts.sh`, add `x86_64`/`aarch64` matrix,
   upload Linux packages.

---

## 7. Reuse assessment, open questions & risks

### Reuse verdict
**The Go helper is reusable on Linux essentially as-is.** It already compiles and renders only on
Linux; the `linux-amd64`/`linux-arm64` artifacts the macOS build produces are exactly what the Linux
app needs. The entire server-side stack (QUIC, tmux control mode, ghosttyvt, remotegrid, outboxes,
StreamPump, registry, keyring, peercred) is portable Go + Linux/POSIX with no macOS coupling. The
Linux port should **vendor and reuse this binary unchanged** and focus all effort on (a) a Linux
**client** that speaks the protocol in §3.4 and (b) the Linux build/packaging in §6.4.

What the Linux client must speak (the deliverable, condensed):
1. Over SSH (`/usr/bin/ssh`,`/usr/bin/scp`): probe `uname -s/-m`, pick `linux-<arch>` (or `darwin-arm64`)
   from the bundled `manifest.json`, `scp` the checksum-verified helper + `libghostty-vt` to
   `~/.cache/fantastty/remote-engine/` (verify remote `sha256sum -c`, atomic `mv`, create `.so.0`/`.so`
   symlinks, set `LD_LIBRARY_PATH`), confirm `helper --version`.
2. SSH-run `env -u XDG_RUNTIME_DIR FANTASTTY_REMOTE_ADVERTISE_HOST=<routable-host> LD_LIBRARY_PATH=<lib>
   <helper> launch-or-resume <workspace> --ttl 8h --key-ttl 30s [--tmux-session N]`; parse the last
   stdout line `FANTASTTY_REMOTE … quic_addr quic_cert_sha256 quic_alpn key …`. (Unsetting
   `XDG_RUNTIME_DIR` makes the helper use `/tmp/fantastty-remote-engine-<uid>` for its runtime dir.)
3. QUIC dial with datagrams + ALPN `fantastty-remote-engine-v1` + **SPKI-SHA256 pin**.
4. Bidi stream: send `{"session","key"}\n`; consume newline-JSON (snapshot/keyframe/delta/unsupported)
   on the stream and compact `paneDelta` on datagrams; honor the reliable-keyframe-before-datagram
   barrier and the generation/keyframeID/rowVersion reconciliation rules.
5. Send `sendKeys`/`resizePane`/`requestKeyframe`/`newWindow`/`selectWindow` JSON; do predictive echo
   locally.

### Open questions / risks
- **QUIC reachability — direct UDP, biggest deployment constraint (now confirmed).** The server binds
  `0.0.0.0:<ephemeral UDP>` and advertises `FANTASTTY_REMOTE_ADVERTISE_HOST`. The macOS client **sets
  that advertise host to a routable address of the SSH host** — resolved via `ssh -G` plus local-subnet
  probing (`SSH_CONNECTION`, `hostname -I`) for LAN routing — and then **dials QUIC directly over UDP
  to that host:port**. QUIC does **not** go through the SSH (TCP) tunnel; SSH is used only to deploy the
  helper and run `launch-or-resume`. ⇒ **The host's QUIC UDP port must be directly reachable from the
  client** (same LAN, VPN, or a routable IP with the UDP port open). The Linux client must replicate
  this advertise-host resolution; behind strict NAT/firewalls with no direct UDP path the feature won't
  connect (a future UDP-capable tunnel would be required).
- **Client QUIC transport is Apple-only (largest client rewrite).** The macOS client is built entirely
  on Network.framework QUIC; there is no Swift third-party QUIC dependency to lift. The Linux client's
  QUIC stack is net-new (pick `quic-go`/`quinn`/`quiche`/`msquic`/`lsquic`) and must re-implement
  datagrams, ALPN, and EC-P256 SPKI pinning. The *protocol* (JSON shapes) ports cleanly; the
  *transport library* does not.
- **darwin-arm64 helper can't render** (renderer gated to Linux). Irrelevant to the Linux port but
  worth knowing: the "darwin-arm64" artifact is probe/smoke-only.
- **`go 1.25.0` + Zig 0.15.2 toolchain pins** must be available in the Linux build/CI environment;
  cgo cross-compiles depend on `zig cc` (or native clang/gcc) + the libghostty-vt pkg-config.
- **Protocol is unversioned beyond the ALPN string** (`-v1`). Client and helper must be built from
  compatible revisions; `Manifest.Verify` enforces helper version/arch/checksum but the *wire* schema
  has no negotiation. Keep client and bundled helper in lockstep.
- **`libghostty-vt` is pinned to a specific Ghostty commit** via the submodule; the C API the renderer
  uses (`ghostty_render_state_*`, `ghostty_cell_*`) must stay stable across the Ghostty version the
  Linux app links for local rendering, or the helper and the local renderer could drift.
