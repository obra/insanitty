#!/usr/bin/env bash
# E2E: insanitty maps a tmux control-mode session's WINDOWS onto AdwTabView TABS. We attach to a
# session with two windows; insanitty builds a tab per window (each with its own pane tree) and
# renders each window's content by injecting %output into its surfaces.
#
# Headless: Xvfb + matchbox + dbus; the tmux -CC workspace is enabled via INSANITTY_TMUX_CC.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-/tmp/claude-1000/-home-jesse-git-insanitty/d4fe9727-abcd-4a64-bfab-456b14fdb334/scratchpad/ghostty-src}"
DISP=":135"; SHOT="${OUT:-docs/images}/tmux-control-windows.png"
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
export XDG_STATE_HOME=/tmp/ins-cc-state; rm -f "$XDG_STATE_HOME/insanitty/layout.json"
mkdir -p /tmp/inscfg/ghostty "${OUT:-docs/images}"; echo "initial-window = false" > /tmp/inscfg/ghostty/config

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; tmux kill-session -t insanitty-cc 2>/dev/null; }
trap cleanup EXIT

# A control session with two windows.
tmux kill-session -t insanitty-cc 2>/dev/null
tmux new-session -d -s insanitty-cc -x 100 -y 38
tmux new-window -t insanitty-cc
sleep 1

Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-ccw.log 2>&1 & XVFB=$!; sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-ccw.log 2>&1 & WM=$!; sleep 1
DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg XDG_STATE_HOME="$XDG_STATE_HOME" INSANITTY_TMUX_CC=1 \
  GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" LD_LIBRARY_PATH="$GS/zig-out/lib" \
  dbus-run-session -- ./build/insanitty >/tmp/app-ccw.log 2>&1 & APP=$!
sleep 7
DISPLAY="$DISP" import -window root "$SHOT" 2>/dev/null
WINS=$(grep -o 'window @[0-9]*' /tmp/app-ccw.log | sort -u | wc -l)
[ "$WINS" -ge 2 ] \
  || { echo "TMUX-CC-WINDOWS E2E FAIL: expected >= 2 window tabs, built $WINS"; exit 1; }
grep -q 'tmux-cc: rendered' /tmp/app-ccw.log \
  || { echo "TMUX-CC-WINDOWS E2E FAIL: no window content rendered"; exit 1; }
echo "TMUX-CC-WINDOWS E2E PASS: insanitty mapped $WINS tmux windows onto tabs and rendered them ($SHOT)"
