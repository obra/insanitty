#!/usr/bin/env bash
# E2E: insanitty renders a REMOTE (QUIC) workspace inside its GUI. The app drives its own remote
# stack — launch-or-resume the helper for a bootstrap line, then connect IN-PROCESS over QUIC
# (SPKI-pinned, RemoteQuicFetcher) and collect the snapshot + pane keyframes — and maps the panes
# onto GtkPaned splits, injecting each via insanitty_surface_inject_output. No subprocess for QUIC,
# no bash/Python. Headless: Xvfb + WM + dbus.
set -uo pipefail
cd "$(dirname "$0")/.."
export INSANITTY_VERBOSE=1   # the assertions below grep insanitty's diagnostic stderr traces
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
SHOT="${OUT:-docs/images}/e2e-7-remote-in-gui.png"
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
export LD_LIBRARY_PATH="$GS/zig-out/lib" FANTASTTY_REMOTE_ADVERTISE_HOST=127.0.0.1 XDG_RUNTIME_DIR=/tmp/ins-remote-rt
mkdir -p /tmp/inscfg/ghostty "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-rgui-state; rm -rf "$XDG_STATE_HOME"  # fresh workspace layout each run
tmux kill-session -t insanitty-remote-gui 2>/dev/null

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; tmux kill-session -t insanitty-remote-gui 2>/dev/null; "${HELPER:-/tmp/fantastty-helper}" shutdown >/dev/null 2>&1; }
trap cleanup EXIT

Xvfb :122 -screen 0 1100x720x24 >/tmp/xvfb-rgui.log 2>&1 & XVFB=$!; sleep 2
DISPLAY=:122 matchbox-window-manager >/tmp/wm-rgui.log 2>&1 & WM=$!; sleep 1
DISPLAY=:122 XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" \
  dbus-run-session -- ./build/insanitty >/tmp/app-rgui.log 2>&1 & APP=$!
sleep 5
# Switch to the "remote (QUIC)" workspace (4th sidebar row; thumbnail rows are ~155px tall)
# so its surface realizes; the re-inject timer then paints the fetched grid where we can see it.
DISPLAY=:122 xdotool mousemove 110 590 click 1
sleep 13   # the default (non-tmux) workspace's helper renderer can take several seconds to launch
DISPLAY=:122 import -window root "$SHOT" 2>/dev/null
grep -q 'rendered .* remote workspace (native QUIC)' /tmp/app-rgui.log || { echo "REMOTE-GUI E2E FAIL: app did not render the remote workspace"; exit 1; }
echo "REMOTE-GUI E2E PASS: insanitty fetched a grid over QUIC and rendered it ($SHOT)"
