#!/usr/bin/env bash
# E2E: a REMOTE (QUIC) workspace maps MULTIPLE panes onto a GtkPaned split. This drives the
# multi-pane RENDER path (snapshot window-layout → GtkPaned tree → one surface per pane, each
# painted from its paneKeyframe) using a fixture of remote messages, since the live multi-pane
# path needs the helper's --tmux-session (its daemon doesn't become ready in this environment).
# The single-pane QUIC fetch itself is covered end-to-end by e2e-remote-gui.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
export INSANITTY_VERBOSE=1   # the assertions below grep insanitty's diagnostic stderr traces
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
DISP=":136"; SHOT="${OUT:-docs/images}/remote-multipane.png"
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
export INSANITTY_REMOTE_FIXTURE="$PWD/scripts/fixtures/remote-2pane.jsonl"
export XDG_STATE_HOME=/tmp/ins-rmp-state; rm -f "$XDG_STATE_HOME/insanitty/layout.json"
mkdir -p /tmp/inscfg/ghostty "${OUT:-docs/images}"; echo "initial-window = false" > /tmp/inscfg/ghostty/config

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; }
trap cleanup EXIT

Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-rmp.log 2>&1 & XVFB=$!; sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-rmp.log 2>&1 & WM=$!; sleep 1
DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" LD_LIBRARY_PATH="$GS/zig-out/lib" \
  dbus-run-session -- ./build/insanitty >/tmp/app-rmp.log 2>&1 & APP=$!
sleep 5
DISPLAY="$DISP" xdotool mousemove 110 590 click 1   # select the remote (QUIC) workspace (4th row)
sleep 4
DISPLAY="$DISP" import -window root "$SHOT" 2>/dev/null
PANES=$(grep -oE 'rendered [0-9]+-pane remote workspace' /tmp/app-rmp.log | grep -oE '[0-9]+' | sort -n | tail -1)
[ "${PANES:-0}" -ge 2 ] \
  || { echo "REMOTE-MULTIPANE E2E FAIL: expected a >=2-pane remote workspace, got ${PANES:-0}"; tail -3 /tmp/app-rmp.log; exit 1; }
echo "REMOTE-MULTIPANE E2E PASS: insanitty mapped a $PANES-pane remote workspace onto a GtkPaned split ($SHOT)"
