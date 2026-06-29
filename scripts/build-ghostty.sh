#!/usr/bin/env bash
# Build the forked Ghostty artifacts insanitty links against, into vendor/ghostty/zig-out:
#
#   libghostty-vt.so   — VT engine for the remote helper (no GTK/blueprint needed).
#   libghostty-gtk.so  — the GTK embedding lib the app links (Spike A): Ghostty's GTK apprt
#                        built as a shared library with insanitty's C ABI. Needs
#                        blueprint-compiler + gettext (msgfmt); see scripts/setup-dev-env.sh.
#   include/insanitty.h — the embedding C ABI header.
#
# Pins upstream Ghostty at the commit the research used and applies patches/ghostty-gtk-embed.patch.
# This mirrors the verified recipe in .github/workflows/deb.yml. Run scripts/build-app.sh next.
set -euo pipefail

GHOSTTY_COMMIT="5d0a82ba337368f5632ffa6ce4d7c558fa2de9ff"
ZIG="${ZIG:-$HOME/.local/zig-0.15.2/zig}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${GHOSTTY_SRC:-$ROOT/vendor/ghostty}"

if [ ! -d "$SRC/.git" ]; then
  echo "Cloning Ghostty into $SRC ..."
  git clone --filter=blob:none https://github.com/ghostty-org/ghostty.git "$SRC"
fi
git -C "$SRC" checkout -q "$GHOSTTY_COMMIT"

echo "Applying the insanitty GTK-embedding patch ..."
if git -C "$SRC" apply --check "$ROOT/patches/ghostty-gtk-embed.patch" 2>/dev/null; then
  git -C "$SRC" apply "$ROOT/patches/ghostty-gtk-embed.patch"
else
  echo "patch already applied or needs rebase — see patches/README.md"
fi

echo "Building libghostty-vt (Zig $($ZIG version)) ..."
( cd "$SRC" && "$ZIG" build -Demit-lib-vt=true -Doptimize=ReleaseFast )
ls -la "$SRC"/zig-out/lib/libghostty-vt* || true

echo "Building libghostty-gtk.so (the GTK embedding lib insanitty links; Spike A) ..."
# X11-only avoids gtk4-layer-shell-0 (not in default Ubuntu repos). Drop the flags below
# to build with Wayland once gtk4-layer-shell is installed from source.
# Requires blueprint-compiler >= 0.16 via meson + gettext (see scripts/setup-dev-env.sh).
# Debug optimize matches the verified recipe in .github/workflows/deb.yml.
( cd "$SRC" && "$ZIG" build -Doptimize=Debug -Dgtk-wayland=false -Dgtk-x11=true -Dapp-runtime=gtk -Dinsanitty-lib=true ) \
  && ls -la "$SRC"/zig-out/lib/libghostty-gtk.so* "$SRC"/zig-out/include/insanitty.h \
  || echo "Embedding-lib build failed — check blueprint-compiler version + system libs (docs/STATUS.md)."

cat <<'EOF'

Done. Built into vendor/ghostty/zig-out:
  lib/libghostty-vt.so   — VT engine for the remote helper (scripts/build-remote-helper.sh)
  lib/libghostty-gtk.so  — the GTK embedding lib the app links (scripts/build-app.sh)
  include/insanitty.h    — the embedding C ABI
Next: scripts/build-app.sh
EOF
