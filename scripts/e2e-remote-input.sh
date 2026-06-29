#!/usr/bin/env bash
# E2E: keystrokes typed in a REMOTE (QUIC) workspace are captured, encoded, and forwarded to the
# remote pane over the LIVE SPKI-pinned QUIC connection. We type `echo RMT-$((6*7))` into the
# remote pane; the app queues the bytes, and the next fetch forwards them (a `sendKeys` request on
# the same connection that just delivered a keyframe) + asks for a fresh keyframe. We assert the
# app logged that it forwarded the keystrokes over the live connection.
#
# Note: the end-to-end echo (the remote shell RUNNING the command) is NOT asserted here, because
# the only remote workspace available in this environment is the helper's default direct-shell
# workspace, whose SendKeys is a no-op stub (remoteWorkspacePayloadSource.SendKeys → return nil);
# input round-trips only for tmux-backed workspaces, whose daemon does not become ready here. That
# is the same helper-side limitation that blocks the live multi-pane path. The GUI input path
# (capture → encode → forward over QUIC) is fully exercised.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
SHOT="${OUT:-docs/images}/e2e-remote-input.png"; LOG=/tmp/app-rinput.log
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
export LD_LIBRARY_PATH="$GS/zig-out/lib" FANTASTTY_REMOTE_ADVERTISE_HOST=127.0.0.1 XDG_RUNTIME_DIR=/tmp/ins-rinput-rt
mkdir -p /tmp/inscfg/ghostty "$XDG_RUNTIME_DIR" "${OUT:-docs/images}"; chmod 700 "$XDG_RUNTIME_DIR"
echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-rinput-state; rm -rf "$XDG_STATE_HOME"
tmux kill-session -t insanitty-remote-gui 2>/dev/null

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; tmux kill-session -t insanitty-remote-gui 2>/dev/null; "${HELPER:-/tmp/fantastty-helper}" shutdown >/dev/null 2>&1; }
trap cleanup EXIT

Xvfb :123 -screen 0 1100x720x24 >/tmp/xvfb-rinput.log 2>&1 & XVFB=$!; sleep 2
DISPLAY=:123 matchbox-window-manager >/tmp/wm-rinput.log 2>&1 & WM=$!; sleep 1
DISPLAY=:123 XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" \
  dbus-run-session -- ./build/insanitty >"$LOG" 2>&1 & APP=$!
sleep 5
# Select the remote (QUIC) workspace (4th sidebar row) and wait for the initial paint.
DISPLAY=:123 xdotool mousemove 110 590 click 1
sleep 13   # the default (non-tmux) workspace's helper renderer can take several seconds to launch
grep -q 'rendered .* remote workspace (native QUIC)' "$LOG" || { echo "REMOTE-INPUT E2E FAIL: remote workspace never painted"; tail -3 "$LOG"; exit 1; }
# Focus the remote pane and type a command (17 visible chars + Enter = 18 bytes).
DISPLAY=:123 xdotool mousemove 650 350 click 1; sleep 1
DISPLAY=:123 xdotool type --delay 40 'echo RMT-$((6*7))'
DISPLAY=:123 xdotool key Return
sleep 5
DISPLAY=:123 import -window root "$SHOT" 2>/dev/null
FWD=$(grep -oE 'forwarding [0-9]+ input byte' "$LOG" | grep -oE '[0-9]+' | sort -n | tail -1)
if [ "${FWD:-0}" -ge 10 ]; then
  echo "REMOTE-INPUT E2E PASS: app captured + forwarded $FWD keystroke bytes to the remote pane over the live QUIC connection ($SHOT)"
else
  echo "REMOTE-INPUT E2E FAIL: app did not forward keystrokes over QUIC (got ${FWD:-0} bytes)"
  grep -E 'forwarding|rendered .* remote' "$LOG" | tail -3
  exit 1
fi
