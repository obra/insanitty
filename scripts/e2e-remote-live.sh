#!/usr/bin/env bash
# E2E (LIVE): a tmux-backed REMOTE (QUIC) workspace — real multi-pane render AND real input echo,
# end to end. We stand up an ISOLATED tmux server (its own TMUX_TMPDIR socket, so tmux control mode
# sees none of the user's other sessions) with a 2-pane session "main", launch insanitty with
# INSANITTY_REMOTE_TMUX=main so the helper attaches to it (tmux-backed source: real SendKeys), then:
#   1. assert the GUI rendered a 2-pane remote workspace live, and
#   2. type `echo RMT-$((6*7))` into the active pane and assert the remote shell's output RMT-42
#      comes back in a fresh keyframe (the arithmetic only evaluates if the REMOTE shell ran it).
# Safety: the isolated server is torn down ONLY via its explicit -S socket; the user's default tmux
# server is never touched.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-/tmp/claude-1000/-home-jesse-git-insanitty/d4fe9727-abcd-4a64-bfab-456b14fdb334/scratchpad/ghostty-src}"
SHOT="${OUT:-docs/images}/e2e-remote-live.png"; LOG=/tmp/app-rlive.log
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }

UID_N=$(id -u)
export TMUX_TMPDIR=/tmp/ins-tmux-live-$$; mkdir -p "$TMUX_TMPDIR/tmux-$UID_N"; chmod 700 "$TMUX_TMPDIR" "$TMUX_TMPDIR/tmux-$UID_N"
SOCK="$TMUX_TMPDIR/tmux-$UID_N/default"   # exactly the socket the helper derives from TMUX_TMPDIR
SESS=main
export INSANITTY_REMOTE_TMUX="$SESS"
export LD_LIBRARY_PATH="$GS/zig-out/lib" FANTASTTY_REMOTE_ADVERTISE_HOST=127.0.0.1 XDG_RUNTIME_DIR=/tmp/ins-rlive-rt
mkdir -p /tmp/inscfg/ghostty "$XDG_RUNTIME_DIR" "${OUT:-docs/images}"; chmod 700 "$XDG_RUNTIME_DIR"
echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-rlive-state; rm -f "$XDG_STATE_HOME/insanitty/layout.json"

cleanup() {
  kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null
  "${HELPER:-/tmp/fantastty-helper}" shutdown >/dev/null 2>&1
  tmux -S "$SOCK" -f /dev/null kill-server 2>/dev/null   # isolated server only, by explicit socket
}
trap cleanup EXIT

# Isolated, clean tmux server with a 2-pane session.
tmux -S "$SOCK" -f /dev/null new-session -d -s "$SESS" -x 100 -y 28
tmux -S "$SOCK" -f /dev/null split-window -h -t "$SESS"
tmux -S "$SOCK" -f /dev/null send-keys -t "$SESS".0 "clear; echo LEFT-LIVE-PANE" Enter
tmux -S "$SOCK" -f /dev/null send-keys -t "$SESS".1 "clear; echo RIGHT-LIVE-PANE" Enter
sleep 1
echo "isolated server panes: $(tmux -S "$SOCK" -f /dev/null list-panes -t "$SESS" -F '#{pane_id}' | tr '\n' ' ')"

Xvfb :124 -screen 0 1100x720x24 >/tmp/xvfb-rlive.log 2>&1 & XVFB=$!; sleep 2
DISPLAY=:124 matchbox-window-manager >/tmp/wm-rlive.log 2>&1 & WM=$!; sleep 1
DISPLAY=:124 XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" \
  dbus-run-session -- ./build/insanitty >"$LOG" 2>&1 & APP=$!
sleep 5
DISPLAY=:124 xdotool mousemove 110 590 click 1   # select the remote (QUIC) workspace
sleep 7
PANES=$(grep -oE 'rendered [0-9]+-pane remote workspace' "$LOG" | grep -oE '[0-9]+' | sort -n | tail -1)
[ "${PANES:-0}" -ge 2 ] || { echo "REMOTE-LIVE E2E FAIL: expected a live 2-pane remote workspace, got ${PANES:-0}"; tail -4 "$LOG"; exit 1; }
echo "live multi-pane OK: rendered $PANES panes"

# Type a command whose OUTPUT differs from its source text into the (active) remote pane.
DISPLAY=:124 xdotool mousemove 820 350 click 1; sleep 1
DISPLAY=:124 xdotool type --delay 40 'echo RMT-$((6*7))'
DISPLAY=:124 xdotool key Return
sleep 8
DISPLAY=:124 import -window root "$SHOT" 2>/dev/null
if grep -q 'remote pane .* content:.*RMT-42' "$LOG"; then
  echo "REMOTE-LIVE E2E PASS: live $PANES-pane workspace + keystrokes round-tripped to the remote shell (RMT-42 echoed) ($SHOT)"
else
  echo "REMOTE-LIVE E2E FAIL: remote shell did not echo RMT-42"
  grep 'remote pane .* content:' "$LOG" | tail -3
  exit 1
fi
