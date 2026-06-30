#!/usr/bin/env bash
# E2E: note revision history. Pre-seeds a workspace note, edits it (the test hook the note Edit dialog
# drives), and asserts the edit pushed the OLD content onto the note's revision history in
# workspaces.json — which the Notes panel surfaces as an expandable "edited N×" row.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
SHOT="${OUT:-docs/images}/e2e-notes-history.png"
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
DISP=":151"
mkdir -p /tmp/inscfg/ghostty "${OUT:-docs/images}"; echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-nhist-state; mkdir -p "$XDG_STATE_HOME/insanitty"
WS="$XDG_STATE_HOME/insanitty/workspaces.json"
cat > "$WS" <<'JSON'
[
  { "workspaceID":"insanitty-ws-0", "name":"", "needsAttention":false, "tags":[],
    "isArchived":false, "isTrashed":false, "createdAt":"2026-01-01T00:00:00Z",
    "modifiedAt":"2026-01-01T00:00:00Z", "totalActiveSeconds":0,
    "notes":[ {"id":"11111111-1111-1111-1111-111111111111","timestamp":"2026-01-01T00:00:00Z",
               "content":"ORIGINAL-NOTE","tags":[],"source":"user","revisions":[]} ] }
]
JSON
export INSANITTY_EDIT_NOTE="insanitty-ws-0:0:EDITED-NOTE"
for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done; }
trap cleanup EXIT

Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-nhist.log 2>&1 & XVFB=$!; sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-nhist.log 2>&1 & WM=$!; sleep 1
DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" LD_LIBRARY_PATH="$GS/zig-out/lib" \
  dbus-run-session -- ./build/insanitty >/tmp/app-nhist.log 2>&1 & APP=$!
sleep 5
# Open the Notes panel so the edited note + its history render (workspace 0 is selected at startup).
DISPLAY="$DISP" xdotool mousemove 740 27 click 1; sleep 2   # notes button (header, near top-right)
DISPLAY="$DISP" import -window root "$SHOT" 2>/dev/null

# The edit must have replaced the content AND archived the original as a revision.
if python3 -c "
import json,sys
d={m['workspaceID']:m for m in json.load(open('$WS'))}
n=d['insanitty-ws-0']['notes'][0]
ok = n['content']=='EDITED-NOTE' and any(r['content']=='ORIGINAL-NOTE' for r in n['revisions'])
sys.exit(0 if ok else 1)"; then
  echo "NOTES-HISTORY E2E PASS: editing a note pushed the original onto its revision history ($SHOT)"
else
  echo "NOTES-HISTORY E2E FAIL"; echo "--- workspaces.json ---"; cat "$WS" 2>/dev/null; exit 1
fi
