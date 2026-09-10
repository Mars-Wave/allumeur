#!/bin/bash
# keys.sh - key lifecycle across the node fleet, and the single reachability ladder that
# every flow in `nodes` resolves through. `ssh to node`, `power off` and the three keys
# operations all fail the same way and recover the same way, because they all end up here.
#
# Shape of a keys run: the parent forks one worker per node, workers never touch the
# terminal and never block on a human, and the parent renders a live board. A worker that
# needs a password writes that state and exits; the parent prompts, remembers the password
# in memory, and respawns it. Every operation is idempotent, so "respawn from the top" is
# the whole resume mechanism.

# ── outcomes ────────────────────────────────────────────────────────────────
# ssh reports 255 for every one of its own failures, so these are decided by matching
# stderr, not exit codes. Terminal states double as the labels shown on the board.
K_OK=0          # a key works on this node
K_NEEDPASS=10   # sshd answered and refused every key - only a human gets past this
K_DOWN=12       # never answered ICMP inside the wake budget: it is off
K_NOSSHD=13     # answers ICMP but sshd never accepted inside the budget
K_FAILED=14     # reached it, but the operation itself failed
K_SKIP=15       # user declined to give a password
K_LUKSLOCK=16   # flagged LUKS-blocked and no ssh: either off, or already sat at its
                # passphrase prompt, answering ICMP from initramfs with :22 never opening.
                # Waking it strands it there: unreachable, and unpowerable-off, that being ssh

K_ICMP_BUDGET=90    # from wake trigger to first ping reply
K_SSHD_BUDGET=90    # from first ping reply to sshd accepting a connection
K_GRACE_BUDGET=25   # already pinging but sshd refusing (mid-boot): wait, don't wake
K_SLEEP_BUDGET=45   # from the power-off order to the machine going quiet, spent in 3s polls

# ── ssh option sets ─────────────────────────────────────────────────────────
# -n                     workers run off the one TTY; without it ssh eats the keystrokes
#                        the parent's board and prompts are reading.
# IdentitiesOnly=yes     load-bearing: without it ssh also offers the agent and ~/.ssh/id_*,
#                        so "the new key works" could be a lie told by some other key - and
#                        rotate would then delete the old key on that strength.
# BatchMode=yes          turns a rejected key into an immediate exit instead of a hidden
#                        password prompt on a stdin nobody is watching.
# known hosts -> /dev/null  never read, never written. The old code wrote known_hosts, so
#                        re-imaging a node produced REMOTE HOST IDENTIFICATION HAS CHANGED
#                        with no path in the tool that could recover from it. The trust
#                        anchor here is the encrypted blob and the LAN, as it always was.
k_opts_batch() {
    K_OPTS=(-n -i "$1" -o IdentitiesOnly=yes -o BatchMode=yes
            -o PreferredAuthentications=publickey
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
            -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR
            -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2)
}

# Interactive shell: same trust model, but it must keep stdin and a tty.
k_opts_tty() {
    K_OPTS=(-i "$1" -o IdentitiesOnly=yes
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
            -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
}

# Password escalation: never offer a key (a dead key burns a MaxAuthTries slot), and never
# let sshd re-prompt into sshpass.
k_opts_pw() {
    K_OPTS=(-n -o PubkeyAuthentication=no
            -o PreferredAuthentications=password,keyboard-interactive
            -o NumberOfPasswordPrompts=1
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
            -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8)
}

# k_classify <stderr-file> <rc> - the entire "ssh exit codes are useless" answer.
k_classify() {
    local e; e=$(cat "$1" 2>/dev/null)
    case "$e" in
        *"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*)
            return $K_NEEDPASS ;;
        *"Permission denied"*|*"Too many authentication failures"*|*"No supported authentication"*)
            return $K_NEEDPASS ;;
        *"Connection refused"*|*"kex_exchange_identification"*|\
        *"Connection closed by"*|*"Connection reset by"*)
            return $K_NOSSHD ;;   # up, sshd not ready yet - retryable
        *"No route to host"*|*"Network is unreachable"*|*"Host is unreachable"*|\
        *"Connection timed out"*|*"Operation timed out"*)
            return $K_DOWN ;;
    esac
    [ "$2" = 124 ] && return $K_NOSSHD   # `timeout` fired: TCP open, handshake stalled
    return $K_DOWN
}

# k_probe <user> <ip> <key> [remote-cmd] - stdout is the remote output.
# A sentinel proves success, because ssh otherwise returns the *remote* command's status.
k_probe() {
    local user=$1 ip=$2 key=$3 cmd=${4:-'echo __KOK__'} out rc
    # Split off, and it is the hazard this codebase already shipped once: bash creates every
    # name in a `local` before it assigns any, so an $ip in the same statement is not this
    # function's $2 - it is the caller's, or nothing. Every caller happens to have one of the
    # same value, which is why the stderr file has always looked right.
    local err="$K_RUN/err.$ip"
    k_opts_batch "$key"
    out=$(timeout 25 ssh "${K_OPTS[@]}" "$user@$ip" "$cmd" 2>"$err"); rc=$?
    printf '%s' "$out"
    case "$out" in *__KOK__*) return $K_OK ;; esac
    [ $rc -eq 0 ] && return $K_OK
    k_classify "$err" $rc
}

# ── the one remote authorized_keys writer ───────────────────────────────────
# Fed to the node on stdin as `sh -s -- <mode> <base64-pubkey>`. stdin delivery is what
# removes all nested-quoting risk; the argument is base64 so it needs no quoting at all.
# `sh`, not bash - the fleet is mixed. Runs entirely inside the connecting user's own
# $HOME, so it never needs sudo whether the node's user is root or not.
IFS= read -r -d '' K_AK_SCRIPT <<'AKEOF'
d=${HOME:-/root}/.ssh; f=$d/authorized_keys; l=$d/.ak.lock; t=$d/.ak.tmp.$$
# A key's identity is its type+blob wherever they sit on the line - a leading options list
# must not make the same key look like a different one.
AKID='function id(  i,r){r="";for(i=1;i<=NF;i++) if($i ~ /^(ssh-|ecdsa-|sk-)/){r=$i" "$(i+1);break} return r} '
umask 077
mkdir -p "$d" || exit 1
chmod 700 "$d" 2>/dev/null
[ -f "$f" ] || : > "$f" || exit 1
chmod 600 "$f" 2>/dev/null
[ "$1" = list ] && { cat "$f"; printf 'AKOK list\n'; exit 0; }
k=$(printf %s "$2" | base64 -d) || exit 1
[ -n "$k" ] || exit 1
kt=$(printf %s "$k" | awk '{for(i=1;i<=NF;i++) if($i ~ /^(ssh-|ecdsa-|sk-)/){print $i" "$(i+1); exit}}')
i=0
while ! mkdir "$l" 2>/dev/null; do
  i=$((i+1)); [ $i -ge 50 ] && { rmdir "$l" 2>/dev/null; break; }
  sleep 1
done
trap 'rm -f "$t"; rmdir "$l" 2>/dev/null' EXIT INT TERM HUP
case "$1" in
  add)  { awk -v kt="$kt" "$AKID"'id()!=kt' "$f"; printf '%s\n' "$k"; } > "$t" ;;
  del)  awk -v kt="$kt" "$AKID"'id()!=kt' "$f" > "$t" ;;
  only) printf '%s\n' "$k" > "$t" ;;
  *) exit 2 ;;
esac
[ -s "$t" ] || exit 3
chmod 600 "$t" || exit 1
mv "$t" "$f" || exit 1
printf 'AKOK %s\n' "$1"
AKEOF

# k_ak <user> <ip> <key> <add|del|only|list> [pubkey-file] - stdout is the remote output.
#
# add  = delete-then-append, so it is idempotent and collapses pre-existing duplicates
# del  = drop one key by identity
# only = reduce the file to exactly this key
# Keys are identified by type+blob ($1" "$2), never by comment: re-commenting a key must
# not create a duplicate, and a foreign line carrying options is still matched.
# The remote writes a temp file and rename()s it over the target, so a reader never sees a
# torn file, and the [ -s ] guard means a filter bug can never empty authorized_keys - that
# would lock the node out permanently.
k_ak() {
    local user=$1 ip=$2 key=$3 mode=$4 b64="" out rc
    [ -n "${5:-}" ] && b64=$(base64 -w0 < "$5")
    k_opts_batch "$key"
    # stdin carries the script here, so -n has to come back out; it is a pipe, never the tty.
    local opts=("${K_OPTS[@]:1}")
    out=$(printf '%s' "$K_AK_SCRIPT" | timeout 30 ssh "${opts[@]}" "$user@$ip" \
              "sh -s -- $mode $b64" 2>"$K_RUN/err.$ip"); rc=$?
    printf '%s' "$out"
    case "$out" in *"AKOK $mode"*) return $K_OK ;; esac
    k_classify "$K_RUN/err.$ip" $rc
}

