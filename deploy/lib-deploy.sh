#!/usr/bin/env bash
# lib-deploy.sh - shared helpers for the Allumeur suite deployer (deploy.sh).
#
# This file is sourced by deploy.sh; it is not meant to be run on its own. Everything here
# is side-effect free until called, and every side-effecting action goes through run()/
# run_eval() so that --dry-run can print instead of execute.
#
# The single most important rule this library enforces is: NOTHING may move, overwrite,
# delete, symlink-over, or read the cryptographed storage. Every destructive primitive
# (link_path, backup_path) calls guard_not_protected() first, and guard_not_protected()
# aborts the whole run if the destination resolves anywhere inside encrypted/ or certs/.
#
# shellcheck shell=bash

#==============================================================================================
# HARD-WON LESSONS (deployment target: a Debian 13 (trixie) box with Dropbear ssh and a
# small root fs, Docker present). Each lesson below is enforced by REAL code elsewhere in this
# file; this block is the index so the next operator does not relearn them the hard way.
#
#   1. File transfer to the target: its sshd has no sftp-server, so a plain `scp` (SFTP mode)
#      fails - but the LEGACY scp protocol works with `scp -O`, and an `ssh` tar-pipe works
#      too. ship_binary uses `scp -O` for the single binary. BEWARE either way: the target's
#      `tar` IGNORES any `--exclude` given AFTER the path operands, so any archive we build for
#      the remote must place every `--exclude` BEFORE the paths, or filter after extraction.
#
#   2. git "dubious ownership": the repo working tree is owned by a non-root uid, but the
#      deployer runs as ROOT, so git refuses every command until the path is trusted.
#      ensure_git_safe_dir() runs `git config --global --add safe.directory <REPO>`
#      idempotently, early. We do NOT chown the repo (and NEVER chown under the protected
#      trees) - marking it safe is enough.
#
#   3. --build=local cross-builds in a container; Docker runs as ROOT, so it leaves a
#      ROOT-owned target/ inside the non-root working tree. build_local() hands ownership
#      back with a throwaway `docker run --rm ... chown -R <uid>:<gid> /src/target` so later
#      non-root git/edit steps do not hit EPERM. target/ is never protected, but the crypto
#      guard still runs before we touch it, and we chown NOTHING else.
#
#   4. NEVER compile Rust on the disk-starved server: a release build needs GBs of scratch
#      and would exhaust the ~3.5GB root. build_here() HARD-REFUSES via guard_disk_for_build
#      when free space is under MIN_BUILD_KB and points at --build=local. Do not weaken it.
#
#   5. The backend API is UNAUTHENTICATED and binds :443 directly. An RCE was found and
#      fixed, but there is still no auth in front. It must stay LAN/tailnet-only.
#      warn_api_unauthenticated() prints a prominent banner after every enable/start so the
#      operator is reminded never to expose :443 to the public internet or any tunnel/funnel.
#
#   6. Preserve, do not "improve away": the symlink/git-aware-prod behavior, the
#      guard_not_protected() crypto rail (must abort on ANY path under encrypted/ or certs/),
#      the backup-before-shadow of every displaced file, and the interactive
#      <hostname>.<domain> cert CN prompt. These are load-bearing; touch with care.
#
#   7. You cannot overwrite the RUNNING binary in place: cp/tar onto it fails with ETXTBSY
#      ("Text file busy"), and the first cut of this deployer SWALLOWED that error and still
#      exited 0, leaving the OLD binary live. ship_binary now writes a sibling `.new` file and
#      rename()s it over the target (atomic; works while the old inode runs), then restarts the
#      service to pick up the new inode - and every step aborts loudly. Build happens ONLY on a
#      workstation (the eMMC-starved box keeps exactly ONE binary and NO staged copy in the
#      repo), so a plain on-box `update` is a links-only refresh.
#==============================================================================================

# ── logging ──────────────────────────────────────────────────────────────────
# Colours only when stderr is a tty, so piping the log to a file stays clean.
if [ -t 2 ]; then
    _C_STEP=$'\e[1;36m'; _C_OK=$'\e[32m'; _C_WARN=$'\e[33m'; _C_ERR=$'\e[31m'
    _C_DIM=$'\e[2m'; _C_RST=$'\e[0m'
else
    _C_STEP=''; _C_OK=''; _C_WARN=''; _C_ERR=''; _C_DIM=''; _C_RST=''
fi

_STEP_N=0
step() { _STEP_N=$((_STEP_N + 1)); printf '%s\n==> [%02d] %s%s\n' "$_C_STEP" "$_STEP_N" "$*" "$_C_RST" >&2; }
log()  { printf '    %s\n' "$*" >&2; }
ok()   { printf '    %s✓ %s%s\n' "$_C_OK" "$*" "$_C_RST" >&2; }
warn() { printf '    %s! %s%s\n' "$_C_WARN" "$*" "$_C_RST" >&2; }
skip() { printf '    %s· %s (already in place)%s\n' "$_C_DIM" "$*" "$_C_RST" >&2; }
die()  { printf '%s\nFATAL: %s%s\n' "$_C_ERR" "$*" "$_C_RST" >&2; exit 1; }

# ── dry-run aware execution ──────────────────────────────────────────────────
# run <cmd> <args...>     - exec argv directly (no shell parsing of the args)
# run_eval '<shell line>' - exec a full shell line (pipes, redirects, globs)
# In dry-run mode both only print what they WOULD do and return success.
run() {
    if [ "${DRY_RUN:-0}" = 1 ]; then printf '    %s[dry-run] %s%s\n' "$_C_DIM" "$*" "$_C_RST" >&2; return 0; fi
    "$@"
}
run_eval() {
    if [ "${DRY_RUN:-0}" = 1 ]; then printf '    %s[dry-run] %s%s\n' "$_C_DIM" "$1" "$_C_RST" >&2; return 0; fi
    eval "$1"
}

