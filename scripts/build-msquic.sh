#!/usr/bin/env bash
# Build msquic (the in-process QUIC stack the app links for the remote workspace) into a durable
# vendor/msquic, producing the layout scripts/build-app.sh + build-deb.sh expect:
#   build/bin/Release/libmsquic.so*                         — the shared lib
#   src/inc/msquic.h                                        — the public header
#   build/_deps/opensslquic-build/openssl/include           — bundled OpenSSL (quictls) headers
#
# Mirrors the recipe in .github/workflows/deb.yml. Needs cmake + ninja (scripts/setup-dev-env.sh
# installs system build tools). Re-run safely; it skips the clone if present.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${MSQUIC_SRC:-$ROOT/vendor/msquic}"
MSQUIC_REF="${MSQUIC_REF:-v2.4.10}"

command -v cmake  >/dev/null || { echo "cmake not found (apt install cmake)"; exit 1; }
command -v ninja  >/dev/null || { echo "ninja not found (apt install ninja-build)"; exit 1; }

if [ ! -d "$SRC/.git" ]; then
  echo "Cloning msquic ($MSQUIC_REF) into $SRC ..."
  git clone --depth 1 -b "$MSQUIC_REF" https://github.com/microsoft/msquic.git "$SRC"
fi
# Populate ONLY the submodules the Linux openssl-TLS build needs, non-recursively. Do NOT use
# --recursive: it drags in openssl's own test submodules (gost-engine, krb5, wycheproof, ...) —
# gigabytes of source msquic never builds. (QUIC_TLS defaults to "openssl"/quictls on Linux.)
echo "Fetching needed submodules (openssl, clog) — non-recursive ..."
git -C "$SRC" submodule update --init --depth 1 submodules/openssl submodules/clog

echo "Configuring + building msquic (Release) ..."
cmake -S "$SRC" -B "$SRC/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build "$SRC/build"

echo "Built msquic:"
ls -la "$SRC/build/bin/Release/"libmsquic.so* "$SRC/src/inc/msquic.h"
echo "Next: scripts/build-app.sh"