# ── remote power-off, granted once ──────────────────────────────────────────
# Powering a node off is the one thing on this fleet that has never worked, because sudo on
# the maddev nodes wants a password and polkit will not authorise a non-interactive remote
# session. This installs the one drop-in that fixes it, and nothing else.
#
# Runs as root, on someone's real machine, writing into the directory that decides who may
# become root. Every line below is one of those hard requirements:
#   * visudo -cf on a temp file FIRST - a syntax error in /etc/sudoers.d breaks sudo for every
#     user on the host, and the way back is a console and a rescue shell;
#   * the temp file is made inside /etc/sudoers.d so the install is a same-filesystem
#     rename() and sudo never sees a half-written policy. It is safe to stage it there
#     because sudo ignores any name containing a dot, which is also why the destination must
#     be exactly `allumeur`: `allumeur.conf` would install and validate and do nothing;
#   * 0440 root:root before the rename, never after - sudo silently ignores a drop-in that is
#     group- or world-writable, and a file is never briefly present and wrong;
#   * the grant is `poweroff` with no arguments and nothing else. `sudo poweroff` under
#     sudo's secure_path finds /usr/sbin/poweroff first, and sudoers matches the path string
#     it resolved, not the file behind it - so on a usrmerge Debian, where /sbin/poweroff is
#     the same inode under a different name, both spellings have to be listed or the rule
#     validates and never matches. systemctl is deliberately absent: nothing in this tool
#     ever runs `sudo systemctl poweroff`, and granting it would widen this from a power
#     switch to a way of starting arbitrary units as root.
IFS= read -r -d '' K_SUDO_SCRIPT <<'SUEOF'
u=$(printf %s "$1" | base64 -d) || exit 1
# The only outside data that reaches sudoers. A newline in it would append a second, wider
# rule to the file we are about to install as policy.
case "$u" in ''|*[!a-zA-Z0-9._-]*) exit 2 ;; esac
# Metacharacters are not the whole of it: a name sudoers reads as a keyword or an alias is
# not a user. `ALL ALL=(root) NOPASSWD: poweroff` passes visudo and hands the power switch
# to every account on the host. Aliases are [A-Z][A-Z0-9_]* and every bare keyword is
# uppercase, so a name with no lowercase letter in it is refused outright and the four Alias
# words by name; %group, +netgroup and #uid never get past the charset above.
case "$u" in *[abcdefghijklmnopqrstuvwxyz]*) ;; *) exit 2 ;; esac
case "$u" in Defaults|User_Alias|Runas_Alias|Host_Alias|Cmnd_Alias|Cmd_Alias) exit 2 ;; esac
command -v visudo >/dev/null 2>&1 || exit 2
f=/etc/sudoers.d/allumeur
r="$u ALL=(root) NOPASSWD: /usr/sbin/poweroff \"\", /sbin/poweroff \"\""
# Twice must be a no-op, not a second rule: the same content already there only gets its
# mode and owner confirmed.
if [ -f "$f" ] && [ "$(cat "$f")" = "$r" ]; then
  chown root:root "$f" && chmod 0440 "$f" || exit 1
  printf 'SUDOOK same\n'; exit 0
fi
umask 077
t=$(mktemp /etc/sudoers.d/.allumeur.XXXXXX) || exit 1
printf '%s\n' "$r" > "$t" || { rm -f "$t"; exit 1; }
visudo -cf "$t" >/dev/null 2>&1 || { rm -f "$t"; exit 2; }
chown root:root "$t" && chmod 0440 "$t" || { rm -f "$t"; exit 1; }
mv -f "$t" "$f" || { rm -f "$t"; exit 1; }
printf 'SUDOOK done\n'
SUEOF

# k_sudo_state <i> - 0 = this node can already power itself off without a password,
# 1 = it cannot, 2 = it could not be asked. An ordinary master-key connection, so it costs
# no password and switches nothing off. This is also the verification step after an install:
# `sudo -n` from inside the sudo session that just ran would prove nothing, since that
# session is already root.
#
# `sudo -n -l` is the question, not `sudo -n poweroff`: it needs no password to answer
# (listpw defaults to letting a user with any NOPASSWD entry list without authenticating)
# and it does not power the machine off to tell us that it could have.
k_sudo_state() {
    local i=$1
    local ip=${K_IP[$i]} user=${K_USER[$i]} out
    # Nothing to grant: root does not go through sudo. pfsense-wall is the one node where remote
    # power-off has always worked, and this is why.
    [ "$user" = root ] && return 0
    out=$(k_probe "$user" "$ip" "$SSH_KEY" 'sudo -n -l 2>/dev/null; echo __KOK__') || return 2
    # Per line, and per entry inside the line. `sudo -n -l` prints one line per rule and a
    # tag holds only until the next tag on that same line, so a NOPASSWD on the apt-get line
    # says nothing whatever about a poweroff two lines below it - and a node read that way is
    # never offered the rule and then silently fails to power off, which is the one failure
    # this feature exists to remove. A blanket `NOPASSWD: ALL` is deliberately not accepted
    # either: it is a root grant somebody hand-wrote, not the power switch this installs, and
    # reporting it as `poweroff ok` is how it stays unnoticed.
    printf '%s\n' "$out" | awk '
        { np = 0; n = split($0, e, /,[ \t]*/)
          for (j = 1; j <= n; j++) {
              if (e[j] ~ /NOPASSWD:/)    np = 1
              else if (e[j] ~ /PASSWD:/) np = 0
              if (np && e[j] ~ /(^|[ \t\/])poweroff([ \t"]|$)/) ok = 1
          } }
        END { exit ok ? 0 : 1 }' && return 0
    return 1
}

# k_sudo_install <i> - install the drop-in on node <i>, paid for with the user's password.
#
# One connection, and the collision it has to get past: `sudo -S` reads the password from
# ITS stdin and `sh -s` would read the script from the same one, and there is a single ssh
# channel. The script is not secret and the password is, so the script travels in the
# command and stdin carries nothing else. It goes up base64'd and the node's own shell
# decodes it straight into `sh -c` as an argument, which is also what keeps the nested
# quoting to none: base64 needs no escaping, and so does the username beside it.
#
# What this replaces: the script used to be uploaded to the connecting user's $HOME over one
# connection and then run by root over a second one. That account is precisely the account
# this whole feature exists because it CANNOT reach root - and between the two connections
# it could rewrite the file root was about to execute, buying arbitrary root with the
# human's sudo password. Nothing is written to the node's disk now, so there is no window
# and nothing to clean up.
# Returns 2 when the node refused the rule - a bad username, no visudo, or its own visudo
# saying no - which is a different thing to tell the user than a password that did not work.
k_sudo_install() {
    local i=$1
    local ip=${K_IP[$i]} user=${K_USER[$i]} out rc
    local s; s=$(printf '%s' "$K_SUDO_SCRIPT" | base64 -w0)
    local u; u=$(printf %s "$user" | base64 -w0)
    k_opts_batch "$SSH_KEY"
    local opts=("${K_OPTS[@]:1}")               # stdin carries the password: -n has to go
    # `allumeur` is $0 for the remote `sh -c`, so the base64 username lands as its $1.
    out=$(printf '%s\n' "${K_PW[$i]}" | timeout 60 ssh "${opts[@]}" "$user@$ip" \
        "sudo -S -p '' sh -c \"\$(printf %s '$s' | base64 -d)\" allumeur '$u'" \
        2>"$K_RUN/err.$ip"); rc=$?
    case "$out" in *SUDOOK*) return 0 ;; esac
    [ "$rc" = 2 ] && return 2
    return 1
}

# k_pingable <ip> - is this machine on the network? One reply proves it is; one lost packet
# proves nothing, so it takes three misses to say no. Both decisions that hang off this are
# destructive when wrong: a single dropped packet on a busy wifi node used to be enough to
# blast WoL at a machine somebody was working on and then power it off, and inside the sleep
# poll it would report a still-running machine as asleep.
k_pingable() {
    local n
    for n in 1 2 3; do ping -c 1 -W 1 "$1" >/dev/null 2>&1 && return 0; done
    return 1
}

wol_blast() {
    local mac=$1 ip=$2 tgt port
    for tgt in "$ip" "${ip%.*}.255" "255.255.255.255"; do
        for port in 9 7; do wakeonlan -i "$tgt" -p "$port" "$mac" >/dev/null 2>&1; done
    done
}

# ── the ladder ──────────────────────────────────────────────────────────────
# k_resolve <i> <key>... - guarantee that some key can run commands on node <i>.
# Sets K_ACTIVE_KEY to whichever key won. Candidate order matters: rotate passes the new
# key first so a half-finished run is recognised and resumed rather than redone.
#
# Waking and waiting for sshd are deliberately two different budgets: a booting box replies
# to ICMP from early userspace long before sshd binds :22, and a box sitting at a LUKS
# passphrase prompt can answer ICMP from its initramfs forever without ever opening 22.
# One combined budget would either cut live boots short or hang the queue on the LUKS box.
k_resolve() {
    local i=$1; shift
    local mac=${K_MAC[$i]} ip=${K_IP[$i]} user=${K_USER[$i]} luks=${K_LUKS[$i]}  # safe: i is a parameter here
    local keys=("$@") key rc t0 woke=0 refused

    # Cleared here, not in k_adopt: the op bodies read it after we return, and a worker that
    # resolved this node by key must not inherit an adoption from a previous call.
    K_ADOPTED=0
    k_st "$i" probe
    for key in "${keys[@]}"; do
        [ -f "$key" ] || continue
        if k_probe "$user" "$ip" "$key" >/dev/null; then K_ACTIVE_KEY=$key; return $K_OK; fi
        rc=$?
    done

    if ! k_pingable "$ip"; then
        [ "${K_NOWAKE:-0}" = 1 ] && return $K_DOWN
        # Only the wake path is gated. A LUKS-blocked node that is already answering has been
        # unlocked by a human and is an ordinary node from here on.
        [ "$luks" = 1 ] && return $K_LUKSLOCK
        k_st "$i" wake
        woke=1
        # Written before the packet goes out, because from here on this run may well be what
        # switched the machine on whatever happens next: a box that boots slower than the
        # budget, or whose worker `q` kills, still comes up minutes later. Without this it
        # would come up with nothing left anywhere that would ever switch it off again.
        : > "$K_RUN/n$i/waking"
        # Prefer the backend so the WebGUI shows the same confirming_up the CLI assumes.
        # Only blast WoL ourselves when the backend is not there to do it.
        local backend=0
        if api_toggle "$mac" "$ip" "$user" "on"; then backend=1; else wol_blast "$mac" "$ip"; fi
        t0=$SECONDS
        while ! ping -c 1 -W 1 "$ip" >/dev/null 2>&1; do
            [ $((SECONDS - t0)) -ge $K_ICMP_BUDGET ] && return $K_DOWN
            [ $backend -eq 0 ] && case $((SECONDS - t0)) in 20|21|40|41) wol_blast "$mac" "$ip";; esac
            sleep 3
        done
        # It answered: confirmation, on top of the intent above. Written only here - a node
        # that was already up must not be switched off under its user.
        : > "$K_RUN/n$i/woke"
    fi

    # It is on the network. Wait for sshd, then decide.
    # A node we just woke gets the full boot budget; one that was already pinging but not
    # answering sshd only gets the short grace wait, so a box parked at a LUKS prompt is
    # given up on quickly instead of holding the run for 90s.
    local budget=$K_SSHD_BUDGET
    [ "$woke" = 0 ] && budget=$K_GRACE_BUDGET
    k_st "$i" sshd
    t0=$SECONDS
    while :; do
        refused=0
        for key in "${keys[@]}"; do
            [ -f "$key" ] || continue
            k_probe "$user" "$ip" "$key" >/dev/null; rc=$?
            case $rc in
                $K_OK)       K_ACTIVE_KEY=$key; return $K_OK ;;
                $K_NEEDPASS) refused=1 ;;
            esac
        done
        # Only once EVERY candidate has been refused is a human actually needed. Escalating
        # on the first refusal would demand a password on every rotate, where the new key is
        # tried first and is of course not on the node yet.
        [ "$refused" = 1 ] && { k_adopt "$i"; return $?; }
        # Flagged, on the network, and :22 never opened is the passphrase prompt answering
        # from initramfs, not a broken daemon - "check sshd on the node" would send the user
        # after something that has not been started yet.
        [ $((SECONDS - t0)) -ge $budget ] && \
            { [ "$luks" = 1 ] && return $K_LUKSLOCK; return $K_NOSSHD; }
        sleep 5
    done
}