# ── path helpers ─────────────────────────────────────────────────────────────
# Absolute, normalised path that does NOT require the target to exist (realpath -m).
abspath() { realpath -m -- "$1"; }

# is_our_link <dest> <src> - true iff <dest> is a symlink already resolving to <src>.
is_our_link() {
    [ -L "$1" ] || return 1
    [ "$(readlink -f -- "$1" 2>/dev/null)" = "$(readlink -f -- "$2" 2>/dev/null)" ]
}

# ── the crypto safety rail ───────────────────────────────────────────────────
# guard_not_protected <path> - abort the whole deploy if <path> is, or is inside, one of the
# protected trees (encrypted/ or certs/), OR if <path> is a symlink whose target lands there.
# Called by every destructive primitive. PROTECTED_DIRS is populated by deploy.sh once the
# live layout is known. This is belt-and-suspenders: we only ever hand these primitives known,
# safe destinations, but a typo or a future edit must never be able to reach the secrets.
guard_not_protected() {
    local p ap prot ap_prot rp
    p="$1"
    ap="$(abspath "$p")"
    for prot in "${PROTECTED_DIRS[@]}"; do
        ap_prot="$(abspath "$prot")"
        if [ "$ap" = "$ap_prot" ] || [[ "$ap/" == "$ap_prot/"* ]]; then
            die "REFUSING to touch protected path: $p  (== or under $prot)"
        fi
        if [ -L "$p" ]; then
            rp="$(readlink -f -- "$p" 2>/dev/null || true)"
            if [ -n "$rp" ] && { [ "$rp" = "$ap_prot" ] || [[ "$rp/" == "$ap_prot/"* ]]; }; then
                die "REFUSING: $p is a symlink resolving into protected $prot"
            fi
        fi
    done
}

# ── timestamped backup store ─────────────────────────────────────────────────
# Backups are created lazily: the directory only appears once something actually needs saving.
BACKUP_DIR=""
init_backup_dir() {
    [ -n "$BACKUP_DIR" ] && return 0
    BACKUP_DIR="${BACKUP_ROOT:-/root/allumeur-deploy-backups}/$(date +%Y%m%d-%H%M%S)"
    run mkdir -p "$BACKUP_DIR"
    log "backups for this run: $BACKUP_DIR"
}

# backup_path <path> - copy <path> (preserving mode/links/tree) into the backup store, keeping
# its absolute layout underneath. Never called for protected paths (guard runs first).
backup_path() {
    local p="$1" dest
    guard_not_protected "$p"
    init_backup_dir
    dest="$BACKUP_DIR/${p#/}"
    run mkdir -p "$(dirname "$dest")"
    run cp -a -- "$p" "$dest"
    warn "backed up existing $p -> $dest"
}

# ── the core deploy primitive ────────────────────────────────────────────────
# ensure_real_dir <dir> [mode] - make sure <dir> exists as a REAL directory. If it is
# currently a symlink (e.g. an older deploy pointed it at the repo) it is backed up and
# replaced with a real directory, because target/ and certs/ must be real and writable.
ensure_real_dir() {
    local d="$1" mode="${2:-}"
    guard_not_protected "$d"
    if [ -L "$d" ]; then
        backup_path "$d"; run rm -f -- "$d"
    fi
    if [ ! -d "$d" ]; then
        run mkdir -p -- "$d"
    fi
    [ -n "$mode" ] && run chmod "$mode" -- "$d"
    return 0
}

# link_path <src> <dest> - make <dest> a symlink to <src>, idempotently and safely.
#   * refuses if <src> does not exist (a required input is missing);
#   * if <dest> is already our symlink to <src> -> skip;
#   * if <dest> exists as a real file/dir/other symlink -> back it up, then replace;
#   * never touches anything the guard flags as protected.
link_path() {
    local src="$1" dest="$2"
    [ -e "$src" ] || [ -L "$src" ] || die "required source is missing: $src"
    guard_not_protected "$dest"
    if is_our_link "$dest" "$src"; then
        skip "$dest -> $src"
        return 0
    fi
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        backup_path "$dest"
        run rm -rf -- "$dest"
    fi
    run mkdir -p -- "$(dirname "$dest")"
    run ln -s -- "$src" "$dest"
    ok "linked $dest -> $src"
}

# ── prerequisites: package sets ──────────────────────────────────────────────
# Runtime set: everything the shell tools and the *already-built* backend need to RUN.
# Inferred from the scripts and main.rs:
#   openssl        blob AES-256-CBC/PBKDF2 crypto (lib.sh, tunnel.sh, subtitle-helper.sh,
#                  main.rs) + self-signed cert generation; also supplies the libssl.so.3 /
#                  libcrypto.so.3 the dynamically-linked backend loads at runtime.
#   openssh-client ssh / ssh-keygen / ssh-copy-id (nodes.sh, keys.sh, main.rs confirm_off)
#   sshpass        password-based key adoption (keys.sh k_adopt, nodes.sh add_node)
#   wakeonlan      WoL magic packets (keys.sh wol_blast, main.rs send_wol)
#   curl           localhost API calls + TLS origin probe (nodes.sh, tunnel.sh) + downloads
#   jq             /api/nodes JSON + tailscale status JSON (nodes.sh, tunnel.sh)
#   iputils-ping   reachability ladder + status table (everywhere)
#   ca-certificates HTTPS for curl/cloudflared downloads
#   git            the repo itself is the deploy substrate
#   ncurses-bin    tput (menus, live boards)
#   sudo           supplies visudo; the sudoers installer runs on the *nodes*, but the origin
#                  box is commonly a node too, and visudo is cheap to have present.
# NB: no `gawk` - the suite's awk usage (record/sudoers parsing) is POSIX-plain and runs on
# Debian's default `mawk` (verified on the live box, which has no gawk). We do not pull gawk in
# just to avoid an install-time divergence; add it here only if a gawk-only feature ever lands.
RUNTIME_PKGS=(openssl openssh-client sshpass wakeonlan curl jq iputils-ping ca-certificates git ncurses-bin sudo)

