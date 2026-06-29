#!/usr/bin/env bash
# E2E: insanitty renders a REMOTE (QUIC) workspace inside its GUI. The app fetches a pane
# grid from the remote-engine helper over QUIC (scripts/remote-grid-ansi.sh) and injects it
# into an inert surface via insanitty_surface_inject_output. Headless: Xvfb + WM + dbus.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-/tmp/claude-1000/-home-jesse-git-insanitty/d4fe9727-abcd-4a64-bfab-456b14fdb334/scratchpad/ghostty-src}"
SHOT="${OUT:-docs/images}/e2e-7-remote-in-gui.png"
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
export LD_LIBRARY_PATH="$GS/zig-out/lib" FANTASTTY_REMOTE_ADVERTISE_HOST=127.0.0.1 XDG_RUNTIME_DIR=/tmp/ins-remote-rt
mkdir -p /tmp/inscfg/ghostty "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
echo "initial-window = false" > /tmp/inscfg/ghostty/config
tmux kill-session -t insanitty-remote-gui 2>/dev/null

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; tmux kill-session -t insanitty-remote-gui 2>/dev/null; "${HELPER:-/tmp/fantastty-helper}" shutdown >/dev/null 2>&1; }
trap cleanup EXIT

Xvfb :122 -screen 0 1100x720x24 >/tmp/xvfb-rgui.log 2>&1 & XVFB=$!; sleep 2
DISPLAY=:122 matchbox-window-manager >/tmp/wm-rgui.log 2>&1 & WM=$!; sleep 1
DISPLAY=:122 XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" \
  dbus-run-session -- ./build/insanitty >/tmp/app-rgui.log 2>&1 & APP=$!
sleep 13
DISPLAY=:122 import -window root "$SHOT" 2>/dev/null
grep -q 'injected .* bytes of remote grid' /tmp/app-rgui.log || { echo "REMOTE-GUI E2E FAIL: app did not inject a fetched grid"; exit 1; }
echo "REMOTE-GUI E2E PASS: insanitty fetched a grid over QUIC and rendered it ($SHOT)"
