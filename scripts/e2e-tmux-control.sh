#!/usr/bin/env bash
# E2E: insanitty renders a real `tmux -CC` control-mode session. The app owns the control
# client (spawned in a PTY), parses the control protocol, and paints the pane by injecting
# %output into a silent Ghostty surface — no shell of its own in that surface. We drive the
# tmux session from outside and confirm the app received + rendered the output.
#
# Headless: Xvfb + matchbox + dbus. The tmux -CC workspace is enabled via INSANITTY_TMUX_CC.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-/tmp/claude-1000/-home-jesse-git-insanitty/d4fe9727-abcd-4a64-bfab-456b14fdb334/scratchpad/ghostty-src}"
DISP=":130"; SHOT="${OUT:-docs/images}/tmux-control.png"
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
export XDG_STATE_HOME=/tmp/ins-cc-state; rm -f "$XDG_STATE_HOME/insanitty/layout.json"
mkdir -p /tmp/inscfg/ghostty "${OUT:-docs/images}"; echo "initial-window = false" > /tmp/inscfg/ghostty/config
tmux kill-session -t insanitty-cc 2>/dev/null

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; tmux kill-session -t insanitty-cc 2>/dev/null; }
trap cleanup EXIT

Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-cc.log 2>&1 & XVFB=$!; sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-cc.log 2>&1 & WM=$!; sleep 1
DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg XDG_STATE_HOME="$XDG_STATE_HOME" INSANITTY_TMUX_CC=1 \
  GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" LD_LIBRARY_PATH="$GS/zig-out/lib" \
  dbus-run-session -- ./build/insanitty >/tmp/app-cc.log 2>&1 & APP=$!
sleep 7
# Type into the silent surface: keystrokes route to tmux (send-keys), the shell runs the
# command, and tmux's %output is injected back — exercising the full control-mode loop.
DISPLAY="$DISP" xdotool mousemove 650 300 click 1; sleep 1
DISPLAY="$DISP" xdotool type --delay 70 'echo TMUX-CC-INPUT-OK'; sleep 0.4
DISPLAY="$DISP" xdotool key Return; sleep 3
DISPLAY="$DISP" import -window root "$SHOT" 2>/dev/null
grep -q 'tmux-cc: attached' /tmp/app-cc.log || { echo "TMUX-CC E2E FAIL: control client did not attach"; exit 1; }
# Input reached tmux (and ran in the real session):
tmux capture-pane -t insanitty-cc -p 2>/dev/null | grep -q 'TMUX-CC-INPUT-OK' \
  || { echo "TMUX-CC E2E FAIL: typed input did not reach the tmux session"; exit 1; }
# Output came back over the control protocol and was injected:
grep -q 'tmux-cc: rendered' /tmp/app-cc.log \
  || { echo "TMUX-CC E2E FAIL: no %output rendered from the control session"; exit 1; }
echo "TMUX-CC E2E PASS: insanitty drove tmux -CC end to end — typed input → send-keys → shell → %output → inject_output ($SHOT)"