# Build set: only needed on a machine that actually compiles the backend. Deliberately kept
# OUT of the runtime set so the disk-starved server never pulls build-essential + headers.
#   build-essential  cc/ld for the Rust build
#   pkg-config       how the openssl crate finds the system OpenSSL
#   libssl-dev       OpenSSL headers; the backend links OpenSSL DYNAMICALLY (no rustls bloat)
BUILD_PKGS=(build-essential pkg-config libssl-dev)

# NOTE (tailscale): tunnel.sh calls `tailscale` for funnels. Tailscale is NOT in Debian main;
# it ships from pkgs.tailscale.com. We only print a reminder - installing a third-party apt
# source is a decision for the operator, and cloudflare tunnels work without it.

install_prereqs() {
    step "Installing runtime prerequisites (apt)"
    if ! command -v apt-get >/dev/null 2>&1; then
        warn "no apt-get here; skipping package install. Ensure these exist: ${RUNTIME_PKGS[*]}"
        return 0
    fi
    if [ "$(id -u)" != 0 ] && [ "${DRY_RUN:-0}" != 1 ]; then
        warn "not root: skipping apt. Re-run as root, or: sudo apt-get install -y ${RUNTIME_PKGS[*]}"
        return 0
    fi
    run_eval "DEBIAN_FRONTEND=noninteractive apt-get update"
    run_eval "DEBIAN_FRONTEND=noninteractive apt-get install -y ${RUNTIME_PKGS[*]}"
    if [ "${WANT_BUILD_DEPS:-0}" = 1 ]; then
        log "also installing build dependencies (--with-build-deps): ${BUILD_PKGS[*]}"
        run_eval "DEBIAN_FRONTEND=noninteractive apt-get install -y ${BUILD_PKGS[*]}"
    fi
    log "reminder: 'tunnel' funnels need tailscale (pkgs.tailscale.com) - not installed here."
    ok "runtime prerequisites present"
}

# ── tailscale (optional; for `tunnel` funnels) ───────────────────────────────
# ENSURE-only by design: if tailscale is already present we NEVER reinstall, restart, or
# re-authenticate it - the box may run other things over the same tailnet and logging it out
# would drop their availability. We install the package only when it is absent, and we bring
# the tunnel UP only when TAILSCALE_UP=1 AND it is not already connected. An already-connected
# node is always left exactly as it is.
ensure_tailscale() {
    if [ "${SKIP_TAILSCALE:-0}" = 1 ]; then warn "skipping tailscale (--skip-tailscale)"; return 0; fi
    step "Ensuring tailscale (optional; needed only for 'tunnel' funnels)"
    if command -v tailscale >/dev/null 2>&1; then
        skip "tailscale present ($(tailscale version 2>/dev/null | head -1)) - install left untouched"
    elif command -v apt-get >/dev/null 2>&1 && { [ "$(id -u)" = 0 ] || [ "${DRY_RUN:-0}" = 1 ]; }; then
        log "installing tailscale via the official installer (pkgs.tailscale.com)"
        run_eval "curl -fsSL https://tailscale.com/install.sh | sh" \
            || warn "tailscale install failed - cloudflare quick tunnels still work without it"
    else
        warn "tailscale absent and cannot install here (need root+apt); get it from pkgs.tailscale.com for funnels"
    fi
    if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
        skip "tailscale already connected - login left exactly as-is"
    elif [ "${TAILSCALE_UP:-0}" = 1 ]; then
        log "bringing tailscale up (may require an interactive login / auth key)"
        run tailscale up || warn "tailscale up did not complete"
    else
        log "tailscale not connected; pass --tailscale-up to log in (funnels need it)"
    fi
}

