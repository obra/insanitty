#!/usr/bin/env bash
# E2E (LIVE): a REMOTE (QUIC) pane entering/leaving the alternate screen (what full-screen apps like
# vim/less do) is mirrored into the inert ghostty surface, so scrollback behaves. We drive the remote
# tmux pane into the alternate screen (DECSET 1049) and back, and assert insanitty switched the
# surface's screen buffer to match (PaneKeyframe.activeScreen). Safety: isolated tmux server only.
set -uo pipefail
cd "$(dirname "$0")/.."
export INSANITTY_VERBOSE=1   # the assertions below grep insanitty's diagnostic stderr traces
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
SHOT="${OUT:-docs/images}/e2e-remote-altscreen.png"; LOG=/tmp/app-ralt.log
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }

UID_N=$(id -u)
export TMUX_TMPDIR=/tmp/ins-tmux-ralt-$$; mkdir -p "$TMUX_TMPDIR/tmux-$UID_N"; chmod 700 "$TMUX_TMPDIR" "$TMUX_TMPDIR/tmux-$UID_N"
SOCK="$TMUX_TMPDIR/tmux-$UID_N/default"; SESS=main
export INSANITTY_REMOTE_TMUX="$SESS" INSANITTY_SELECT_REMOTE=1
export LD_LIBRARY_PATH="$GS/zig-out/lib" FANTASTTY_REMOTE_ADVERTISE_HOST=127.0.0.1 XDG_RUNTIME_DIR=/tmp/ins-ralt-rt-$$
mkdir -p /tmp/inscfg/ghostty "$XDG_RUNTIME_DIR" "${OUT:-docs/images}"; chmod 700 "$XDG_RUNTIME_DIR"
echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-ralt-state; rm -f "$XDG_STATE_HOME/insanitty/layout.json"

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; tmux -S "$SOCK" -f /dev/null kill-server 2>/dev/null; }
trap cleanup EXIT

tmux -S "$SOCK" -f /dev/null new-session -d -s "$SESS" -x 100 -y 28
sleep 1
Xvfb :150 -screen 0 1100x720x24 >/tmp/xvfb-ralt.log 2>&1 & XVFB=$!; sleep 2
DISPLAY=:150 matchbox-window-manager >/tmp/wm-ralt.log 2>&1 & WM=$!; sleep 1
DISPLAY=:150 XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" \
  dbus-run-session -- ./build/insanitty >"$LOG" 2>&1 & APP=$!
sleep 5
for _ in $(seq 1 25); do grep -q 'native QUIC' "$LOG" && break; sleep 1; done
grep -q 'native QUIC' "$LOG" || { echo "REMOTE-ALTSCREEN E2E FAIL: remote workspace never rendered"; tail -4 "$LOG"; exit 1; }
sleep 6   # let the initial delta storm settle

# Enter the alternate screen, then leave it (what vim/less do on open/quit).
tmux -S "$SOCK" -f /dev/null send-keys -t "$SESS".0 "printf '\\033[?1049h'; sleep 3; printf '\\033[?1049l'" Enter
for _ in $(seq 1 15); do grep -q 'screen . alternate' "$LOG" && break; sleep 1; done
for _ in $(seq 1 15); do [ "$(grep -oE 'screen . (primary|alternate)' "$LOG" | tail -1)" = "$(printf 'screen \342\206\222 primary')" ] && break; sleep 1; done
DISPLAY=:150 import -window root "$SHOT" 2>/dev/null

ENTERED=$(grep -c 'screen . alternate' "$LOG")
LAST=$(grep -oE 'screen . (primary|alternate)' "$LOG" | tail -1 | grep -oE '(primary|alternate)')
if [ "${ENTERED:-0}" -ge 1 ] && [ "$LAST" = primary ]; then
  echo "REMOTE-ALTSCREEN E2E PASS: remote pane entered the alternate screen and returned to primary ($SHOT)"
else
  echo "REMOTE-ALTSCREEN E2E FAIL: entered-alt=$ENTERED last-screen=$LAST"
  grep 'screen .' "$LOG" | tail -6; exit 1
fi
