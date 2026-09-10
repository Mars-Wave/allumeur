#!/usr/bin/env bash
#==============================================================================
# pkg-teardown.sh - pre/post-remove hook shared by every native package.
#
# Stops and disables the service and removes ONLY the symlinks + copied binary
# that the setup created. It NEVER deletes the encrypted data store
# (~/.allumeur-scripts/encrypted) or the TLS certs (/opt/allumeur/certs): those
# are the crypto-protected trees and hold irreplaceable user data.
#
# Safe to run more than once; every step tolerates already-gone targets.
#==============================================================================
set -u

OPT="${ALLUMEUR_OPT:-/opt/allumeur}"
CLI_DIR="${ALLUMEUR_CLI_DIR:-${HOME:-/root}/.allumeur-scripts}"
UNIT="/etc/systemd/system/allumeur.service"

echo "allumeur: stopping and disabling the service"
systemctl stop allumeur.service    2>/dev/null || true
systemctl disable allumeur.service 2>/dev/null || true
rm -f "$UNIT"
systemctl daemon-reload 2>/dev/null || true

# Symlinks into the package tree (leaving encrypted/ and binaries/ + certs/ alone).
for l in "$OPT/public" "$OPT/backend/src" "$OPT/backend/Cargo.toml" "$OPT/backend/Cargo.lock"; do
    [ -L "$l" ] && rm -f "$l"
done
# The copied binary (a real file, not a symlink) under the otherwise-real target/ dir.
[ -f "$OPT/backend/target/release/allumeur-backend" ] && rm -f "$OPT/backend/target/release/allumeur-backend"

for f in nodes.sh tunnel.sh keys.sh lib.sh help.sh subtitle-helper.sh tests; do
    [ -L "$CLI_DIR/$f" ] && rm -f "$CLI_DIR/$f"
done

cat <<EOF
allumeur: service removed. Left in place on purpose:
          - encrypted data store: $CLI_DIR/encrypted
          - TLS certificates:     $OPT/certs
          Delete those by hand if you really want them gone.
EOF
