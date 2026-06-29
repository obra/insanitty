#!/usr/bin/env bash
# Build the forked Ghostty artifacts insanitty links against.
#
#   libghostty-vt   — VT engine for the remote helper (no GTK/blueprint needed). VERIFIED.
#   GTK surface     — the GhosttySurface widget insanitty embeds (Spike A). Needs
#                     blueprint-compiler + gettext (msgfmt); see scripts/setup-dev-env.sh.
#
# Until the fork has its own remote, this pins upstream Ghostty at the commit the research
# used and applies our patch.
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

echo "Applying insanitty patches ..."
git -C "$SRC" apply --check "$ROOT/patches/ghostty-inject-output.patch" \
  && git -C "$SRC" apply "$ROOT/patches/ghostty-inject-output.patch" \
  || echo "patch already applied or needs rebase — see patches/README.md"

echo "Building libghostty-vt (Zig $($ZIG version)) ..."
( cd "$SRC" && "$ZIG" build -Demit-lib-vt=true -Doptimize=ReleaseFast )
ls -la "$SRC"/zig-out/lib/libghostty-vt* || true

cat <<'EOF'

libghostty-vt built. To build the GTK surface (Spike A) you also need
blueprint-compiler + gettext, then (from the ghostty tree):
  zig build -Dapp-runtime=gtk -Doptimize=ReleaseFast
See docs/research/03b-ghostty-source-verified.md for the embedding plan.
EOF
