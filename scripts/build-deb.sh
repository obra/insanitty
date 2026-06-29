#!/usr/bin/env bash
# Package insanitty into an installable Debian .deb.
#
# Stages the app + the Ghostty GTK engine lib + Ghostty resources + the remote-engine helper
# + shell integration + a launcher wrapper + a .desktop entry, then `dpkg-deb --build`.
# Rebuilds the app with an install rpath so it finds its bundled engine lib at /usr/lib/insanitty.
#
# Env: GHOSTTY (ghostty checkout with zig-out), HELPER (fantastty-helper), VERSION, ARCH.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0~dev}"
ARCH="${ARCH:-$(dpkg --print-architecture 2>/dev/null || echo amd64)}"
GHOSTTY="${GHOSTTY:-$PWD/vendor/ghostty}"   # scripts/build-ghostty.sh builds the lib here
ZLIB="$GHOSTTY/zig-out/lib"; ZSHARE="$GHOSTTY/zig-out/share/ghostty"
HELPER="${HELPER:-build/fantastty-helper}"; [ -x "$HELPER" ] || HELPER=/tmp/fantastty-helper

PKG=insanitty
ROOT="build/deb/${PKG}_${VERSION}_${ARCH}"
say() { printf '\n== %s ==\n' "$*"; }

[ -f "$ZLIB/libghostty-gtk.so" ] || { echo "missing libghostty-gtk.so ($ZLIB) — run scripts/build-ghostty.sh + the insanitty-lib build"; exit 1; }

say "1/4 Build the app with install rpath (/usr/lib/$PKG)"
RPATH="/usr/lib/$PKG" ./scripts/build-app.sh

say "2/4 Stage the package tree"
rm -rf "$ROOT"
install -Dm755 build/insanitty                "$ROOT/usr/lib/$PKG/insanitty-bin"
# Engine lib (+ versioned soname links)
for f in "$ZLIB"/libghostty-gtk.so*; do install -Dm644 "$f" "$ROOT/usr/lib/$PKG/$(basename "$f")"; done
# Ghostty resources (terminfo, themes, etc.)
mkdir -p "$ROOT/usr/share/$PKG"; cp -r "$ZSHARE" "$ROOT/usr/share/$PKG/ghostty"
# Remote-engine helper + its VT lib (best-effort; remote needs these at runtime)
if [ -x "$HELPER" ]; then
  install -Dm755 "$HELPER" "$ROOT/usr/libexec/$PKG/fantastty-helper"
  for f in "$ZLIB"/libghostty-vt.so*; do [ -e "$f" ] && install -Dm644 "$f" "$ROOT/usr/libexec/$PKG/$(basename "$f")"; done
fi
# Shell integration + desktop entry
install -Dm644 scripts/shell-integration/insanitty.sh "$ROOT/usr/share/$PKG/shell-integration/insanitty.sh"
install -Dm644 packaging/insanitty.desktop           "$ROOT/usr/share/applications/insanitty.desktop"

# Launcher wrapper: point Ghostty at its bundled resources, then exec the real binary.
install -Dm755 /dev/stdin "$ROOT/usr/bin/insanitty" <<EOF
#!/bin/sh
export GHOSTTY_RESOURCES_DIR="\${GHOSTTY_RESOURCES_DIR:-/usr/share/$PKG/ghostty}"
exec /usr/lib/$PKG/insanitty-bin "\$@"
EOF

say "3/4 Control metadata"
INSTALLED_KB=$(du -sk "$ROOT" | cut -f1)
mkdir -p "$ROOT/DEBIAN"
cat > "$ROOT/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Maintainer: insanitty <jesse@primeradiant.com>
Installed-Size: $INSTALLED_KB
Depends: libgtk-4-1, libadwaita-1-0, libwebkitgtk-6.0-4, tmux
Description: Terminal workspace manager (native Linux port of Fantastty)
 insanitty is a libghostty-based terminal workspace manager: persistent
 tmux-backed workspaces with tabs, splits, browser tabs, and an SSH/QUIC
 remote engine.
EOF

say "4/4 dpkg-deb --build"
mkdir -p dist
DEB="dist/${PKG}_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$ROOT" "$DEB"
echo "Built $DEB"
dpkg-deb --info "$DEB" | sed -n '1,12p'