# k_adopt <i> - push our public key using the node's password. The password lives only in
# the parent's memory and this process's environment; it is never written to disk and never
# appears in `ps` (which is what `sshpass -p` would have done).
k_adopt() {
    local i=$1; local ip=${K_IP[$i]} user=${K_USER[$i]} out
    [ -z "${K_PW[$i]:-}" ] && { k_st "$i" need_pass; return $K_NEEDPASS; }
    k_st "$i" adopt
    k_opts_pw
    out=$(printf '%s' "$K_AK_SCRIPT" | SSHPASS="${K_PW[$i]}" timeout 40 sshpass -e \
              ssh "${K_OPTS[@]:1}" "$user@$ip" \
              "sh -s -- add $(base64 -w0 < "$K_ADOPT_PUB")" 2>"$K_RUN/err.$ip")
    case "$out" in *"AKOK add"*) ;; *) return $K_NEEDPASS ;; esac
    # Prove the key actually works before anything is allowed to rely on it.
    k_probe "$user" "$ip" "$K_ADOPT_KEY" >/dev/null || return $K_NEEDPASS
    K_ACTIVE_KEY=$K_ADOPT_KEY
    # Record it, do not act on it. A node reached this way was refusing keys of ours that it
    # still holds, and they have to go - but WHEN is the operation's decision, not this
    # function's. See k_purge_ours. Workers are subshells and this whole chain (k_op_* ->
    # k_resolve -> k_adopt) is plain function calls inside one of them, so a variable is the
    # channel; nothing here crosses a process boundary.
    K_ADOPTED=1
    return $K_OK
}

# ── per-node state, the only worker -> parent channel ───────────────────────
# One file per node, single writer, replaced by rename(). A plain `>` truncates first and
# the render loop would catch the empty window and draw a blank row.
k_st() {
    printf '%s|%s|%s\n' "$2" "$EPOCHSECONDS" "${3:-}" > "$K_RUN/n$1/st.tmp" \
        && mv -f "$K_RUN/n$1/st.tmp" "$K_RUN/n$1/st"
}
k_st_read() { IFS='|' read -r K_S K_T K_D < "$K_RUN/n$1/st" 2>/dev/null; K_S=${K_S:-queued}; }

# An operation is several passes over the same fleet, and every pass rewrites st. Freeze the
# operation's own result before the passes that are not about it, or a node that failed the
# thing the report exists to describe would be reported `asleep`.
k_snapshot() {
    local i
    for ((i=0; i<K_N; i++)); do cp -f "$K_RUN/n$i/st" "$K_RUN/n$i/st.final" 2>/dev/null; done
}

# k_st_final <i> - what the report reads: the operation's own result and only that, from the
# frozen copy, because every later pass has overwritten st since. The frozen copy is the
# verdict, full stop - a live nok used to win, which handed every pass after the snapshot a
# veto over it: declining the sudoers grant, or `q` on its board, or a node dropping off the
# network between passes, each turned a node this run genuinely reached into FAILED with
# "fix: run it again". A pass that IS answerable for the run says so by writing into the
# frozen copy itself; k_sleep_woken is the one that does.
k_st_final() {
    local i=$1
    [ -f "$K_RUN/n$i/st.final" ] || { k_st_read "$i"; return 0; }
    IFS='|' read -r K_S K_T K_D < "$K_RUN/n$i/st.final"
    return 0
}

# Either marker means this run is answerable for the machine being on: `waking` is the intent,
# written before the magic packet; `woke` the confirmation that it came back.
k_woke() { [ -f "$K_RUN/n$1/waking" ] || [ -f "$K_RUN/n$1/woke" ]; }

# ── keys of ours ────────────────────────────────────────────────────────────
# The comment `allumeur-master-key` is the only mark this server puts on a key, so it is the
# only honest answer to "did we mint this?" - and therefore the only rule under which a key
# may be destroyed without asking. Everything else on the node, personal or foreign, belongs
# to somebody else; only `purge any other keys` touches those, and it asks first.
#
# k_stale_scan <i> <keep-pub> - over $K_ACTIVE_KEY, print the type+blob of every key of ours
# on node <i> except the one in <keep-pub>. Fails, printing nothing, if <keep-pub> carries no
# readable key: without it every allumeur line matches and the caller would strip the live
# key off the node.
k_stale_scan() {
    local i=$1; local keep=$2; local auth=${3:-$K_ACTIVE_KEY}
    local ip=${K_IP[$i]} user=${K_USER[$i]} cur
    cur=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^(ssh-|ecdsa-|sk-)/){print $i" "$(i+1); exit}}' "$keep")
    [ -n "$cur" ] || return 1
    k_ak "$user" "$ip" "$auth" list \
    | awk -v kt="$cur" 'function id(  i,r){r="";for(i=1;i<=NF;i++) if($i ~ /^(ssh-|ecdsa-|sk-)/){r=$i" "$(i+1);c=$(i+2);break} return r}
                        {k=id()} k!="" && c=="allumeur-master-key" && k!=kt {print k}'
}

