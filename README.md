# insanitty

A native **Linux** port of [Fantastty](inspo/fantastty) — a libghostty-based terminal
**workspace manager** with tmux-backed persistent sessions and an SSH/QUIC remote engine.

> Status: **Phase 0 (de-risking spikes).** The planning is complete (see `docs/`); the repo
> currently contains a building, tested scaffold and a runnable GTK4 app shell skeleton.
> Terminal panes are placeholders until the forked Ghostty GTK surface is wired (Spike A).

## What this is

insanitty is not a terminal emulator — the terminal engine is **Ghostty**. insanitty is the
workspace/session manager around it: persistent, tmux-backed workspaces with tabs, splits,
notes, ticket/PR URLs, attention, and a remote engine (SSH-deployed Go helper attached over
QUIC). Full design:

- **`docs/SPEC.md`** — the feature + contract spec (what insanitty must do).
- **`docs/IMPLEMENTATION-PROPOSAL.md`** — the architecture & phased plan.
- **`docs/STATUS.md`** — what's been built/verified so far.
- **`docs/research/`** — subsystem deep-dive reports.

## Architecture (ratified)

- **Language: Swift** — reuses Fantastty's tested logic (split tree, session model, tmux
  client, remote protocol + predictive echo).
- **Chrome: GTK4 + libadwaita** via direct C interop (`Sources/CAdw`).
- **Engine: forked Ghostty** — embed its GTK `GhosttySurface` widget; the only renderer that
  works on Linux (the embeddable C API is Metal-only). Bridge in `Sources/CInsanitty`.
- **Remote helper: the existing Go helper, reused unchanged.**
- **QUIC: msquic.**

## Layout

```
Package.swift              SwiftPM manifest
Sources/
  CAdw/                    GTK4 + libadwaita module map (system library)
  CInsanitty/              C bridge: Ghostty surface shim (stub) + GObject signal helper
  InsanittyCore/           ported platform-neutral Swift logic (grows into the app)
  insanitty/               GTK4/libadwaita app shell skeleton
  spike-gtk-smoke/         Phase-0 spike: Swift↔GTK interop (verified)
Tests/InsanittyCoreTests/  unit tests for the ported logic
patches/                   libghostty patch the forked-Ghostty build must apply
scripts/                   dev-env setup + Ghostty build
docs/                      spec, proposal, research, status
```

## Build & run

Requires the toolchains in `scripts/setup-dev-env.sh` (Swift 6.x, Zig 0.15.2, GTK4 4.14+ /
libadwaita 1.4+ dev). Then:

```sh
swift build          # builds the shell + spikes
swift test           # runs InsanittyCore tests
# Headless smoke (CI uses this):
xvfb-run -a .build/debug/spike-gtk-smoke
INSANITTY_SMOKE=1 xvfb-run -a .build/debug/insanitty
```

See `docs/STATUS.md` for what currently builds/runs and the remaining Phase-0 work.

## License

MIT (matching Fantastty).
