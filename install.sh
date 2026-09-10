#!/usr/bin/env bash
#==============================================================================
# install.sh - one command to stand up the Allumeur homelab suite, here or over ssh.
#
# MANDATORY first argument - WHERE to install:
#     this            install on THIS machine (local)
#     user@host       deploy to a REMOTE over ssh - fqdn / ip / hostname WITH a
#                     user, e.g.  root@your-server.example.com   or   root@192.0.2.50
#
# It brings up EVERYTHING the suite needs, so that after it finishes the box has
# the full feature set:
#     • apt dependencies (openssl, ssh, sshpass, wakeonlan, curl, jq, ping, git, …)
#     • the shell integration - `nodes`, `tunnel`, `subtitles`, `help` in your shell
#     • the systemd service on :443 (the web UI + JSON API)
#     • a TLS certificate - self-signed for <hostname>.<domain>, or provide your own
#     • cloudflared (quick tunnels) and tailscale (ensured present; only logs in if asked)
#
# The backend binary is NEVER built on the target (it may be disk-starved): it is a
# static musl build (rustls + ring, no dynamic libraries) cross-built in a container
# HERE and only the finished, portable binary is shipped. A LOCAL install builds it
# the same way if docker is present, or pass --binary= to skip building entirely.
#
# ONE-LINERS (run from a clone of this repo):
#     ./install.sh this                     # install on this machine
#     ./install.sh root@your-server.example.com        # deploy to that box over ssh
#
# OPTIONS (all optional)
#     --domain=NAME      cert domain; the UI is served at https://<hostname>.<domain>
#     --restore=PATH     restore secrets + data (encrypted blobs, TLS certs,
#                        .tui-fields, cloudflared) from a backup tarball this
#                        suite produced, so the box returns to an EXACT prior
#                        state instead of empty. For a remote target PATH is a
#                        local file here and is shipped over. Tailscale state is
#                        never touched.
#     --binary=PATH      install this prebuilt backend binary (skip building)
#     --build=local|here local-install build strategy when no --binary (default local)
#     --tailscale-up     run `tailscale up` if not already connected
#     --skip-tailscale   do not install / ensure tailscale
#     --skip-tests       skip the pre-deploy bash test gate
#     --dry-run          print actions, change nothing
#     -h | --help
#
# ELEVATION: privileged steps need root. If the ssh user (or you, locally) is not
# root, export ALLUMEUR_SUDO_PASS and it is fed transiently to `sudo -S` (cached
# once with `sudo -v`; never written to any file). A root target needs none.
#==============================================================================
set -euo pipefail

SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
REPO_DIR="$(dirname -- "$SELF")"
REPO_PARENT="$(dirname -- "$REPO_DIR")"
REPO_NAME="$(basename -- "$REPO_DIR")"
DEPLOY="$REPO_DIR/deploy/deploy.sh"

# tiny logger (colour only on a tty)
if [ -t 2 ]; then C_S=$'\e[1;36m'; C_OK=$'\e[32m'; C_W=$'\e[33m'; C_E=$'\e[31m'; C_R=$'\e[0m'
else C_S=''; C_OK=''; C_W=''; C_E=''; C_R=''; fi
say()  { printf '%s:: %s%s\n' "$C_S" "$*" "$C_R" >&2; }
ok()   { printf '%s   ✓ %s%s\n' "$C_OK" "$*" "$C_R" >&2; }
warn() { printf '%s   ! %s%s\n' "$C_W" "$*" "$C_R" >&2; }
die()  { printf '%s FATAL: %s%s\n' "$C_E" "$*" "$C_R" >&2; exit 1; }
helptext() { sed -n '2,50p' "$SELF" | sed 's/^# \{0,1\}//; s/^#$//'; }

TARGET="${1:-}"; shift || true
case "$TARGET" in
    -h|--help|help) helptext; exit 0 ;;
    "") helptext; die "a target is required: 'this' or user@host" ;;
esac

# ── options ───────────────────────────────────────────────────────────────
DOMAIN=""; RESTORE=""; BINARY=""; BUILD="local"; TS_UP=0; SKIP_TS=0; SKIP_TESTS=0; DRY=0
for a in "$@"; do case "$a" in
    --domain=*)       DOMAIN="${a#*=}" ;;
    --restore=*)      RESTORE="${a#*=}" ;;
    --binary=*)       BINARY="${a#*=}" ;;
    --build=*)        BUILD="${a#*=}" ;;
    --tailscale-up)   TS_UP=1 ;;
    --skip-tailscale) SKIP_TS=1 ;;
    --skip-tests)     SKIP_TESTS=1 ;;
    --dry-run)        DRY=1 ;;
    -h|--help)        helptext; exit 0 ;;
    *) die "unknown option: $a" ;;