# ── restore secrets + data from a suite backup (opt-in; --restore=PATH) ───────
# Lays real encrypted blobs, TLS certs, the .tui-fields prefs and the cloudflared binary from a
# tarball this suite produced, so a freshly bootstrapped box comes back to an EXACT prior state
# instead of empty. It runs BEFORE the create-only provisioning steps (init_empty_data_store,
# gen_certs_if_absent, fetch_cloudflared), which then all no-op because the real files exist.
# Like init_empty_data_store it writes INTO the protected trees on purpose (it is the operator
# restoring their own secrets), so it uses plain cp/mkdir rather than the guarded primitives.
# TAILSCALE STATE IS NEVER TOUCHED - that is deliberately out of scope for restore.
restore_state() {
    [ -n "${RESTORE_TARBALL:-}" ] || return 0
    step "Restoring secrets + data from ${RESTORE_TARBALL}"
    [ -f "$RESTORE_TARBALL" ] || die "restore tarball not found: $RESTORE_TARBALL"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        log "[dry-run] would extract encrypted/, certs/, .tui-fields, cloudflared into place"
        return 0
    fi
    local tmp; tmp="$(mktemp -d)"
    tar -C "$tmp" -xzf "$RESTORE_TARBALL" || { rm -rf "$tmp"; die "could not unpack $RESTORE_TARBALL"; }

    local enc; enc="$(find "$tmp" -type d -name encrypted -path '*allumeur-scripts*' 2>/dev/null | head -1)"
    [ -n "$enc" ] && [ -f "$enc/usr_blob.enc" ] || { rm -rf "$tmp"; die "backup has no encrypted/ database"; }
    mkdir -p "$ENCRYPTED_DIR"; chmod 700 "$ENCRYPTED_DIR"
    cp -a "$enc/." "$ENCRYPTED_DIR/"
    ok "restored encrypted database + keys -> $ENCRYPTED_DIR"

    local crt; crt="$(find "$tmp" -type f -name cert.pem -path '*certs*' 2>/dev/null | head -1)"
    if [ -n "$crt" ]; then
        mkdir -p "$CERTS_DIR"; cp -a "$(dirname "$crt")/." "$CERTS_DIR/"
        [ -f "$CERTS_DIR/key.pem" ] && chmod 600 "$CERTS_DIR/key.pem"
        ok "restored TLS keypair -> $CERTS_DIR"
    fi

    local tf; tf="$(find "$tmp" -name .tui-fields 2>/dev/null | head -1)"
    [ -n "$tf" ] && { cp -a "$tf" "$CLI_DIR/.tui-fields"; ok "restored .tui-fields prefs"; }

    local cf; cf="$(find "$tmp" -type f -name cloudflared 2>/dev/null | head -1)"
    if [ -n "$cf" ]; then
        mkdir -p "$CLI_DIR/binaries"; cp -a "$cf" "$CLI_DIR/binaries/cloudflared"; chmod +x "$CLI_DIR/binaries/cloudflared"
        ok "restored cloudflared binary"
    fi
    rm -rf "$tmp"
    ok "restore complete (tailscale state intentionally untouched)"
}

# ── cloudflared (vendored 39MB binary, downloaded, never committed) ──────────
fetch_cloudflared() {
    step "Ensuring cloudflared binary"
    local dest="$CLI_DIR/binaries/cloudflared"
    if [ "${SKIP_CLOUDFLARED:-0}" = 1 ]; then
        warn "skipping cloudflared download (--skip-cloudflared); cloudflare tunnels stay unavailable until you run: deploy.sh cloudflared"
        return 0
    fi
    ensure_real_dir "$CLI_DIR/binaries"
    if [ -x "$dest" ]; then
        skip "$dest"
        return 0
    fi
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    log "downloading cloudflared (~39MB) from $url"
    run curl -fL --retry 3 --connect-timeout 15 -o "$dest" "$url" \
        || die "cloudflared download failed (check network); it is required by 'tunnel'"
    run chmod +x "$dest"
    ok "cloudflared -> $dest"
}

# ── self-signed TLS cert (create-only; NEVER overwrites an existing keypair) ──
gen_certs_if_absent() {
    step "Ensuring TLS certificate at $CERTS_DIR"
    # NB: certs/ is a REAL directory and is NEVER symlinked. We create the directory if the
    # box is brand new, but we never write over an existing cert or key.
    run mkdir -p "$CERTS_DIR"
    if [ -f "$CERTS_DIR/cert.pem" ] && [ -f "$CERTS_DIR/key.pem" ]; then
        skip "existing cert.pem + key.pem (left untouched)"
        return 0
    fi
    if [ -f "$CERTS_DIR/cert.pem" ] || [ -f "$CERTS_DIR/key.pem" ]; then
        die "only one of cert.pem/key.pem exists in $CERTS_DIR - refusing to generate over a half-present keypair"
    fi
    # The web UI is served at  <hostname>.<domain> . This machine's hostname is the
    # "website name"; you supply the domain, and together they form the cert CN/SAN.
    # e.g. a host named 'streetlamp' with domain 'lan' is reachable at https://streetlamp.lan
    local host_name; host_name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo localhost)"
    local domain="${SITE_DOMAIN:-}"
    if [ -z "$domain" ]; then
        if [ -t 0 ] && [ "${DRY_RUN:-0}" != 1 ]; then
            printf '%s\n' "This node's hostname is '${host_name}' - it becomes the website name." >&2
            printf '%s' "Domain to append (web UI will be https://${host_name}.<domain>, e.g. ${host_name}.streetlamp): " >&2
            read -r domain
        fi
        domain="${domain:-local}"   # non-interactive / dry-run fallback
    fi
    local CERT_CN="${host_name}.${domain}"
    log "no certs present: generating a self-signed 10-year cert for https://${CERT_CN} (CN=$CERT_CN)"
    run_eval "openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout '$CERTS_DIR/key.pem' -out '$CERTS_DIR/cert.pem' \
        -subj '/CN=$CERT_CN' -addext 'subjectAltName=DNS:$CERT_CN,DNS:localhost,IP:127.0.0.1'"
    run chmod 600 "$CERTS_DIR/key.pem"
    run chmod 644 "$CERTS_DIR/cert.pem"
    ok "generated self-signed cert in $CERTS_DIR"
}

# ── runtime registry dir the tunnel CLI expects ──────────────────────────────
ensure_registry() {
    step "Ensuring tunnel registry dir /tmp/allumeur_tunnels"
    run mkdir -p /tmp/allumeur_tunnels
    ok "/tmp/allumeur_tunnels ready"
}

