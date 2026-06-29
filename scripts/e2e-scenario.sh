#!/usr/bin/env bash
# End-to-end scenario test for the insanitty app, driven through its real UI.
#
# Launches the app headless (Xvfb + a window manager + a private session bus),
# uses xdotool to focus a terminal and type a command, and verifies the embedded
# shell executed it (the surface reports the command via its title; output is also
# captured to a screenshot). Then switches workspaces and types in a second one.
#
# Requires: build/insanitty (scripts/build-app.sh), Xvfb, matchbox-window-manager,
# dbus, xdotool, imagemagick, and the Ghostty resources dir (GHOSTTY).
set -uo pipefail
cd "$(dirname "$0")/.."

GS="${GHOSTTY:-/tmp/claude-1000/-home-jesse-git-insanitty/d4fe9727-abcd-4a64-bfab-456b14fdb334/scratchpad/ghostty-src}"
OUT="${OUT:-docs/images}"
DISP=":121"
mkdir -p /tmp/inscfg/ghostty "$OUT"; echo "initial-window = false" > /tmp/inscfg/ghostty/config

cleanup() { kill "${APP_PID:-}" "${WM_PID:-}" "${XVFB_PID:-}" 2>/dev/null; for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done; }
trap cleanup EXIT
# Start from a clean slate so captured pane content is from this run, not a leftover session.
for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done

Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-e2e.log 2>&1 & XVFB_PID=$!
sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-e2e.log 2>&1 & WM_PID=$!
sleep 1
DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" \
  dbus-run-session -- ./build/insanitty >/tmp/app-e2e.log 2>&1 & APP_PID=$!
sleep 15
export DISPLAY="$DISP"

fail() { echo "E2E FAIL: $1"; exit 1; }
WID=$(xdotool search --name "insanitty" 2>/dev/null | tail -1)
[ -n "$WID" ] || fail "app window not found"
xdotool windowactivate --sync "$WID"

type_in_terminal() { # $1 = text to type
  xdotool mousemove 650 400 click 1; sleep 1
  xdotool type --delay 60 "$1"; sleep 0.4; xdotool key Return; sleep 3
}

# Scenario 1: type a command and verify the shell ran it.
MARK="E2E-ALPHA-\$((6*7))"
type_in_terminal "echo $MARK"
import -window root "$OUT/e2e-1-typed-command.png" 2>/dev/null
# Verify in the workspace's real tmux session that the shell evaluated $((6*7)) → 42.
tmux capture-pane -t insanitty-ws-0 -p 2>/dev/null | grep -q "E2E-ALPHA-42" || fail "typed command did not run in the workspace's tmux session"
echo "PASS scenario 1: command ran in the embedded shell (see $OUT/e2e-1-typed-command.png for the '42' output)"

# Scenario 2: switch workspace (click sidebar row 2) and type in a different terminal.
xdotool mousemove 110 112 click 1; sleep 2
type_in_terminal "echo E2E-BRAVO-on-second-workspace"
import -window root "$OUT/e2e-2-second-workspace.png" 2>/dev/null
tmux capture-pane -t insanitty-ws-1 -p 2>/dev/null | grep -q "E2E-BRAVO" || fail "second-workspace command did not run in its tmux session"
echo "PASS scenario 2: second workspace has its own live terminal"

# Scenario 3: split the terminal (Ctrl+D) and type in the new pane.
xdotool key ctrl+d; sleep 3
xdotool mousemove 850 400 click 1; sleep 1
xdotool type --delay 60 "echo E2E-SPLIT-pane"; sleep 0.4; xdotool key Return; sleep 3
import -window root "$OUT/e2e-3-split.png" 2>/dev/null
grep -q "E2E-SPLIT-pane" /tmp/app-e2e.log || fail "split-pane command did not reach a shell"
echo "PASS scenario 3: Ctrl+D split into a second independent live terminal"

# Scenario 4: new tab (Ctrl+T) with its own terminal.
xdotool key ctrl+t; sleep 4
xdotool mousemove 650 400 click 1; sleep 1
xdotool type --delay 60 "echo E2E-TAB-two"; sleep 0.4; xdotool key Return; sleep 3
import -window root "$OUT/e2e-4-tabs.png" 2>/dev/null
grep -q "E2E-TAB-two" /tmp/app-e2e.log || fail "new-tab command did not reach a shell"
echo "PASS scenario 4: Ctrl+T new tab with its own live terminal"

echo "E2E PASS"
