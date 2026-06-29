# 10 — Swift-on-Linux Viability (insanitty)

**Question being decided:** keep Fantastty's tested, platform-neutral Swift logic and build the
Linux UI as a **GTK4 (libadwaita) app written in Swift**, vs **rewrite everything in Zig or Rust**.

**Scope of this report:** ecosystem viability of the *Swift-on-Linux* path — GTK4/libadwaita
bindings, direct C interop, Swift core libraries on Linux, and a QUIC client from Swift — plus a
short contrast against Rust and Zig. It does **not** re-decide the libghostty embedding strategy
(covered by `02-ghostty-bridge.md`, `03-ghostty-vendor-linux.md`, `03b-ghostty-source-verified.md`),
but it surfaces the one cross-cutting risk from those reports that dominates every option.

All versions/dates verified June 2026 via web research; sources listed at the end.

---

## Bottom-line verdict: **VIABLE-WITH-CAVEATS**

Swift-on-Linux can drive GTK4 and run the reusable core, and doing so preserves tens of thousands
of lines of *tested* logic that a Zig/Rust rewrite would have to re-derive **and re-test**. That is
the decisive economic argument and it holds up. But the Swift GTK story is the **unpaved road**, and
the caveats are specific and load-bearing:

1. **You cannot use the "nice" Swift GTK frameworks.** The SwiftUI-style declarative bindings
   (Adwaita-for-Swift, SwiftCrossUI) have **no escape hatch to embed a raw `GtkGLArea` or any
   custom/foreign widget** — they wrap a fixed widget set behind retained-mode diffing. They are a
   trap for a libghostty terminal. The realistic path is the **imperative binding (makoni's
   swift-adwaita) or direct C interop** — more verbose, less magical.