# ── disk guard for in-place builds ───────────────────────────────────────────
guard_disk_for_build() {
    local dir="$1" kb mnt
    kb=$(df -Pk "$dir" 2>/dev/null | awk 'NR==2{print $4}')
    mnt=$(df -Pk "$dir" 2>/dev/null | awk 'NR==2{print $6}')
    if [ "${kb:-0}" -lt "${MIN_BUILD_KB:-2000000}" ]; then
        die "refusing an in-place cargo build: only $(( ${kb:-0} / 1024 ))MB free on ${mnt:-?} (need >= $(( ${MIN_BUILD_KB:-2000000} / 1024 ))MB). A release build needs GBs of scratch and would exhaust this disk. LESSON 4: NEVER compile Rust on this host - cross-build in a container and ship it:  deploy.sh update --build=local --remote=<user@host>   (or --build=copy --binary=<prebuilt>)."
    fi
    log "disk check ok: $(( kb / 1024 ))MB free on ${mnt}"
}

# ── ship a prebuilt binary into prod (local cp, or tar-pipe over ssh) ─────────
# The host has no sftp-server, so remote transfer is a tar pipe, exactly as the handover
# documents. Whichever running binary is present is backed up before it is replaced.
ship_binary() {
    local bin="$1"
    local destdir="$OPT/backend/target/release"
    local dest="$destdir/allumeur-backend"
    [ -f "$bin" ] || die "no binary to ship at: $bin"
    # Linkage sanity check: the binary is a static musl build (rustls + ring, no dynamic
    # OpenSSL), so it must have NO dynamic dependencies and run on any x86_64 Linux. `ldd`
    # reports "not a dynamic executable" / "statically linked" for a good build; a dynamic
    # binary here would mean the musl cross-build did not take.
    if command -v ldd >/dev/null 2>&1 && [ "${DRY_RUN:-0}" != 1 ]; then
        if ldd "$bin" 2>&1 | grep -qiE 'statically linked|not a dynamic executable'; then
            log "ldd: static binary (no dynamic deps, portable across distros) - expected"
        else
            warn "ldd shows dynamic dependencies - the musl static build may not have taken; verify before trusting this binary"
        fi
    fi

    if [ -n "${REMOTE:-}" ]; then
        # LESSON 1 + 7: ship the ONE finished binary with `scp -O` (legacy protocol; plain
        # scp/sftp is unavailable on the target). You cannot land it directly onto the running
        # ExecStart path - that is ETXTBSY - so scp to a sibling ".new", then on the box back
        # up the current binary, rename() the new one over it (atomic; safe while the old inode
        # runs), and restart so the new inode takes over. Every step aborts loudly on failure.
        step "Shipping binary to $REMOTE:$dest (scp -O, rename-in-place, restart)"
        run_eval "ssh '$REMOTE' 'mkdir -p \"$destdir\"'" || die "could not create $destdir on $REMOTE"
        run_eval "scp -O '$bin' '$REMOTE:$dest.new'" || die "scp -O of the binary to $REMOTE failed (is the key installed?)"
        run_eval "ssh '$REMOTE' 'set -e; d=\"$destdir\"; b=/root/allumeur-backups/\$(date +%Y%m%d-%H%M%S); mkdir -p \"\$b\"; [ -f \"\$d/allumeur-backend\" ] && cp -a \"\$d/allumeur-backend\" \"\$b/\"; chmod +x \"\$d/allumeur-backend.new\"; mv -f \"\$d/allumeur-backend.new\" \"\$d/allumeur-backend\"; systemctl try-restart allumeur.service 2>/dev/null || true'" \
            || die "remote install/restart of the binary failed on $REMOTE"
        ok "binary shipped + installed on $REMOTE (previous binary backed up under /root/allumeur-backups)"
    else
        # LESSON 7: cp OVER the running binary is ETXTBSY. Stage a sibling ".new" and rename()
        # it into place; the caller's service restart applies the new inode. Fail loudly.
        step "Installing binary into $destdir (local, rename-in-place)"
        ensure_real_dir "$destdir"
        if [ -f "$dest" ]; then
            init_backup_dir
            run cp -a "$dest" "$BACKUP_DIR/allumeur-backend" || die "could not back up the running binary"
            warn "backed up running binary -> $BACKUP_DIR/allumeur-backend"
        fi
        run cp -a "$bin" "$dest.new"  || die "could not stage the new binary at $dest.new"
        run chmod +x "$dest.new"
        run mv -f "$dest.new" "$dest" || die "could not rename the new binary into place ($destdir writable?)"
        ok "binary installed at $dest (rename-in-place; a service restart applies it)"
    fi
}

# ── build strategies ─────────────────────────────────────────────────────────
# build_local: containerised cross-build that produces a STATIC musl binary (rustls + ring,
# no dynamic OpenSSL), so ONE artifact runs on any x86_64 Linux regardless of the target's
# glibc/openssl. The musl-cross image sets CARGO_BUILD_TARGET=x86_64-unknown-linux-musl, so a
# plain `cargo build --release` lands the binary under target/x86_64-unknown-linux-musl/. Sets BINARY.
MUSL_TARGET="x86_64-unknown-linux-musl"
build_local() {
    step "Cross-building a static musl backend in ${BUILD_IMAGE}"
    command -v docker >/dev/null 2>&1 \
        || die "docker not found. Install Docker on the build machine, or build the static binary elsewhere and pass --build=copy --binary=<path>."
    run docker run --rm \
        -v "$REPO/backend":/src -w /src \
        "${BUILD_IMAGE}" \
        cargo build --release
    # LESSON 3: Docker ran as root, so target/ is now ROOT-owned inside a non-root working
    # tree. Hand it back to the repo owner with a throwaway container, or later non-root git
    # and edit operations on target/ fail with EPERM. target/ is not a protected tree, but we
    # still run the crypto guard before touching it, and we chown NOTHING else.
    local tdir="$REPO/backend/target" owner
    guard_not_protected "$tdir"
    if [ -d "$tdir" ]; then
        owner="$(stat -c '%u:%g' "$REPO/backend" 2>/dev/null || echo 0:0)"
        if [ "$owner" != "0:0" ]; then
            run docker run --rm -v "$REPO/backend":/src busybox \
                chown -R "$owner" /src/target \
                || warn "could not restore ownership of $tdir to $owner (try: sudo chown -R $owner $tdir)"
            ok "restored ownership of target/ to $owner"
        fi
    fi
    BINARY="$REPO/backend/target/$MUSL_TARGET/release/allumeur-backend"
    ok "container build produced $BINARY"
}