# k_drop_keys <i> <key> <list> - delete each type+blob line of <list> from node <i> over
# <key>. One ssh per key, but one worker per node, so a fleet's worth of them lands on the
# board instead of blocking the parent node by node. Sets K_DROPPED to how many went.
k_drop_keys() {
    local i=$1; local key=$2; local list=$3
    local ip=${K_IP[$i]} user=${K_USER[$i]}
    local tmp="$K_RUN/n$i/drop.pub" line
    K_DROPPED=0
    while read -r line; do
        [ -z "$line" ] && continue
        # Per node, not per run: the workers are concurrent and one shared file would have
        # them handing each other's keys to k_ak.
        printf '%s allumeur-master-key\n' "$line" > "$tmp"
        k_ak "$user" "$ip" "$key" del "$tmp" >/dev/null || { rm -f "$tmp"; return 1; }
        K_DROPPED=$((K_DROPPED+1))
    done <<< "$list"
    rm -f "$tmp"
    return 0
}

# k_purge_ours <i> [keep-pub] - drop every key of ours from node <i> except <keep-pub>,
# which defaults to the key this run adopts with. Rotate passes the NEW key explicitly:
# there the key to keep is the one being installed, not the one we authenticated with, and
# leaving that to a global was how this silently purged nothing at all.
#
# Deliberately NOT called from k_adopt, and this is the ordering the next reader will want to
# "simplify" away: during a rotate, adoption puts the NEW key on the node, and destroying the
# old one before "$K_NEW_KEY.deployed" exists means a worker that dies in between leaves
# k_rotate_finalize discarding the new key while the node holds only keys nobody has any
# more - locked out, recoverable only by password. k_adopt therefore just records that it
# adopted, and each operation triggers this at ITS own safe point.
k_purge_ours() {
    local i=$1; local keep=${2:-${K_ADOPT_PUB:-}}; local stale
    K_DROPPED=0
    [ -n "$keep" ] || return 0
    # Authenticate with the key we are KEEPING, never with K_ACTIVE_KEY. On a rotate the
    # connection was opened with the old key, and the very first deletion is that key - every
    # later one then failed to log in, so a node holding two of our keys ended the rotate as
    # a failure with the older key still authorised. The kept key is installed and verified
    # by this point, so it is the only one guaranteed to still open the door at the end.
    local auth=${keep%.pub}
    [ -f "$auth" ] || auth=$K_ACTIVE_KEY
    stale=$(k_stale_scan "$i" "$keep" "$auth") || return 0
    [ -n "$stale" ] || return 0
    k_st "$i" wipe
    k_drop_keys "$i" "$auth" "$stale"
}

# ── the three operations, as worker bodies ──────────────────────────────────
k_op_rotate() {
    local i=$1; local ip=${K_IP[$i]} user=${K_USER[$i]}
    # New key first: if a previous attempt got this far, we resume instead of redoing.
    k_resolve "$i" "$K_NEW_KEY" "$SSH_KEY" || return $?

    if [ "$K_ACTIVE_KEY" != "$K_NEW_KEY" ]; then
        k_st "$i" push
        k_ak "$user" "$ip" "$K_ACTIVE_KEY" add "$K_NEW_KEY.pub" >/dev/null || return $K_FAILED
        k_st "$i" verify
        k_probe "$user" "$ip" "$K_NEW_KEY" >/dev/null || return $K_FAILED
    fi
    # This node now answers to the new key. Recording it is what licenses the parent to
    # destroy the old one - see k_rotate_finalize.
    : > "$K_NEW_KEY.deployed" || return $K_FAILED

    # Rotate's safe point, and only here: past this marker the new key is promoted whatever
    # happens next, so every key it replaces can be destroyed.
    #
    # ALL of ours, not just the one being superseded. Deleting only $SSH_KEY left every older
    # allumeur key still authorised - a node that missed two rotations kept both, and a node
    # that had to be adopted was refusing $SSH_KEY anyway, so the narrow delete removed
    # nothing at all there. Rotation is supposed to mean the fleet answers to exactly one key
    # of ours, and this is the line that makes that true. Foreign keys are untouched: only
    # `purge any other keys` may destroy those, and it asks first.
    k_purge_ours "$i" "$K_NEW_KEY.pub" || return $K_FAILED
    return $K_OK
}

k_op_purge() {
    local i=$1; local ip=${K_IP[$i]} user=${K_USER[$i]} before removed
    # No adoption branch: `only` below already reduces the node to one key, which is a
    # superset of dropping the keys of ours an adoption superseded.
    k_resolve "$i" "$SSH_KEY" || return $?
    k_st "$i" scan
    # Counted the same way a key is identified everywhere else in this file - type+blob
    # wherever they sit on the line. `^ssh-` would miss ecdsa and sk keys and every line
    # carrying an options prefix, so the report said "0 gone" on a node whose personal keys
    # this had just destroyed.
    before=$(k_ak "$user" "$ip" "$SSH_KEY" list \
             | awk '{for(i=1;i<=NF;i++) if($i ~ /^(ssh-|ecdsa-|sk-)/){n++; break}} END{print n+0}')
    k_st "$i" purge
    k_ak "$user" "$ip" "$SSH_KEY" only "$SSH_KEY.pub" >/dev/null || return $K_FAILED
    removed=$((before - 1)); [ "$removed" -lt 0 ] && removed=0
    k_st "$i" ok "$removed gone"
    return $K_OK
}

# Delete the superseded keys `ensure` found and the user then said yes to.
k_op_wipe() {
    local i=$1; local f="$K_RUN/n$i/stale"
    [ -f "$f" ] || return $K_OK
    k_st "$i" wipe
    k_drop_keys "$i" "$SSH_KEY" "$(cat "$f")" || return $K_FAILED
    k_st "$i" ok "$K_DROPPED gone"
    return $K_OK
}

# Grant this node non-interactive poweroff, if it has not got it already. Asking costs one
# ordinary connection and no password, so the human is only ever bothered where the rule is
# actually missing.
k_op_sudoers() {
    local i=$1; local st
    k_sudo_state "$i"; st=$?
    [ "$st" = 0 ] && { k_st "$i" ok "poweroff ok"; return $K_OK; }
    # It answered a moment ago in the main pass and does not now; nothing here can fix that.
    [ "$st" = 2 ] && return $K_FAILED
    # Nothing is spent here that the user did not hand to THIS pass: k_grant_sudoers takes
    # the adoption passwords out of reach before the pass starts, so a node that needs the
    # rule always comes through the prompt, which is where saying no is possible.
    if [ -z "${K_PW[$i]:-}" ]; then
        # The detail is what k_prompt_pw reads to say what the password is FOR.
        k_st "$i" need_pass "sudoers"
        return $K_NEEDPASS
    fi
    k_st "$i" sudoers
    k_sudo_install "$i"; st=$?
    # Proved from a separate ordinary connection, the way every other claim here is proved.
    if [ "$st" = 0 ] && k_sudo_state "$i"; then
        : > "$K_RUN/n$i/granted"
        k_st "$i" ok "poweroff ok"
        return $K_OK
    fi
    # A typo must not be final here when it is final nowhere else in this tool: sudo not
    # taking the password is the one failure another go can fix, so it goes back to the
    # prompt exactly as a refused master key does. Empty still means skip.
    [ "$st" = 1 ] && { k_st "$i" need_pass "sudoers"; return $K_NEEDPASS; }
    # Counted like a decline in the note, and reported as a failure on top of it: the user
    # asked for this one and it did not happen.
    : > "$K_RUN/n$i/nogrant"
    [ "$st" = 2 ] && { k_st "$i" nok "rule refused"; return $K_FAILED; }
    k_st "$i" nok "no sudo rule"
    return $K_FAILED
}

# Powering a machine off quietly did not work on most of this fleet: without the drop-in
# k_grant_sudoers installs, `sudo poweroff` fails at sudo with its stderr discarded and again
# at polkit. The command below is left exactly as it is because it is the command the rule
# authorises - `poweroff`, no arguments, resolved through secure_path - and a caller that
# drifted from the rule would be a rule that validates and never matches.
# api_toggle's curl carries no -f either, so an HTTP error still exits 0. No exit status here
# means anything. ICMP decides.
k_op_sleep() {
    local i=$1; local mac=${K_MAC[$i]} ip=${K_IP[$i]} user=${K_USER[$i]}
    # The marker is the whole authorisation. Being in the fleet, or merely being queued into
    # this pass, must never be enough to switch a machine off.
    k_woke "$i" || return $K_OK

    if [ -f "$K_RUN/n$i/woke" ]; then
        # It answered during this run, so it really did come up. Quiet now means it has
        # already gone back off - by the backend's confirm_off, or by a hand at the console.
        k_pingable "$ip" || { k_st "$i" ok "off"; return $K_OK; }
    else
        # Only the intent: the magic packet went out and the box never answered inside the
        # wake budget. "Not answering right now" is NOT "off" - a machine with a slow POST or
        # a RAID controller comes up two minutes later, and if this pass walks away calling it
        # off, there is nothing left anywhere that will ever switch it off again. That is the
        # stranded machine this whole feature exists to prevent, so give it a bounded chance
        # to appear and say so plainly if it never does.
        k_st "$i" sleep
        local wait=$K_SLEEP_BUDGET
        while ! k_pingable "$ip"; do
            [ "$wait" -le 0 ] && { k_st "$i" nok "may wake later"; return $K_FAILED; }
            sleep 3; wait=$((wait - 3))
        done
    fi

    k_st "$i" sleep
    # Through the backend, like hit_lights, so the WebGUI sees the same confirming_down the
    # CLI does. Direct poweroff only when the backend is not there to do it.
    if ! api_toggle "$mac" "$ip" "$user" "off"; then
        k_opts_batch "$SSH_KEY"
        ssh "${K_OPTS[@]}" "$user@$ip" "sudo poweroff 2>/dev/null || poweroff" >/dev/null 2>&1
    fi
    local left=$K_SLEEP_BUDGET
    while [ "$left" -gt 0 ]; do
        sleep 3; left=$((left - 3))
        k_pingable "$ip" || { k_st "$i" ok "asleep"; return $K_OK; }
    done
    k_st "$i" nok "no poweroff"
    return $K_FAILED
}

