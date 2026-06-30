#!/usr/bin/env bash
# Package insanitty into an installable .rpm (Fedora/openSUSE-style FHS layout under /usr), mirroring
# build-deb.sh. Needs rpmbuild (Fedora: rpm-build; Debian/Ubuntu: apt-get install rpm). The app is
# built with an install rpath of /usr/lib/insanitty, and a /usr/bin wrapper points Ghostty at its
# bundled resources.
#
# Env: GHOSTTY, MSQUIC, HELPER, VERSION, ARCH.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib-package.sh

command -v rpmbuild >/dev/null || { echo "rpmbuild not found — install it (Fedora: rpm-build, Debian/Ubuntu: rpm)"; exit 1; }

PKG=insanitty
VERSION="${VERSION:-0.1.0~dev}"
RPMVER="$(printf '%s' "$VERSION" | tr '~-' '..')"   # rpm versions can't contain ~ or -
ARCH="${ARCH:-$(uname -m)}"
pkg_resolve_inputs
say() { printf '\n== %s ==\n' "$*"; }

pkg_check_inputs

say "1/4 Build the app with install rpath (/usr/lib/$PKG)"
RPATH="/usr/lib/$PKG" MQRPATH="/usr/lib/$PKG" ./scripts/build-app.sh

say "2/4 Stage the FHS tree"
TOP="$PWD/build/rpm"
STAGE="$TOP/stage"
rm -rf "$STAGE"
stage_payload "$STAGE/usr/bin" "$STAGE/usr/lib/$PKG" "$STAGE/usr/share" "$STAGE/usr/libexec" "$PKG"
install -Dm755 /dev/stdin "$STAGE/usr/bin/insanitty" <<EOF
#!/bin/sh
export GHOSTTY_RESOURCES_DIR="\${GHOSTTY_RESOURCES_DIR:-/usr/share/$PKG/ghostty}"
exec /usr/lib/$PKG/insanitty-bin "\$@"
EOF

say "3/4 Generate the spec"
mkdir -p "$TOP/SPECS" "$TOP/RPMS"
# List only what actually got staged — the remote helper (/usr/libexec) is optional (its source is
# the unbundled Fantastty tree), so don't list it in %files when it wasn't built.
FILES=""
[ -e "$STAGE/usr/bin/insanitty" ]                     && FILES+="/usr/bin/insanitty
"
[ -d "$STAGE/usr/lib/$PKG" ]                          && FILES+="/usr/lib/$PKG
"
[ -d "$STAGE/usr/libexec/$PKG" ]                      && FILES+="/usr/libexec/$PKG
"
[ -d "$STAGE/usr/share/$PKG" ]                        && FILES+="/usr/share/$PKG
"
[ -e "$STAGE/usr/share/applications/insanitty.desktop" ] && FILES+="/usr/share/applications/insanitty.desktop
"
cat > "$TOP/SPECS/$PKG.spec" <<EOF
Name:           $PKG
Version:        $RPMVER
Release:        1%{?dist}
Summary:        Terminal workspace manager (native Linux port of Fantastty)
License:        MIT
BuildArch:      $ARCH
# System libraries insanitty links against (Fedora names; rename for other distros).
Requires:       gtk4, libadwaita, webkitgtk6.0, openssl-libs, tmux
# Pre-built tree is staged outside rpmbuild; don't let it strip/mangle the bundled binaries.
%global __os_install_post %{nil}
AutoReqProv:    no

%description
insanitty is a libghostty-based terminal workspace manager: persistent
tmux-backed workspaces with tabs, splits, browser tabs, and an SSH/QUIC
remote engine.

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a %{stage}/. %{buildroot}/

%files
$FILES

%changelog
* Mon Jan 01 2024 insanitty <jesse@primeradiant.com> - $RPMVER-1
- Automated build.
EOF

say "4/4 rpmbuild"
mkdir -p dist
rpmbuild -bb \
    --define "_topdir $TOP" \
    --define "stage $STAGE" \
    --define "_build_id_links none" \
    --target "$ARCH" \
    "$TOP/SPECS/$PKG.spec"
RPM=$(find "$TOP/RPMS" -name "$PKG-$RPMVER-*.rpm" | head -1)
cp "$RPM" dist/
echo "Built dist/$(basename "$RPM")"
rpm -qip "dist/$(basename "$RPM")" 2>/dev/null | sed -n '1,12p' || true
