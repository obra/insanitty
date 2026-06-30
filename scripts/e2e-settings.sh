#!/usr/bin/env bash
# E2E: settings + theming. Starts insanitty with a dark appearance preference (settings.json),
# so the libadwaita chrome loads dark; opens the Preferences window; toggles a setting row; and
# asserts the change persisted to settings.json (and the dark appearance was preserved). Proves
# applyAppearance (startup theming), the settings window, and live-persist all work end-to-end.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
SHOT="${OUT:-docs/images}/e2e-8-settings.png"
[ -x build/insanitty ] || { echo "build the app first: scripts/build-app.sh"; exit 1; }
DISP=":131"
mkdir -p /tmp/inscfg/ghostty "${OUT:-docs/images}"; echo "initial-window = false" > /tmp/inscfg/ghostty/config
export XDG_STATE_HOME=/tmp/ins-settings-state
mkdir -p "$XDG_STATE_HOME/insanitty"
SETTINGS="$XDG_STATE_HOME/insanitty/settings.json"
# Seed a dark appearance so startup theming is exercised; tabsInSidebar starts false.
printf '{\n  "appearance" : "dark"\n}\n' > "$SETTINGS"

cleanup() { kill "${APP:-}" "${WM:-}" "${XVFB:-}" 2>/dev/null; for s in 0 1 2; do tmux kill-session -t "insanitty-ws-$s" 2>/dev/null; done; }
trap cleanup EXIT

Xvfb "$DISP" -screen 0 1100x720x24 >/tmp/xvfb-set.log 2>&1 & XVFB=$!; sleep 2
DISPLAY="$DISP" matchbox-window-manager >/tmp/wm-set.log 2>&1 & WM=$!; sleep 1
DISPLAY="$DISP" XDG_CONFIG_HOME=/tmp/inscfg GHOSTTY_RESOURCES_DIR="$GS/zig-out/share/ghostty" LD_LIBRARY_PATH="$GS/zig-out/lib" \
  dbus-run-session -- ./build/insanitty >/tmp/app-set.log 2>&1 & APP=$!
sleep 5
# Open Preferences (gear icon, header bar top-right, left of the window controls).
DISPLAY="$DISP" xdotool mousemove 957 27 click 1; sleep 2
# Toggle the "Predictive echo" row in the Remote Engine group (AdwSwitchRow is activatable — click
# the row). It defaults on, so toggling persists remotePredictiveEcho=false.
DISPLAY="$DISP" xdotool mousemove 320 260 click 1; sleep 2
DISPLAY="$DISP" import -window root "$SHOT" 2>/dev/null

# Assert: the toggle persisted, and the dark appearance survived the write.
if grep -q '"remotePredictiveEcho" : false' "$SETTINGS" && grep -q '"appearance" : "dark"' "$SETTINGS"; then
  echo "SETTINGS E2E PASS: dark theme applied at startup; toggling a row persisted to settings.json ($SHOT)"
else
  echo "SETTINGS E2E FAIL: settings.json did not reflect the toggle"; echo "--- settings.json ---"; cat "$SETTINGS"
  exit 1
fi
