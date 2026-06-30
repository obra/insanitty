#!/usr/bin/env bash
# Sourced helper shared by build-deb.sh / build-rpm.sh / build-tarball.sh. Resolves the build inputs
# (Ghostty engine lib + resources, msquic, the remote helper) and stages the insanitty payload into
# a set of target directories, so each packager only differs in its archive format and metadata.
#
# Provides: pkg_resolve_inputs (sets ZLIB/ZSHARE/MQLIB/HELPER), pkg_check_inputs, and
# stage_payload <bindir> <libdir> <sharedir> <libexecdir> <pkg>.
# Expects the app to be built already (build/insanitty), with an rpath matching <libdir>.

pkg_resolve_inputs() {
    GHOSTTY="${GHOSTTY:-$PWD/vendor/ghostty}"
    ZLIB="$GHOSTTY/zig-out/lib"; ZSHARE="$GHOSTTY/zig-out/share/ghostty"
    MQ="${MSQUIC:-$PWD/vendor/msquic}"; MQLIB="$MQ/build/bin/Release"
    HELPER="${HELPER:-build/fantastty-helper}"; [ -x "$HELPER" ] || HELPER=/tmp/fantastty-helper
}

pkg_check_inputs() {
    [ -f "$ZLIB/libghostty-gtk.so" ] || { echo "missing libghostty-gtk.so ($ZLIB) — run scripts/build-ghostty.sh + the insanitty-lib build"; exit 1; }
    [ -f "$MQLIB/libmsquic.so" ] || { echo "missing libmsquic.so ($MQLIB) — build msquic (set MSQUIC)"; exit 1; }
}

# Copy the binary + engine lib + msquic + Ghostty resources + remote helper + shell integration +
# desktop entry into the given directories. `$ORIGIN`/install-time rpath is the caller's concern.
stage_payload() {
    local BINDIR="$1" LIBDIR="$2" SHAREDIR="$3" LIBEXECDIR="$4" PKG="$5"; local f
    install -Dm755 build/insanitty "$LIBDIR/insanitty-bin"
    for f in "$ZLIB"/libghostty-gtk.so*; do install -Dm644 "$f" "$LIBDIR/$(basename "$f")"; done
    for f in "$MQLIB"/libmsquic.so*; do [ -e "$f" ] && install -Dm644 "$f" "$LIBDIR/$(basename "$f")"; done
    mkdir -p "$SHAREDIR/$PKG"; cp -r "$ZSHARE" "$SHAREDIR/$PKG/ghostty"
    if [ -x "$HELPER" ]; then
        install -Dm755 "$HELPER" "$LIBEXECDIR/$PKG/fantastty-helper"
        for f in "$ZLIB"/libghostty-vt.so*; do [ -e "$f" ] && install -Dm644 "$f" "$LIBEXECDIR/$PKG/$(basename "$f")"; done
    fi
    install -Dm644 scripts/shell-integration/insanitty.sh "$SHAREDIR/$PKG/shell-integration/insanitty.sh"
    install -Dm644 packaging/insanitty.desktop           "$SHAREDIR/applications/insanitty.desktop"
}
