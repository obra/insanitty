#!/usr/bin/env bash
# E2E: per-workspace session notes. Opens the Notes panel for the selected workspace, types a note,
# adds it, and asserts the note was persisted to workspaces.json under that workspace's id.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
SHOT="${OUT:-docs/images}/e2e-9-notes.png"
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
DISP=":132"; MARK="REMEMBER-THE-MILK"
mkdir -p /tmp/inscfg/ghostty "${OUT:-docs/images}"; echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-notes-state; mkdir -p "$XDG_STATE_HOME/insanitty"
WS="$XDG_STATE_HOME/insanitty/workspaces.json"; rm -f "$WS"

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done; }
trap cleanup EXIT

Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-n.log 2>&1 & XVFB=$!; sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-n.log 2>&1 & WM=$!; sleep 1
DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" LD_LIBRARY_PATH="$GS/zig-out/lib" \
  dbus-run-session -- ./build/insanitty >/tmp/app-n.log 2>&1 & APP=$!
sleep 5
DISPLAY="$DISP" xdotool mousemove 62 27 click 1; sleep 2          # open Notes
DISPLAY="$DISP" xdotool mousemove 185 489 click 1; sleep 1        # focus the entry
DISPLAY="$DISP" xdotool type --delay 30 "$MARK"
DISPLAY="$DISP" xdotool key Return; sleep 2                       # entry activate → Add
DISPLAY="$DISP" import -window root "$SHOT" 2>/dev/null

if grep -q "$MARK" "$WS" 2>/dev/null && grep -q '"insanitty-ws-0"' "$WS"; then
  echo "NOTES E2E PASS: note persisted to workspaces.json for the selected workspace ($SHOT)"
else
  echo "NOTES E2E FAIL: workspaces.json missing the note"; echo "--- workspaces.json ---"; cat "$WS" 2>/dev/null || echo "(absent)"
  exit 1
fi
