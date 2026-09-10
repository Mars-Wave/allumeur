#!/bin/sh
#==============================================================================
# get.sh - one-line installer for the Allumeur homelab suite.
#
#   curl -fsSL https://raw.githubusercontent.com/Mars-Wave/allumeur/main/packaging/get.sh | sh
#
# It downloads the latest release tarball (portable shell + a prebuilt static
# backend binary), then runs the suite's own install.sh, which elevates with
# sudo as needed and stands up dependencies, the systemd service, a TLS cert,
# and the shell integration. No git clone, no Rust toolchain, no docker.
#
# Pass options straight through, e.g.:
#   curl -fsSL .../get.sh | sh -s -- --domain=lan --skip-tailscale
#
# Env:
#   ALLUMEUR_VERSION   release tag to install (default: latest)
#==============================================================================
set -eu

REPO="Mars-Wave/allumeur"
ASSET="allumeur-x86_64-linux.tar.gz"
VERSION="${ALLUMEUR_VERSION:-latest}"

say()  { printf '\033[1;36m:: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

arch="$(uname -m 2>/dev/null || echo unknown)"
[ "$arch" = "x86_64" ] || [ "$arch" = "amd64" ] || \
    die "unsupported architecture: $arch (prebuilt binary is x86_64 only; build from source for others)"

if command -v curl >/dev/null 2>&1; then DL="curl -fSL -o"
elif command -v wget >/dev/null 2>&1; then DL="wget -O"
else die "need curl or wget"; fi
command -v tar >/dev/null 2>&1 || die "need tar"

if [ "$VERSION" = "latest" ]; then
    URL="https://github.com/$REPO/releases/latest/download/$ASSET"
else
    URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

say "downloading $ASSET ($VERSION)"
$DL "$TMP/$ASSET" "$URL" || die "download failed from $URL"

say "unpacking"
tar -C "$TMP" -xzf "$TMP/$ASSET" || die "could not unpack $ASSET"

DIR="$TMP/allumeur"
[ -f "$DIR/install.sh" ] || DIR="$(dirname "$(find "$TMP" -name install.sh -maxdepth 3 2>/dev/null | head -1)")"
[ -n "$DIR" ] && [ -f "$DIR/install.sh" ] || die "install.sh not found in the tarball"
BIN="$DIR/backend/target/release/allumeur-backend"
[ -f "$BIN" ] || die "bundled binary missing in the tarball"

say "installing on this machine (install.sh will elevate with sudo if needed)"
exec bash "$DIR/install.sh" this --binary="$BIN" "$@"