esac; done

# option strings shared by both paths
optstr=()
[ -n "$DOMAIN" ]      && optstr+=("--domain=$DOMAIN")
[ "$TS_UP" = 1 ]      && optstr+=("--tailscale-up")
[ "$SKIP_TS" = 1 ]    && optstr+=("--skip-tailscale")
[ "$SKIP_TESTS" = 1 ] && optstr+=("--skip-tests")
[ "$DRY" = 1 ]        && optstr+=("--dry-run")

#==============================================================================
# LOCAL:  ./install.sh this
#==============================================================================
if [ "$TARGET" = "this" ]; then
    say "installing Allumeur on THIS machine"
    args=(bootstrap)
    if [ -n "$BINARY" ]; then args+=(--build=copy --binary="$BINARY")
    else args+=(--build="$BUILD"); fi
    [ -n "$RESTORE" ] && args+=(--restore="$RESTORE")
    args+=("${optstr[@]}")
    # bootstrap needs root (apt, /opt, /etc/systemd). If we already are root - or this is a
    # dry-run - just run it; otherwise elevate ourselves rather than making the user prefix sudo.
    if [ "$(id -u)" = 0 ] || [ "$DRY" = 1 ]; then
        exec bash "$DEPLOY" "${args[@]}"
    elif [ -n "${ALLUMEUR_SUDO_PASS:-}" ]; then
        say "not root - elevating with sudo (password from ALLUMEUR_SUDO_PASS, never stored)"
        exec sudo -S -p "" bash "$DEPLOY" "${args[@]}" <<<"$ALLUMEUR_SUDO_PASS"
    else
        say "not root - elevating with sudo (you may be prompted for your password)"
        exec sudo bash "$DEPLOY" "${args[@]}"
    fi
fi

#==============================================================================
# REMOTE:  ./install.sh user@host
#==============================================================================
case "$TARGET" in *@*) : ;; *) die "remote target must be user@host (e.g. root@your-server.example.com), got: $TARGET" ;; esac
RUSER="${TARGET%@*}"; RHOST="${TARGET#*@}"
[ -n "$RUSER" ] && [ -n "$RHOST" ] || die "malformed target: $TARGET"
command -v ssh >/dev/null 2>&1 || die "ssh not found on this machine"

say "deploying Allumeur to $TARGET over ssh"
[ "$DRY" = 1 ] && warn "DRY-RUN: no remote changes will be made"

# 1. connectivity + elevation model ------------------------------------------
say "checking ssh connectivity to $TARGET"
ruid="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" 'id -u' 2>/dev/null)" \
    || die "cannot ssh to $TARGET non-interactively (is the key installed? try: ssh $TARGET true)"
ok "ssh ok (remote uid=$ruid)"

# A non-root target needs a password for sudo. sudo's credential cache does NOT survive across
# separate ssh sessions, so we never rely on `sudo -v`. We also never pipe the privileged
# SCRIPT over stdin (bootstrap or a child can read that inherited stdin and eat the not-yet-run
# part of the script): the script is staged as a FILE and run with stdin </dev/null, and stdin
# carries ONLY the sudo password.
if [ "$ruid" != 0 ] && [ -z "${ALLUMEUR_SUDO_PASS:-}" ] && [ "$DRY" != 1 ]; then
    die "remote user is not root - export ALLUMEUR_SUDO_PASS so privileged steps can elevate (it is fed to sudo transiently, never stored). Or deploy as root."
fi

# remote_root_run - run the staged /tmp/allumeur-run.sh as root on the remote, with the script's
# own stdin detached (</dev/null) so nothing it runs can consume the script. Root: no sudo. Non-
# root: only the password is fed to sudo -S on stdin; the script still comes from the file.
remote_root_run() {
    if [ "$ruid" = 0 ]; then
        ssh "$TARGET" 'bash /tmp/allumeur-run.sh'
    else
        # sudo -S reads the password from the pipe; the script's own `exec </dev/null` (its first
        # line) then detaches stdin so bootstrap's children never see the pipe.
        printf '%s\n' "$ALLUMEUR_SUDO_PASS" | ssh "$TARGET" 'sudo -S -p "" bash /tmp/allumeur-run.sh'
    fi
}