# The ladder, plus the purge every path owes an adopted node. This is what `ssh to node` and
# `power off` run, so those two get the same board, the same password prompt and the same
# failure vocabulary as the keys ops. Reaching the node IS the whole operation here, so the
# safe point is immediately after it.
k_op_resolve() {
    k_resolve "$1" "$SSH_KEY" || return $?
    # Reaching a node by password means the current key was not on it - which happens exactly
    # when it missed a rotation, so whatever keys of ours it still holds are ones nobody has.
    # They go without being asked about, because they are ours and they are already dead; the
    # board says how many so it is not silent.
    if [ "$K_ADOPTED" = 1 ]; then
        k_purge_ours "$1" || return $K_FAILED
        [ "${K_DROPPED:-0}" -gt 0 ] && k_st "$1" ok "$K_DROPPED old gone"
    fi
    return $K_OK
}

k_op_ensure() {
    local i=$1; local stale n
    # k_resolve is the whole of "make sure the current key is on this node": it pushes the
    # key by password when the node no longer accepts it.
    k_resolve "$i" "$SSH_KEY" || return $?
    # A node that had to be adopted was refusing this key, so every OTHER key of ours on it
    # is one nobody can use any more - not a finding to put to the user, just rubbish to take
    # out. ensure has no later step that needs an old key, so its safe point is here.
    if [ "$K_ADOPTED" = 1 ]; then
        k_purge_ours "$i" || return $K_FAILED
        [ "$K_DROPPED" -gt 0 ] && k_st "$i" ok "$K_DROPPED gone"
        return $K_OK
    fi
    k_st "$i" scan
    # Superseded keys minted by this origin server. The key still works here, so these are
    # only ever proposed - k_wipe_stale removes them once the user has said yes.
    stale=$(k_stale_scan "$i" "$SSH_KEY.pub") || return $K_OK
    if [ -n "$stale" ]; then
        printf '%s\n' "$stale" > "$K_RUN/n$i/stale"
        n=$(printf '%s\n' "$stale" | grep -c .)
        k_st "$i" ok "$n stray"
    fi
    return $K_OK
}

# ── worker ──────────────────────────────────────────────────────────────────
# Runs in a subshell: nothing it sets can reach the parent, every byte that crosses the
# boundary crosses as a file. It never reads stdin and never writes to the terminal.
k_worker() {
    local i=$1 rc
    case "$K_OP" in
        rotate)  k_op_rotate  "$i" ;;
        purge)   k_op_purge   "$i" ;;
        ensure)  k_op_ensure  "$i" ;;
        resolve) k_op_resolve "$i" ;;
        wipe)    k_op_wipe    "$i" ;;
        sudoers) k_op_sudoers "$i" ;;
        sleep)   k_op_sleep   "$i" ;;
    esac
    rc=$?
    case $rc in
        "$K_OK")       k_st_read "$i"; [ "$K_S" = ok ] || k_st "$i" ok ;;
        # Same rule as K_OK below: a body that already said WHY it wants a password keeps its
        # own word for it, or the prompt goes back to claiming the master key was refused.
        "$K_NEEDPASS") k_st_read "$i"; [ "$K_S" = need_pass ] || k_st "$i" need_pass ;;
        "$K_DOWN")     k_st "$i" nok "never woke" ;;
        "$K_NOSSHD")   k_st "$i" nok "no sshd" ;;
        "$K_LUKSLOCK") k_st "$i" nok "luks locked" ;;
        "$K_SKIP")     k_st "$i" nok "skipped" ;;
        # Symmetrical with K_OK above: a body that already said why it failed keeps its own
        # word for it, so "no poweroff" is not flattened into "op failed".
        *)             k_st_read "$i"; [ "$K_S" = nok ] || k_st "$i" nok "op failed" ;;
    esac
    exit 0
}

k_spawn() {
    # </dev/null is mandatory, not hygiene: under `set -m` bash does NOT redirect a
    # background job's stdin, so a worker would race the parent for the user's keystrokes.
    ( k_worker "$1" ) </dev/null >>"$K_RUN/n$1/log" 2>&1 &
    K_PID[$1]=$!
}

# ── the board ───────────────────────────────────────────────────────────────
# Never `clear` during a run: it flashes on a phone terminal and destroys the scrollback
# the user needs to re-read a nok. Instead the frame is rebuilt, compared, and - only if it
# changed - emitted as ONE printf after a cursor-up. One write per frame means the board
# lands atomically over a slow link instead of painting top-to-bottom.
k_trunc() {
    if [ "${#1}" -gt "$2" ]; then printf '%s~' "${1:0:$(($2-1))}"; else printf '%s' "$1"; fi
}

k_elapsed() {
    local s=$1
    [ "$s" -lt 60 ] && { printf '%ds' "$s"; return; }
    printf '%d:%02d' $((s/60)) $((s%60))
}

# Status is carried three ways at once - gutter char, lowercase word, colour - so it still
# reads on a monochrome phone terminal. The only uppercase on the board is the one thing
# that wants the user's eye.
k_style() {
    case "$1" in
        queued) K_G=' '; K_C=$GRAY;      K_L='queued'    ;;
        probe)  K_G='>'; K_C=$GRAY;      K_L='checking'  ;;
        wake)   K_G='>'; K_C=$PINK;      K_L='waking'    ;;
        sshd)   K_G='>'; K_C=$PINK;      K_L='wait sshd' ;;
        adopt)  K_G='>'; K_C=$PINK;      K_L='adopting'  ;;
        push)   K_G='>'; K_C=$PINK;      K_L='push key'  ;;
        verify) K_G='>'; K_C=$PINK;      K_L='verifying' ;;
        prune)  K_G='>'; K_C=$PINK;      K_L='drop old'  ;;
        scan)   K_G='>'; K_C=$PINK;      K_L='scanning'  ;;
        purge)  K_G='>'; K_C=$PINK;      K_L='purging'   ;;
        wipe)   K_G='>'; K_C=$PINK;      K_L='drop keys' ;;
        sudoers) K_G='>'; K_C=$PINK;     K_L='sudo rule' ;;
        sleep)  K_G='>'; K_C=$PINK;      K_L='sleeping'  ;;
        ok)     K_G='*'; K_C=$WHITE;     K_L='done'      ;;
        need_pass) K_G='!'; K_C=$PINK$BOLD; K_L='NEEDS PASS' ;;
        # A locked disk is not a failure, it is a thing that cannot be done from here: nothing
        # went wrong, nothing is broken, and no amount of retrying changes it until a human
        # types the passphrase at that keyboard. Calling it FAILED sends the reader looking
        # for a fault that does not exist. Ten characters, which is exactly the column.
        nok)    K_G='!'; K_C=$PINK$BOLD
                case "$2" in
                    "luks locked") K_L='UNFEASIBLE' ;;
                    *)             K_L='FAILED'     ;;
                esac ;;
        *)      K_G=' '; K_C=$GRAY;      K_L="$1"        ;;
    esac
}

