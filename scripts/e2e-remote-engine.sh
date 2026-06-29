#!/usr/bin/env bash
# End-to-end test of the REMOTE FEATURE SET, locally (localhost is the host).
#
# Starts the Go helper's QUIC service (launch-or-resume), then uses its reference QUIC
# client (the probes) to: (1) attach over QUIC with cert-pin + one-time key and pull the
# rendered structured grid, (2) send input to the remote pane, (3) confirm a wrong cert
# is rejected. This exercises the same protocol/transport/security the Swift client will,
# against the real unchanged helper.
set -uo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
HELPER="${HELPER:-build/fantastty-helper}"
[ -x "$HELPER" ] || HELPER=/tmp/fantastty-helper
[ -x "$HELPER" ] || { echo "helper not built — run scripts/build-remote-helper.sh"; exit 1; }

export LD_LIBRARY_PATH="$GS/zig-out/lib" FANTASTTY_REMOTE_ADVERTISE_HOST=127.0.0.1
export XDG_RUNTIME_DIR=/tmp/ins-remote-rt
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
WS=insanitty-remote-e2e
cleanup() { "$HELPER" shutdown >/dev/null 2>&1; tmux kill-session -t "$WS" 2>/dev/null; }
trap cleanup EXIT
fail() { echo "REMOTE E2E FAIL: $1"; exit 1; }

# Fresh attach material (one-time key, 30s TTL) — echo "addr cert session key".
attach() {
  local l; l=$("$HELPER" launch-or-resume "$WS" --ttl 8h --key-ttl 30s 2>/dev/null)
  printf '%s %s %s %s' \
    "$(printf '%s' "$l" | tr ' ' '\n' | sed -n 's/quic_addr=//p')" \
    "$(printf '%s' "$l" | tr ' ' '\n' | sed -n 's/quic_cert_sha256=//p')" \
    "$(printf '%s' "$l" | tr ' ' '\n' | sed -n 's/^session=//p')" \
    "$(printf '%s' "$l" | tr ' ' '\n' | sed -n 's/^key=//p')"
}

# 1. Attach over QUIC and pull the structured grid.
read -r ADDR CERT SESS KEY <<<"$(attach)"
[ -n "$ADDR" ] || fail "helper did not start / no attach line"
"$HELPER" quic-probe --addr "$ADDR" --cert-sha256 "$CERT" --session "$SESS" --key "$KEY" >/tmp/grid.json 2>/dev/null || fail "quic-probe failed"
grep -q '"workspaceSnapshot"' /tmp/grid.json && grep -q '"paneKeyframe"' /tmp/grid.json || fail "grid payload missing snapshot/keyframe"
echo "PASS 1: QUIC attach (cert-pinned, one-time key) + structured grid render (workspaceSnapshot + paneKeyframe)"

# 2. Send input to the remote pane.
read -r ADDR CERT SESS KEY <<<"$(attach)"
"$HELPER" input-probe --addr "$ADDR" --cert-sha256 "$CERT" --session "$SESS" --key "$KEY" --marker INSANITTY-INPUT 2>/dev/null | grep -q 'ok marker=INSANITTY-INPUT' || fail "input-probe failed"
echo "PASS 2: input over QUIC reached the remote pane"

# 3. Cert pin must reject a wrong SPKI.
read -r ADDR CERT SESS KEY <<<"$(attach)"
if "$HELPER" quic-probe --addr "$ADDR" --cert-sha256 "$(printf '0%.0s' {1..64})" --session "$SESS" --key "$KEY" >/dev/null 2>/tmp/badpin.err; then
  fail "wrong cert was ACCEPTED — pin not enforced"
fi
grep -q 'SPKI SHA256' /tmp/badpin.err || fail "wrong-cert failure was not a pin mismatch"
echo "PASS 3: cert pin enforced (wrong SPKI rejected)"

echo "REMOTE ENGINE E2E PASS"
