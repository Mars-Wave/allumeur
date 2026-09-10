#!/usr/bin/env bash
#==============================================================================================
# deploy.sh - reproducible deployer for the Allumeur homelab suite.
#
# DEFINING PROPERTY: it deploys by SYMLINKING repo files into their live/prod locations, so
# that editing a file where it runs edits the repo working tree. Prod changes become
# git-aware: `git -C <repo> status` shows the drift and you can commit/push a new version
# straight from an edit made in production.
#
#----------------------------------------------------------------------------------------------
# WHAT GETS LINKED (full rationale in the header comments of this file and lib-deploy.sh)
#   CLI tools   $CLI_DIR/{nodes,tunnel,keys,lib,help,subtitle-helper}.sh  and  tests/
#               -> <repo>/scripts/*    (per-FILE, so encrypted/ and binaries/ stay REAL)
#   backend     $OPT/backend/{src,Cargo.toml,Cargo.lock} -> <repo>/backend/*
#               $OPT/backend/target/   stays a REAL, writable dir (holds the built binary;
#                                      NOT tracked, NOT in the repo - never symlinked)
#   public      $OPT/public            -> <repo>/public
#   systemd     /etc/systemd/system/allumeur.service -> <repo>/systemd/allumeur.service
#   aliases     managed block in ~/.bashrc; fixes the broken `lights` alias
#
# NEVER TOUCHED (cryptographed storage): $CLI_DIR/encrypted/* and $OPT/certs/* are real and
# stay in place. Every destructive primitive calls guard_not_protected() first; the whole run
# aborts if any destination resolves inside those trees. Their contents are never read.
#
# SECURITY POSTURE: the backend binds :443 directly and its API is UNAUTHENTICATED (an RCE was
# found and fixed, but there is still no auth in front). It MUST stay LAN/tailnet-only - never
# expose :443 to the public internet or any cloudflare tunnel / tailscale funnel. Every deploy
# prints a banner (warn_api_unauthenticated) after enable/start restating this.
#
# See lib-deploy.sh's "HARD-WON LESSONS" block for the target-specific traps this deployer
# encodes: Dropbear (no scp/sftp -> ssh tar-pipes, trailing --exclude ignored), git dubious-
# ownership as root, root-owned target/ after a containerised build, and the no-compile-on-
# the-disk-starved-server rule.
#
#----------------------------------------------------------------------------------------------
# MODES
#   bootstrap   brand-new Ubuntu/Debian box: install prereqs, lay down an EMPTY non-secret
#               data store, generate fresh certs, link everything, enable+start the service.
#   update      existing remote: refresh symlinks + (re)ship the binary + daemon-reload.
#               NEVER creates/overwrites encrypted/ or certs/.
#   doctor      read-only: report which live paths are linked / drifted / missing + git status.
#   Sub-steps (advanced): prereqs | link | binary | aliases | certs | cloudflared
#
# BUILD (respect "NEVER compile Rust on the disk-starved server")
#   --build=copy   (default) install a PREBUILT binary (--binary=PATH, or the repo's
#                  target/x86_64-unknown-linux-musl/release/allumeur-backend)
#   --build=local  cross-build a STATIC musl binary in a container (rustls + ring, no dynamic
#                  OpenSSL/glibc), then install/ship it. One artifact runs on any x86_64 Linux,
#                  so the target needs no toolchain and no matching system libraries.
#   --build=here   in-place cargo build (capable machines only; refuses on low disk)
#
#   --remote=user@host  build here, ship ONLY the finished binary to that host with `scp -O`
#                       (rename-in-place over the running binary + restart; never builds on the
#                       box). Symlinks/aliases/unit are managed by running `update` ON that box.
#
#----------------------------------------------------------------------------------------------
# USAGE
#   deploy.sh <bootstrap|update|doctor|prereqs|link|binary|aliases|certs|cloudflared> [options]
#
#   --repo=PATH          git working tree to link FROM (default: parent of this script's dir)
#   --opt=PATH           live /opt prefix for backend/public/certs (default: /opt/allumeur)
#                        (changing it needs a backend rebuild - paths are compiled into main.rs)
#   --cli-dir=PATH       live CLI dir (default: $HOME/.allumeur-scripts)
#   --build=copy|local|here     binary strategy (default: copy)
#   --binary=PATH        prebuilt binary for --build=copy
#   --build-image=IMG    container image for --build=local (default: messense/rust-musl-cross:x86_64-musl)
#   --remote=user@host   ship binary over ssh instead of installing locally
#   --domain=NAME        domain for the self-signed cert; the web UI is served at
#                        <hostname>.<domain> (e.g. host 'streetlamp' + 'lan' => streetlamp.lan).
#                        Also read from $SITE_DOMAIN; prompted interactively if neither is set.
#   --with-build-deps    also apt-install build-essential/pkg-config/libssl-dev
#   --skip-prereqs       don't touch apt
#   --skip-tailscale     don't install/ensure tailscale
#   --skip-cloudflared   don't download cloudflared now ('tunnel' fetches it on demand)
#   --skip-tests         don't run the pre-deploy test gate
#   --dry-run            print every action, change nothing
#   -h | --help          this help
#
# EXAMPLES
#   sudo ./deploy.sh bootstrap                          # fresh box, prebuilt binary in repo
#   sudo ./deploy.sh update                             # refresh links + reship binary + reload
#   ./deploy.sh update --build=local                    # container-build then install locally
#   ./deploy.sh update --build=local --remote=root@HOST   # build in a container here, ship the binary there
#   ./deploy.sh doctor                                  # what's linked / drifted
#   ./deploy.sh update --dry-run                        # preview
#==============================================================================================

