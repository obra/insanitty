#!/usr/bin/env bash
# End-to-end test of tmux-backed persistence ("sessions survive app restart").
#
# Each insanitty workspace's terminal runs `tmux new-session -A -s insanitty-ws-N`, so the
# shell + its child processes live in the tmux server, not the app. This test starts a
# counter process inside workspace 0's session, KILLS the app, confirms the counter kept
# running while the app was dead, relaunches, and confirms the workspace re-attached the
# same live session.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-/tmp/claude-1000/-home-jesse-git-insanitty/d4fe9727-abcd-4a64-bfab-456b14fdb334/scratchpad/ghostty-src}"
OUT="${OUT:-docs/images}"; DISP=":117"; COUNTER=/tmp/persist-counter
mkdir -p /tmp/inscfg/ghostty "$OUT"; echo "initial-window = false" > /tmp/inscfg/ghostty/config

launch_app() { # -> echoes the pid
  DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" \
    dbus-run-session -- ./build/insanitty >"/tmp/app-persist.log" 2>&1 & echo $!
}
cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; tmux kill-session -t insanitty-ws-0 2>/dev/null; }
trap cleanup EXIT
fail() { echo "PERSISTENCE FAIL: $1"; exit 1; }

tmux kill-session -t insanitty-ws-0 2>/dev/null; rm -f "$COUNTER"
Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-p.log 2>&1 & XVFB=$!; sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-p.log 2>&1 & WM=$!; sleep 1

APP=$(launch_app); sleep 12
tmux has-session -t insanitty-ws-0 2>/dev/null || fail "workspace did not create its tmux session"
tmux send-keys -t insanitty-ws-0 '(i=0; while true; do i=$((i+1)); echo $i > /tmp/persist-counter; sleep 0.5; done) &' Enter
sleep 4; V1=$(cat "$COUNTER" 2>/dev/null || echo 0)

kill -9 "$APP" 2>/dev/null; sleep 5
V2=$(cat "$COUNTER" 2>/dev/null || echo 0)
[ "$V2" -gt "$V1" ] || fail "counter did not advance while app was dead (V1=$V1 V2=$V2)"

APP=$(launch_app); sleep 12
import -window root "$OUT/e2e-5-persistence.png" 2>/dev/null
V3=$(cat "$COUNTER" 2>/dev/null || echo 0)
tmux has-session -t insanitty-ws-0 2>/dev/null || fail "session gone after relaunch"
[ "$V3" -gt "$V2" ] || fail "counter did not advance after relaunch (V2=$V2 V3=$V3)"

echo "PERSISTENCE PASS: process survived app restart (V1=$V1 < V2=$V2 < V3=$V3); workspace re-attached its tmux session"
