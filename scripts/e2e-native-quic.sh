#!/usr/bin/env bash
# E2E: insanitty's NATIVE Swift QUIC client (binds msquic) attaches to the remote-engine
# helper over QUIC, sends {session,key}, reads the reliable stream, and decodes a paneKeyframe
# with InsanittyCore.RemoteGridProtocol — the native transport, no Go-probe subprocess.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-/tmp/claude-1000/-home-jesse-git-insanitty/d4fe9727-abcd-4a64-bfab-456b14fdb334/scratchpad/ghostty-src}"
MQ="${MSQUIC:-/tmp/claude-1000/-home-jesse-git-insanitty/d4fe9727-abcd-4a64-bfab-456b14fdb334/scratchpad/msquic}"
HELPER="${HELPER:-build/fantastty-helper}"; [ -x "$HELPER" ] || HELPER=/tmp/fantastty-helper
[ -x build/quic-client ] || bash tools/quic-client/build.sh
export LD_LIBRARY_PATH="$GS/zig-out/lib:$MQ/build/bin/Release" FANTASTTY_REMOTE_ADVERTISE_HOST=127.0.0.1
export XDG_RUNTIME_DIR=/tmp/ins-remote-rt
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
WS=insanitty-native
cleanup() { "$HELPER" shutdown >/dev/null 2>&1; tmux kill-session -t "$WS" 2>/dev/null; }
trap cleanup EXIT

LINE=$("$HELPER" launch-or-resume "$WS" --ttl 8h --key-ttl 30s 2>/dev/null)
field() { printf '%s' "$LINE" | tr ' ' '\n' | sed -n "s/$1//p"; }
ADDR=$(field quic_addr=)
OUT=$(./build/quic-client "${ADDR%:*}" "${ADDR##*:}" "$(field '^session=')" "$(field '^key=')")
echo "$OUT"
echo "$OUT" | grep -q 'NATIVE-QUIC-OK' || { echo "NATIVE QUIC E2E FAIL"; exit 1; }
echo "NATIVE QUIC E2E PASS"
