# insanitty — Implementation Proposal

**How to build the native Linux port specified in `docs/SPEC.md`.**

This proposal recommends an architecture, names the one decision that needs Jesse's sign-off, lays out a phased plan that de-risks the hard unknowns first, and is honest about cost. It is grounded in the eleven research reports in `docs/research/` — especially `03b` (Ghostty's Linux rendering, verified against source) and `10` (Swift-on-Linux viability).

> **Ratified decisions (locked):**
> - **Language = Swift** (Decision 1, §4) — reuse the tested logic; GTK chrome via C interop; msquic for QUIC. Reversible to Rust only if the Phase-0 spikes fail.
> - **v1 scope = full parity, including the remote engine** (§5) — the QUIC remote engine is **in v1**, not a fast-follow. This makes **Spike C (msquic ↔ the real Go helper) a hard critical-path gate**, and pulls Phase 3 into the v1 commitment.
> - *Defaults pending objection:* on-disk format is **fresh** (no read of existing macOS `~/.fantastty` files); predictive echo stays **on by default** to match parity. Say the word to change either.

---

## 1. The shape of the problem (one paragraph)

insanitty is a **workspace/session manager wrapped around a terminal engine**, not a terminal emulator (see SPEC §0). Three assets already exist and should be reused, not rebuilt:

1. **The terminal engine** — Ghostty. On Linux it renders **only** through Ghostty's own GTK `GhosttySurface` widget (GtkGLArea + Ghostty's OpenGL renderer). The embeddable C-ABI libghostty the macOS app uses is **Metal-only and does not render on Linux** (`03b`, verified). This is the gating architectural constraint.
2. **The Go remote-engine helper** — already a Linux program; reused **unchanged** (`08`).
3. **~25–30K lines of platform-neutral, well-tested Swift logic** — the split tree, the session/workspace model + persistence, the tmux control-mode client (parser + reducers), and the remote-engine client (wire protocol + grid state machine + the subtle ~1100-line predictive-echo engine with ~1500 lines of tests). This is the crown-jewel reuse asset (`04`,`05`,`06`,`07`).

Everything else — the SwiftUI/AppKit UI and the Apple-framework glue (Network.framework QUIC, Keychain, WebKit, etc.) — is rewritten against Linux-native equivalents (SPEC §5).

The **central tension**: asset (1) pulls toward Ghostty's GTK/Zig world; asset (3) pulls toward keeping Swift. The good news (`10`): **the rendering bridge to Ghostty's GTK surface is required regardless of host language** — Swift and Rust both bridge to it; only writing the whole app in Zig *inside* Ghostty's apprt avoids the bridge. So rendering does **not** decide the language. The language decision is purely **"reuse the tested Swift logic" vs. "adopt a more mature toolkit ecosystem."**

---

## 2. Recommended architecture

A four-layer design. Layers 1, 2, and 4 are largely **language-independent**; the language choice (Decision 1, §4) only changes layer 3 and the binding style for layer 1.

```
┌─────────────────────────────────────────────────────────────────────┐
│ 3. CHROME  (new)   GTK4 + libadwaita: window, sidebar, tabs, split    │
│                    container, notes panel, settings, dialogs,         │
│                    browser tab (WebKitGTK), thumbnails                 │
├─────────────────────────────────────────────────────────────────────┤
│ 2. CORE LOGIC  (reused, ported near-verbatim)                         │
│    SplitTree · SessionManager/metadata/persistence · tmux control-    │
│    mode client (+V2 reducers) · remote-engine client (protocol/grid/  │
│    predictive-echo) — paths→XDG, Combine→OpenCombine, Darwin→Glibc,   │
│    Network.framework→msquic, CryptoKit→swift-crypto                    │
├─────────────────────────────────────────────────────────────────────┤
│ 1. ENGINE  (reused, forked Ghostty)                                   │
│    Ghostty GTK `GhosttySurface` widget (GL render, xkb, IME,          │
│    clipboard, search, progress) embedded as a GtkWidget +             │
│    a small C shim (surface construction, re-homed inject_output/      │
│    remote_grid_*, tmux-pane hooks) + libghostty-vt for the helper     │
├─────────────────────────────────────────────────────────────────────┤
│ 0. REMOTE HELPER  (reused unchanged, Go)  — runs on remote hosts      │
└─────────────────────────────────────────────────────────────────────┘
```

