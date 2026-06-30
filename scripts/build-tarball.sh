#!/usr/bin/env bash
# Package insanitty into a relocatable .tar.gz: extract anywhere and run bin/insanitty. The app is
# built with an `$ORIGIN` rpath so it finds its bundled libs next to the binary, and a small wrapper
# resolves its own location to point Ghostty at the bundled resources.
#
# Env: GHOSTTY (ghostty checkout with zig-out), MSQUIC, HELPER, VERSION, ARCH.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib-package.sh

VERSION="${VERSION:-0.1.0~dev}"
ARCH="${ARCH:-$(uname -m)}"
PKG=insanitty
pkg_resolve_inputs
say() { printf '\n== %s ==\n' "$*"; }

pkg_check_inputs

say "1/3 Build the app relocatable (\$ORIGIN rpath)"
RPATH='$ORIGIN' MQRPATH='$ORIGIN' ./scripts/build-app.sh

say "2/3 Stage the relocatable tree"
DIR="insanitty-${VERSION}-linux-${ARCH}"
ROOT="build/tar/$DIR"
rm -rf "$ROOT"
stage_payload "$ROOT/bin" "$ROOT/lib" "$ROOT/share" "$ROOT/libexec" "$PKG"

# Self-locating launcher: find our own dir, point Ghostty at the bundled resources, exec the binary.
install -Dm755 /dev/stdin "$ROOT/bin/insanitty" <<'EOF'
#!/bin/sh
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export GHOSTTY_RESOURCES_DIR="${GHOSTTY_RESOURCES_DIR:-$here/../share/insanitty/ghostty}"
exec "$here/../lib/insanitty-bin" "$@"
EOF

say "3/3 tar.gz"
mkdir -p dist
TAR="dist/${DIR}.tar.gz"
tar -C build/tar -czf "$TAR" "$DIR"
echo "Built $TAR"
tar -tzf "$TAR" | sed -n '1,12p'
