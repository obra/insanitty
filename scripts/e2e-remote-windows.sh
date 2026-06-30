#!/usr/bin/env bash
# E2E (LIVE): a tmux-backed REMOTE (QUIC) workspace with MULTIPLE windows — each remote tmux window
# is rendered as its own tab, and Ctrl+T creates a new remote window (newWindow request) that shows
# up as another tab. We stand up an ISOLATED tmux server with a 2-window session, point insanitty at
# it (INSANITTY_REMOTE_TMUX), assert the GUI rendered 2 windows, then press Ctrl+T and assert a 3rd
# window appears. Safety: the isolated server is torn down ONLY via its explicit -S socket.
set -uo pipefail
cd "$(dirname "$0")/.."
export INSANITTY_VERBOSE=1   # the assertions below grep insanitty's diagnostic stderr traces
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
SHOT="${OUT:-docs/images}/e2e-remote-windows.png"; LOG=/tmp/app-rwin.log
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }

UID_N=$(id -u)
export TMUX_TMPDIR=/tmp/ins-tmux-rwin-$$; mkdir -p "$TMUX_TMPDIR/tmux-$UID_N"; chmod 700 "$TMUX_TMPDIR" "$TMUX_TMPDIR/tmux-$UID_N"
SOCK="$TMUX_TMPDIR/tmux-$UID_N/default"
SESS=main
export INSANITTY_REMOTE_TMUX="$SESS" INSANITTY_SELECT_REMOTE=1
export LD_LIBRARY_PATH="$GS/zig-out/lib" FANTASTTY_REMOTE_ADVERTISE_HOST=127.0.0.1 XDG_RUNTIME_DIR=/tmp/ins-rwin-rt-$$
mkdir -p /tmp/inscfg/ghostty "$XDG_RUNTIME_DIR" "${OUT:-docs/images}"; chmod 700 "$XDG_RUNTIME_DIR"
echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-rwin-state; rm -f "$XDG_STATE_HOME/insanitty/layout.json"

cleanup() {
  kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null
  tmux -S "$SOCK" -f /dev/null kill-server 2>/dev/null   # isolated server only, by explicit socket
}
trap cleanup EXIT

# Isolated, clean tmux server with a 2-window session.
tmux -S "$SOCK" -f /dev/null new-session -d -s "$SESS" -x 100 -y 28
tmux -S "$SOCK" -f /dev/null new-window -t "$SESS"
tmux -S "$SOCK" -f /dev/null send-keys -t "$SESS":0 "clear; echo WINDOW-ZERO" Enter
tmux -S "$SOCK" -f /dev/null send-keys -t "$SESS":1 "clear; echo WINDOW-ONE" Enter
sleep 1
echo "isolated server windows: $(tmux -S "$SOCK" -f /dev/null list-windows -t "$SESS" -F '#{window_id}' | tr '\n' ' ')"

Xvfb :148 -screen 0 1100x720x24 >/tmp/xvfb-rwin.log 2>&1 & XVFB=$!; sleep 2
DISPLAY=:148 matchbox-window-manager >/tmp/wm-rwin.log 2>&1 & WM=$!; sleep 1
DISPLAY=:148 XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" \
  dbus-run-session -- ./build/insanitty >"$LOG" 2>&1 & APP=$!
sleep 5
for _ in $(seq 1 25); do grep -q 'window(s)$' "$LOG" && break; sleep 1; done
WINS=$(grep -oE 'native QUIC\), [0-9]+ window' "$LOG" | grep -oE '[0-9]+' | sort -n | tail -1)
[ "${WINS:-0}" -ge 2 ] || { echo "REMOTE-WINDOWS E2E FAIL: expected ≥2 remote windows, got ${WINS:-0}"; tail -5 "$LOG"; exit 1; }
echo "multi-window OK: rendered $WINS windows"

# Ctrl+T → newWindow request → a 3rd remote tmux window appears as a tab.
DISPLAY=:148 xdotool mousemove 600 350 click 1; sleep 1   # focus a remote pane surface
DISPLAY=:148 xdotool key ctrl+t; sleep 8
DISPLAY=:148 import -window root "$SHOT" 2>/dev/null
SERVER_WINS=$(tmux -S "$SOCK" -f /dev/null list-windows -t "$SESS" | wc -l)
WINS2=$(grep -oE 'native QUIC\), [0-9]+ window' "$LOG" | grep -oE '[0-9]+' | sort -n | tail -1)
if [ "${SERVER_WINS:-0}" -ge 3 ] && [ "${WINS2:-0}" -ge 3 ]; then
  echo "REMOTE-WINDOWS E2E PASS: $WINS windows rendered as tabs, Ctrl+T created a 3rd remote window ($SHOT)"
else
  echo "REMOTE-WINDOWS E2E FAIL: after Ctrl+T server windows=$SERVER_WINS, app rendered windows=$WINS2"
  tail -6 "$LOG"; exit 1
fi
