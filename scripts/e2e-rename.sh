#!/usr/bin/env bash
# E2E: renaming a workspace persists. Launches insanitty with INSANITTY_RENAME=0=<name> (the test
# hook the Rename… dialog drives) and asserts the new name lands in layout.json for workspace 0, so
# it survives a restart. The dialog UI itself (right-click → Rename…) is built from the same
# renameWorkspace() path.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
SHOT="${OUT:-docs/images}/e2e-rename.png"
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
DISP=":146"
NEW="Renamed Workspace"
mkdir -p /tmp/inscfg/ghostty "${OUT:-docs/images}"; echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-rename-state; mkdir -p "$XDG_STATE_HOME/insanitty"
LAYOUT="$XDG_STATE_HOME/insanitty/layout.json"; rm -f "$LAYOUT"
export INSANITTY_RENAME="0=$NEW"
for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done; }
trap cleanup EXIT

Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-rename.log 2>&1 & XVFB=$!; sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-rename.log 2>&1 & WM=$!; sleep 1
DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" LD_LIBRARY_PATH="$GS/zig-out/lib" \
  dbus-run-session -- ./build/insanitty >/tmp/app-rename.log 2>&1 & APP=$!
sleep 6
DISPLAY="$DISP" import -window root "$SHOT" 2>/dev/null

if grep -q "\"name\" : \"$NEW\"" "$LAYOUT" 2>/dev/null; then
  echo "RENAME E2E PASS: workspace 0 renamed to \"$NEW\" and persisted to layout.json ($SHOT)"
else
  echo "RENAME E2E FAIL: layout.json missing the new name"; cat "$LAYOUT" 2>/dev/null || echo "(no layout.json)"; exit 1
fi
