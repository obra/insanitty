#!/usr/bin/env bash
# E2E: within-workspace layout RESTORE. Splits a workspace (Ctrl+D → a real tmux pane), kills the
# app leaving the tmux session alive, relaunches, and asserts the 2-pane layout came back — proving
# splits are tmux-owned and survive restarts (the parity gap the control-mode refactor closes).
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
SHOT="${OUT:-docs/images}/e2e-12-layout-restore.png"
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
DISP=":141"
mkdir -p /tmp/inscfg/ghostty "${OUT:-docs/images}"; echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-restore-state; mkdir -p "$XDG_STATE_HOME"; rm -f "$XDG_STATE_HOME/insanitty/layout.json"
for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done   # start fresh

launch() { DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" LD_LIBRARY_PATH="$GS/zig-out/lib" \
  dbus-run-session -- ./build/insanitty >"$1" 2>&1 & APP=$!; }
cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done; }
trap cleanup EXIT

Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-restore.log 2>&1 & XVFB=$!; sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-restore.log 2>&1 & WM=$!; sleep 1

# First launch: workspace 0 (control-mode) starts; split it into two tmux panes.
launch /tmp/app-restore1.log
sleep 6
DISPLAY="$DISP" xdotool mousemove 650 350 click 1; sleep 1
DISPLAY="$DISP" xdotool key ctrl+d; sleep 4
DISPLAY="$DISP" import -window root "${OUT:-docs/images}/e2e-12-split.png" 2>/dev/null
grep -q 'window @[0-9]* → 2-pane layout' /tmp/app-restore1.log || { echo "RESTORE E2E FAIL: Ctrl+D did not create a 2-pane tmux layout"; tail -3 /tmp/app-restore1.log; exit 1; }

# Kill the app but leave the tmux session (server) running.
kill "$APP" 2>/dev/null; sleep 2

# Relaunch: re-attach to insanitty-ws-0 and rebuild its 2-pane layout from tmux.
launch /tmp/app-restore2.log
sleep 8
DISPLAY="$DISP" import -window root "$SHOT" 2>/dev/null
if grep -q 'window @[0-9]* → 2-pane layout' /tmp/app-restore2.log; then
  echo "LAYOUT-RESTORE E2E PASS: a tmux-pane split survived an app restart and was rebuilt from tmux ($SHOT)"
else
  echo "LAYOUT-RESTORE E2E FAIL: split not restored after relaunch"; grep 'window @' /tmp/app-restore2.log | tail -3
  exit 1
fi