### Layer 1 — Engine (forked Ghostty)

We maintain a **lightly-patched fork** of Ghostty (pinned, currently `5d0a82ba`, Zig 0.15.2) that builds two artifacts on Linux:

- The **GTK app/library** exposing `GhosttySurface`. Per `03b`, the surface widget is reusable (signal-based, not bolted to Window/Tab/Split) but depends on Ghostty's GTK `Application` singleton for allocator/core-app/config/winproto. We **host Ghostty's GTK `Application`** (instantiate their `adw.Application` subclass) so `Application.default()` answers, and parent `GhosttySurface` widgets into **our** chrome.
- `libghostty-vt` for the helper (unchanged).

The fork delta over upstream is small and well-scoped (`03b` estimates the Application-coupling work at ~50–150 LoC Zig):
1. **Re-home the patch.** `patches/ghostty-inject-output.patch` adds `ghostty_surface_inject_output` + `ghostty_surface_remote_grid_*` to `embedded.zig`'s (Metal-only) C API. The bodies are renderer-agnostic (they target `core_surface.io` / `renderer_state.terminal`); we re-expose them against the **GTK** apprt's core surface (mechanical port).
2. **A thin C shim** our app links: construct a `GhosttySurface` and return `GtkWidget*`; attach/detach a tmux pane id; call the re-homed inject/remote-grid functions; subscribe to the widget's signals (`close-request`, `bell`, `clipboard-*`, `present-request`, title/pwd, desktop-notification, …).

This fork carries an **ongoing rebase cost** against upstream Ghostty — but that cost is **inherent to reusing Ghostty's renderer on Linux at all** (true for the Rust path too), so it is not a strike against any particular language.

> **Cleaner-but-costlier alternative (deferred):** add a real **embedded-OpenGL backend** to libghostty (a new Linux platform variant + GL context lifecycle in `OpenGL.zig` + a "host provides current GL context, calls `ghostty_surface_draw`" contract — `03b` sketches the 4 steps). That would give a pure C-ABI surface with **no** `Application` coupling, mirroring the macOS architecture exactly. It is more upstream Zig work and is **not** required for v1; we keep it as a future option to upstream and simplify the fork.

### Layer 2 — Core logic (reused Swift, *if* Decision 1 = Swift)

These port with bounded, mostly-mechanical edits (per `04`–`07`, `10`):

