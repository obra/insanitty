#!/usr/bin/env bash
# E2E: reorder workspaces. Launches insanitty and moves the 3rd workspace to the front via the test
# hook the sidebar drag drives (INSANITTY_MOVE_WS=from:to), then asserts the new order persisted to
# layout.json (workspaces are written in sidebar order). The drag gesture itself uses the same
# moveWorkspace() path.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
SHOT="${OUT:-docs/images}/e2e-reorder.png"
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
DISP=":152"
mkdir -p /tmp/inscfg/ghostty "${OUT:-docs/images}"; echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-reorder-state; mkdir -p "$XDG_STATE_HOME/insanitty"
LAYOUT="$XDG_STATE_HOME/insanitty/layout.json"; rm -f "$LAYOUT"
export INSANITTY_MOVE_WS="2:0"   # move the 3rd workspace (index 2) to the front
for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done; }
trap cleanup EXIT

Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-reorder.log 2>&1 & XVFB=$!; sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-reorder.log 2>&1 & WM=$!; sleep 1
DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" LD_LIBRARY_PATH="$GS/zig-out/lib" \
  dbus-run-session -- ./build/insanitty >/tmp/app-reorder.log 2>&1 & APP=$!
sleep 6
DISPLAY="$DISP" import -window root "$SHOT" 2>/dev/null

# After moving index 2 to the front, the sidebar order (and layout.json) is 2,0,1.
if python3 -c "
import json,sys
order=[w['index'] for w in json.load(open('$LAYOUT'))['workspaces']]
sys.exit(0 if order[:3]==[2,0,1] else 1)"; then
  echo "REORDER E2E PASS: workspace order persisted as 2,0,1 after the move ($SHOT)"
else
  echo "REORDER E2E FAIL: order = $(python3 -c "import json;print([w['index'] for w in json.load(open('$LAYOUT'))['workspaces']])" 2>/dev/null)"
  cat "$LAYOUT" 2>/dev/null; exit 1
fi
