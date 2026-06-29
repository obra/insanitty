#!/usr/bin/env bash
# E2E: insanitty persists its workspace LAYOUT across restart — the set of workspaces (names,
# order, count) and each workspace's browser-tab URLs, written to an XDG layout.json and
# restored on the next launch. (This is distinct from e2e-persistence.sh, which proves the
# tmux *session* content survives; this proves the app remembers its own structure.)
#
# Headless: Xvfb + matchbox + dbus. Isolated via a throwaway XDG_STATE_HOME.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-/tmp/claude-1000/-home-jesse-git-insanitty/d4fe9727-abcd-4a64-bfab-456b14fdb334/scratchpad/ghostty-src}"
DISP=":129"
export XDG_STATE_HOME=/tmp/ins-layout-state
LAYOUT="$XDG_STATE_HOME/insanitty/layout.json"
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
rm -rf "$XDG_STATE_HOME"
mkdir -p /tmp/inscfg/ghostty; echo "initial-window = false" > /tmp/inscfg/ghostty/config
for s in 0 1 2 3; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; for s in 0 1 2 3; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done; }
trap cleanup EXIT

launch() {
  DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg XDG_STATE_HOME="$XDG_STATE_HOME" \
    GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" LD_LIBRARY_PATH="$GS/zig-out/lib" \
    dbus-run-session -- ./build/insanitty >"$1" 2>&1 & APP=$!
}
jq_py() { python3 -c "import json;d=json.load(open('$LAYOUT'));print($1)"; }

Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-lp.log 2>&1 & XVFB=$!; sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-lp.log 2>&1 & WM=$!; sleep 1

# Launch 1: add a workspace (Ctrl+N) and a browser tab (Ctrl+B), then read the persisted layout.
launch /tmp/app-lp1.log; sleep 6
DISPLAY="$DISP" xdotool key ctrl+n; sleep 3
DISPLAY="$DISP" xdotool key ctrl+b; sleep 3; sleep 1
[ -f "$LAYOUT" ] || { echo "LAYOUT-PERSIST FAIL: no layout.json written"; exit 1; }
COUNT1=$(jq_py "len(d['workspaces'])")
NAMES1=$(jq_py "','.join(sorted(w['name'] for w in d['workspaces']))")
URLS1=$(jq_py "sum(len(w['browserURLs']) for w in d['workspaces'])")
kill "$APP" 2>/dev/null; sleep 2
for s in 0 1 2 3; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done

# Launch 2: should restore the same workspaces + browser tab, then re-save the same layout.
launch /tmp/app-lp2.log; sleep 8
COUNT2=$(jq_py "len(d['workspaces'])")
NAMES2=$(jq_py "','.join(sorted(w['name'] for w in d['workspaces']))")
URLS2=$(jq_py "sum(len(w['browserURLs']) for w in d['workspaces'])")

echo "before restart: count=$COUNT1 urls=$URLS1 names=[$NAMES1]"
echo "after  restart: count=$COUNT2 urls=$URLS2 names=[$NAMES2]"
[ "$COUNT1" = "4" ] || { echo "LAYOUT-PERSIST FAIL: expected 4 workspaces after Ctrl+N, got $COUNT1"; exit 1; }
[ "$COUNT1" = "$COUNT2" ] || { echo "LAYOUT-PERSIST FAIL: workspace count changed across restart ($COUNT1 -> $COUNT2)"; exit 1; }
[ "$NAMES1" = "$NAMES2" ] || { echo "LAYOUT-PERSIST FAIL: workspace names not restored"; exit 1; }
[ "${URLS2:-0}" -ge 1 ] || { echo "LAYOUT-PERSIST FAIL: browser-tab URL not restored"; exit 1; }
echo "LAYOUT-PERSIST E2E PASS: $COUNT2 workspaces (same names) + $URLS2 browser tab(s) restored across restart"