| Module | Port work |
|---|---|
| `SplitTree` (1362 lines) | Rebind the `ViewType: NSView` generic to a GtkWidget-backed leaf type (or an abstract `protocol SplitLeaf`). Keep the immutable tree, `Spatial` nav, `equalize`, Codable, and the `SplitLayoutPipelineTests` as the **layout oracle** (34 pt min, cell-snap, ratio clamps). |
| Session/workspace model + persistence | Swap `~/.fantastty` → XDG; `@AppStorage`/`UserDefaults` → a config store; **Combine → OpenCombine**; `NSAppearance` → `AdwStyleManager` + appearance portal; `NSSound.beep` → libcanberra; `NSWorkspace.open` → `gtk_show_uri`. The injectable provider seams in `SessionManager` make this tractable. |
| tmux control-mode client (~2800 lines incl. V2 reducers) | `import Darwin` → `Glibc` (`openpty` identical); drive the PTY via **raw fds on the GLib main loop** (avoid `Pipe.readabilityHandler`'s Linux bugs, `10`); keep the parser, command queue, block tracker, layout mapper, V2 reducers, `CoalescingInjector` back-pressure as-is. Rebind the controller glue to the new SplitTree leaf + surface widget. |
| Remote-engine client (~3000 lines) | Keep the wire protocol, grid state machine, predictive echo, bootstrap, deploy/checksum verbatim. **Swap the QUIC transport to msquic** behind the existing `RemoteEngineTransport`/`RemoteEngineConnection` seam; `CryptoKit.SHA256` → **swift-crypto**; re-tune the `localizedDescription`-based failure classifier for msquic's error strings. |
| Linear/sprite/browser services | Linear GraphQL: `URLSession` → **async-http-client** (`10`), Keychain → **libsecret**. Sprite: fix CLI search paths. Browser: WebKitGTK. |

The reused logic keeps its test suites (they run on Linux Swift), which is a major correctness and velocity win.

### Layer 3 — Chrome (new)

A GTK4 + libadwaita UI (SPEC §3, §5): `AdwApplicationWindow` + `AdwNavigationSplitView`; sidebar as a `GtkListBox` with drag-reorder, attention badges, archived/trashed sections, context menus, inline thumbnails; tab bar (`AdwTabBar`/`AdwTabView` or custom); **split container driven by `SplitTree`** (nested `GtkPaned` reproducing the layout-oracle constants, or a custom widget); notes panel; settings via `AdwPreferencesPage`; connection dialogs via `AdwDialog`; editable title via `GtkEditableLabel`; browser tab via WebKitGTK; pane **drag-to-split** via `GtkDragSource`/`GtkDropTarget` (mime `application/x-ghostty-surface-id`); **thumbnails via FBO/`GdkTexture` readback** (the one load-bearing UX with no cheap analogue — early design item).

If Decision 1 = Swift, the chrome is built with **direct C interop** to GTK4/libadwaita (a hand-written `CGtk`/`CAdwaita` module map), **not** the immature declarative Swift-GTK frameworks (`10`: they lack a `GtkGLArea`/foreign-widget escape hatch). Custom GObject subclassing is unsupported in Swift bindings, so we **compose stock widgets + embed Ghostty's surface widget + a ~50-line C shim** for any unavoidable new GType (`10`).

### Layer 0 — Remote helper (reused unchanged)

Ship the existing `linux-amd64`/`linux-arm64` helper + `libghostty-vt.so` as bundled artifacts under `libexec`/`$XDG_DATA_DIRS`; the client SSH-deploys them exactly as today (`07`,`08`). No changes.

### Build & packaging

- **Zig 0.15.2** builds the Ghostty fork (GTK lib + C shim + `libghostty-vt`).
- **Swift Package Manager** (if Swift) builds insanitty, linking the C shim + GTK4/libadwaita/WebKitGTK/libsecret/libnotify/msquic via system libs + module maps.
- **Packaging:** Flatpak as the primary target (GNOME Platform runtime ≥ the GTK 4.14 / libadwaita 1.4 floor from `03b`), plus AppImage and deb/rpm; `.desktop` + symbolic icons.
- **CI:** Linux runners; keep `setup-zig` 0.15.2 + `setup-go`; add the Swift (or Rust) toolchain. Carry the helper-artifact build (`zig cc` cross-compile) and `verify_app_artifacts` checks.

---

## 3. Why this architecture (and what it deliberately avoids)

- **Reuse the renderer, don't fight it.** `03b` is unambiguous: the only working Linux terminal renderer in Ghostty is the GTK surface widget. Embedding it (hosting their `Application`) is far cheaper than writing a new embedded-GL backend, and infinitely cheaper than writing a terminal renderer.
- **Reuse the helper, don't reimplement it.** It already targets Linux and the protocol is verified to match the client byte-for-byte.
- **Don't port the dead code.** SPEC §6: the non-native fullscreen modes, the (Fantastty) command palette, the manual secure-input toggle, and multi-window are unwired — we implement the *native* equivalents only where they make sense (one `GtkWindow.fullscreen()`; a palette is even *available* from Ghostty's GTK apprt if we want it).
- **Fix, don't faithfully reproduce, the known defect.** SPEC §3.12: the "automatic" OSC-7 pwd tracking appears unwired in Fantastty — we wire it properly (inject `ZDOTDIR`) or drop the "automatic" claim.

---

## 4. Decision 1 (needs Jesse): implementation language

This is the one high-stakes fork. The architecture above is the same for all three; the language only changes whether layer 2 is **reused** or **rewritten**, and the layer-1/3 binding style.

