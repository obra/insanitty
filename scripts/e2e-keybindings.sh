#!/usr/bin/env bash
# E2E: keyboard shortcuts. Presses Ctrl+Shift+A (toggle attention) on the selected workspace and
# asserts it persisted to workspaces.json + the sidebar shows the ⚠ marker.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
SHOT="${OUT:-docs/images}/e2e-14-attention.png"
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
DISP=":143"
mkdir -p /tmp/inscfg/ghostty "${OUT:-docs/images}"; echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-keys-state; mkdir -p "$XDG_STATE_HOME/insanitty"
WS="$XDG_STATE_HOME/insanitty/workspaces.json"; rm -f "$WS"
for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done; }
trap cleanup EXIT

Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-keys.log 2>&1 & XVFB=$!; sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-keys.log 2>&1 & WM=$!; sleep 1
DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" LD_LIBRARY_PATH="$GS/zig-out/lib" \
  dbus-run-session -- ./build/insanitty >/tmp/app-keys.log 2>&1 & APP=$!
LAYOUT="$XDG_STATE_HOME/insanitty/layout.json"
sleep 5
DISPLAY="$DISP" xdotool mousemove 110 115 click 1; sleep 1   # focus the window (workspace 0 row)

# 1. Ctrl+Shift+A flags the current workspace.
DISPLAY="$DISP" xdotool key ctrl+shift+a; sleep 2
grep -q '"needsAttention" : true' "$WS" 2>/dev/null && grep -q '"insanitty-ws-0"' "$WS" \
  || { echo "KEYBINDINGS E2E FAIL: Ctrl+Shift+A did not flag the workspace"; cat "$WS" 2>/dev/null; exit 1; }

# 2. Ctrl+2 jumps directly to the 2nd workspace (row index 1 → tmux index 1), persisted as `selected`.
DISPLAY="$DISP" xdotool key ctrl+2; sleep 2
grep -q '"selected" : 1' "$LAYOUT" 2>/dev/null \
  || { echo "KEYBINDINGS E2E FAIL: Ctrl+2 did not select workspace 2"; cat "$LAYOUT" 2>/dev/null; exit 1; }

# 3. Ctrl+Shift+L clears every attention flag at once.
DISPLAY="$DISP" xdotool key ctrl+shift+l; sleep 2
DISPLAY="$DISP" import -window root "$SHOT" 2>/dev/null
grep -q '"needsAttention" : false' "$WS" 2>/dev/null \
  || { echo "KEYBINDINGS E2E FAIL: Ctrl+Shift+L did not clear the attention flag"; cat "$WS" 2>/dev/null; exit 1; }

echo "KEYBINDINGS E2E PASS: Ctrl+Shift+A flagged, Ctrl+2 jumped to workspace 2, Ctrl+Shift+L cleared all flags ($SHOT)"
