# Research Brief: Fantastty → Linux Native Port ("insanitty")

## Mission
We are planning a **native Linux port** of **Fantastty**, a macOS terminal app. The port must
replicate the **full feature set** including the **remote feature set**, but be Linux-native:
clean, fast, easy to use, and use Linux platform affordances (not a macOS skin on Linux).

The macOS source lives at `/home/jesse/git/insanitty/inspo/fantastty`.
The Linux port repo root is `/home/jesse/git/insanitty`.

## What Fantastty is (already-established context — do not re-derive)
A ~32K-line macOS SwiftUI app built on **libghostty** (Ghostty's terminal engine, vendored at
`inspo/fantastty/vendor/ghostty`, embedded as a `GhosttyKit.xcframework` static lib). Core ideas:
- **Workspaces**: each sidebar item is an independent workspace (tabs, notes, URLs, tags, metadata).
- **Persistent sessions**: workspaces/tabs are backed by **tmux** sessions that survive restarts.
- **Splits**: split panes within tabs (a split tree).
- **Remote engine**: connect to an SSH host, deploy a bundled **Go helper**, attach over **QUIC**,
  and render structured grid/keyframe/delta messages with predictive local echo.
- **tmux control mode**: a large subsystem that drives tmux via control mode (-CC) and maps tmux
  layouts to the app's panes.
- Auxiliary: WebKit **browser tabs**, **Fly.io Sprites** (cloud VM workspaces via `sprite` CLI),
  **Linear** ticket/project integration (token in macOS Keychain), timestamped **notes**,
  shell integration (zsh pwd tracking + `fantastty-note`), attention indicators.

Key porting facts already known:
- Ghostty's *native* platform is **Linux/GTK** — a reference GTK frontend + OpenGL renderer exist
  in the vendored source. libghostty is cross-platform via a C API.
- The Go remote helper already builds `linux-amd64`/`linux-arm64`/`darwin-arm64`.
- tmux integration is process-based (cross-platform).
- The hard part is the **UI layer** (SwiftUI + AppKit) and the **surface embedding** (Metal + NSView).

## Your job
Deep-dive your assigned subsystem in the macOS source. Produce TWO things:
1. A **detailed written report** at the path given in your assignment (`docs/research/NN-*.md`).
2. A **concise structured summary** returned as your final message (this is data for the orchestrator,
   not a human-facing note — return the substance, not pleasantries).

## Reporting contract — every report MUST have these sections:
1. **Scope** — files you actually read (with line counts), and what you did NOT cover.
2. **What it does (behavior & features)** — the user-facing behaviors and contracts this subsystem
   provides. Be concrete: what can a user do, what are the rules, edge cases, states. This feeds the
   product SPEC, so describe the *feature*, not just the code.
3. **How it's built (architecture)** — key types, data flow, control flow, important invariants,
   protocols/wire formats, persistence formats. Include the few most important code refs as
   `path:line`. Note threading/concurrency model where relevant.
4. **Platform dependencies (macOS-specific)** — every macOS/Apple API, framework, idiom, private API,
   or platform assumption this subsystem relies on. Be exhaustive and specific (name the class/call).
5. **Linux mapping** — for each macOS dependency, the concrete Linux-native equivalent (GTK4/libadwaita,
   Wayland/X11, WebKitGTK, libsecret/Secret Service, libnotify, OpenGL/EGL, XKB, systemd, XDG dirs,
   D-Bus, etc.). Flag anything with NO clean Linux equivalent as a RISK.
6. **Reuse assessment** — what is cross-platform Swift/logic that could port largely as-is; what is
   macOS-glue that must be rewritten; what could be reused from Ghostty's own Linux/GTK frontend.
7. **Open questions / risks** — unknowns, hard problems, things the orchestrator should investigate.

Keep code reading deep but report tight. Prefer concrete specifics over generalities. Cite `path:line`.
Do not edit any source files. Only write your one report file.
