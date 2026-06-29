#!/usr/bin/env bash
# Fetch the current remote pane grid from the helper (over QUIC, cert-pinned) and emit it
# as ANSI (clear screen + the rendered rows). insanitty runs this and injects the output
# into an inert surface via insanitty_surface_inject_output — i.e. a remote workspace
# rendered inside insanitty's GUI, fed by the real remote-engine server.
set -uo pipefail
GS="${GHOSTTY:-/tmp/claude-1000/-home-jesse-git-insanitty/d4fe9727-abcd-4a64-bfab-456b14fdb334/scratchpad/ghostty-src}"
HELPER="${HELPER:-build/fantastty-helper}"; [ -x "$HELPER" ] || HELPER=/tmp/fantastty-helper
export LD_LIBRARY_PATH="$GS/zig-out/lib" FANTASTTY_REMOTE_ADVERTISE_HOST=127.0.0.1
export XDG_RUNTIME_DIR=/tmp/ins-remote-rt
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
WS="${1:-insanitty-remote-gui}"

LINE=$("$HELPER" launch-or-resume "$WS" --ttl 8h --key-ttl 30s 2>/dev/null)
field() { printf '%s' "$LINE" | tr ' ' '\n' | sed -n "s/$1//p"; }
ADDR="$(field quic_addr=)"; CERT="$(field quic_cert_sha256=)"
"$HELPER" quic-probe --addr "$ADDR" --cert-sha256 "$CERT" \
    --session "$(field '^session=')" --key "$(field '^key=')" 2>/dev/null | \
  ADDR="$ADDR" CERT="$CERT" WS="$WS" python3 -c '
import sys, json, os
ws, addr, cert = os.environ["WS"], os.environ["ADDR"], os.environ["CERT"]
snap = kf = None
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    msg = json.loads(line)
    if "workspaceSnapshot" in msg: snap = msg["workspaceSnapshot"]["_0"]
    if "paneKeyframe" in msg: kf = msg["paneKeyframe"]["_0"]
out = ["\x1b[2J\x1b[H"]  # clear + home
g = kf["gridSize"] if kf else {"columns":"?","rows":"?"}
win = (snap["windows"][0]["title"] if snap and snap["windows"] else "?")
out.append("\x1b[1;32m  insanitty — REMOTE (QUIC) workspace  \x1b[0m\r\n")
out.append("\x1b[2m  fetched over QUIC from the remote-engine helper (SPKI cert-pinned)\x1b[0m\r\n")
out.append("  addr=\x1b[36m%s\x1b[0m  cert=\x1b[36m%s…\x1b[0m\r\n" % (addr, cert[:16]))
out.append("  workspace=\x1b[33m%s\x1b[0m  window=%s  grid=%sx%s  rows_received=%d\r\n" %
           (ws, win, g["columns"], g["rows"], len(kf["rows"]) if kf else 0))
out.append("  \x1b[2m─── remote pane content (rendered server-side by libghostty-vt) ───\x1b[0m\r\n")
if kf:
    for row in kf["rows"][:16]:
        out.append("  \x1b[34m│\x1b[0m " + row.get("text","")[:72] + "\r\n")
sys.stdout.write("".join(out))
'