set -euo pipefail

# Resolve our own location so the repo default and the helper library are found regardless of
# where the script is invoked from.
SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname -- "$SELF")"
# The repo is the parent of deploy/ by default (deploy.sh lives at <repo>/deploy/deploy.sh).
DEFAULT_REPO="$(dirname -- "$SELF_DIR")"

# ── defaults (overridable by flags) ──────────────────────────────────────────
REPO="$DEFAULT_REPO"
OPT="/opt/allumeur"
CLI_DIR="${HOME:-/root}/.allumeur-scripts"
BUILD_MODE="copy"
BINARY=""
BUILD_IMAGE="messense/rust-musl-cross:x86_64-musl"
REMOTE=""
WANT_BUILD_DEPS=0
SKIP_PREREQS=0
SKIP_TESTS=0
DRY_RUN=0
RESTORE_TARBALL=""      # --restore=PATH: lay real secrets/data before the create-only steps
TAILSCALE_UP=0          # --tailscale-up: log tailscale in if not already connected
SKIP_TAILSCALE=0        # --skip-tailscale: don't install/ensure tailscale at all
SKIP_CLOUDFLARED=0      # --skip-cloudflared: don't download cloudflared (fetch on demand later)
MIN_BUILD_KB="${MIN_BUILD_KB:-2000000}"   # < ~2GB free => refuse an in-place build
export MIN_BUILD_KB

usage() { sed -n '2,90p' "$SELF" | sed 's/^# \{0,1\}//; s/^#$//'; }

# ── argument parsing ─────────────────────────────────────────────────────────
[ $# -ge 1 ] || { usage; exit 1; }
CMD="$1"; shift || true
case "$CMD" in -h|--help|help) usage; exit 0 ;; esac

for arg in "$@"; do
    case "$arg" in
        --repo=*)        REPO="${arg#*=}" ;;
        --opt=*)         OPT="${arg#*=}" ;;
        --cli-dir=*)     CLI_DIR="${arg#*=}" ;;
        --build=*)       BUILD_MODE="${arg#*=}" ;;
        --binary=*)      BINARY="${arg#*=}" ;;
        --build-image=*) BUILD_IMAGE="${arg#*=}" ;;
        --remote=*)      REMOTE="${arg#*=}" ;;
        --domain=*)      export SITE_DOMAIN="${arg#*=}" ;;
        --with-build-deps) WANT_BUILD_DEPS=1 ;;
        --skip-prereqs)  SKIP_PREREQS=1 ;;
        --skip-tests)    SKIP_TESTS=1 ;;
        --restore=*)     RESTORE_TARBALL="${arg#*=}" ;;
        --tailscale-up)  TAILSCALE_UP=1 ;;
        --skip-tailscale) SKIP_TAILSCALE=1 ;;
        --skip-cloudflared) SKIP_CLOUDFLARED=1 ;;
        --dry-run)       DRY_RUN=1 ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "unknown option: $arg" >&2; usage; exit 1 ;;
    esac
