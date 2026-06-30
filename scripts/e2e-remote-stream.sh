#!/usr/bin/env bash
# E2E (LIVE): external output on a tmux-backed REMOTE (QUIC) workspace streams to the app as paneDelta
# messages and renders autonomously — i.e. output the app never typed shows up on screen, folded onto
# the pane keyframe by the delta-apply path rather than waiting for a full keyframe re-poll. (The
# helper sends each delta as a QUIC datagram when it fits the datagram size limit and over the
# reliable stream otherwise; real-sized grids exceed the limit, so deltas arrive on the stream. The
# app applies both.) We stand up an ISOLATED tmux server (its own TMUX_TMPDIR socket), launch insanitty
# with INSANITTY_REMOTE_TMUX=main so the helper attaches to it, render the remote workspace, then —
# WITHOUT touching the GUI — inject output straight into the tmux pane from outside (tmux send-keys to
# the isolated socket). We then assert both that the app applied streamed deltas ("applied remote
# delta/datagram") and that the external marker (EXT-STREAM-42, whose value only exists if the REMOTE
# shell evaluated it) reached the screen.
# Safety: the isolated server is torn down ONLY via its explicit -S socket; the user's default tmux
# server is never touched.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
SHOT="${OUT:-docs/images}/e2e-remote-stream.png"; LOG=/tmp/app-rstream.log
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }

UID_N=$(id -u)
export TMUX_TMPDIR=/tmp/ins-tmux-stream-$$; mkdir -p "$TMUX_TMPDIR/tmux-$UID_N"; chmod 700 "$TMUX_TMPDIR" "$TMUX_TMPDIR/tmux-$UID_N"
SOCK="$TMUX_TMPDIR/tmux-$UID_N/default"   # exactly the socket the helper derives from TMUX_TMPDIR
SESS=main
export INSANITTY_REMOTE_TMUX="$SESS"
export INSANITTY_SELECT_REMOTE=1   # open straight onto the remote workspace (no fragile pixel click)
export LD_LIBRARY_PATH="$GS/zig-out/lib" FANTASTTY_REMOTE_ADVERTISE_HOST=127.0.0.1 XDG_RUNTIME_DIR=/tmp/ins-rstream-rt-$$
mkdir -p /tmp/inscfg/ghostty "$XDG_RUNTIME_DIR" "${OUT:-docs/images}"; chmod 700 "$XDG_RUNTIME_DIR"
echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-rstream-state; rm -f "$XDG_STATE_HOME/insanitty/layout.json"

cleanup() {
  kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null
  "${HELPER:-/tmp/fantastty-helper}" shutdown >/dev/null 2>&1
  tmux -S "$SOCK" -f /dev/null kill-server 2>/dev/null   # isolated server only, by explicit socket
}
trap cleanup EXIT

# Isolated, clean tmux server with a single-pane session.
tmux -S "$SOCK" -f /dev/null new-session -d -s "$SESS" -x 100 -y 28
tmux -S "$SOCK" -f /dev/null send-keys -t "$SESS".0 "clear; echo READY-STREAM-PANE" Enter
sleep 1

Xvfb :125 -screen 0 1100x720x24 >/tmp/xvfb-rstream.log 2>&1 & XVFB=$!; sleep 2
DISPLAY=:125 matchbox-window-manager >/tmp/wm-rstream.log 2>&1 & WM=$!; sleep 1
DISPLAY=:125 XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" \
  dbus-run-session -- ./build/insanitty >"$LOG" 2>&1 & APP=$!
sleep 5
# The remote workspace is selected on startup via INSANITTY_SELECT_REMOTE.
# A fresh helper (launch, not resume) + QUIC connect + first keyframe takes a while; poll for it.
for _ in $(seq 1 25); do
  grep -q 'rendered [0-9]*-pane remote workspace' "$LOG" && break; sleep 1
done
PANES=$(grep -oE 'rendered [0-9]+-pane remote workspace' "$LOG" | grep -oE '[0-9]+' | sort -n | tail -1)
[ "${PANES:-0}" -ge 1 ] || { echo "REMOTE-STREAM E2E FAIL: remote workspace never rendered"; tail -4 "$LOG"; exit 1; }
echo "remote workspace up: rendered $PANES pane(s)"

# Let the initial keyframe's delta storm (the first render of a pane bursts large deltas) drain before
# injecting, so the marker isn't buried behind the backlog.
sleep 12
# Inject output from OUTSIDE the app — straight into the tmux pane via its socket, exactly once. The
# app never sees these keystrokes; the change reaches the screen only because the helper streams the
# resulting paneDelta to us. EXT-STREAM-42 only exists if the REMOTE shell evaluated the arithmetic.
# (We avoid polling the pane with capture-pane while streaming — interrogating the session perturbs
# the helper's grid stream — and instead give the live delta time to arrive, then check the render.)
tmux -S "$SOCK" -f /dev/null send-keys -t "$SESS".0 'echo EXT-STREAM-$((6*7))' Enter
for _ in $(seq 1 25); do
  grep -q 'remote pane .* content:.*EXT-STREAM-42' "$LOG" && break; sleep 1
done
# Ground-truth check (single, after the fact): confirm the remote shell really produced the marker,
# so a render miss is a real streaming failure and not just a clipped keystroke.
tmux -S "$SOCK" -f /dev/null capture-pane -t "$SESS".0 -p | grep -q 'EXT-STREAM-42' \
  || { echo "REMOTE-STREAM E2E FAIL: marker never landed in the remote pane (test setup)"; exit 1; }
DISPLAY=:125 import -window root "$SHOT" 2>/dev/null

DELTAS=$(grep -cE 'applied remote (delta|datagram)' "$LOG")
if [ "${DELTAS:-0}" -ge 1 ] && grep -q 'remote pane .* content:.*EXT-STREAM-42' "$LOG"; then
  echo "REMOTE-STREAM E2E PASS: external output streamed as paneDeltas ($DELTAS applied) and rendered (EXT-STREAM-42) ($SHOT)"
else
  echo "REMOTE-STREAM E2E FAIL: deltas applied=$DELTAS, external marker on screen=$(grep -q 'remote pane .* content:.*EXT-STREAM-42' "$LOG" && echo yes || echo no)"
  grep -E 'applied remote (delta|datagram)|remote pane .* content:' "$LOG" | tail -5
  exit 1
fi