k_board() {
    local w nw frame='' rows=0 ok=0 busy=0 ask=0 nok=0 i el
    w=$(tput cols 2>/dev/null); [ -z "$w" ] && w=40
    [ "$w" -lt 24 ] && w=40
    nw=15; [ "$w" -lt 36 ] && nw=$((w-14))     # 15 == len("immich-provider"), the longest fleet name

    frame+="${PINK}*~ ${WHITE}${BOLD}$1${PINK} ~*${RESET}"$'\e[K\n'
    frame+="${GRAY}q = stop${RESET}"$'\e[K\n'$'\e[K\n'
    rows=3

    for ((i=0; i<K_N; i++)); do
        k_st_read "$i"
        k_style "$K_S" "$K_D"
        case "$K_S" in
            ok) ((ok++)) ;; nok) ((nok++)) ;; need_pass) ((ask++)) ;;
            queued) ;; *) ((busy++)) ;;
        esac
        case "$K_S" in
            queued|need_pass) el='--' ;;
            ok|nok)           el='' ;;    # settled: a climbing timer would be a lie, and it
                                          # would also force a repaint every single second
            *) el=$(k_elapsed $((EPOCHSECONDS - ${K_T:-$EPOCHSECONDS}))) ;;
        esac
        [ -n "$K_D" ] && el=$(k_trunc "$K_D" $((w - nw - 14)))
        if [ "$w" -lt 34 ]; then
            frame+=$(printf '%b%s %-*s %-10s%b\e[K' "$K_C" "$K_G" "$nw" \
                     "$(k_trunc "${K_NAME[$i]}" "$nw")" "$K_L" "$RESET")$'\n'
        else
            frame+=$(printf '%b%s %-*s %-10s %5s%b\e[K' "$K_C" "$K_G" "$nw" \
                     "$(k_trunc "${K_NAME[$i]}" "$nw")" "$K_L" "$el" "$RESET")$'\n'
        fi
        ((rows++))
    done

    frame+=$'\e[K\n'; ((rows++))
    frame+=$(printf '%b %d ok  %d run  %d ask  %d nok%b\e[K' \
             "$WHITE" "$ok" "$busy" "$ask" "$nok" "$RESET")$'\n'; ((rows++))

    if [ "$frame" != "$K_PREV_FRAME" ]; then
        [ "$K_PREV_ROWS" -gt 0 ] && tput cuu "$K_PREV_ROWS"
        printf '%b\e[J' "$frame"      # erase-to-end lets the block grow and shrink for free
        K_PREV_FRAME=$frame; K_PREV_ROWS=$rows
    fi
}

# Index of the first node waiting on a human, or failure if none is. Kept separate from the
# renderer: encoding "someone needs a password" in a draw function's exit status is how the
# loop ends up asking the wrong question.
k_ask_index() {
    local i
    for ((i=0; i<K_N; i++)); do
        k_st_read "$i"
        [ "$K_S" = need_pass ] && { printf '%s' "$i"; return 0; }
    done
    return 1
}

# ── the one place a keys run reads the terminal ─────────────────────────────
# The board is deliberately abandoned rather than drawn over: the stale copy scrolls up and
# becomes honest history, which on a phone is exactly what you want to scroll back to.
k_prompt_pw() {
    local i=$1 pw
    # Two passes ask for a password and they want it for different things. The detail on the
    # need_pass state says which, because telling the user their key was refused while
    # actually collecting a password to change sudo on their machine would be a lie.
    k_st_read "$i"
    # A password typed to put the master key back was given for that. Reusing it to save the
    # user a second typing is fine; spending it on a privilege change they were never given
    # the chance to refuse is not, so it is offered here and not assumed anywhere.
    local reuse=''
    [ "$K_D" = sudoers ] && reuse=${K_PW_ADOPT[$i]:-}
    tput cnorm
    printf '%b\n' "${GRAY}(other nodes keep working)${RESET}"
    if [ -n "$reuse" ]; then
        printf '%b\n' "${PINK}*~ ${WHITE}${BOLD}${K_NAME[$i]} needs your ok${PINK} ~*${RESET}"
    else
        printf '%b\n' "${PINK}*~ ${WHITE}${BOLD}${K_NAME[$i]} needs a password${PINK} ~*${RESET}"
    fi
    printf '%b\n' "${GRAY}${K_USER[$i]}@${K_IP[$i]}${RESET}"
    if [ "$K_D" = sudoers ]; then
        printf '%b\n' "${WHITE}remote power-off needs sudo."
        if [ -n "$reuse" ]; then
            printf '%b\n' "y = use the password you gave."
            printf '%b\n' "or type it again."
        else
            printf '%b\n' "type the password to grant it."
        fi
        printf '%b\n' "empty = skip.${RESET}"
    else
        printf '%b\n' "${WHITE}the master key was refused here."
        # Three short lines, not one long one: at 30 columns the old single line wrapped
        # mid-sentence and the "empty = skip" half of it landed under the password field.
        printf '%b\n' "type the password to restore it."
        printf '%b\n' "empty = skip.${RESET}"
    fi
    printf '%b' "${PINK}${reuse:+y or }password: ${WHITE}"
    # pw is pre-set empty and the read is allowed to fail: with no controlling terminal -
    # `nodes` from cron, a detached session, a test - opening /dev/tty errors, and an unset pw
    # under `set -u` killed the whole run instead of taking the skip two lines below. A
    # terminal we cannot read from means the user cannot answer, which IS a skip.
    pw=""
    IFS= read -rs pw < "${K_TTY:-/dev/tty}" || pw=""
    printf '%b\n\n' "$RESET"
    # No hazard in a password that is literally `y`: reuse holds that same password.
    [ -n "$reuse" ] && case "$pw" in y|Y) pw=$reuse ;; esac
    if [ -z "$pw" ]; then
        # Declining the grant is not a failure of ensure: the node is reachable, which is all
        # ensure was ever about. Only a master key still refused is a failure of the run.
        if [ "$K_D" = sudoers ]; then
            : > "$K_RUN/n$i/nogrant"
            k_st "$i" ok "no sudo rule"
        else
            k_st "$i" nok "skipped"
        fi
        K_PREV_FRAME=''; K_PREV_ROWS=0; tput civis
        return 1
    fi
    K_PW[$i]=$pw; pw=
    K_PREV_FRAME=''; K_PREV_ROWS=0     # re-anchor: the next frame paints fresh below
    tput civis
    return 0
}

# Stop everything that is still moving and settle the board. Used by both `q` and ^C, so
# an interrupted run still reaches its report and, for rotate, its finalize step - which is
# what keeps an interrupt from stranding a node that already dropped the old key.
k_stop_run() {
    local i
    k_kill_workers
    for ((i=0; i<K_N; i++)); do
        k_st_read "$i"
        case "$K_S" in ok|nok) ;; *) k_st "$i" nok "stopped" ;; esac
    done
}

k_all_terminal() {
    local i
    for ((i=0; i<K_N; i++)); do
        k_st_read "$i"
        case "$K_S" in ok|nok) ;; *) return 1 ;; esac
    done
    return 0
}

k_kill_workers() {
    local p
    # Negative pid = process group. Killing the worker alone would orphan its ssh.
    for p in "${K_PID[@]}"; do [ -n "$p" ] && kill -TERM -- "-$p" 2>/dev/null; done
    for p in "${K_PID[@]}"; do [ -n "$p" ] && kill -KILL -- "-$p" 2>/dev/null; done
    wait 2>/dev/null
}

k_cleanup() {
    trap '' INT TERM
    k_kill_workers
    set +m
    [ -n "${K_RUN:-}" ] && [ -d "$K_RUN" ] && rm -rf "$K_RUN"
    K_PW=(); K_PW_ADOPT=()
    tput cnorm
    trap "tput cnorm; exit" INT TERM
}

# ── orchestrator ────────────────────────────────────────────────────────────
k_begin() {
    # Reap run dirs left by runs that died before k_cleanup could remove them. They pile up -
    # 225 were found on the server - and each holds this fleet's ssh error output and its wake
    # markers, on a box with 3.5GB of disk and no log rotation for /tmp. A day old means no
    # live run is still writing to it, so this can never race a concurrent one.
    find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'nodes-keys.*' -type d -mtime +0 \
         -exec rm -rf {} + 2>/dev/null
    K_RUN=$(mktemp -d "${TMPDIR:-/tmp}/nodes-keys.XXXXXX") || return 1
    chmod 700 "$K_RUN"
    K_MAC=(); K_IP=(); K_NAME=(); K_USER=(); K_LUKS=(); K_PID=(); K_PW=(); K_PW_ADOPT=()
    K_PREV_FRAME=''; K_PREV_ROWS=0
    K_N=0
}

k_add_node() {
    K_MAC[K_N]=$1; K_IP[K_N]=$2; K_NAME[K_N]=$3; K_USER[K_N]=$4; K_LUKS[K_N]=$5
    mkdir -p "$K_RUN/n$K_N"
    k_st "$K_N" queued
    ((K_N++))
}

# Parsed once, in the main shell: `<<<` inside a loop allocates a temp file per evaluation,
# and a pipe would put the array writes in a subshell where they would vanish.
k_load_all() {
    # Nine fields: favourite ($7), order ($8) and pretty ($9) are frontend curation and mean
    # nothing to a keys run, but they MUST still be split off - reading fewer variables
    # would fold the tail into $6 and every record would fail the luks guard below,
    # dropping the whole fleet from the run.
    local mac ip name user subtitle luks favourite order pretty
    while IFS=',' read -r mac ip name user subtitle luks favourite order pretty; do
        [ -z "$ip" ] && continue
        # This is the one loader that feeds the wake decision, so it is the one place where a
        # flag that is neither 0 nor 1 matters: a hand-edited record with a stray comma slides
        # the field along, and anything that is not exactly 1 reads as "safe to wake". Skipping
        # the node loses it from this run; guessing wrong strands it at a passphrase prompt
        # nothing here can answer.
        case "$luks" in 0|1) ;; *) continue ;; esac
        k_add_node "$mac" "$ip" "$name" "$user" "$luks"
    done <<< "$(decrypt_blob | grep '[^[:space:]]')"
}