# build_here: in-place cargo build. Only for a machine with disk to spare - guarded HARD.
# LESSON 4: this must NEVER run on the disk-starved server (~3.5GB root). guard_disk_for_build
# hard-refuses below MIN_BUILD_KB and points at --build=local; do not weaken that rail.
build_here() {
    step "Building backend in place (cargo build --release)"
    warn "in-place build requested - refused on low-disk hosts (LESSON 4); the server must use --build=local and ship the binary."
    guard_disk_for_build "$REPO/backend"
    command -v cargo >/dev/null 2>&1 \
        || die "cargo not installed. Install it (--with-build-deps plus rustup/cargo) or use --build=local."
    run_eval "cd '$REPO/backend' && cargo build --release"
    BINARY="$REPO/backend/target/release/allumeur-backend"
    ok "in-place build produced $BINARY"
}

# deploy_binary: dispatch on BUILD_MODE and hand the result to ship_binary.
deploy_binary() {
    case "${BUILD_MODE:-copy}" in
        copy|none)
            : "${BINARY:=$REPO/backend/target/x86_64-unknown-linux-musl/release/allumeur-backend}"
            if [ ! -f "$BINARY" ]; then
                # LESSON 7: the eMMC-starved box deliberately keeps NO staged binary in the repo,
                # so a plain on-box `update` has nothing to install - that's fine, it becomes a
                # links-only refresh as long as a live binary already exists. Only a fresh box
                # with no binary at all is fatal. NEVER build here to conjure one.
                if [ -z "${REMOTE:-}" ] && [ -f "$OPT/backend/target/release/allumeur-backend" ]; then
                    warn "no staged binary at $BINARY - leaving the live binary as-is (links-only update)."
                    warn "to update the binary, build+ship from a workstation: deploy.sh binary --build=local --remote=root@<host>"
                    return 0
                fi
                die "no prebuilt binary at $BINARY. Build+ship from a workstation (--build=local --remote=<host>) or pass --binary=<path>. NEVER build on this server."
            fi
            ship_binary "$BINARY" ;;
        local) build_local; ship_binary "$BINARY" ;;
        here)  build_here;  ship_binary "$BINARY" ;;
        *) die "unknown --build mode: $BUILD_MODE (want: copy|local|here)" ;;
    esac
}

# ── systemd ──────────────────────────────────────────────────────────────────
# We SYMLINK the unit into /etc/systemd/system so that editing the unit in prod edits the
# repo working tree (the whole git-aware-prod property). systemd resolves the symlink and
# re-reads the target on `daemon-reload`, so an edit followed by a reload takes effect, and
# `git status` shows the drift. `enable` then records its own wants-symlink by unit name.
link_systemd_unit() {
    step "Linking systemd unit"
    if [ -n "${REMOTE:-}" ]; then
        warn "remote mode: skipping local unit link - run 'update' ON $REMOTE for its systemd."
        return 0
    fi
    link_path "$REPO/systemd/allumeur.service" "$SYSTEMD_UNIT_DEST"
    run systemctl daemon-reload
    ok "unit linked + daemon-reloaded"
}

# ── LESSON 5: unauthenticated-API exposure banner ────────────────────────────
# The backend binds :443 directly and serves an UNAUTHENTICATED API. An RCE was found and
# fixed, but there is still NO auth in front of it, so it must stay reachable only from the
# LAN / tailnet. This banner prints after every enable/start/restart to remind the operator
# never to expose :443 to the public internet or any tunnel/funnel.
warn_api_unauthenticated() {
    local line="=========================================================================="
    printf '%s\n' "$_C_WARN" >&2
    printf '  %s\n' "$line" >&2
    printf '  %s\n' "** SECURITY: the Allumeur backend API is UNAUTHENTICATED and binds :443. **" >&2
    printf '  %s\n' "Keep it LAN / tailnet-only. Do NOT expose :443 to the public internet or" >&2
    printf '  %s\n' "ANY tunnel/funnel (cloudflared, tailscale funnel, port-forward, proxy)." >&2
    printf '  %s\n' "An RCE was found and fixed, but there is still no auth in front of it." >&2
    printf '  %s\n' "$line" >&2
    printf '%s\n' "$_C_RST" >&2
}

service_enable_start() {
    step "Enabling + starting allumeur.service"
    if [ -n "${REMOTE:-}" ]; then
        warn "remote mode: manage the service on $REMOTE"
    else
        run systemctl enable allumeur.service
        run systemctl restart allumeur.service
        health_check
    fi
    warn_api_unauthenticated      # LESSON 5: remind on every enable/start
}

service_reload_restart() {
    step "daemon-reload + restart allumeur.service"
    if [ -n "${REMOTE:-}" ]; then
        warn "remote mode: restart the service on $REMOTE"
    else
        run systemctl daemon-reload
        run systemctl restart allumeur.service
        health_check
    fi
    warn_api_unauthenticated      # LESSON 5: remind on every enable/start
}

