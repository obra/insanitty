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

[ -x "$SWIFTC" ] || { echo "swiftc not found (set SWIFTC)"; exit 1; }
[ -f "$LIBDIR/libghostty-gtk.so" ] || { echo "libghostty-gtk.so not found in $LIBDIR — run scripts/build-ghostty.sh"; exit 1; }

mkdir -p build
echo "Compiling insanitty (swiftc $($SWIFTC --version 2>/dev/null | head -1))..."
"$SWIFTC" -O \
  -I app/CGhostty -I "$INCDIR" \
  $(pkg-config --cflags-only-I libadwaita-1 webkitgtk-6.0 | sed 's/-I/-Xcc -I/g') \
  Sources/InsanittyCore/*.swift app/*.swift \
  -L "$LIBDIR" -lghostty-gtk \
  $(pkg-config --libs libadwaita-1 webkitgtk-6.0 | tr ' ' '\n' | grep -E '^-[lL]' | tr '\n' ' ') \
  -Xlinker -rpath -Xlinker "$RPATH" \
  -o build/insanitty
echo "Built build/insanitty"
