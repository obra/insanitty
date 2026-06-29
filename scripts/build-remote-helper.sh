#!/usr/bin/env bash
# Build the Go remote-engine helper (the SERVER side of the remote feature set) with
# libghostty-vt. The helper is Fantastty's, reused unchanged (already a Linux program).
# Requires: Go >= 1.25, libghostty-vt built (scripts/build-ghostty.sh), cgo.
set -euo pipefail
cd "$(dirname "$0")/.."
GS="${GHOSTTY:-$PWD/vendor/ghostty}"
HELPER_SRC="${HELPER_SRC:-inspo/fantastty/tools/remote-engine-helper/helper}"
[ -f "$GS/zig-out/lib/libghostty-vt.so" ] || { echo "libghostty-vt not built — run scripts/build-ghostty.sh"; exit 1; }
[ -d "$HELPER_SRC" ] || { echo "helper source not found at $HELPER_SRC (set HELPER_SRC)"; exit 1; }

export PKG_CONFIG_PATH="$GS/zig-out/share/pkgconfig" CGO_ENABLED=1
mkdir -p build
OUT="$PWD/build/fantastty-helper"
( cd "$HELPER_SRC" && GOFLAGS=-mod=mod go build -tags ghostty_vt -o "$OUT" . )
echo "Built build/fantastty-helper ($(LD_LIBRARY_PATH="$GS/zig-out/lib" "$OUT" --version 2>/dev/null))"
