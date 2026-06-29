#!/usr/bin/env bash
# Set up an insanitty development environment.
#
# Splits into: (1) system packages (need root/apt), (2) user-local toolchains (no root).
# Re-run safely; it skips what's already present. Verified against Ubuntu 24.04 / x86_64.
set -euo pipefail

ZIG_VERSION="0.15.2"          # must match the forked Ghostty's build.zig.zon
SWIFT_CHANNEL="latest"        # swiftly release channel (Swift 6.x)
BLUEPRINT_VERSION="0.20.4"    # verified to compile Ghostty's 1.5/*.blp (apt's 0.12.0 fails)

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

say "1/3 System packages (apt — needs sudo)"
# GTK4 + libadwaita dev (chrome), Ghostty GTK build tools (blueprint-compiler, gettext),
# remote/aux deps (webkitgtk, libsecret, libnotify), and Xvfb for headless runs.
# NOTE: do NOT use apt's blueprint-compiler — Ubuntu 24.04 ships 0.12.0, which is too old
# for Ghostty's `.blp` files (they use `template $Class: Adw.Bin` syntax). We install a
# newer one from source below (verified: v0.16.0 compiles them).
APT_PKGS=(
  build-essential pkg-config git curl xvfb gettext
  libgtk-4-dev libadwaita-1-dev
  libwebkitgtk-6.0-dev libsecret-1-dev libnotify-dev
)
if command -v apt-get >/dev/null; then
  echo "sudo apt-get install -y ${APT_PKGS[*]}"
  sudo apt-get update && sudo apt-get install -y "${APT_PKGS[@]}" || \
    echo "WARN: apt step failed/skipped — install the above manually."
else
  echo "Non-apt distro: install equivalents of: ${APT_PKGS[*]}"
fi

say "1b/3 blueprint-compiler ${BLUEPRINT_VERSION} from source (Ghostty needs > distro's 0.12.0)"
# Run-from-source: no meson/install needed; symlink the entry point onto PATH.
BP_DIR="$HOME/.local/blueprint-compiler"
if [ ! -d "$BP_DIR/.git" ]; then
  git clone --quiet https://gitlab.gnome.org/jwestman/blueprint-compiler.git "$BP_DIR"
fi
git -C "$BP_DIR" checkout -q "v${BLUEPRINT_VERSION}"
ln -sf "$BP_DIR/blueprint-compiler.py" "$HOME/.local/bin/blueprint-compiler"
echo "blueprint-compiler: $("$HOME/.local/bin/blueprint-compiler" --version) (from $BP_DIR @ v${BLUEPRINT_VERSION})"

say "2/3 Zig ${ZIG_VERSION} (user-local, no root)"
if ! "$HOME/.local/zig-${ZIG_VERSION}/zig" version 2>/dev/null | grep -q "${ZIG_VERSION}"; then
  curl -fsSL -o /tmp/zig.tar.xz \
    "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz"
  mkdir -p "$HOME/.local/zig-${ZIG_VERSION}"
  tar -xf /tmp/zig.tar.xz -C "$HOME/.local/zig-${ZIG_VERSION}" --strip-components=1
fi
echo "zig: $("$HOME/.local/zig-${ZIG_VERSION}/zig" version)"

say "3/3 Swift (user-local via swiftly, no root)"
if ! "$HOME/.local/bin/swiftly" --version >/dev/null 2>&1; then
  curl -fsSL -o /tmp/swiftly.tar.gz "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
  mkdir -p /tmp/swiftly-bin && tar -xf /tmp/swiftly.tar.gz -C /tmp/swiftly-bin
  SWIFTLY_HOME_DIR="$HOME/.local/swiftly" SWIFTLY_BIN_DIR="$HOME/.local/bin" \
    /tmp/swiftly-bin/swiftly init --assume-yes --skip-install --quiet-shell-followup
fi
"$HOME/.local/bin/swiftly" install "${SWIFT_CHANNEL}" --assume-yes || true

cat <<EOF

Done. Add the toolchains to your PATH (and persist in your shell rc):

  export PATH="\$HOME/.local/zig-${ZIG_VERSION}:\$HOME/.local/bin:\$PATH"
  # swiftly's 'swift' proxy resolves the active toolchain; or use the toolchain bin directly:
  #   \$HOME/.local/share/swiftly/toolchains/<ver>/usr/bin

Then build the native toolchains insanitty links against (both into vendor/, durable):
  scripts/build-ghostty.sh   # libghostty-gtk + libghostty-vt + the embedding header
  scripts/build-msquic.sh    # msquic (in-process QUIC for the remote workspace)
  scripts/build-app.sh       # the app itself
EOF
