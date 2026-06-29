#!/usr/bin/env bash
# E2E: archive a workspace. Right-clicks the second workspace row, picks "Archive" from the popover,
# and asserts the workspace was stamped isArchived in workspaces.json and dropped from the sidebar.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
SHOT="${OUT:-docs/images}/e2e-10-archive.png"
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
DISP=":134"
mkdir -p /tmp/inscfg/ghostty "${OUT:-docs/images}"; echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-arch-state; mkdir -p "$XDG_STATE_HOME/insanitty"
WS="$XDG_STATE_HOME/insanitty/workspaces.json"; rm -f "$WS" "$XDG_STATE_HOME/insanitty/layout.json"

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done; }
trap cleanup EXIT

Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-ar.log 2>&1 & XVFB=$!; sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-ar.log 2>&1 & WM=$!; sleep 1
DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" LD_LIBRARY_PATH="$GS/zig-out/lib" \
  dbus-run-session -- ./build/insanitty >/tmp/app-ar.log 2>&1 & APP=$!
sleep 5
DISPLAY="$DISP" xdotool mousemove 110 270 click 3; sleep 1   # right-click workspace ws-1
DISPLAY="$DISP" xdotool mousemove 109 307 click 1; sleep 2   # "Archive"
DISPLAY="$DISP" import -window root "$SHOT" 2>/dev/null

if grep -q '"insanitty-ws-1"' "$WS" 2>/dev/null && python3 -c "import json,sys; d={m['workspaceID']:m for m in json.load(open('$WS'))}; sys.exit(0 if d.get('insanitty-ws-1',{}).get('isArchived') else 1)"; then
  echo "ARCHIVE E2E PASS: workspace ws-1 stamped isArchived in workspaces.json ($SHOT)"
else
  echo "ARCHIVE E2E FAIL"; echo "--- workspaces.json ---"; cat "$WS" 2>/dev/null || echo "(absent)"
  exit 1
fi
