#!/usr/bin/env bash
# Build the insanitty app (app/) linking libghostty-gtk (the Ghostty GTK embedding lib).
# Requires that lib to be built first: scripts/build-ghostty.sh (with -Dinsanitty-lib),
# or set GHOSTTY to a checkout whose zig-out has libghostty-gtk.so + insanitty.h.
set -euo pipefail
cd "$(dirname "$0")/.."

# Swift toolchain (swiftly-managed); override SWIFTC if installed elsewhere.
SWIFTC="${SWIFTC:-$(ls -d "$HOME"/.local/share/swiftly/toolchains/*/usr/bin/swiftc 2>/dev/null | head -1)}"
GHOSTTY="${GHOSTTY:-$PWD/vendor/ghostty}"   # where scripts/build-ghostty.sh puts the lib
LIBDIR="$GHOSTTY/zig-out/lib"
INCDIR="$GHOSTTY/zig-out/include"
RPATH="${RPATH:-$LIBDIR}"   # packaging overrides this to the install lib dir

# msquic (in-process QUIC for the remote workspace). MSQUIC points at a built msquic checkout.
MQ="${MSQUIC:-/tmp/claude-1000/-home-jesse-git-insanitty/d4fe9727-abcd-4a64-bfab-456b14fdb334/scratchpad/msquic}"
MQLIB="$MQ/build/bin/Release"
OSSL_INC="${OSSL_INC:-$MQ/build/_deps/opensslquic-build/openssl/include}"
MQRPATH="${MQRPATH:-$MQLIB}"   # packaging overrides this to the install lib dir
LIBCRYPTO=""; for c in /usr/lib/*/libcrypto.so /usr/lib/*/libcrypto.so.3; do [ -e "$c" ] && { LIBCRYPTO="$c"; break; }; done

[ -x "$SWIFTC" ] || { echo "swiftc not found (set SWIFTC)"; exit 1; }
[ -f "$LIBDIR/libghostty-gtk.so" ] || { echo "libghostty-gtk.so not found in $LIBDIR — run scripts/build-ghostty.sh"; exit 1; }
[ -f "$MQLIB/libmsquic.so" ] || { echo "libmsquic.so not found in $MQLIB — build msquic (set MSQUIC)"; exit 1; }
[ -n "$LIBCRYPTO" ] || { echo "libcrypto not found"; exit 1; }

mkdir -p build
echo "Compiling insanitty (swiftc $($SWIFTC --version 2>/dev/null | head -1))..."
"$SWIFTC" -O \
  -I app/CGhostty -I "$INCDIR" -I tools/quic-client/CMsQuic -Xcc -I"$MQ/src/inc" -Xcc -I"$OSSL_INC" \
  $(pkg-config --cflags-only-I libadwaita-1 webkitgtk-6.0 | sed 's/-I/-Xcc -I/g') \
  Sources/InsanittyCore/*.swift app/*.swift \
  -L "$LIBDIR" -lghostty-gtk -lutil -L "$MQLIB" -lmsquic -Xlinker "$LIBCRYPTO" \
  $(pkg-config --libs libadwaita-1 webkitgtk-6.0 | tr ' ' '\n' | grep -E '^-[lL]' | tr '\n' ' ') \
  -Xlinker -rpath -Xlinker "$RPATH" -Xlinker -rpath -Xlinker "$MQRPATH" \
  -o build/insanitty
echo "Built build/insanitty"
