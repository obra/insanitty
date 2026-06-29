#!/usr/bin/env bash
# Build the native Swift QUIC client (binds msquic) — the native transport for insanitty's
# remote engine, replacing the Go-probe subprocess bridge. Requires msquic built from source.
set -euo pipefail
cd "$(dirname "$0")/../.."
SWIFTC="${SWIFTC:-$(ls -d "$HOME"/.local/share/swiftly/toolchains/*/usr/bin/swiftc 2>/dev/null | head -1)}"
MQ="${MSQUIC:-/tmp/claude-1000/-home-jesse-git-insanitty/d4fe9727-abcd-4a64-bfab-456b14fdb334/scratchpad/msquic}"
[ -f "$MQ/build/bin/Release/libmsquic.so" ] || { echo "build msquic first (see tools/quic-client/README.md)"; exit 1; }
mkdir -p build
"$SWIFTC" -I tools/quic-client/CMsQuic -Xcc -I"$MQ/src/inc" \
  Sources/InsanittyCore/*.swift tools/quic-client/main.swift \
  -L "$MQ/build/bin/Release" -lmsquic -Xlinker -rpath -Xlinker "$MQ/build/bin/Release" \
  -o build/quic-client
echo "Built build/quic-client"
