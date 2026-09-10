#!/usr/bin/env bash
#==============================================================================
# build-deb.sh - assemble a .deb for the Allumeur suite.
#
# The package lays the whole suite tree down under /usr/lib/allumeur (including a
# prebuilt static musl backend binary) and, on configure, runs the shared
# packaging/common/pkg-setup.sh which drives deploy.sh to stand the service up.
# On removal, pkg-teardown.sh stops the service and removes only what setup made,
# never the encrypted data store or the TLS certs.
#
# USAGE
#   build-deb.sh --version=1.0.0 [--binary=PATH] [--arch=amd64] [--outdir=DIR]
#
#   --binary=PATH  prebuilt static backend binary to bundle
#                  (default: <repo>/backend/target/x86_64-unknown-linux-musl/release/allumeur-backend)
#   --outdir=DIR   where to write the .deb (default: <repo>/dist)
#
# Produces:  <outdir>/allumeur_<version>_<arch>.deb
#==============================================================================
set -euo pipefail

SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
REPO="$(cd "$(dirname -- "$SELF")/../.." && pwd)"

VERSION=""
ARCH="amd64"
BINARY=""
OUTDIR="$REPO/dist"
for a in "$@"; do case "$a" in
    --version=*) VERSION="${a#*=}" ;;
    --binary=*)  BINARY="${a#*=}" ;;
    --arch=*)    ARCH="${a#*=}" ;;
    --outdir=*)  OUTDIR="${a#*=}" ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
esac; done

[ -n "$VERSION" ] || { echo "FATAL: --version is required (e.g. --version=1.0.0)" >&2; exit 1; }
: "${BINARY:=$REPO/backend/target/x86_64-unknown-linux-musl/release/allumeur-backend}"
[ -f "$BINARY" ] || { echo "FATAL: backend binary not found at $BINARY (build it first)" >&2; exit 1; }
command -v dpkg-deb >/dev/null 2>&1 || { echo "FATAL: dpkg-deb not found (install dpkg-dev)" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PREFIX="$STAGE/usr/lib/allumeur"
mkdir -p "$STAGE/DEBIAN" "$PREFIX"

echo ":: staging suite tree into /usr/lib/allumeur"
# Ship the parts the runtime needs; leave out the git metadata, build artefacts, and dist/.
for d in scripts deploy public systemd packaging; do
    cp -a "$REPO/$d" "$PREFIX/"
done
cp -a "$REPO/install.sh" "$REPO/README.md" "$REPO/LICENSE.md" "$PREFIX/"
mkdir -p "$PREFIX/backend/src"
cp -a "$REPO/backend/src/." "$PREFIX/backend/src/"
cp -a "$REPO/backend/Cargo.toml" "$REPO/backend/Cargo.lock" "$PREFIX/backend/"
# The bundled static binary at the path deploy.sh's --build=copy expects.
mkdir -p "$PREFIX/backend/target/release"
install -m 0755 "$BINARY" "$PREFIX/backend/target/release/allumeur-backend"
# Drop any local build tree that cp -a on packaging/ might not include (it won't), and any dist/.
rm -rf "$PREFIX/backend/target/x86_64-unknown-linux-musl" "$PREFIX/dist"

echo ":: normalising permissions (no group/other-writable bits)"
find "$STAGE/usr" -type d -exec chmod 0755 {} +
find "$STAGE/usr" -type f -exec chmod 0644 {} +
# Restore the executable bit on everything meant to be run directly.
find "$STAGE/usr" -type f -name '*.sh' -exec chmod 0755 {} +
chmod 0755 "$PREFIX/install.sh" "$PREFIX/backend/target/release/allumeur-backend"

INSTALLED_KB="$(du -sk "$STAGE/usr" | cut -f1)"

echo ":: writing DEBIAN/control"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: allumeur
Version: $VERSION
Section: admin
Priority: optional
Architecture: $ARCH
Depends: openssl, openssh-client, sshpass, wakeonlan, curl, jq, iputils-ping, ca-certificates, git, ncurses-bin, bsdextrautils, sudo, systemd
Maintainer: Mars-Wave <noreply@users.noreply.github.com>
Installed-Size: $INSTALLED_KB
Homepage: https://github.com/Mars-Wave/allumeur
Description: Ultra-light homelab control suite
 Wake, sleep and manage LAN machines, rotate SSH keys, open on-demand
 cloudflare/tailscale tunnels, and serve a tiny Rust web UI plus JSON API on
 :443. The backend is a static, dependency-free binary; the rest is portable
 shell. Bind it to your LAN or tailnet only - the API is unauthenticated.
EOF

echo ":: writing maintainer scripts"
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
    ALLUMEUR_PREFIX=/usr/lib/allumeur /bin/bash /usr/lib/allumeur/packaging/common/pkg-setup.sh
fi
exit 0
EOF

cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
# Only tear down on a real removal, not on the remove step of an upgrade.
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    ALLUMEUR_OPT=/opt/allumeur ALLUMEUR_CLI_DIR=/root/.allumeur-scripts \
        /bin/bash /usr/lib/allumeur/packaging/common/pkg-teardown.sh || true
fi
exit 0
EOF

cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    systemctl daemon-reload 2>/dev/null || true
fi
exit 0
EOF

chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" "$STAGE/DEBIAN/postrm"

mkdir -p "$OUTDIR"
DEB="$OUTDIR/allumeur_${VERSION}_${ARCH}.deb"
echo ":: building $DEB"
# --root-owner-group: files are owned by root:root regardless of who builds (no fakeroot needed).
dpkg-deb --root-owner-group --build "$STAGE" "$DEB" >/dev/null

echo "built: $DEB"
[ -n "${QUIET:-}" ] || dpkg-deb --info "$DEB"