2. **No Swift binding can define a new GObject type (subclass a widget).** This is a real, confirmed
   gap (gtk-rs and Ghostty's own Zig both do it first-class; Swift does not). It is **largely
   avoidable** for this app (compose stock widgets, reuse Ghostty's own surface widget, drop to a
   tiny C shim where a true new GType is unavoidable) — but it is friction you will feel.
3. **Small, thin ecosystem.** Swift GTK bindings have hobby-scale communities and few shipped apps;
   gtk-rs ships Fractal/Amberol/etc. with ~180k downloads/month. You will be a trailblazer in the
   UI layer and own bugs the community hasn't hit yet.
4. **`Process` and `URLSession` have Linux rough edges** (see §3) — solvable, but budget for them.
5. **QUIC requires binding a C library** (msquic recommended) — no native Swift QUIC exists. This is
   true in Zig too, so it doesn't differentiate, but it is net-new glue (~300–600 LOC).

None of these is a showstopper. The single biggest *unknown* — getting a rendered libghostty surface
inside a GTK widget — is **language-independent** (§8): Swift and Rust both must bridge to Ghostty's
Zig/GTK surface, so it does not tilt the decision. Given that, and given how much subtle tested code
(the ~1100-line predictive-echo engine + ~1500 lines of tests, the grid state machine, the tmux
reducers) you keep for free, **Swift-on-Linux is worth it — provided the team accepts an imperative /
C-interop GTK layer and trailblazer risk.** If the team's priority is a *mature, well-trodden toolkit*
over *logic reuse*, Rust is the more comfortable bet — at the cost of rewriting and re-testing the
core. That is the real trade; this report's lean is that the reuse is worth the unpaved UI road.

---

## 0. The decision, reframed by what's actually portable

The reusable Swift is **pure logic with no AppKit/SwiftUI in it**: the split-tree model, the
session/workspace model, the tmux control-mode client (parser + reducers), and the remote-engine
client — its Codable wire contract (`RemoteGridProtocol.swift`, 335 lines), grid state machine,
reconnect loop, SSH-bootstrap parsing, manifest verification, and the **~1100-line predictive-echo
engine with ~1500 lines of tests**. Per `07-remote-engine-client.md`, this logic already sits
**above a transport interface** (`transport = RemoteEngineNWQUICTransport()`), so only the transport
*implementation* is platform-bound.

So the port splits cleanly:

| Layer | Reuse on Linux-Swift | Notes |
|---|---|---|
| Split-tree / session / workspace models | **As-is** | Plain Swift + Codable |
| tmux control-mode parser + reducers | **As-is** | Process-driven (`tmux -CC`); see §3 caveat |
| Remote-engine: wire contract, grid SM, predictive echo, reconnect | **As-is** | Codable + logic; the crown jewel of reuse |
| Remote-engine **QUIC transport** (`NWConnection`/`NWProtocolQUIC` + Security.framework SPKI) | **Rewrite** (~700 LOC) | Apple-locked; re-implement on a C QUIC lib (§4) |
| Linear GraphQL client | **Mostly as-is** | Swap URLSession → async-http-client recommended (§3) |
| UI (SwiftUI + AppKit), surface host (NSView/Metal) | **Rewrite** | Required in *every* option, not a Swift-specific cost |

The point: a Zig/Rust rewrite pays the UI-rewrite cost **and** re-implements the entire middle three
rows from scratch (and re-tests them). The Swift path pays the UI-rewrite cost and a ~700-LOC
transport shim. That asymmetry is the whole case for keeping Swift.

---

## 1. GTK4 + libadwaita bindings for Swift

There are **three distinct tiers**, and they are not interchangeable for our use case.

| Binding | Style | Latest | Maintainer/community | Custom GObject subclass | Embed `GtkGLArea` + drive render/realize | Event controllers / IME / clipboard | Fit |
|---|---|---|---|---|---|---|---|
| **Adwaita-for-Swift** (AparokshaUI / david-swift) | Declarative (SwiftUI-like) | 284 commits, last 2026-06-13 | Small; 1 Flathub app (Memorize) | No | **No documented escape hatch** | Only what it wraps | ✗ Trap |
| **SwiftCrossUI** (stackotter / moreSwift) | Declarative, multi-backend | v0.7.0 (2026-06-03) | ~1.6k★, self-described "work-in-progress" | No | **No arbitrary-widget escape hatch** | Only what it wraps | ✗ Trap |
| **swift-adwaita** (makoni) | **Imperative** (build widgets directly) | v1.5.0 (2026-06-04) | Small but active | No | Not pre-wrapped (adds via its C layer) | **Yes** — EventControllerKey/Motion/Scroll, Clipboard, 50+ closure signals | ◐ Best high-level fit |
| **SwiftGtk** (rhx, `gtk4` branch) + SwiftGObject/SwiftGdk + **gir2swift** | Low-level, ~1:1 GIR-generated | tested GTK 4.0–4.22; gir2swift v15 SPM plugin | Tiny (hobby) | **No** (confirmed — SwiftGObject has no GType registration) | **Yes** — GLArea is generated from the GIR; connect render/realize/resize signals | Bindable (signals/methods) | ◐ Lowest-level Swift option |
| **Raw C interop** (`import CGtk` / module map) | Hand-bound C | n/a | You own it | Via C shim | **Yes** | **Yes** | ✓ Most robust (see §2) |

### What the mandatory requirements actually need

The brief lists "custom widgets + GtkGLArea embedding" as mandatory. The two need to be separated,
because their feasibility differs sharply:

- **(b) Embed `GtkGLArea` and drive render/realize — SUPPORTED.** GTK's own contract is: *"connect to
  the `GtkGLArea::render` signal, **or** subclass GtkGLArea and override the render vfunc."* The
  **signal path requires no subclassing** and is exactly how Ghostty itself does it — its
  `GhosttySurface` widget owns a `GtkGLArea` template child and wires `glareaRender` / `glareaResize`
  / realize / unrealize **signals** to the renderer lifecycle (`src/apprt/gtk/class/surface.zig`, per
  `03b-ghostty-source-verified.md`). Any binding that exposes `GtkGLArea` + signal connection
  (SwiftGtk, an extended swift-adwaita, or raw C interop) can do this. Swift's closure→`@convention(c)`
  trampoline + `Unmanaged` context pointer is the standard `g_signal_connect_data` pattern, and
  swift-adwaita already implements 50+ such signal bridges, proving the mechanism works.
- **(a) Define a *custom GObject widget* (register a new GType) — NOT SUPPORTED by any Swift binding.**
  Confirmed: SwiftGObject (the base of the rhx stack) has **no type-registration / class-init
  mechanism**; it wraps *existing* GObject classes. The declarative and imperative libs don't expose
  it either. This is a genuine hole. **But it is mostly avoidable**:
  - The terminal surface = **reuse Ghostty's `GhosttySurface` GObject** (it's already a subclass of
    `adw.Bin`, built in Zig) and embed it as an opaque `GtkWidget*`. No Swift subclass needed.
  - Chrome (splits/tabs/sidebar/dialogs) = compose **stock** widgets: `GtkPaned` (recursive split
    tree), `AdwTabView`/`AdwTabBar`, `AdwNavigationSplitView`/`GtkListBox`, `GtkOverlay`,
    `GtkDragSource`, `GtkGesture*`. None requires a new GType.
  - Where a true custom-drawn/custom-layout widget is genuinely unavoidable, **define that one GType
    in a ~50-line C file** compiled into the module and instantiate/drive it from Swift. This is the
    standard interop escape and the same shim you already accept for libghostty's C API.
