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
. scripts/lib-package.sh

VERSION="${VERSION:-0.1.0~dev}"
ARCH="${ARCH:-$(dpkg --print-architecture 2>/dev/null || echo amd64)}"
pkg_resolve_inputs

PKG=insanitty
ROOT="build/deb/${PKG}_${VERSION}_${ARCH}"
say() { printf '\n== %s ==\n' "$*"; }

pkg_check_inputs

say "1/4 Build the app with install rpath (/usr/lib/$PKG)"
RPATH="/usr/lib/$PKG" MQRPATH="/usr/lib/$PKG" ./scripts/build-app.sh

say "2/4 Stage the package tree"
rm -rf "$ROOT"
stage_payload "$ROOT/usr/bin" "$ROOT/usr/lib/$PKG" "$ROOT/usr/share" "$ROOT/usr/libexec" "$PKG"

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
Depends: libgtk-4-1, libadwaita-1-0, libwebkitgtk-6.0-4, libssl3, tmux
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
