#!/usr/bin/env bash
#==============================================================================
# pkg-setup.sh - post-install hook shared by every native package (.deb, AUR, ...).
#
# A native package only lays the suite's FILES down under a package prefix
# (default /usr/lib/allumeur). This script then performs the one-time, on-box
# setup by driving the same deploy.sh the manual installer uses, so there is a
# single source of truth for how Allumeur is stood up.
#
# It is deliberately conservative for a package context:
#   --skip-prereqs      runtime deps are declared as package Depends, not apt'd here
#   --skip-tailscale    tailscale is optional; the admin opts in later if they want funnels
#   --skip-cloudflared  no ~39MB download during package install; fetched best-effort after
#   --skip-tests        the test gate guards manual installs over live scripts, not a fresh box
#   --domain=local      non-interactive default CN (<hostname>.local); override with ALLUMEUR_DOMAIN
#
# It NEVER overwrites an existing encrypted data store or TLS cert (deploy.sh's
# steps are all create-only / left-untouched-if-present), so re-running it on an
# upgrade is safe.
#==============================================================================
set -euo pipefail

PREFIX="${ALLUMEUR_PREFIX:-/usr/lib/allumeur}"
DEPLOY="$PREFIX/deploy/deploy.sh"
BINARY="$PREFIX/backend/target/release/allumeur-backend"
DOMAIN="${ALLUMEUR_DOMAIN:-local}"

[ -f "$DEPLOY" ] || { echo "allumeur: $DEPLOY missing - package payload incomplete" >&2; exit 1; }
[ -f "$BINARY" ] || { echo "allumeur: bundled binary $BINARY missing - package payload incomplete" >&2; exit 1; }

echo "allumeur: standing up the service from $PREFIX (domain: $DOMAIN)"
bash "$DEPLOY" bootstrap \
    --repo="$PREFIX" \
    --build=copy --binary="$BINARY" \
    --skip-prereqs --skip-tailscale --skip-cloudflared --skip-tests \
    --domain="$DOMAIN"

# Best-effort, non-fatal: fetch cloudflared so 'tunnel' works out of the box when online.
# A package install must never fail just because the network or GitHub is unreachable.
if bash "$DEPLOY" cloudflared >/dev/null 2>&1; then
    echo "allumeur: cloudflared fetched (cloudflare tunnels ready)"
else
    echo "allumeur: cloudflared not fetched (offline?). Run 'sudo $DEPLOY cloudflared' later for tunnels."
fi

cat <<EOF
allumeur: installed. The web UI + JSON API serve HTTPS on :443 (LAN/tailnet only - never expose it).
          Open a new shell for the 'nodes' / 'tunnel' / 'subtitles' / 'help' aliases.
          Check the service with:  systemctl status allumeur
EOF