| | **Swift** (recommended) | **Rust** (gtk-rs + quinn) | **Zig** (extend Ghostty apprt) |
|---|---|---|---|
| Reuse the ~25–30K lines of tested logic | **Yes** (near-verbatim + tests) | No — full rewrite | No — full rewrite |
| GTK4 toolkit maturity | Caveated — hobby-scale bindings; use **direct C interop** | **Best** — gtk4-rs, first-class GObject subclassing | Via Ghostty's own apprt (zig-gobject) |
| QUIC client | msquic via C interop (~300–600 LoC) | **quinn** (native, RFC 9221 datagrams) | None native — would bind a C lib |
| Rendering bridge to Ghostty GTK surface | Required (C interop) | Required (FFI) | **Avoided** (lives in the apprt) |
| Ghostty fork rebase cost | Yes (small shim) | Yes (small shim) | **Highest** (own their chrome in Zig) |
| Net new code for v1 | **Lowest** (chrome only) | High (chrome + all logic) | Highest (chrome + all logic in Zig) |
| Maturity risk | Swift-on-Linux GUI is less-trodden | **Lowest** | Pre-1.0 Zig (0.16), churny |

**Recommendation: Swift.** The decider is that **rendering forces the same Ghostty-GTK bridge on every option**, so Rust's superior toolkit doesn't buy us out of the hard part — while Swift uniquely lets us keep tens of thousands of lines of subtle, *tested* logic (the predictive-echo engine and the tmux control-mode reducers are exactly the kind of code you do not want to re-derive and re-test). Report `10`'s verdict is **"viable-with-caveats,"** and the caveats are bounded and have known mitigations (direct C interop for the chrome; msquic for QUIC; async-http-client + raw-fd PTY for the two stdlib gaps; a ~50-line C shim for custom GTypes).

**When I would switch to Rust instead:** if the Phase-0 spikes (§5) show the Swift↔GTK C-interop chrome is materially more painful than expected (e.g., GObject signal/lifetime management or WebKitGTK integration fights us), the calculus flips — Rust's mature toolkit could outweigh the lost reuse, since we'd be writing a lot of new chrome either way. **The spikes are designed to surface exactly this before we're committed.** I'd avoid Zig-extending-the-apprt unless we decide we want to live entirely inside Ghostty long-term — it has the highest fork-coupling and no logic reuse.

> **RATIFIED: Swift.** The Phase-0 spikes remain the escape hatch — if Spike A (surface embedding) or the GTK C-interop ergonomics prove materially worse than `10` predicts, we revisit before Phase 1. Otherwise Swift is the committed path.

---

## 5. Phased plan (de-risk first)

### Phase 0 — Spikes (retire the top risks before committing to the full build)

Four small, throwaway-friendly spikes, each proving one load-bearing unknown. **Gate the rest of the project on these.**

- **Spike A — Embed the surface.** Build the Ghostty fork on Linux; from a minimal app (in the candidate language), host Ghostty's GTK `Application` and embed one live `GhosttySurface` running a shell, in our own `AdwApplicationWindow`. *Proves: the embedding + Application-hosting + the language↔GTK binding.*
- **Spike B — Re-home the patch.** Port `inject_output` + `remote_grid_*` to the GTK core surface; drive a few styled cells and some injected output from layer-2 code. *Proves: the tmux/remote render path on Linux.*
- **Spike C — QUIC to the real helper.** Bind msquic; attach to the **unchanged** Go helper on a LAN host with SPKI-pin verification + datagrams; render one keyframe. *Proves: the single hardest rewrite, against the real protocol.*
- **Spike D — SplitTree on GtkPaned.** Rebind `SplitTree`'s leaf type; render a 2-pane split via nested `GtkPaned` honoring the layout-oracle tests. *Proves: the split layout + the reuse-rebinding pattern.*

Exit criterion: all four green → Phase 1. If A or C is much harder than expected, revisit Decision 1 now (cheap), not later. **Because v1 includes the remote engine, Spike C is critical-path: it must go green for the v1 commitment to hold** — if msquic↔helper interop proves intractable, that is the moment to either re-scope v1 (ship local+ssh first) or rethink the transport, not Phase 3.