- **(c) Event controllers / IME / clipboard.** Controllers and clipboard are confirmed in
  swift-adwaita. **IME** (`GtkIMContext`/`GtkIMMulticontext` with `preedit-changed`/`commit` signals
  and `filter_keypress`) is a plain GObject — bindable via SwiftGtk or C interop, though **not
  pre-wrapped** in the high-level libs, so you will bind it yourself. `02-ghostty-bridge.md` already
  flags CJK/IBus preedit fidelity as a test-heavy risk regardless of language.

### Honest read on Area 1

- **Reject the declarative frameworks** (Adwaita-for-Swift, SwiftCrossUI) as the primary toolkit:
  no way to host a `GtkGLArea`/foreign widget, which is non-negotiable here. They could still be
  used for *isolated* leaf dialogs, but not for the app shell.
- **swift-adwaita (imperative)** is the most pleasant high-level option and is built on direct C
  interop (so missing pieces — GLArea, IMContext — can be added), but it's a small project; you'd be
  depending on (and contributing to) a hobby binding.
- **SwiftGtk + gir2swift** gets you a near-complete, GIR-generated surface (GLArea included) but a
  tiny community and the same no-subclassing limit.
- The most *predictable* path is **raw C interop** (§2), optionally cherry-picking swift-adwaita's
  C-shim layer. You trade some boilerplate for not being hostage to a thin third-party binding.

---

## 2. Direct C-interop fallback — **viable, and arguably the right primary choice**

GTK4/libadwaita is a C/GObject API, and Swift's C interop (Clang module maps, `import CGtk`) is
mature and battle-tested. Hand-binding the *subset we need* is realistic, with strong precedent:

- **Precedent already in-tree:** the macOS app links libghostty purely through its **C API**
  (`GhosttyKit` / `ghostty_*`). The Linux port keeps doing exactly that for libghostty; adding GTK is
  the same kind of work.
- **Precedent in the ecosystem:** makoni's **swift-adwaita is itself just a Swift layer over a
  `CAdwaita` system-library module map** (`pkg-config: libadwaita-1`) — i.e. direct C interop to
  libadwaita/GTK, with closure-based signals on top. The rhx stack (SwiftGLib/SwiftGObject/SwiftGdk)
  is likewise module-maps + gir2swift codegen over the same C ABI.
- **What C interop handles cleanly:** C functions, structs, pointers, opaque handles
  (`GtkWidget*`), and **C function-pointer callbacks** — which is all `g_signal_connect_data`,
  `GtkEventController`, `GtkIMContext`, and `GdkClipboard` need. The callback bridge is the standard
  non-capturing `@convention(c)` trampoline + `Unmanaged<Context>.toOpaque()` as `user_data`.