done

# Normalise REPO to an absolute path (may be a relative arg).
REPO="$(realpath -m -- "$REPO")"

# Derived live paths.
ENCRYPTED_DIR="$CLI_DIR/encrypted"
CERTS_DIR="$OPT/certs"
SYSTEMD_UNIT_DEST="/etc/systemd/system/allumeur.service"
BASHRC="${HOME:-/root}/.bashrc"

# The crypto safety rail: every destructive primitive refuses to touch these trees.
PROTECTED_DIRS=("$ENCRYPTED_DIR" "$CERTS_DIR")

export DRY_RUN REPO OPT CLI_DIR ENCRYPTED_DIR CERTS_DIR SYSTEMD_UNIT_DEST BASHRC BUILD_MODE \
       BINARY BUILD_IMAGE REMOTE WANT_BUILD_DEPS SKIP_TESTS \
       RESTORE_TARBALL TAILSCALE_UP SKIP_TAILSCALE SKIP_CLOUDFLARED

# shellcheck source=lib-deploy.sh
. "$SELF_DIR/lib-deploy.sh"

# ── banner ───────────────────────────────────────────────────────────────────
printf '%s\n' "Allumeur deployer - command: $CMD" >&2
log "repo    : $REPO"
log "opt     : $OPT"
log "cli-dir : $CLI_DIR"
log "build   : $BUILD_MODE${REMOTE:+  (remote: $REMOTE)}"
[ "$DRY_RUN" = 1 ] && warn "DRY-RUN: no changes will be made"
log "protected (never touched): ${PROTECTED_DIRS[*]}"

# ── orchestration ────────────────────────────────────────────────────────────
do_bootstrap() {
    validate_repo
    [ "$SKIP_PREREQS" = 1 ] && warn "skipping prereqs (--skip-prereqs)" || install_prereqs
    ensure_tailscale                # ensure-only: never re-auths an already-connected node
    restore_state                   # --restore=PATH: real secrets/data BEFORE create-only steps
    init_empty_data_store           # create-only: no-ops anything restore_state already laid down
    gen_certs_if_absent
    fetch_cloudflared
    ensure_registry
    run_test_gate
    link_all
    link_systemd_unit
    wire_aliases
    deploy_binary
    service_enable_start
    printf '\n' >&2
    ok "bootstrap complete. Open a new shell (aliases) and check: systemctl status allumeur"
    [ -d "$REPO/.git" ] || warn "run: git -C $REPO init && git add -A && git commit  - to make prod edits diffable"
}

do_update() {
    validate_repo
    [ "$SKIP_PREREQS" = 1 ] || { [ "$WANT_BUILD_DEPS" = 1 ] && install_prereqs; }
    # In update mode we NEVER init the data store and NEVER overwrite certs; we only create
    # certs if the box somehow has none (create-only guard inside).
    gen_certs_if_absent
    fetch_cloudflared
    ensure_registry
    run_test_gate
    link_all
    link_systemd_unit
    wire_aliases
    deploy_binary
    service_reload_restart
    printf '\n' >&2
    ok "update complete."
    if [ -d "$REPO/.git" ] && command -v git >/dev/null 2>&1; then
        log "prod edits now show as git drift:"
        git -C "$REPO" status --short >&2 || true
    fi
}

case "$CMD" in
    bootstrap)   do_bootstrap ;;
    update)      do_update ;;
    doctor)      doctor ;;
    prereqs)     install_prereqs ;;
    link)        validate_repo; run_test_gate; link_all; link_systemd_unit ;;
    aliases)     wire_aliases ;;
    certs)       gen_certs_if_absent ;;
    cloudflared) fetch_cloudflared ;;
    build)       case "$BUILD_MODE" in here) build_here ;; *) build_local ;; esac
                 ok "built: $BINARY" ;;
    binary)      deploy_binary; [ -z "$REMOTE" ] && service_reload_restart || true ;;
    *) echo "unknown command: $CMD" >&2; usage; exit 1 ;;
esac