### Phase 1 — Local terminal MVP
One window; workspaces in the sidebar; tabs; splits driven by `SplitTree`; local tmux backing + control-mode client + persistence (`workspaces.json`/`layout.json` under XDG) + restore-on-launch; settings; appearance (light/dark/system via portal). *This is where most of the layer-2 reuse lands.*

### Phase 2 — Workspace features
Notes panel + OSC-9 notes; ticket/PR URLs + Linear (libsecret); attention indicators + **desktop notifications** (libnotify, click-to-focus); thumbnails + Exposé overview (FBO readback); shell integration (notes + **properly-wired** OSC-7 pwd); archive/trash/restore; drag-to-split + drag-to-reorder.

### Phase 3 — Remote (in v1)
SSH tmux-control workspaces; then the **remote engine** end-to-end (deploy helper, msquic transport, structured-grid render, predictive echo, reconnect + ssh-fallback, advertise-host resolution). Sprites; browser tabs (WebKitGTK). *Per the ratified scope, this phase is part of the v1 release, so its risks (msquic, advertise-host/UDP reachability, host-compat) carry first-release weight — build a small soak/host-compat matrix as it lands.*

### Phase 4 — Polish & ship
Deliberate Ctrl/Super keymap (no ⌘ transliteration, no WM collisions); Flatpak + AppImage + deb/rpm; Linux CI; remote-engine soak + host-compat matrix; secure-input indicator (no-op lockdown); audit/trim the Flatpak permissions.

---

## 6. Risks & mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Ghostty GTK surface embedding / `Application` hosting harder than `03b` estimates | High | **Spike A** first; fallback is the DI-refactor of the surface widget, or (longer) the embedded-GL backend |
| msquic ↔ Go-helper interop (datagrams ≥1200, in-handshake SPKI pin) | High | **Spike C** against the real helper early; msquic chosen specifically because it supports in-handshake custom validation with the cert as a DER blob (`10`) |
| Swift↔GTK C-interop chrome more painful than expected | Medium | Spikes A/D expose it; **Decision 1 is reversible to Rust at the Phase-0 gate** |
| Live GL thumbnails (FBO readback) cost/perf | Medium | Prototype in Phase 2; fallbacks: lower refresh, on-demand capture, or text preview |
| Ghostty fork rebase burden | Medium | Keep the delta tiny (re-homed patch + C shim + Application host); pin commits; consider upstreaming the embedded-GL backend later |
| Remote engine needs direct UDP reachability (not via SSH tunnel) | Medium | Inherent to the design; reuse the advertise-host probing; document the NAT/firewall constraint |
| On-disk format compatibility with macOS files | Low | Default to a **fresh** format (these are private files); cross-read only on explicit request (would freeze the enum schemas) |
| Secure input has no Linux equivalent | Low | Keep the indicator, no-op the lockdown (Wayland makes it largely moot) |

---

## 7. Decision status & next step

**Ratified:**
1. **Language = Swift** — preserve the tested logic; reversible at the Phase-0 gate if the spikes say otherwise.
2. **v1 = full parity incl. the remote engine** — Phases 1–3 are all v1; Spike C (msquic↔helper) is critical-path.

**Proceeding on these defaults unless you object:**
3. **On-disk format = fresh** (no read of existing macOS `~/.fantastty` files; per our rules, cross-read back-compat would need your explicit OK and would freeze the enum schemas).
4. **Predictive echo = on by default** (matches parity; trivially flippable).

**Immediate next step — Phase 0 spikes.** The first concrete build work is the four de-risking spikes (§5): embed Ghostty's GTK surface from Swift (A), re-home the render patch (B), msquic to the real helper (C), SplitTree-on-GtkPaned (D). These need a forked Ghostty checkout, a Swift+GTK C-interop scaffold, and a LAN host with the Go helper for Spike C. **Say the word and I'll start with the repo scaffold + Spike A.**

---

*Companion docs: `docs/SPEC.md` (the what); `docs/research/01`–`10` + `03b` (subsystem detail). The Ghostty source used for `03b`/`10` is checked out under the session scratchpad at commit `5d0a82ba`.*