- **What needs a shim:** C **macros** and **varargs** don't import (`g_object_new(…, "prop", v, NULL)`,
  variadic `g_signal_connect`). These are wrapped in a few dozen lines of `static inline` C helpers
  (or you use `g_object_set_property` / `g_signal_connect_data` non-variadic forms directly). This is
  routine; every non-C GTK binding does it.

**Effort scale:** binding the subset (GtkApplication/AdwApplication, windows, `GtkBox`/`GtkPaned`/
`GtkOverlay`, `AdwTabView`, `GtkGLArea` + signals, `GtkEventController*`, `GtkIMMulticontext`,
`GdkClipboard`, plus `GNotification`/libnotify and `libsecret`) is a **few hundred lines of module
map + thin C shims**, not a from-scratch toolkit. The one true new-GType need (if any) is the ~50-line
C shim from §1.

**Verdict:** direct C interop is the most robust foundation and removes the dependency risk of a thin
third-party binding. Recommended primary, optionally reusing swift-adwaita's `CAdwaita` shim layer.

---

## 3. Swift core libraries on Linux

Materially better than its pre-2024 reputation, because Foundation was rewritten.

- **Foundation / `Codable` / `JSONEncoder`/`Decoder` — GREEN.** As of Swift 6, importing `Foundation`
  on Linux uses the **new Swift rewrite (`swift-foundation` / `FoundationEssentials`)**, not the old
  ObjC-reimplementation. `Codable`, `JSONEncoder`/`JSONDecoder`, `Data`, `URL`, `Calendar`, etc. are
  in `FoundationEssentials` and are first-class. The remote-engine and tmux Codable contracts port
  unchanged. (`Future of Foundation`, swift.org.)
- **`FileManager` — GREEN.** Present and stable; XDG paths handled by you, but the API works.
- **`NotificationCenter` — GREEN.** The *in-process* `NotificationCenter` (observer pattern) is core
  Foundation and present on Linux. (Do not confuse with Apple's `UNUserNotificationCenter`, which is
  OS notifications → map to libnotify/`GNotification`, per `03-ghostty-vendor-linux.md`.)
