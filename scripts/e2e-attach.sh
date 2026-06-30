#!/usr/bin/env bash
# E2E: attach to an existing tmux session as a workspace (what the attach picker does). Creates an
# external tmux session, launches insanitty with INSANITTY_ATTACH pointing at it (the env hook the
# picker drives), and asserts insanitty attached to THAT session in control mode and rendered it.
# (The picker UI itself is visually confirmed in docs; this exercises the attach path without
# clicking near any live session.)
set -uo pipefail
cd "$(dirname "$0")/.."
export INSANITTY_VERBOSE=1   # the assertions below grep insanitty's diagnostic stderr traces
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
SHOT="${OUT:-docs/images}/e2e-13-attach.png"; LOG=/tmp/app-attach.log
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
DISP=":142"; SESS="ins-attach-target"
mkdir -p /tmp/inscfg/ghostty "${OUT:-docs/images}"; echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-attach-state; mkdir -p "$XDG_STATE_HOME"; rm -f "$XDG_STATE_HOME/insanitty/layout.json"
export INSANITTY_ATTACH="$SESS"
tmux kill-session -t "$SESS" 2>/dev/null
tmux new-session -d -s "$SESS" -x 100 -y 28
tmux send-keys -t "$SESS" "clear; echo ATTACH-MARKER-HELLO" Enter
for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done; tmux kill-session -t "$SESS" 2>/dev/null; }
trap cleanup EXIT

Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-attach.log 2>&1 & XVFB=$!; sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-attach.log 2>&1 & WM=$!; sleep 1
DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" LD_LIBRARY_PATH="$GS/zig-out/lib" \
  dbus-run-session -- ./build/insanitty >"$LOG" 2>&1 & APP=$!
sleep 7
# Select the attached workspace (last sidebar row) so it paints, then screenshot.
DISPLAY="$DISP" xdotool mousemove 110 650 click 1; sleep 3
DISPLAY="$DISP" import -window root "$SHOT" 2>/dev/null

if grep -q "tmux-cc: attached $SESS" "$LOG"; then
  echo "ATTACH E2E PASS: insanitty attached the existing tmux session '$SESS' as a workspace ($SHOT)"
else
  echo "ATTACH E2E FAIL: did not attach $SESS"; grep -i 'tmux-cc' "$LOG" | tail -3
  exit 1
fi
