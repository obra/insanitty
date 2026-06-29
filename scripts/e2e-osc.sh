#!/usr/bin/env bash
# E2E: OSC 9 note/ticket/pr interception. Sources the shell integration in a workspace terminal and
# runs `insanitty-note <text>`, which emits an OSC 9 `insanitty:note;…` payload. The embedding lib's
# notification hook hands it to insanitty, which stores it on the workspace's metadata. Asserts the
# note (source "terminal") landed in workspaces.json. tmux passthrough is enabled so the OSC reaches
# ghostty through the workspace's tmux session.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
SHOT="${OUT:-docs/images}/e2e-11-osc.png"; LOG=/tmp/app-osc.log
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
DISP=":140"; MARK="OSC-NOTE-MARKER-42"
mkdir -p /tmp/inscfg/ghostty "${OUT:-docs/images}"; echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-osc-state; mkdir -p "$XDG_STATE_HOME/insanitty"
WS="$XDG_STATE_HOME/insanitty/workspaces.json"; rm -f "$WS"

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done; }
trap cleanup EXIT

Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-osc.log 2>&1 & XVFB=$!; sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-osc.log 2>&1 & WM=$!; sleep 1
DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" LD_LIBRARY_PATH="$GS/zig-out/lib" \
  dbus-run-session -- ./build/insanitty >"$LOG" 2>&1 & APP=$!
sleep 6
tmux set-option -t insanitty-ws-0 -g allow-passthrough on 2>/dev/null   # let OSC passthrough reach ghostty
DISPLAY="$DISP" xdotool mousemove 650 350 click 1; sleep 1              # focus the terminal
DISPLAY="$DISP" xdotool type --delay 20 "source $PWD/scripts/shell-integration/insanitty.sh"
DISPLAY="$DISP" xdotool key Return; sleep 1
DISPLAY="$DISP" xdotool type --delay 20 "insanitty-note $MARK"
DISPLAY="$DISP" xdotool key Return; sleep 3
DISPLAY="$DISP" import -window root "$SHOT" 2>/dev/null

if grep -q "$MARK" "$WS" 2>/dev/null && grep -q '"terminal"' "$WS"; then
  echo "OSC E2E PASS: insanitty-note OSC 9 consumed → note stored on the workspace (source=terminal) ($SHOT)"
else
  echo "OSC E2E FAIL: note not stored"; echo "--- app log (osc) ---"; grep -i 'consumed OSC' "$LOG" | tail -2; echo "--- workspaces.json ---"; cat "$WS" 2>/dev/null || echo "(absent)"
  exit 1
fi
