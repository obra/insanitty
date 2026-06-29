#!/usr/bin/env bash
# E2E: the native Swift QUIC client ENFORCES SPKI cert pinning. The remote cert is self-signed,
# so the client validates hex(SHA256(SubjectPublicKeyInfo)) against the pin from the bootstrap
# line itself. We prove both directions: the correct pin connects, and a TAMPERED pin is rejected
# (the connection never completes the attach).
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-/tmp/claude-1000/-home-jesse-git-insanitty/d4fe9727-abcd-4a64-bfab-456b14fdb334/scratchpad/ghostty-src}"
MQ="${MSQUIC:-/tmp/claude-1000/-home-jesse-git-insanitty/d4fe9727-abcd-4a64-bfab-456b14fdb334/scratchpad/msquic}"
HELPER="${HELPER:-build/fantastty-helper}"; [ -x "$HELPER" ] || HELPER=/tmp/fantastty-helper
[ -x build/quic-client ] || bash tools/quic-client/build.sh
export LD_LIBRARY_PATH="$GS/zig-out/lib:$MQ/build/bin/Release" FANTASTTY_REMOTE_ADVERTISE_HOST=127.0.0.1
export XDG_RUNTIME_DIR=/tmp/ins-remote-rt
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
WS=insanitty-pin
cleanup() { "$HELPER" shutdown >/dev/null 2>&1; tmux kill-session -t "$WS" 2>/dev/null; }
trap cleanup EXIT

# A fresh bootstrap line (fresh one-time key) per attempt, so a failure can only be the pin.
freshline() { "$HELPER" launch-or-resume "$WS" --ttl 8h --key-ttl 30s 2>/dev/null | grep -m1 '^FANTASTTY_REMOTE '; }

# 1) Correct pin → connects.
LINE=$(freshline)
[ -n "$LINE" ] || { echo "PINNING E2E FAIL: no FANTASTTY_REMOTE bootstrap line"; exit 1; }
OK=$(printf '%s\n' "$LINE" | ./build/quic-client --bootstrap 2>&1)
echo "$OK" | grep -q 'NATIVE-QUIC-OK' \
  || { echo "PINNING E2E FAIL: correct pin did not connect"; echo "$OK" | tail -2; exit 1; }

# 2) Tampered pin (all-zeros SPKI) with a fresh key → must be rejected (PIN-FAIL, no attach).
BAD_LINE=$(freshline | sed -E 's/quic_cert_sha256=[0-9a-fA-F]+/quic_cert_sha256=0000000000000000000000000000000000000000000000000000000000000000/')
BAD=$(printf '%s\n' "$BAD_LINE" | ./build/quic-client --bootstrap 2>&1)
if echo "$BAD" | grep -q 'NATIVE-QUIC-OK'; then
  echo "PINNING E2E FAIL: client connected despite a WRONG cert pin (pinning not enforced!)"; exit 1
fi
echo "$BAD" | grep -q 'PIN-FAIL' \
  || { echo "PINNING E2E FAIL: wrong pin did not produce a PIN-FAIL"; echo "$BAD" | tail -2; exit 1; }

echo "PINNING E2E PASS: correct SPKI pin connects; a tampered pin is rejected (PIN-FAIL)"
