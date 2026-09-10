#!/usr/bin/env bash
#==============================================================================
# make-tarball.sh - assemble the portable release tarball.
#
# The tarball is a self-contained copy of the suite (portable shell + a prebuilt
# static musl backend binary) that get.sh downloads and hands to install.sh, so
# a homelabber needs no git clone, no Rust toolchain, and no docker.
#
# USAGE
#   make-tarball.sh [--binary=PATH] [--outdir=DIR] [--name=NAME]
#
#   --binary=PATH  static backend binary to bundle
#                  (default: <repo>/backend/target/x86_64-unknown-linux-musl/release/allumeur-backend)
#   --outdir=DIR   output dir (default: <repo>/dist)
#   --name=NAME    output filename (default: allumeur-x86_64-linux.tar.gz)
#
# The archive unpacks to a single top-level dir 'allumeur/'.
#==============================================================================
set -euo pipefail

SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
REPO="$(cd "$(dirname -- "$SELF")/.." && pwd)"

BINARY=""
OUTDIR="$REPO/dist"
NAME="allumeur-x86_64-linux.tar.gz"
for a in "$@"; do case "$a" in
    --binary=*) BINARY="${a#*=}" ;;
    --outdir=*) OUTDIR="${a#*=}" ;;
    --name=*)   NAME="${a#*=}" ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
esac; done

: "${BINARY:=$REPO/backend/target/x86_64-unknown-linux-musl/release/allumeur-backend}"
[ -f "$BINARY" ] || { echo "FATAL: backend binary not found at $BINARY (build it first)" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/allumeur"
mkdir -p "$ROOT"

echo ":: staging suite tree"
for d in scripts deploy public systemd packaging; do
    cp -a "$REPO/$d" "$ROOT/"
done
cp -a "$REPO/install.sh" "$REPO/README.md" "$REPO/LICENSE.md" "$ROOT/"
mkdir -p "$ROOT/backend/src"
cp -a "$REPO/backend/src/." "$ROOT/backend/src/"
cp -a "$REPO/backend/Cargo.toml" "$REPO/backend/Cargo.lock" "$ROOT/backend/"
mkdir -p "$ROOT/backend/target/release"
install -m 0755 "$BINARY" "$ROOT/backend/target/release/allumeur-backend"
rm -rf "$ROOT/dist"

echo ":: normalising permissions"
find "$ROOT" -type d -exec chmod 0755 {} +
find "$ROOT" -type f -exec chmod 0644 {} +
find "$ROOT" -type f -name '*.sh' -exec chmod 0755 {} +
chmod 0755 "$ROOT/install.sh" "$ROOT/backend/target/release/allumeur-backend"

mkdir -p "$OUTDIR"
OUT="$OUTDIR/$NAME"
echo ":: writing $OUT"
tar -C "$STAGE" -czf "$OUT" allumeur
echo "built: $OUT ($(du -h "$OUT" | cut -f1))"