health_check() {
    [ "${DRY_RUN:-0}" = 1 ] && { log "[dry-run] would curl https://127.0.0.1/api/services"; return 0; }
    local i
    for i in 1 2 3 4 5; do
        if curl -sk --max-time 3 https://127.0.0.1/api/services >/dev/null 2>&1; then
            ok "backend answering on https://127.0.0.1/api/services"
            return 0
        fi
        sleep 1
    done
    warn "backend did not answer /api/services yet - check: journalctl -u allumeur -e"
}

# ── managed .bashrc aliases ──────────────────────────────────────────────────
# Idempotent managed block between markers, plus a FIX for the broken `lights` alias: the old
# alias pointed at a missing lights.sh; 'hit lights' is really a submenu of `nodes`, so we
# point `lights` at nodes.sh (valid) and neutralise any stale unmanaged alias lines for our
# names so the managed block is authoritative.
BASHRC_BEGIN="# >>> allumeur suite (managed by deploy.sh) >>>"
BASHRC_END="# <<< allumeur suite (managed by deploy.sh) <<<"

wire_aliases() {
    step "Wiring shell aliases into $BASHRC"
    [ -n "${REMOTE:-}" ] && { warn "remote mode: wire aliases on $REMOTE"; return 0; }
    local block
    block="$BASHRC_BEGIN
alias nodes='$CLI_DIR/nodes.sh'
alias tunnel='$CLI_DIR/tunnel.sh'
alias subtitles='$CLI_DIR/subtitle-helper.sh'
alias help='$CLI_DIR/help.sh'
# 'lights' formerly pointed at a missing lights.sh; 'hit lights' is a submenu of nodes.
alias lights='$CLI_DIR/nodes.sh'
$BASHRC_END"

    if [ "${DRY_RUN:-0}" = 1 ]; then
        log "[dry-run] would (re)write managed alias block in $BASHRC and comment stale nodes/tunnel/subtitles/help/lights/keys aliases"
        printf '%s\n' "$block" | sed 's/^/      /' >&2
        return 0
    fi

    [ -f "$BASHRC" ] || : > "$BASHRC"
    init_backup_dir
    cp -a "$BASHRC" "$BACKUP_DIR/bashrc.orig"

    local tmp; tmp="$(mktemp)"
    # 1) drop any previous managed block; 2) comment out stale unmanaged alias lines for the
    #    names we own (this is what removes the broken `lights` alias for good).
    awk -v b="$BASHRC_BEGIN" -v e="$BASHRC_END" '
        $0==b {inblk=1; next}
        $0==e {inblk=0; next}
        inblk {next}
        /^[[:space:]]*alias[[:space:]]+(nodes|tunnel|subtitles|help|lights|keys)=/ {
            print "# [allumeur deploy disabled] " $0; next }
        {print}
    ' "$BASHRC" > "$tmp"
    printf '%s\n' "$block" >> "$tmp"
    mv "$tmp" "$BASHRC"
    ok "managed alias block written; stale aliases neutralised; broken 'lights' fixed"
}

# ── the symlink map (scripts + backend inputs + public) ──────────────────────
# CLI tools: link each FILE/dir individually so that encrypted/ and binaries/ under
# $CLI_DIR stay REAL and untouched. Backend: keep the dir real with a real writable target/,
# and link only the tracked build inputs. public/: one dir symlink.
link_all() {
    step "Linking CLI tool scripts into $CLI_DIR (per-file; encrypted/ + binaries/ untouched)"
    ensure_real_dir "$CLI_DIR"
    local f
    for f in nodes.sh tunnel.sh keys.sh lib.sh help.sh subtitle-helper.sh; do
        # make the source executable so the aliases can exec the symlink directly
        run chmod +x "$REPO/scripts/$f"
        link_path "$REPO/scripts/$f" "$CLI_DIR/$f"
    done
    link_path "$REPO/scripts/tests" "$CLI_DIR/tests"

    step "Linking backend build inputs (src, Cargo.toml, Cargo.lock); target/ stays REAL"
    ensure_real_dir "$OPT/backend"
    ensure_real_dir "$OPT/backend/target"          # real + writable: holds the deployed binary
    ensure_real_dir "$OPT/backend/target/release"
    link_path "$REPO/backend/src"        "$OPT/backend/src"
    link_path "$REPO/backend/Cargo.toml" "$OPT/backend/Cargo.toml"
    link_path "$REPO/backend/Cargo.lock" "$OPT/backend/Cargo.lock"

    step "Linking public/ web root"
    link_path "$REPO/public" "$OPT/public"

    # certs/ is deliberately NOT touched here - it is a protected tree. The guard would abort
    # ensure_real_dir on it anyway; the directory itself is created (create-only, plain mkdir
    # that bypasses the guard by design) by gen_certs_if_absent, which always runs first.
}

# ── git "dubious ownership" guard (LESSON 2) ─────────────────────────────────
# The deployer runs as ROOT against a working tree owned by a non-root uid, so modern git
# aborts every command with "detected dubious ownership in repository". That would break
# validate_repo's checks, doctor's `git status`, and the post-update drift report. Mark the
# repo trusted for the current (root) user, idempotently - a bare `--add` appends a duplicate
# on every run, so we check first. We do NOT chown the repo (safe.directory avoids ownership
# churn) and NEVER chown anything under the protected trees.
ensure_git_safe_dir() {
    command -v git >/dev/null 2>&1 || return 0
    local repo="${1:-$REPO}"
    if git config --global --get-all safe.directory 2>/dev/null | grep -qxF -- "$repo"; then
        skip "git safe.directory already trusts $repo"
        return 0
    fi
    run git config --global --add safe.directory "$repo"
    ok "git safe.directory registered for $repo (root can now operate the repo)"
}