# 2. build the binary HERE (never on the target) -----------------------------
# A static musl build: one artifact that runs on any x86_64 Linux, so the target needs no
# toolchain and no matching OpenSSL/glibc. The musl-cross image lands it under the musl target dir.
if [ -z "$BINARY" ]; then
    say "cross-building the static backend binary here (never on the target)"
    if [ "$DRY" = 1 ]; then warn "[dry-run] would run: $DEPLOY build --build=$BUILD"
    else bash "$DEPLOY" build --build="$BUILD"; fi
    BINARY="$REPO_DIR/backend/target/x86_64-unknown-linux-musl/release/allumeur-backend"
fi
[ "$DRY" = 1 ] || [ -f "$BINARY" ] || die "no binary at $BINARY after build"
ok "binary ready: $BINARY"

# 3. stage EVERYTHING to unprivileged /tmp on the remote (no sudo needed here) ---
# The repo goes with .git (for git-aware prod) but without the huge target/. Staging to /tmp
# as the login user means the ONE privileged pass below is all that needs root.
say "staging repo + binary${RESTORE:+ + restore} to $TARGET:/tmp"
if [ "$DRY" = 1 ]; then
    warn "[dry-run] would stage repo tarball, binary${RESTORE:+, restore tarball} into /tmp on $TARGET"
else
    tar -C "$REPO_PARENT" --exclude="$REPO_NAME/backend/target" -czf - "$REPO_NAME" \
        | ssh "$TARGET" 'cat > /tmp/allumeur-repo.tgz' || die "staging the repo failed"
    scp -O "$BINARY" "$TARGET:/tmp/allumeur-backend.staged" || die "staging the binary failed"
    if [ -n "$RESTORE" ]; then
        [ -f "$RESTORE" ] || die "restore tarball not found here: $RESTORE"
        say "  (restore tarball is $(du -h "$RESTORE" | cut -f1))"
        scp -O "$RESTORE" "$TARGET:/tmp/allumeur-restore.tgz" || die "staging the restore tarball failed"
    fi
fi
ok "staged to /tmp"

# 4. build the bootstrap arg line --------------------------------------------
rargs="bootstrap --build=copy --binary=/tmp/allumeur-backend.staged"
[ -n "$RESTORE" ]     && rargs="$rargs --restore=/tmp/allumeur-restore.tgz"
[ -n "$DOMAIN" ]      && rargs="$rargs --domain=$DOMAIN"
[ "$TS_UP" = 1 ]      && rargs="$rargs --tailscale-up"
[ "$SKIP_TS" = 1 ]    && rargs="$rargs --skip-tailscale"
[ "$SKIP_TESTS" = 1 ] && rargs="$rargs --skip-tests"
[ "$DRY" = 1 ]        && rargs="$rargs --dry-run"

# 5. ONE privileged pass on the box: unpack repo -> /opt, bootstrap, clean /tmp. The script is
# staged as a FILE (not piped) and run with stdin detached, so bootstrap reading stdin can never
# corrupt the not-yet-executed part of the script.
say "installing on $TARGET$( [ "$ruid" = 0 ] && echo " (as root)" || echo " (via sudo)")"
if [ "$DRY" = 1 ]; then
    warn "[dry-run] would, as root on $TARGET: unpack /tmp/allumeur-repo.tgz -> /opt/allumeur-suite; run deploy.sh $rargs; clean /tmp"
else
    runsh="$(mktemp)"
    cat > "$runsh" <<REMOTE
exec </dev/null
set -e
rm -rf /opt/allumeur-suite.new && mkdir -p /opt/allumeur-suite.new
tar -C /opt/allumeur-suite.new --strip-components=1 -xzf /tmp/allumeur-repo.tgz
rm -rf /opt/allumeur-suite && mv /opt/allumeur-suite.new /opt/allumeur-suite
bash /opt/allumeur-suite/deploy/deploy.sh $rargs
rm -f /tmp/allumeur-repo.tgz /tmp/allumeur-backend.staged /tmp/allumeur-restore.tgz /tmp/allumeur-run.sh
REMOTE
    scp -O "$runsh" "$TARGET:/tmp/allumeur-run.sh" >/dev/null || { rm -f "$runsh"; die "staging the run script failed"; }
    rm -f "$runsh"
    remote_root_run || die "remote install failed - see output above"
fi

# 6. verify from here ---------------------------------------------------------
if [ "$DRY" != 1 ]; then
    say "verifying the API answers on $RHOST"
    i=0
    until [ "$i" -ge 8 ]; do
        if curl -sk --max-time 4 "https://$RHOST/api/services" >/dev/null 2>&1; then
            ok "backend answering at https://$RHOST/api/services"; break
        fi
        i=$((i+1)); sleep 2
    done
    [ "$i" -ge 8 ] && warn "backend not answering yet on $RHOST - check: ssh $TARGET journalctl -u allumeur -e"
fi

say "done - Allumeur deployed to $TARGET"