k_run() {
    local title=$1 i
    K_OP=${K_OP:-ensure}

    if [ "$K_N" -eq 0 ]; then
        echo -e "${WHITE}no nodes found.${RESET}"; sleep 1; return 0
    fi

    # Each worker gets its own process group, so a terminal ^C reaches us and not them and
    # we can take them down in order with the tty restored. Verified on bash 5.2 and 5.3:
    # non-interactively this prints no job-control noise, and `</dev/null` on every spawn
    # keeps them off the one stdin the board and prompts are reading.
    set -m
    K_ABORT=0
    trap 'K_ABORT=1' INT TERM
    # Only queued nodes are spawned, which is what makes an operation a sequence of passes
    # over one fleet: the caller queues the nodes a pass is about, everything already settled
    # keeps its result and simply renders. On the first pass k_add_node queued them all.
    K_PID=()
    for ((i=0; i<K_N; i++)); do
        k_st_read "$i"; [ "$K_S" = queued ] && k_spawn "$i"
    done

    tput civis
    local key ask
    while :; do
        # Abort is checked first: ^C while a node is waiting on a password must abort, not
        # hand the user another prompt.
        [ "$K_ABORT" = 1 ] && { k_stop_run; K_ABORT=0; }
        k_board "$title"
        # One prompt per pause, then straight back to the board - the other nodes are still
        # working and the user should see that, not a queue of five password prompts.
        if ask=$(k_ask_index); then
            if k_prompt_pw "$ask"; then
                # Move the node off need_pass BEFORE respawning it. The worker only rewrites
                # its state once it is running, and until then this loop would see need_pass
                # again and ask the user for the same password over and over. The label is
                # the pass's, or the board would say "adopting" during a sudoers grant.
                case "$K_OP" in
                    sudoers) k_st "$ask" sudoers ;;
                    *)       k_st "$ask" adopt ;;
                esac
                k_spawn "$ask"
            fi
            continue
        fi
        k_all_terminal && break
        # The 1s tick IS the keyboard poll - free abort key, no extra code.
        if read -rsn1 -t 1 key; then
            case "$key" in
                q|Q) k_stop_run ;;
                *)   K_PREV_FRAME='' ;;      # any other key forces a repaint
            esac
        fi
    done
    k_board "$title"
    tput cnorm
    k_kill_workers
    k_trap_idle
}

# What ^C means between the passes - the wipe confirmation, the report, rotate's finalize.
# K_ABORT means nothing out here, so the interrupt goes back to being an exit; but a run that
# has woken machines cannot be allowed to exit having silently left them on, and $K_RUN, the
# only record of which ones those are, dies with the process. So it sleeps them first.
# `ssh to node` and `power off` are exempt: they reach one node because a human asked, and
# shutting that node down under them would be absurd.
# After the sleep pass itself there is nothing left to answer for - the machines are off, and
# the one that refused already says so in the report. Running it again on ^C would only flash a
# second board over the report and spend another budget on a node polkit is never going to let
# go, so from there ^C is just an exit that tidies up.
k_trap_idle() {
    case "$K_OP" in
        resolve) trap "tput cnorm; exit" INT TERM ;;
        sleep)   trap 'k_cleanup; exit 130' INT TERM ;;
        *)       trap 'k_sleep_woken; k_cleanup; exit 130' INT TERM ;;
    esac
}

# ── reporting ───────────────────────────────────────────────────────────────
# The run is over and the board is dead, so this is the one place `clear` is right.
# ok nodes collapse to one line each; a nok gets its reason and what to do about it.
k_report() {
    local i ok=0 nok=0
    print_header "$1 - report" ""
    # NOT `[ ok ] && ((ok++)) || ((nok++))`: ((ok++)) evaluates to the OLD value, so the
    # very first success is 0, which is false, which also counted it as a failure.
    for ((i=0; i<K_N; i++)); do
        k_st_final "$i"
        if [ "$K_S" = ok ]; then ok=$((ok+1)); else nok=$((nok+1)); fi
    done

    echo -e "${WHITE} ok $ok / $K_N${RESET}\n"
    for ((i=0; i<K_N; i++)); do
        k_st_final "$i"
        [ "$K_S" = ok ] || continue
        printf "${WHITE} * %-13s ${GRAY}%s${RESET}\n" "$(k_trunc "${K_NAME[$i]}" 13)" "$K_D"
    done

    if [ "$nok" -gt 0 ]; then
        echo -e "\n${PINK} nok $nok${RESET}\n"
        for ((i=0; i<K_N; i++)); do
            k_st_final "$i"
            [ "$K_S" = nok ] && {
                printf "${PINK} ! %s${RESET}\n" "${K_NAME[$i]}"
                echo -e "${GRAY}   ${K_D}"
                case "$K_D" in
                    "never woke") echo -e "   fix: power it on, or unlock it${RESET}" ;;
                    "no sshd")    echo -e "   fix: check sshd on the node${RESET}" ;;
                    # Not "ensure reachability": nothing this tool can do reaches a disk
                    # waiting on a passphrase. Only a human at that keyboard can.
                    "luks locked") echo -e "   fix: unlock at its console,\n        then run again${RESET}" ;;
                    # It is still on because sudo and polkit both refused, not because it is
                    # unreachable - it answered every ping. Sending the user to ensure
                    # reachability would be advice about a problem that is not there.
                    "no poweroff") echo -e "   fix: needs a NOPASSWD\n        poweroff rule in sudoers${RESET}" ;;
                    # We ordered the wake and it never answered, so we cannot switch it off
                    # and cannot promise it will stay off. Said plainly, because the one
                    # thing worse than a machine left running is not being told about it.
                    "may wake later") echo -e "   it never answered the wake.\n   fix: check it is off${RESET}" ;;
                    # The grant was attempted and did not take. Either the password was
                    # wrong, or that account cannot use sudo at all - which no rule of ours
                    # can fix, because writing one needs sudo.
                    "no sudo rule") echo -e "   fix: check the password, and\n        that the user has sudo${RESET}" ;;
                    "rule refused") echo -e "   fix: that node's visudo\n        rejected the rule${RESET}" ;;
                    "skipped"|"stopped") echo -e "   fix: run it again${RESET}" ;;
                    *)            echo -e "   fix: keys > ensure reachability${RESET}" ;;
                esac
            }
        done
    fi
    [ -n "${2:-}" ] && echo -e "\n${GRAY} $2${RESET}"
    echo -e "\n${PINK}[ press any key to return ]${RESET}"
    read -rsn1
}

# ── operations ──────────────────────────────────────────────────────────────
# Rotation destroys the old key, so it is only allowed to do that once at least one node is
# provably answering to the new one. If nothing was rotated (fleet offline, run aborted at
# the first prompt) the old key is still the only way in to every node, and throwing it away
# would be pure self-harm - so in that case the new key is discarded instead.
k_rotate_finalize() {
    # The marker lives beside the key, not in the run dir, so an interrupted run that had
    # already pruned a node still promotes and cannot strand us with a discarded new key.
    if [ -f "$K_NEW_KEY.deployed" ]; then
        rm -f "$K_NEW_KEY.deployed"
        mv -f "$K_NEW_KEY" "$SSH_KEY"; mv -f "$K_NEW_KEY.pub" "$SSH_KEY.pub"
        chmod 600 "$SSH_KEY"
        K_ROTATE_NOTE="old key deleted. nodes that did not rotate now need their password."
    else
        rm -f "$K_NEW_KEY" "$K_NEW_KEY.pub"
        K_ROTATE_NOTE="no node took the new key - the old key was kept so you can retry."
    fi
}

keys_rotate() {
    print_header "rotate all keys"
    echo -e "${WHITE}mints a new master key, puts it on every node, then deletes"
    echo -e "${WHITE}every allumeur key it replaces - not just the last one."
    echo -e "${GRAY}your own keys are left alone."
    echo -e "${GRAY}nodes that cannot be reached will need their password next run.${RESET}\n"
    interactive_menu "rotate now" "cancel"
    [ $? -ne 0 ] && return

    # Minted in the encrypted dir, not the run dir: if this run is interrupted after a node
    # has already dropped the old key, the new key must still exist afterwards.
    K_NEW_KEY="$SSH_KEY.new"
    # A marker left behind means a previous run was killed AFTER a node took that staged
    # key - possibly after it dropped the old one. Adopt the survivor before staging a new
    # key, or we would delete the only key that still opens part of the fleet.
    [ -f "$K_NEW_KEY.deployed" ] && k_rotate_finalize
    rm -f "$K_NEW_KEY" "$K_NEW_KEY.pub" "$K_NEW_KEY.deployed"
    ssh-keygen -t ed25519 -a 100 -f "$K_NEW_KEY" -N "" -q -C "allumeur-master-key"

    k_begin || return; k_load_all
    K_OP=rotate K_ADOPT_PUB="$K_NEW_KEY.pub" K_ADOPT_KEY="$K_NEW_KEY"
    k_run "rotate all keys"
    # Finalize first: it is part of rotating, and the report must show what it decided.
    k_rotate_finalize
    k_snapshot
    k_sleep_woken
    k_report "rotate all keys" "$K_ROTATE_NOTE${K_SLEEP_NOTE:+ $K_SLEEP_NOTE}"
    k_cleanup
}