# ── validation ───────────────────────────────────────────────────────────────
validate_repo() {
    step "Validating repo at $REPO"
    ensure_git_safe_dir      # LESSON 2: make git usable as root before any git call
    [ -d "$REPO/.git" ] || warn "$REPO is not a git working tree yet (git-aware-prod needs 'git init' + commit here)"
    local req=(
        scripts/nodes.sh scripts/tunnel.sh scripts/keys.sh scripts/lib.sh
        scripts/help.sh scripts/subtitle-helper.sh scripts/tests/run.sh
        backend/Cargo.toml backend/Cargo.lock backend/src/main.rs
        public/index.html systemd/allumeur.service
    )
    local r missing=0
    for r in "${req[@]}"; do
        [ -e "$REPO/$r" ] || { warn "missing required source: $REPO/$r"; missing=1; }
    done
    [ "$missing" = 0 ] || die "repo is incomplete; refusing to deploy"
    ok "repo looks complete"
}

# ── test gate (nothing installs over live scripts until the suite passes) ────
run_test_gate() {
    if [ "${SKIP_TESTS:-0}" = 1 ]; then warn "skipping test gate (--skip-tests)"; return 0; fi
    step "Running the pure-bash test suite (deploy gate)"
    if [ "${DRY_RUN:-0}" = 1 ]; then log "[dry-run] would run: bash $REPO/scripts/tests/run.sh"; return 0; fi
    if bash "$REPO/scripts/tests/run.sh"; then
        ok "test suite passed"
    else
        die "test suite FAILED - refusing to install over the live scripts (override with --skip-tests)"
    fi
}

# ── empty non-secret data store (BOOTSTRAP ONLY; create-only, never overwrites) ──
# A brand-new machine has no real encrypted/ blobs. To let the tools run at all we lay down a
# throwaway .root_key and EMPTY blobs, and mint a fresh master key. This is non-secret
# provisioning: it deliberately never touches an existing file, so re-running it on the real
# server is a no-op and can never clobber the real database.
init_empty_data_store() {
    step "Initialising empty non-secret data store in $ENCRYPTED_DIR (create-only)"
    run mkdir -p "$ENCRYPTED_DIR"
    run chmod 700 "$ENCRYPTED_DIR"

    if [ -f "$ENCRYPTED_DIR/.root_key" ]; then
        skip ".root_key already present (left untouched)"
    else
        log "generating a fresh throwaway .root_key"
        run_eval "openssl rand -base64 48 > '$ENCRYPTED_DIR/.root_key'"
        run chmod 600 "$ENCRYPTED_DIR/.root_key"
    fi

    local blob
    for blob in usr_blob.enc srv_blob.enc; do
        if [ -f "$ENCRYPTED_DIR/$blob" ]; then
            skip "$blob already present (left untouched)"
        else
            log "creating empty encrypted $blob"
            run_eval "printf '' | openssl enc -aes-256-cbc -salt -pbkdf2 -pass file:'$ENCRYPTED_DIR/.root_key' -out '$ENCRYPTED_DIR/$blob'"
            run chmod 600 "$ENCRYPTED_DIR/$blob"
        fi
    done

    if [ -f "$ENCRYPTED_DIR/allumeur-master-key" ]; then
        skip "master key already present (left untouched)"
    else
        log "minting a fresh ed25519 master key"
        run ssh-keygen -t ed25519 -a 100 -f "$ENCRYPTED_DIR/allumeur-master-key" -N "" -q -C "allumeur-master-key"
    fi
    ok "data store ready (empty, non-secret)"
}

# ── doctor: report drift without changing anything ───────────────────────────
doctor() {
    step "Doctor: reporting live layout vs repo (read-only)"
    ensure_git_safe_dir      # LESSON 2: doctor runs `git status` as root too
    local pairs=(
        "$CLI_DIR/nodes.sh|$REPO/scripts/nodes.sh"
        "$CLI_DIR/tunnel.sh|$REPO/scripts/tunnel.sh"
        "$CLI_DIR/keys.sh|$REPO/scripts/keys.sh"
        "$CLI_DIR/lib.sh|$REPO/scripts/lib.sh"
        "$CLI_DIR/help.sh|$REPO/scripts/help.sh"
        "$CLI_DIR/subtitle-helper.sh|$REPO/scripts/subtitle-helper.sh"
        "$CLI_DIR/tests|$REPO/scripts/tests"
        "$OPT/backend/src|$REPO/backend/src"
        "$OPT/backend/Cargo.toml|$REPO/backend/Cargo.toml"
        "$OPT/backend/Cargo.lock|$REPO/backend/Cargo.lock"
        "$OPT/public|$REPO/public"
        "$SYSTEMD_UNIT_DEST|$REPO/systemd/allumeur.service"
    )
    local p dest src
    for p in "${pairs[@]}"; do
        dest="${p%%|*}"; src="${p##*|}"
        if is_our_link "$dest" "$src"; then ok "linked: $dest"
        elif [ -L "$dest" ]; then warn "symlink but NOT to repo: $dest -> $(readlink -f -- "$dest" 2>/dev/null)"
        elif [ -e "$dest" ]; then warn "real (not linked): $dest"
        else warn "missing: $dest"; fi
    done
    [ -d "$OPT/backend/target/release" ] && log "backend target/ is $( [ -L "$OPT/backend/target" ] && echo 'A SYMLINK (should be real!)' || echo 'a real dir (good)')"
    for p in "${PROTECTED_DIRS[@]}"; do
        [ -L "$p" ] && warn "PROTECTED path is a symlink: $p" || log "protected OK (real/absent): $p"
    done
    if [ -d "$REPO/.git" ] && command -v git >/dev/null 2>&1; then
        step "git status in $REPO (prod edits show here)"
        git -C "$REPO" status --short || true
    fi
}