- **`Process` / `Pipe` — GREEN with a CAVEAT.** Present and heavily exercised (SwiftPM spawns
  compilers with it). **Caveat for the tmux control channel:** Foundation's `Pipe.readabilityHandler`
  has known Linux rough edges — e.g. *not firing on EOF* (swift-issues #12080) and blocking-I/O
  interactions with Swift concurrency. For a long-lived, high-throughput bidirectional `tmux -CC`
  channel this is the kind of thing that bites. Mitigations: drive the pipe with raw POSIX fds +
  the GLib main-loop (`g_unix_fd_add`, which you have anyway via GTK) instead of `readabilityHandler`,
  or use SwiftNIO pipes. The new async **`Subprocess`** API (SF-0007, shipped Swift 6.2, Oct 2025) is
  the modern replacement for spawning, but the *streaming-read* concern is the part to design around.
- **`URLSession` (Linear GraphQL) — VIABLE WITH CAVEAT.** Provided by `FoundationNetworking`
  (libcurl-backed) on Linux. Plain HTTPS POST/JSON for Linear's GraphQL works, but Linux URLSession
  has historically lagged Darwin (auth/cookies/concurrency inconsistencies) and is **broken under the
  fully-static Linux SDK** (corelibs-foundation #5092/#5089). **Recommendation:** use
  **`async-http-client`** (swift-server/SwiftNIO) for the Linear calls — it behaves identically on
  Linux and macOS and is the server-Swift standard. Low cost, removes a flaky dependency.
- **`OpenCombine` (Combine replacement) — GREEN-ish.** Actively maintained (last release 2025-12-01;
  maintainers incl. Max Desiatov), modules `OpenCombine`/`OpenCombineFoundation`/`OpenCombineDispatch`
  + an `OpenCombineShim` that re-exports real Combine on Apple platforms and OpenCombine elsewhere —
  so shared code compiles both places. Caveat: it's an *independent reimplementation*; coverage of the
  common `Publisher`/`Subject`/operators is good, but exotic operators or Combine-Foundation bridges
  may differ. Audit which Combine surface Fantastty actually uses (likely `@Published`/`PassthroughSubject`/
  `sink`/`map` — all covered).
- **`swift-crypto` (CryptoKit replacement) — GREEN.** API-compatible with CryptoKit; on Linux it
  vendors **BoringSSL** and implements the same API. **SHA-256 is supported** — directly relevant: the
  remote-engine SPKI pin is a SHA-256 over the cert's SubjectPublicKeyInfo, which you compute with
  `Crypto.SHA256` over the DER blob the QUIC lib hands you (§4). Actively maintained.

Net: the core-lib surface the reusable logic needs is mature. The two things to *engineer around* are
the `Pipe` streaming-read edge cases (tmux) and URLSession (use async-http-client).

---

## 4. QUIC client from Swift on Linux

The macOS transport (`07-remote-engine-client.md`) is **Network.framework**: `NWConnection` /
`NWProtocolQUIC.Options` (legacy) and `NetworkConnection<QUIC>` (macOS 26 typed API), with
`maxDatagramFrameSize=1200`, ALPN `fantastty-remote-engine-v1`, `.peerAuthentication(.required)`, and
`sec_protocol_options_set_verify_block` doing **SPKI-SHA256 pinning** (extract leaf cert SPKI, prepend
the P-256 SubjectPublicKeyInfo DER prefix, SHA-256, compare — mirroring the Go helper's
`x509.MarshalPKIXPublicKey`). Network.framework has **no Linux equivalent**, so this ~700-LOC layer is
rewritten on a C QUIC library. The hard requirements: **client-sent unreliable datagrams (≥1200B,
RFC 9221)**, **fully custom SPKI-pin verification (no CA chain)**, **ALPN**, **concurrent streams +
datagrams**.

| Library | C API | Client datagrams | Custom cert verify (SPKI pin, no CA) | ALPN | Maintenance | Swift-binding difficulty |
|---|---|---|---|---|---|---|
| **msquic** (Microsoft) | Yes (`msquic.h`) | Yes (`DatagramSend`) | **Yes — true in-handshake callback; cert delivered as a DER blob** | Yes | v2.5.7-rc, Jan 2026, MIT; MS-production | **Easiest** (~300–600 LOC) |
| lsquic (LiteSpeed) | Yes | Yes | Yes — `ea_verify_cert(ctx, STACK_OF(X509)*)` | Yes | v4.6.4, May 2025, MIT | Hard (you own UDP loop + BoringSSL X509 types) |
| Cloudflare quiche | Yes | Yes (`quiche_conn_dgram_send`) | **Partial** — no in-handshake callback in C API; only `verify_peer(false)` + post-handshake `peer_cert()` check | Yes | 0.28.0, Apr 2026, BSD-2 | Hard (you own UDP loop) |
| ngtcp2 | Yes | Yes | Yes — you own `SSL_CTX` (`SSL_CTX_set_custom_verify`) | Yes | 1.24.x, 2026, MIT | Hardest (bind ngtcp2 + TLS + full I/O) |
| swift-nio / swift-quic | n/a (native Swift) | Not usable | Not usable | Not usable | swift-quic: "**not ready for production**"; swift-nio has **no QUIC** (#1730) | Not an option |

### Recommendation: **msquic**

It is the only candidate that gives a **true in-handshake custom-validation callback AND hands the
server certificate across the FFI as a plain DER blob** (`QUIC_CREDENTIAL_FLAG_USE_PORTABLE_CERTIFICATES`),
so the Swift binding **never touches OpenSSL/BoringSSL `X509` types** — it computes the SPKI SHA-256
with **swift-crypto** and accepts/rejects, reproducing the macOS `verify_block` almost line-for-line.
It also **owns its own epoll datapath, worker threads, sockets, and TLS**, so there is **no UDP loop
or timer pump to write in Swift** (the big hidden cost in quiche/lsquic/ngtcp2). Client datagrams via
`DatagramSend`; ALPN supported; concurrent streams + datagrams native.

- **Binding effort:** module map ~10 LOC; Swift wrapper (API table from `MsQuicOpen2`, handle
  lifetimes, C-callback→Swift trampolines via `Unmanaged`) ~**300–600 LOC**; SPKI-pin check ~30 LOC.
  Total well under the ~700-LOC the macOS NW transport occupies.
- **Day-one gotcha:** for the self-signed/no-CA cert you must set
  `QUIC_CREDENTIAL_FLAG_NO_CERTIFICATE_VALIDATION` **together with** `INDICATE_CERTIFICATE_RECEIVED`
  + `USE_PORTABLE_CERTIFICATES`. `INDICATE` alone leaves OpenSSL's own validation in place, which
  fails the handshake on the self-signed cert before your pin check runs.
- **1200-byte caveat (all libs):** a DATAGRAM frame can't fragment; it must fit one QUIC packet. On a
  hard 1280-MTU path a ≥1200-byte payload isn't achievable on *any* library — query the runtime
  max-writable-datagram length rather than assuming 1200. This is fine for us: the protocol already
  **gates datagrams behind a keyframe** (`datagramsEnabledAfterKeyframe`) and **falls back to the
  reliable stream**, so degraded-MTU paths downgrade gracefully instead of breaking.

quiche is the notable trap: its **C API cannot register a custom verify callback** (the Rust API can;
issue #326), forcing post-handshake pin-and-close — weaker and not what we want.

---

## 5. Contrast: Rust and Zig ecosystem maturity (for weighing the trade)

**Rust — the most mature toolkit of the three, but it discards the Swift logic.**
GTK4: `gtk4` crate **0.11.3** (Apr 2026) + `libadwaita` **0.9.1** (Feb 2026), tracking GTK 4.0→4.22,
~180k downloads/month, shipping real GNOME apps (Fractal, Amberol, Authenticator, Pika Backup,
Shortwave). **Custom GObjects/widgets are first-class** (`glib::ObjectSubclass` + `glib::wrapper!`,
vfunc overrides), `GtkGLArea` is bound (connect render *or* override the render vfunc), and event
controllers/IME/clipboard are near-complete vs the C API; `relm4` 0.11.0 is a mature Elm-style layer.
QUIC: **quinn 0.11.11** (Jun 2026) implements RFC 9221 datagrams with an identical client/server API
(client datagrams fully supported), and **rustls 0.23.41** `ServerCertVerifier` (`dangerous()`
custom verifier) does SPKI-pin-only verification trivially; ALPN supported; deployed on 100k+ devices
via iroh. Rust clearly wins on *toolkit maturity and a native QUIC stack* — the price is rewriting and
**re-testing** the entire reusable core (split-tree, tmux reducers, grid SM, the 1100-line predictive
echo + 1500 test lines).

**Zig — viable essentially only by extending Ghostty's own apprt; pre-1.0 risk; no native QUIC.**
Ghostty is Zig and ships its **own GTK4 + libadwaita frontend**, calling GTK via GObject-introspection
bindings (`ghostty-org/zig-gobject`, a fork of `ianprime0509/zig-gobject` v0.3.1, Nov 2025), and its
2025 GTK rewrite **defines custom GObject subclasses/widgets in Zig** — so Zig *can* subclass and the
"extend Ghostty's apprt" route sidesteps the libghostty-surface problem natively (its strongest
selling point). But Zig is **pre-1.0 (0.16.0, Apr 2026)** with breaking changes every release, the
non-Ghostty Zig+GTK ecosystem is thin, and **there is no production-grade native Zig QUIC** — you'd
`@cImport` the same C library (msquic/quiche/lsquic) Swift would, plus re-implement all the reusable
logic in a churning language. Zig's appeal is almost entirely the libghostty shortcut, not independent
ecosystem maturity.

**Where Swift sits:** behind Rust on toolkit maturity and community size; ahead of Zig on language
stability and core-library breadth; level with both on QUIC (everyone binds a C lib); and **uniquely
able to reuse the tested core without a rewrite.** The decision is "logic reuse vs toolkit maturity,"
and Swift's whole value is the former.

---

## 6. The cross-cutting risk that dominates every option (language-independent)

Per `03b-ghostty-source-verified.md`: libghostty's **embedded C API renders Metal-only**; OpenGL works
**only inside Ghostty's GTK apprt's own Zig code**, where the `GtkGLArea` provides/makes-current the
context — and that surface widget is **coupled to Ghostty's GTK `Application` singleton** and is **not
exposed over the C ABI**. So getting a *rendered* terminal surface into our window requires either
(a) reusing Ghostty's `GhosttySurface` GTK widget as an embeddable `GtkWidget`, or (b) net-new Zig work
in libghostty to expose a GL-embed C API.

This is **the #1 risk for the whole port**, but it is **orthogonal to the Swift-vs-rewrite decision**:
a Rust app faces the identical bridge; only a *Zig* app (extending Ghostty's apprt directly) avoids it.
It therefore does **not** count against Swift relative to Rust — but it does mean the Swift (or Rust)
app needs a Zig/C bridge to Ghostty's surface regardless. Plan the surface widget as "embed an opaque
`GtkWidget*` Ghostty hands us and connect its signals/actions," which is well within C-interop reach.

---

## 7. Recommended shape if Swift is chosen

1. **Keep** the platform-neutral Swift core (split-tree, session/workspace, tmux client, remote-engine
   logic + tests) — port as-is on `swift-foundation` + `swift-crypto` + OpenCombine.
2. **Build the GTK4 chrome via direct C interop** (optionally reusing swift-adwaita's `CAdwaita` shim
   for ergonomics). **Do not** adopt the declarative frameworks for the shell.
3. **Reuse Ghostty's GTK surface widget** (its `GhosttySurface` GObject) embedded as an opaque
   `GtkWidget`; drive it via signals/actions — avoid building a GL host (and avoid needing to subclass)
   in Swift. Keep one ~50-line C shim available for any unavoidable new GType.
4. **Remote transport:** bind **msquic**; reproduce SPKI-SHA256 pinning with swift-crypto over the
   portable-cert DER blob; keep the existing `RemoteEngineQUICTransport` interface so the reusable
   message loop/predictive-echo sits unchanged on top.
5. **Linear:** swap URLSession → `async-http-client`. **tmux:** drive the control-mode pipe via raw
   fds on the GLib main loop, not `Pipe.readabilityHandler`.
6. **IME:** bind `GtkIMMulticontext` yourself; budget real CJK/IBus testing (risk is language-independent).

## 8. Honest holes (don't gloss these)

- **No GObject subclassing in any Swift binding** — confirmed gap; avoidable but a real ergonomic tax,
  and the thing Rust/Zig do better.
- **Declarative Swift GTK frameworks are unusable for the shell** — you're committed to the more
  verbose imperative/C-interop layer.
- **Thin ecosystem / trailblazer risk** in the UI layer; the binding maintainers are hobby-scale.
- **`Pipe` streaming + Linux `URLSession`** need engineering-around (solutions identified above).
- **QUIC is net-new C-binding work** (~300–600 LOC) — modest, but real, and unavoidable in Swift *and*
  Zig.
- **The libghostty GL-surface bridge** is the dominant unknown — but shared with Rust, so neutral to
  this decision.

If those are acceptable, Swift-on-Linux is the right call because of how much tested code it saves. If
the team would rather stand on the most mature toolkit and is willing to rewrite+re-test the core,
Rust is the safer-but-costlier alternative. **Verdict: Viable-with-caveats.**

---

## Sources

**GTK4/libadwaita Swift bindings**
- Writing GNOME Apps with Swift — https://www.swift.org/blog/adwaita-swift/ (Mar 25 2024)
- Adwaita-for-Swift — https://github.com/AparokshaUI/adwaita-swift → https://codeberg.org/aparoksha/adwaita-swift (last 2026-06-13)
- SwiftCrossUI — https://github.com/stackotter/swift-cross-ui (v0.7.0, 2026-06-03)
- swift-adwaita (makoni) — https://github.com/makoni/swift-adwaita (v1.5.0, 2026-06-04)
- SwiftGtk (gtk4) — https://github.com/rhx/SwiftGtk/tree/gtk4 ; docs https://rhx.github.io/SwiftGtk4Doc/
- SwiftGObject — https://github.com/rhx/SwiftGObject ; gir2swift — https://github.com/rhx/gir2swift
- Gtk.GLArea (render-signal-or-subclass) — https://docs.gtk.org/gtk4/class.GLArea.html

**Swift core libs on Linux**
- swift-foundation — https://github.com/swiftlang/swift-foundation ; Future of Foundation — https://www.swift.org/blog/future-of-foundation/
- Subprocess (SF-0007, Swift 6.2) — https://github.com/swiftlang/swift-foundation/blob/main/Proposals/0007-swift-subprocess.md
- Pipe readabilityHandler EOF bug — https://github.com/apple/swift-issues/issues/12080
- corelibs-foundation URLSession static-SDK issue — https://github.com/swiftlang/swift-corelibs-foundation/issues/5092
- async-http-client — https://github.com/swift-server/async-http-client
- OpenCombine — https://github.com/OpenCombine/OpenCombine (last release 2025-12-01)
- swift-crypto (CryptoKit-compatible, vendored BoringSSL, SHA256) — https://github.com/apple/swift-crypto

**QUIC**
- msquic — https://github.com/microsoft/msquic ; DatagramSend https://github.com/microsoft/msquic/blob/main/docs/api/DatagramSend.md ; QUIC_CREDENTIAL_CONFIG https://github.com/microsoft/msquic/blob/main/docs/api/QUIC_CREDENTIAL_CONFIG.md ; portable-cert gotcha https://github.com/microsoft/msquic/discussions/4007
- Cloudflare quiche — https://github.com/cloudflare/quiche ; custom-verify gap https://github.com/cloudflare/quiche/issues/326
- lsquic — https://github.com/litespeedtech/lsquic ; ngtcp2 — https://github.com/ngtcp2/ngtcp2
- swift-quic ("not production ready") — https://github.com/swift-quic/swift-quic ; swift-nio QUIC ask — https://github.com/apple/swift-nio/issues/1730

**Rust / Zig contrast**
- gtk4-rs subclassing — https://gtk-rs.org/gtk4-rs/stable/latest/book/g_object_subclassing.html ; gtk4 crate https://lib.rs/crates/gtk4 ; libadwaita https://lib.rs/crates/libadwaita ; relm4 https://lib.rs/crates/relm4
- quinn (RFC 9221 datagrams) — https://docs.rs/quinn/latest/quinn/struct.Connection.html ; rustls custom verifier — https://docs.rs/rustls/latest/rustls/client/danger/trait.ServerCertVerifier.html ; quinn cert guide https://quinn-rs.github.io/quinn/quinn/certificate.html
- s2n-quic — https://lib.rs/crates/s2n-quic ; datagram bug https://github.com/aws/s2n-quic/issues/2520
- Ghostty zig-gobject — https://github.com/ghostty-org/zig-gobject ; ianprime0509/zig-gobject — https://github.com/ianprime0509/zig-gobject ; Ghostty GTK rewrite — https://mitchellh.com/writing/ghostty-gtk-rewrite ; Zig releases — https://ziglang.org/download/

**In-repo cross-refs:** `07-remote-engine-client.md` (NW QUIC transport, SPKI pin), `02-ghostty-bridge.md`
(GTK surface/IME/clipboard mapping), `03-ghostty-vendor-linux.md` & `03b-ghostty-source-verified.md`
(GtkGLArea surface widget, GL-embed C-API gap).
