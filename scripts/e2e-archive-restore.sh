#!/usr/bin/env bash
# E2E: restore an archived workspace. Pre-seeds workspaces.json with an archived workspace (the state
# `archiveWorkspace` leaves behind), launches insanitty with INSANITTY_RESTORE (the test hook the
# Archived picker drives), and asserts the workspace comes back: re-added to layout.json with its
# saved name, and its metadata flag cleared (isArchived=false) in workspaces.json.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
SHOT="${OUT:-docs/images}/e2e-archive-restore.png"
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
DISP=":147"
mkdir -p /tmp/inscfg/ghostty "${OUT:-docs/images}"; echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-restore-state; mkdir -p "$XDG_STATE_HOME/insanitty"
WS="$XDG_STATE_HOME/insanitty/workspaces.json"
LAYOUT="$XDG_STATE_HOME/insanitty/layout.json"; rm -f "$LAYOUT"
# An archived workspace, as archiveWorkspace would have left it.
cat > "$WS" <<'JSON'
[
  { "workspaceID":"insanitty-ws-5", "name":"Archived One", "notes":[], "needsAttention":false,
    "tags":[], "isArchived":true, "archivedAt":"2026-01-01T00:00:00Z", "isTrashed":false,
    "createdAt":"2026-01-01T00:00:00Z", "modifiedAt":"2026-01-01T00:00:00Z", "totalActiveSeconds":0 }
]
JSON
export INSANITTY_RESTORE="insanitty-ws-5"
for s in 0 1 2 5; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; for s in 0 1 2 5; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done; }
trap cleanup EXIT

Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-restore.log 2>&1 & XVFB=$!; sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-restore.log 2>&1 & WM=$!; sleep 1
DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" LD_LIBRARY_PATH="$GS/zig-out/lib" \
  dbus-run-session -- ./build/insanitty >/tmp/app-restore.log 2>&1 & APP=$!
sleep 6
DISPLAY="$DISP" import -window root "$SHOT" 2>/dev/null

backInLayout=$(grep -q '"index" : 5' "$LAYOUT" 2>/dev/null && grep -q '"name" : "Archived One"' "$LAYOUT" 2>/dev/null && echo yes || echo no)
flagCleared=$(python3 -c "import json,sys; d={m['workspaceID']:m for m in json.load(open('$WS'))}; sys.exit(0 if not d.get('insanitty-ws-5',{}).get('isArchived', True) else 1)" && echo yes || echo no)
if [ "$backInLayout" = yes ] && [ "$flagCleared" = yes ]; then
  echo "ARCHIVE-RESTORE E2E PASS: archived workspace restored to the sidebar (layout.json) and unflagged ($SHOT)"
else
  echo "ARCHIVE-RESTORE E2E FAIL: backInLayout=$backInLayout flagCleared=$flagCleared"
  echo "--- layout.json ---"; cat "$LAYOUT" 2>/dev/null; echo "--- workspaces.json ---"; cat "$WS" 2>/dev/null
  exit 1
fi