keys_purge() {
    # No confirmation: choosing `purge any other keys` from the keys menu IS the confirmation,
    # and a second prompt for the same decision teaches people to hit enter through prompts -
    # which is worse for the one prompt in this tool that really cannot be automatic, the
    # password. Stated plainly and briefly instead, so the screen is still read.
    print_header "purge any other keys" ""
    echo -e "${WHITE}leaving exactly one key on every node: the one in use."
    echo -e "${PINK}every other key is destroyed, including your own personal keys.${RESET}"
    echo -e "${GRAY}q stops the run.${RESET}"
    sleep 2

    k_begin || return; k_load_all
    K_OP=purge K_ADOPT_PUB="$SSH_KEY.pub" K_ADOPT_KEY="$SSH_KEY"
    k_run "purge any other keys"
    k_snapshot
    k_sleep_woken
    k_report "purge any other keys" "$K_SLEEP_NOTE"
    k_cleanup
}

keys_ensure() {
    k_begin || return; k_load_all
    K_OP=ensure K_ADOPT_PUB="$SSH_KEY.pub" K_ADOPT_KEY="$SSH_KEY"
    k_run "ensure reachability"

    # Superseded keys minted by this server are only ever removed with the user's say-so.
    local i any=0
    for ((i=0; i<K_N; i++)); do [ -f "$K_RUN/n$i/stale" ] && any=1; done
    if [ "$any" = 1 ]; then
        print_header "superseded keys found"
        echo -e "${WHITE}old keys from this server are still on:${RESET}\n"
        for ((i=0; i<K_N; i++)); do
            [ -f "$K_RUN/n$i/stale" ] || continue
            printf "${WHITE}   %-13s ${GRAY}%s stray${RESET}\n" \
                   "$(k_trunc "${K_NAME[$i]}" 13)" "$(grep -c . "$K_RUN/n$i/stale")"
        done
        echo ""
        interactive_menu "wipe them" "keep them"
        [ $? -eq 0 ] && k_wipe_stale
    fi
    # Wiping is part of what ensure was asked to do, so it is inside the snapshot; granting
    # poweroff and sleeping are not, and must not overwrite anyone's result.
    k_snapshot
    k_grant_sudoers
    k_sleep_woken
    local note=$K_SUDO_NOTE
    [ -n "$K_SLEEP_NOTE" ] && note="${note:+$note }$K_SLEEP_NOTE"
    k_report "ensure reachability" "$note"
    k_cleanup
}

# k_resolve_tty <mac> <ip> <name> <user> <title> <luks> - reach one node, on the same board
# and with the same password prompt as a fleet-wide run. Sets K_LAST_NOK to the reason on
# failure. This is the entire "ssh access and poweroff resolve the same way" requirement.
k_resolve_tty() {
    local ok=1
    k_begin || return 1
    k_add_node "$1" "$2" "$3" "$4" "$6"
    K_OP=resolve K_ADOPT_PUB="$SSH_KEY.pub" K_ADOPT_KEY="$SSH_KEY"
    k_run "$5"
    # The reach verdict is read BEFORE the sudoers pass, so declining that grant - or a node
    # whose account has no sudo at all - can never turn a node we did reach into one we did
    # not, and drop the user out of a shell they can plainly have.
    k_st_read 0
    [ "$K_S" = ok ] && ok=0
    K_LAST_NOK=$K_D
    # Same tail as a keys run: having got in, make sure this node can still be switched off
    # without a human. Silent when the rule is already there, so the common path is unchanged.
    [ "$ok" = 0 ] && k_grant_sudoers
    k_cleanup
    return $ok
}

# The wipe pass. Only ever called after the user has said yes.
k_wipe_stale() {
    local i any=0
    for ((i=0; i<K_N; i++)); do
        [ -f "$K_RUN/n$i/stale" ] || continue
        k_st "$i" queued; any=1
    done
    [ "$any" = 1 ] || return 0
    K_OP=wipe
    k_run "remove excess keys"
}

# The sudoers pass: offer non-interactive poweroff to every node that ended the main pass
# reachable and has not got it. Deliberately AFTER k_snapshot, unlike the wipe: ensure was
# asked to make the fleet reachable, and it did - a user who declines the grant, or a node
# whose account has no sudo, must not turn that into a failed ensure. Deliberately BEFORE
# k_sleep_woken, because the rule only means anything if the sleep pass can use it, and
# before k_cleanup, which takes $K_RUN and the passwords with it.
# Only nodes still `ok` are queued: a node that never woke has nothing to grant.
k_grant_sudoers() {
    local i any=0 n=0 s=0
    K_SUDO_NOTE=''
    for ((i=0; i<K_N; i++)); do
        k_st_read "$i"; [ "$K_S" = ok ] || continue
        [ "${K_USER[$i]}" = root ] && continue      # root needs no rule; no board row for it
        k_st "$i" queued; any=1
    done
    [ "$any" = 1 ] || return 0

    # The passwords in hand were given to restore the master key, not to change sudo. They
    # are kept so nobody types one twice, but they are put out of the pass's reach: with
    # K_PW empty every node that is missing the rule comes back through k_prompt_pw, and the
    # prompt is the only place the user can say no. Index by index - "${K_PW[@]}" would
    # collapse a sparse array and hand one node's password to another.
    for ((i=0; i<K_N; i++)); do K_PW_ADOPT[$i]=${K_PW[$i]:-}; done
    K_PW=()

    K_OP=sudoers
    k_run "allow remote power off"
    for ((i=0; i<K_N; i++)); do
        [ -f "$K_RUN/n$i/granted" ] && n=$((n+1))
        [ -f "$K_RUN/n$i/nogrant" ] && s=$((s+1))
    done
    [ "$n" -gt 0 ] && K_SUDO_NOTE="$n node(s) can now be powered off remotely."
    [ "$s" -gt 0 ] && K_SUDO_NOTE="${K_SUDO_NOTE:+$K_SUDO_NOTE }$s still cannot."
    return 0
}

# The sleep pass: put back off every machine this run switched on. Any operation that had to
# turn a device on turns it off again - a fleet that was asleep when the run started has to
# be asleep when it ends, or a nightly habit slowly leaves the whole house running.
# Skipping the pass when nothing woke is not an optimisation: an empty pass would flash an
# instantly-finished board. Call order is fixed: after the wipe, which still needs these
# nodes over ssh, and before k_cleanup, which takes $K_RUN and the markers with it.
k_sleep_woken() {
    local i
    K_SLEPT=0; K_SLEPT_NOK=0; K_SLEEP_NOTE=''
    for ((i=0; i<K_N; i++)); do
        k_woke "$i" || continue
        k_st "$i" queued; K_SLEPT=$((K_SLEPT+1))
    done
    [ "$K_SLEPT" -eq 0 ] && return 0

    K_OP=sleep
    k_run "back to sleep"
    for ((i=0; i<K_N; i++)); do
        k_woke "$i" || continue
        k_st_read "$i"; [ "$K_S" = nok ] || continue
        K_SLEPT_NOK=$((K_SLEPT_NOK+1))
        # Only over a node that has nothing worse to say. A machine that would not switch off
        # is worth reporting, but not at the price of the verdict the operation itself
        # reached: a node whose report line said `never woke` was being rewritten to
        # `may wake later`, so the one place that names WHY a node was not rotated stopped
        # saying it. The note below still accounts for every machine left running.
        # Guarded, not `2>/dev/null`: that silences the READ, while the failing input
        # redirection is the shell's own complaint and prints anyway - and leaves prev unset,
        # which under `set -u` is fatal. No snapshot at all means nothing is being protected,
        # because k_report then reads `st` directly and the sleep verdict is the only one there.
        local prev=""
        [ -f "$K_RUN/n$i/st.final" ] && IFS='|' read -r prev _ < "$K_RUN/n$i/st.final"
        [ -n "$prev" ] || continue
        [ "$prev" = ok ] && cp -f "$K_RUN/n$i/st" "$K_RUN/n$i/st.final"
    done
    K_SLEEP_NOTE="$((K_SLEPT - K_SLEPT_NOK)) woken node(s) put back off."
    [ "$K_SLEPT_NOK" -gt 0 ] && K_SLEEP_NOTE="$K_SLEEP_NOTE $K_SLEPT_NOK would NOT go off."
    return 0
}

keys_menu() {
    while true; do
        print_header "keys"
        interactive_menu "rotate all keys" "purge any other keys" "ensure reachability" "back"
        case $? in
            0) keys_rotate ;;
            1) keys_purge ;;
            2) keys_ensure ;;
            3) return ;;
        esac
    done
}
