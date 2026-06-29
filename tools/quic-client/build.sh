#!/usr/bin/env bash
# Build the native Swift QUIC client (binds msquic) — the native transport for insanitty's
# remote engine, replacing the Go-probe subprocess bridge. Requires msquic built from source.
set -euo pipefail
cd "$(dirname "$0")/../.."
SWIFTC="${SWIFTC:-$(ls -d "$HOME"/.local/share/swiftly/toolchains/*/usr/bin/swiftc 2>/dev/null | head -1)}"
MQ="${MSQUIC:-/tmp/claude-1000/-home-jesse-git-insanitty/d4fe9727-abcd-4a64-bfab-456b14fdb334/scratchpad/msquic}"
[ -f "$MQ/build/bin/Release/libmsquic.so" ] || { echo "build msquic first (see tools/quic-client/README.md)"; exit 1; }
# OpenSSL: prefer system dev headers/lib (-lcrypto); else use msquic's bundled quictls headers
# + the system runtime libcrypto (X509/SHA256 ABI is stable across OpenSSL 3.x). Used for SPKI pinning.
OSSL_INC="${OSSL_INC:-$MQ/build/_deps/opensslquic-build/openssl/include}"
LIBCRYPTO=""
for cand in /usr/lib/*/libcrypto.so /usr/lib/*/libcrypto.so.3 /usr/lib/libcrypto.so.3; do
  [ -e "$cand" ] && { LIBCRYPTO="$cand"; break; }
done
[ -n "$LIBCRYPTO" ] || { echo "libcrypto not found"; exit 1; }
mkdir -p build
"$SWIFTC" -I tools/quic-client/CMsQuic -Xcc -I"$MQ/src/inc" -Xcc -I"$OSSL_INC" \
  Sources/InsanittyCore/*.swift tools/quic-client/main.swift \
  -L "$MQ/build/bin/Release" -lmsquic -Xlinker "$LIBCRYPTO" \
  -Xlinker -rpath -Xlinker "$MQ/build/bin/Release" \
  -o build/quic-client
echo "Built build/quic-client"
