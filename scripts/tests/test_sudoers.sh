#!/usr/bin/env bash
# The sudoers grant - the drop-in that makes remote power-off work on the maddev nodes,
# where sudo wants a password and polkit will not authorise a non-interactive session.
#
# Nothing here may ever touch a real /etc/sudoers.d, so the fake node models one: a
# per-node directory standing in for that machine's root, a `sudo` that takes its password
# from stdin exactly as the real one does, and a `sudo -n -l` that answers out of the
# drop-in ONLY when sudo would really read it - a dotted filename or a mode wider than 0440
# is ignored in silence, which is the entire reason those two requirements exist. The fake
# `poweroff` obeys only where a rule sudo can read grants it, so "the machine went off" is
# a statement about the rule and not about the test's goodwill.
#
# One liberty is taken with the installer: the single absolute path in it is repointed at
# the node's fake root before it runs, because there is no other way to run the real script
# without being root on this machine. The filename, the mktemp template, the visudo call,
# the mode, the ownership and the order of all of it are the real script's, and those are
# what every assertion below is about.
#
# Every fixture puts the node under test at index 3. `local i=$1 v=${ARR[$i]}` silently
# addresses index 0 for every worker, and a single-node fixture cannot see that.

OLD_PUB='ssh-ed25519 AAAAOLD allumeur-master-key'
FOREIGN='ssh-ed25519 AAAAFOREIGN tmorolias@protonmail.com'

# The real fleet, in its real order: pfsense-wall is root (nothing to grant), pi-blocker is the
# LUKS box, and immich-provider - the node under test - is index 3.
FLEET_BLOB='02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,Gaming!,0,1,1,
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,Series & Movies,0,1,2,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,Workstation,1,0,3,
02:00:00:00:00:14,192.168.77.14,immich-provider,maddev,Sensors,0,1,4,
02:00:00:00:00:15,192.168.77.15,vault-warden,maddev,AI Ecosystem,0,1,5,'

IP0=192.168.77.12   # pfsense-wall,      root
IP1=192.168.77.13   # jelly-streamer, maddev
IP2=192.168.77.11   # pi-blocker,        maddev, LUKS_BLOCKED=1
IP3=192.168.77.14   # immich-provider,    maddev  <- the node under test
IP4=192.168.77.15   # vault-warden,     maddev

PW=hunter2
# What the installer must produce, to the byte. Anything wider than this is a root backdoor
# wearing a power switch's clothes.
RULE='maddev ALL=(root) NOPASSWD: /usr/sbin/poweroff "", /sbin/poweroff ""'

setup() {
    source "$SRC_DIR/lib.sh"
    source "$SRC_DIR/keys.sh"

    SSH_KEY="$HOME/.allumeur-scripts/encrypted/allumeur-master-key"
    printf 'PRIVOLD\n' > "$SSH_KEY"; printf '%s\n' "$OLD_PUB" > "$SSH_KEY.pub"

    NODES="$SANDBOX/nodes"; mkdir -p "$NODES"; export NODES
    export TMPDIR="$SANDBOX"          # k_begin mktemp -d's here, so teardown reaps it
    K_PREV_FRAME=''; K_PREV_ROWS=0

    K_ICMP_BUDGET=1; K_SSHD_BUDGET=1; K_GRACE_BUDGET=1; K_SLEEP_BUDGET=6

    # api_toggle is a nodes.sh function, not a PATH stub. Absent by default: the backend
    # being down is what forces the ssh poweroff path, which is the path the rule is for.
    API_TOGGLE_RC=1
    api_toggle() {
        printf 'api_toggle\t%s\n' "$*" >> "$STUB_LOG"
        [ "$API_TOGGLE_RC" = 0 ] || return 1
        case "$4" in on) rm -f "$NODES/$2/.down" ;; esac
        return 0
    }

    set_blob "$FLEET_BLOB"
    fake_ssh
    stub clear
    stub sshpass 1                    # no password path unless a test opts in
    stub visudo 0                     # the node's own syntax check, passing
    stub_script chown <<'EOF'
exit 0
EOF
    # WoL that actually brings the machine back, so the wake -> grant -> sleep sequence can
    # be driven end to end.
    cat > "$STUB_DIR/wakeonlan" <<'EOF'
#!/usr/bin/env bash
printf 'wakeonlan\t%s\n' "$*" >> "$STUB_LOG"
for a in "$@"; do case "$a" in 192.168.*) rm -f "$NODES/$a/.down" ;; esac; done
exit 0
EOF
    chmod +x "$STUB_DIR/wakeonlan"
    printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/sleep"; chmod +x "$STUB_DIR/sleep"
    cat > "$STUB_DIR/tput" <<'EOF'
#!/usr/bin/env bash
[ "$1" = cols ] && { echo 40; exit 0; }
exit 0
EOF
    chmod +x "$STUB_DIR/tput"
    log_chmod                         # last: everything above still needs a real chmod
}

# chmod is logged and then really applied. The mode on disk is one assertion; WHICH file it
# was applied to is the other - a mode set after the rename would mean the drop-in was live
# and world-readable-writable for a window, which is the thing sudo silently ignores.
log_chmod() {
    local real; real=$(command -v chmod)
    cat > "$STUB_DIR/chmod" <<EOF
#!/usr/bin/env bash
printf 'chmod\t%s\n' "\$*" >> "$STUB_LOG"
exec "$real" "\$@"
EOF
    "$real" +x "$STUB_DIR/chmod"
}

# ── the blob ────────────────────────────────────────────────────────────────
set_blob() {
    export FIXTURE_BLOB="$1"
    cat > "$STUB_DIR/openssl" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\n' openssl "\$*" >> "$STUB_LOG"
out=""; inf=""; prev=""
for a in "\$@"; do
    [ "\$prev" = "-out" ] && out="\$a"
    [ "\$prev" = "-in" ]  && inf="\$a"
    prev="\$a"
done
if [ -n "\$out" ]; then
    cat > "\$out"
    cp -f "\$out" "$SANDBOX/written_blob"
elif [ -n "\$inf" ] && [ -s "\$inf" ]; then
    cat "\$inf"
else
    case "\$inf" in
        *srv_blob*) printf '%s\n' "\${FIXTURE_SRV:-}" ;;
        *)          printf '%s\n' "\$FIXTURE_BLOB" ;;
    esac
fi
EOF
    chmod +x "$STUB_DIR/openssl"
}
written_blob() { cat "$SANDBOX/written_blob" 2>/dev/null; }

# ── the fake node ───────────────────────────────────────────────────────────
fake_ssh() {
    cat > "$STUB_DIR/ssh" <<'FAKE'
#!/usr/bin/env bash
key=""; target=""; cmd=""; args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    case "${args[$i]}" in
        -i) key="${args[$((i+1))]}"; ((i++)) ;;
        -o) ((i++)) ;;
        -n|-q|-t) ;;
        *@*) target="${args[$i]}"; cmd="${args[*]:$((i+1))}"; break ;;
    esac
done
ip="${target#*@}"
printf 'ssh\t%s\n' "$*" >> "$STUB_LOG"
printf 'CMD\t%s\t%s\t%s\n' "$ip" "$key" "$cmd" >> "$STUB_LOG.trace"
nodedir="$NODES/$ip"
sd="$nodedir/etc/sudoers.d"
[ -f "$nodedir/.down" ] && { echo "ssh: connect to host $ip port 22: No route to host" >&2; exit 255; }
if [ -n "$key" ] && [ -f "$key.pub" ]; then
    blob=$(awk '{print $2}' "$key.pub")
    awk '{print $2}' "$nodedir/.ssh/authorized_keys" 2>/dev/null | grep -qx "$blob" \
        || { echo "$target: Permission denied (publickey,password)." >&2; exit 255; }
else
    echo "$target: Permission denied (publickey,password)." >&2; exit 255
fi

# What `sudo -n -l` would print - which is nothing at all unless sudo would actually read
# the drop-in. A name with a dot in it, or a mode with any write bit past the owner, is
# skipped without a word, and that silence is exactly what these tests exist to catch.
sudo_list() {
    local f="$sd/allumeur" m
    [ -f "$f" ] || return 0
    m=$(stat -c %a "$f" 2>/dev/null)
    case "$m" in 440|400) ;; *) return 0 ;; esac
    echo "User ${target%@*} may run the following commands on this host:"
    sed 's/^[^ ]* ALL=/    /' "$f"
}

case "$cmd" in
    *"sudo -n -l"*)
        sudo_list
        echo "__KOK__" ;;
    "sudo -S"*)
        # The collision the installer is built around: sudo takes its password from ITS
        # stdin, one line, and the rest of the channel is nobody's. Recorded so a test can
        # prove the password came down here and appeared in no argv anywhere.
        IFS= read -r pw
        printf '%s\n' "$pw" >> "$nodedir/.stdin_seen"
        if [ "$pw" != "$(cat "$nodedir/.password" 2>/dev/null)" ]; then
            echo "sudo: Sorry, try again." >&2; exit 1
        fi
        # The installer writes nothing to the node's disk: the script travels base64'd
        # inside the command and the node's own shell decodes it straight into `sh -c`.
        # So it is decoded HERE, purely so the one absolute path in it can be repointed at
        # this node's fake root - there is no real /etc/sudoers.d to let it near, and on a
        # host that has one this stub would otherwise install a live rule on the machine
        # running the tests. Its filename, temp template, validation, mode, ownership and
        # the order of all of it are the shipped script's, untouched, and those are what
        # every assertion below is about.
        b64=$(printf '%s' "$cmd" | sed -n "s/.*printf %s '\([A-Za-z0-9+/=]*\)'.*/\1/p")
        u=$(printf '%s' "$cmd" | sed -n "s/.*base64 -d)\" allumeur '\([A-Za-z0-9+/=]*\)'.*/\1/p")
        [ -n "$b64" ] || { echo "fake sudo: no script in the command" >&2; exit 1; }
        s="$nodedir/.shipped-sudoers.sh"
        printf '%s' "$b64" | base64 -d | sed "s#/etc/sudoers.d#$sd#g" > "$s"
        # What was really shipped, before the repointing, for the tests that assert on it.
        printf '%s' "$b64" | base64 -d > "$nodedir/.shipped"
        HOME="$nodedir" sh "$s" "$u"
        rc=$?
        rm -f "$s"
        exit $rc ;;
    *poweroff*)
        # The measured problem, modelled: with no rule sudo asks for a password nobody can
        # type, polkit refuses the session, stderr is discarded, and the machine stays up.
        if [ "${target%@*}" = root ] || [ -n "$(sudo_list)" ]; then : > "$nodedir/.down"; fi
        exit 0 ;;
    "echo __KOK__") echo "__KOK__" ;;
    *"cat > "*)
        HOME="$nodedir" sh -c "$cmd"; rc=$?
        # Snapshotted before the sudo run rewrites the path in it, so a test can assert on
        # what was really shipped.
        cp -f "$nodedir/.allumeur-sudoers.sh" "$nodedir/.uploaded" 2>/dev/null
        exit $rc ;;
    "sh -s -- "*) HOME="$nodedir" sh -s -- ${cmd#sh -s -- } ;;
    *) HOME="$nodedir" sh -c "$cmd" ;;
esac
FAKE
    chmod +x "$STUB_DIR/ssh"

    cat > "$STUB_DIR/ping" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in 192.168.*|10.*) ip="$a";; esac; done
[ -f "$NODES/$ip/.down" ] && exit 1
exit 0
FAKE
    chmod +x "$STUB_DIR/ping"
}

# sshpass with a password gets in where the key could not, and runs the real writer.
fake_sshpass() {
    cat > "$STUB_DIR/sshpass" <<'FAKE'
#!/usr/bin/env bash
printf 'sshpass\t%s\n' "$*" >> "$STUB_LOG"
args=("$@"); target=""; cmd=""
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in *@*) target="${args[$i]}"; cmd="${args[*]:$((i+1))}"; break ;; esac
done
ip="${target#*@}"
HOME="$NODES/$ip" sh -s -- ${cmd#sh -s -- }
FAKE
    chmod +x "$STUB_DIR/sshpass"
}

# ── fixtures ────────────────────────────────────────────────────────────────
node_fs() {   # ip pubkey... - a real ~/.ssh/authorized_keys, a real fake /etc/sudoers.d
    local ip=$1; shift
    mkdir -p "$NODES/$ip/.ssh" "$NODES/$ip/etc/sudoers.d"
    printf '%s\n' "$@" > "$NODES/$ip/.ssh/authorized_keys"
    printf '%s' "$PW" > "$NODES/$ip/.password"
}
node_keys() { cat "$NODES/$1/.ssh/authorized_keys" 2>/dev/null; }
set_down()  { : > "$NODES/$1/.down"; }

sudoers_dir()  { printf '%s' "$NODES/$1/etc/sudoers.d"; }
dropin()       { printf '%s' "$NODES/$1/etc/sudoers.d/allumeur"; }
dropin_names() { ls -A "$(sudoers_dir "$1")" 2>/dev/null; }

# A node that already carries the rule, installed correctly, as three of the fleet will be
# on the second run of anything.
grant_rule() {
    local f; f="$(dropin "$1")"
    printf '%s\n' "$RULE" > "$f"
    chmod 0440 "$f"
}

load_fleet() {
    local ip
    for ip in "$IP0" "$IP1" "$IP2" "$IP3" "$IP4"; do node_fs "$ip" "$OLD_PUB" "$FOREIGN"; done
    k_begin
    k_load_all
}

# The fleet as `ensure` meets it: everything reachable, everyone else already granted, and
# immich-provider - index 3 - the one node with something to do. pi-blocker is off and flagged, so
# it drops out of every pass without holding one up.
one_node_needs_it() {
    load_fleet
    grant_rule "$IP1"; grant_rule "$IP4"
    set_down "$IP2"
}

# A terminal that cannot be opened at all - `nodes` from cron, a detached session, a test
# harness. Distinct from tty_empty, where the read succeeds and returns nothing.
tty_absent() { K_TTY="$SANDBOX/no-such-tty-device"; }

tty_says() { printf '%s\n' "$1" > "$SANDBOX/tty"; K_TTY="$SANDBOX/tty"; }
tty_empty() { : > "$SANDBOX/tty"; K_TTY="$SANDBOX/tty"; }

drive_ensure() {
    interactive_menu() { return "${MENU_RC:-0}"; }
    keys_ensure < /dev/null > "$SANDBOX/out" 2>&1
}
out()    { sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' "$SANDBOX/out"; }
report() { out | sed -n '/- report/,$p'; }
trace()  { cut -f2- "$STUB_LOG.trace" 2>/dev/null; }

# ── the installer: validate first, or not at all ────────────────────────────
test_the_rule_is_validated_before_anything_is_installed() {
    load_fleet
    K_PW[3]=$PW
    # The ordering IS the safety property: a syntax error reaching /etc/sudoers.d breaks
    # sudo for every user on that host, and the way back is a console and a rescue shell.
    cat > "$STUB_DIR/visudo" <<EOF
#!/usr/bin/env bash
printf 'visudo\t%s\n' "\$*" >> "$STUB_LOG"
[ -e "\$(dirname "\$2")/allumeur" ] && echo live >> "$SANDBOX/at_validate" \
                                    || echo absent >> "$SANDBOX/at_validate"
exit 0
EOF
    chmod +x "$STUB_DIR/visudo"

    assert_rc 0 k_sudo_install 3
    assert_eq "absent" "$(cat "$SANDBOX/at_validate")" \
        "the destination did not exist yet when the check ran"
    assert_file "$(dropin "$IP3")" "and it does now"
    local v; v=$(stub_calls visudo)
    assert_contains "$v" "-cf" "checked as a file, not after the fact"
    assert_not_contains "$v" "sudoers.d/allumeur" "and never the live path"
    assert_contains "$v" "sudoers.d/.allumeur." \
        "the staged file is dotted, so sudo would ignore it even mid-install"
}

test_a_rule_the_node_rejects_is_never_installed() {
    load_fleet
    K_PW[3]=$PW
    stub visudo 1                       # that node's own visudo says no
    assert_rc 2 k_sudo_install 3 "a refused rule is its own outcome, not a bad password"
    assert_no_file "$(dropin "$IP3")" "nothing was installed"
    assert_eq "" "$(dropin_names "$IP3")" "and no staged file was left behind either"
}

test_the_rule_is_accepted_by_a_real_visudo() {
    # Every other test here validates against a stub that always says yes, so nothing else
    # in the suite would notice the day the rule text stops being sudoers at all - it would
    # install on a live node and be rejected there. Run against the real parser where the
    # machine has one; where sudo is not installed there is nothing to ask.
    local real
    for real in /usr/sbin/visudo /sbin/visudo /usr/bin/visudo; do [ -x "$real" ] && break; done
    [ -x "$real" ] || return 0

    load_fleet
    K_PW[3]=$PW
    k_sudo_install 3
    assert_ok "$real" -cf "$(dropin "$IP3")"
}

# ── the file it installs ────────────────────────────────────────────────────
test_the_drop_in_is_named_allumeur_with_no_dot_in_it() {
    # sudo ignores every name in that directory containing a dot or ending in ~, silently.
    # `allumeur.conf` would install cleanly, validate cleanly, and do nothing at all.
    load_fleet
    K_PW[3]=$PW
    assert_rc 0 k_sudo_install 3
    assert_eq "allumeur" "$(dropin_names "$IP3")" "exactly one file, named exactly that"
}

test_the_drop_in_is_mode_0440_owned_by_root() {
    load_fleet
    K_PW[3]=$PW
    : > "$STUB_LOG"
    assert_rc 0 k_sudo_install 3
    assert_eq "440" "$(stat -c %a "$(dropin "$IP3")")" \
        "sudo refuses a drop-in any wider than this, and says nothing about it"
    local ch; ch=$(stub_calls chown | grep sudoers.d | tail -1)
    assert_contains "$ch" "root:root" "owned by root, or sudo will not read it"
    assert_contains "$ch" "/.allumeur." \
        "and owned before the rename: the live path is never briefly wrong"
    assert_contains "$(stub_calls chmod | grep sudoers.d | tail -1)" "/.allumeur." \
        "same for the mode"
}

test_the_rule_grants_poweroff_and_nothing_wider() {
    load_fleet
    K_PW[3]=$PW
    k_sudo_install 3
    local r; r="$(cat "$(dropin "$IP3")")"
    assert_eq "$RULE" "$r" "the whole file, to the byte"
    assert_contains "$r" 'poweroff ""' "no arguments may be passed to it"
    assert_not_contains "$r" "NOPASSWD: ALL" "this is a power switch, not a way in"
    assert_not_contains "$r" "ALL=(ALL"
    assert_not_contains "$r" "systemctl" "which would be a way to start any unit as root"
    assert_not_contains "$r" "*" "no wildcard"
    assert_not_contains "$r" "/bin/sh" "no shell"
    assert_eq "1" "$(printf '%s\n' "$r" | grep -c .)" "one line, one grant"
}

test_installing_it_twice_leaves_one_rule() {
    load_fleet
    K_PW[3]=$PW
    assert_rc 0 k_sudo_install 3
    : > "$STUB_LOG"
    assert_rc 0 k_sudo_install 3 "a second run is a no-op that still succeeds"
    local r; r="$(cat "$(dropin "$IP3")")"
    assert_eq "$RULE" "$r" "not appended to, not duplicated"
    assert_eq "1" "$(printf '%s\n' "$r" | grep -c poweroff)"
    assert_eq "allumeur" "$(dropin_names "$IP3")"
    assert_eq "0" "$(stub_count visudo)" \
        "identical content short-circuits before anything is staged at all"
    assert_eq "440" "$(stat -c %a "$(dropin "$IP3")")" "and the mode is re-confirmed"
}

# ── the password ────────────────────────────────────────────────────────────
test_the_password_goes_down_stdin_and_appears_in_no_argv() {
    # `ps` is world-readable on these machines. sshpass -p and sudo on a command line both
    # put the password where every user of the box can read it.
    load_fleet
    K_PW[3]=$PW
    : > "$STUB_LOG"; : > "$STUB_LOG.trace"
    assert_rc 0 k_sudo_install 3

    assert_eq "$PW" "$(cat "$NODES/$IP3/.stdin_seen")" "sudo read it from its own stdin"
    assert_not_contains "$(cat "$STUB_LOG")" "$PW" "no argv on this side carried it"
    assert_not_contains "$(trace)" "$PW" "nor the command line the node was given"
    assert_not_contains "$(cat "$NODES/$IP3/.shipped")" "$PW" \
        "the script is not secret, but it is also not where the password goes"
    local ondisk
    ondisk=$(grep -rl "$PW" "$NODES/$IP3" --exclude=.stdin_seen --exclude=.password 2>/dev/null)
    assert_eq "" "$ondisk" "and it is nowhere on the node's disk"
}

test_a_wrong_password_installs_nothing_and_is_not_reported_as_a_bad_rule() {
    load_fleet
    K_PW[3]=wrong
    assert_rc 1 k_sudo_install 3
    assert_no_file "$(dropin "$IP3")"
}

# The script used to be uploaded to the connecting user's $HOME over one connection and run
# by root over a second one - and that account is precisely the account this feature exists
# because it CANNOT reach root, so between the two connections it could rewrite the file root
# was about to execute. There is no upload and no window now: the script travels inside the
# command. So the assertion is no longer "it is cleaned up afterwards" but the stronger
# "it was never on the node's disk to clean up".
test_the_script_it_ships_is_never_written_to_the_node() {
    load_fleet
    K_PW[3]=$PW
    k_sudo_install 3
    assert_file "$NODES/$IP3/.shipped" "the script really was delivered"
    assert_eq "" "$(ls -A "$NODES/$IP3" | grep -v '^\.\(ssh\|password\|stdin_seen\|shipped\|down\)$\|^etc$')" \
        "and nothing else was left on the node"
}

test_nothing_is_written_to_the_node_even_when_the_rule_is_refused() {
    load_fleet
    K_PW[3]=$PW
    stub visudo 1
    k_sudo_install 3
    assert_no_file "$NODES/$IP3/.shipped-sudoers.sh"
    assert_eq "" "$(dropin_names "$IP3")" "and no staged file survived in sudoers.d either"
}

test_a_username_that_would_write_a_second_wider_rule_is_refused() {
    # The one piece of outside data that reaches sudoers. A newline in it appends a rule of
    # the caller's choosing to the file about to become policy.
    load_fleet
    K_USER[3]=$'maddev\nevil ALL=(ALL) NOPASSWD: ALL'
    K_PW[3]=$PW
    k_sudo_install 3
    assert_no_file "$(dropin "$IP3")" "nothing at all is installed"
    assert_eq "" "$(dropin_names "$IP3")"
}

# ── proving it from outside ─────────────────────────────────────────────────
test_the_grant_is_proved_over_a_separate_ordinary_connection() {
    # `sudo -n` inside the session that just ran proves nothing: that session is root
    # already. The claim is only worth what an ordinary master-key connection says.
    load_fleet
    K_PW[3]=$PW
    : > "$STUB_LOG.trace"
    assert_rc 0 k_op_sudoers 3
    local t; t="$(trace)"
    local install_line verify_line
    install_line=$(printf '%s\n' "$t" | grep -n 'sudo -S' | tail -1 | cut -d: -f1)
    verify_line=$(printf '%s\n' "$t" | grep -n 'sudo -n -l' | tail -1 | cut -d: -f1)
    assert_ok test -n "$install_line"
    assert_lt "$install_line" "$verify_line" "asked again after the install, not during it"
    assert_contains "$(printf '%s\n' "$t" | sed -n "${verify_line}p")" "$SSH_KEY" \
        "and asked over the master key, as an ordinary user"
    assert_file "$K_RUN/n3/granted"
    k_st_read 3; assert_eq "ok" "$K_S"; assert_eq "poweroff ok" "$K_D"
}

test_a_rule_sudo_would_ignore_is_reported_as_a_failure_however_well_it_installed() {
    # The installer said SUDOOK and the file is on the node - but it kept mktemp's 0600, so
    # sudo skips it in silence. Only the outside check can tell the difference.
    load_fleet
    K_PW[3]=$PW
    # The mode never gets set, so the drop-in keeps mktemp's 0600. Only the stub's body
    # changes here; it is already on PATH and already executable.
    printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/chmod"
    assert_rc "$K_FAILED" k_op_sudoers 3
    assert_file "$(dropin "$IP3")" "the file is there"
    k_st_read 3
    assert_eq "nok" "$K_S" "and it is still a failure, because sudo will not read it"
    assert_eq "no sudo rule" "$K_D"
    assert_file "$K_RUN/n3/nogrant"
}

test_a_node_that_already_has_the_permission_is_left_alone() {
    load_fleet
    grant_rule "$IP3"
    : > "$STUB_LOG"
    assert_rc 0 k_op_sudoers 3
    assert_eq "0" "$(stub_calls ssh | grep -c 'sudo -S')" "nothing was installed"
    assert_no_file "$K_RUN/n3/granted" "and the note does not claim a grant that never was"
    k_st_read 3; assert_eq "ok" "$K_S"; assert_eq "poweroff ok" "$K_D"
}

test_root_is_never_asked_for_anything() {
    # pfsense-wall is the one node where remote power-off has always worked: root does not go
    # through sudo, so there is nothing to grant and nothing to ask.
    load_fleet
    : > "$STUB_LOG"
    assert_rc 0 k_sudo_state 0
    assert_eq "0" "$(stub_count ssh)" "it did not even open a connection"
}

# ── the pass, over a fleet ──────────────────────────────────────────────────
test_only_the_node_that_needs_the_rule_is_touched() {
    # The index-0 bug: every worker addressing node 0 is invisible unless the node with
    # something to do is somewhere else.
    one_node_needs_it
    # The pass only ever queues nodes the main pass left reachable, so put the fleet where
    # the main pass would have left it: pi-blocker offline, everyone else ok.
    local i
    for i in 0 1 3 4; do k_st "$i" ok; done
    k_st 2 nok "luks locked"
    tty_says "$PW"
    k_grant_sudoers < /dev/null > "$SANDBOX/out" 2>&1

    assert_file "$(dropin "$IP3")" "the node that needed it got it"
    assert_eq "$RULE" "$(cat "$(dropin "$IP3")")"
    assert_eq "" "$(dropin_names "$IP0")" "root was never queued into the pass"
    assert_eq "allumeur" "$(dropin_names "$IP1")" "an already-granted node is unchanged"
    assert_eq "$RULE" "$(cat "$(dropin "$IP1")")"
    assert_eq "" "$(dropin_names "$IP2")" "and the offline one was never in the pass"
    assert_eq "" "$(cat "$NODES/$IP1/.stdin_seen" 2>/dev/null)" \
        "no password was spent on a node that did not need one"
    assert_contains "$K_SUDO_NOTE" "1 node(s) can now be powered off remotely."
    assert_not_contains "$K_SUDO_NOTE" "still cannot"
}

test_the_pass_asks_nothing_of_a_fleet_that_already_has_the_rule() {
    one_node_needs_it
    grant_rule "$IP3"
    tty_says "$PW"
    : > "$STUB_LOG"
    drive_ensure

    assert_not_contains "$(out)" "needs a password" "the human is not bothered for nothing"
    assert_eq "0" "$(stub_calls ssh | grep -c 'sudo -S')" "and no sudo session was opened"
    assert_contains "$(out)" "poweroff ok" "it just says so on the board"
    assert_eq "" "$K_SUDO_NOTE" "with nothing to report either way"
}

test_a_password_already_given_for_a_node_is_reused_rather_than_asked_for_twice() {
    one_node_needs_it
    node_fs "$IP3" "$FOREIGN"          # our key is gone: this node has to be adopted first
    fake_sshpass
    tty_says "$PW"
    drive_ensure

    assert_eq "1" "$(out | grep -c 'needs a password')" \
        "asked once, during adoption, and never again for the same node"
    assert_contains "$(node_keys "$IP3")" "AAAAOLD" "the key went back on"
    assert_eq "$RULE" "$(cat "$(dropin "$IP3")")" "and the rule went on with the same password"
    assert_eq "$PW" "$(cat "$NODES/$IP3/.stdin_seen")"
}

test_the_prompt_says_what_the_password_is_actually_for() {
    # Telling the user their key was refused while collecting a password to change sudo on
    # their machine would be a lie, and the two prompts are one function apart.
    one_node_needs_it
    tty_says "$PW"
    drive_ensure

    local o; o="$(out)"
    assert_contains "$o" "immich-provider needs a password"
    assert_contains "$o" "remote power-off needs sudo."
    assert_contains "$o" "type the password to grant it."
    assert_not_contains "$o" "the master key was refused here." \
        "which is the other pass's reason, and not true here"
    assert_contains "$o" "allow remote power off" "and the board says which pass this is"
}

test_declining_the_grant_leaves_the_node_reachable_and_says_it_cannot_be_switched_off() {
    # ensure was asked to make the fleet reachable and it did. A user who declines a
    # privilege change has not failed that, but the report still has to be honest about
    # what the fleet can do.
    one_node_needs_it
    tty_empty
    drive_ensure

    assert_no_file "$(dropin "$IP3")" "nothing was written"
    local rep; rep="$(report)"
    assert_contains "$rep" " ok 4 / 5" "the declined node still counts as reached"
    assert_contains "$rep" "1 still cannot." "and the note says power-off is still out"
    local nok_block; nok_block=$(printf '%s\n' "$rep" | sed -n '/ nok /,$p')
    assert_not_contains "$nok_block" "immich-provider" "declining is not a failure of ensure"
}

test_the_pass_runs_before_the_machines_are_put_back_to_sleep() {
    # The whole point: the rule is worthless unless the sleep pass can use it in the same
    # run. immich-provider is off, gets woken, gets the rule, and only then is switched off with
    # the very grant this run installed.
    one_node_needs_it
    set_down "$IP3"
    tty_says "$PW"
    drive_ensure

    assert_eq "$RULE" "$(cat "$(dropin "$IP3")")"
    assert_file "$NODES/$IP3/.down" "and it really went back off"
    local rep; rep="$(report)"
    assert_contains "$rep" "1 node(s) can now be powered off remotely."
    assert_contains "$rep" "1 woken node(s) put back off."
    assert_not_contains "$rep" "would NOT go off"
}

test_without_the_grant_the_same_woken_node_stays_up() {
    # The measured behaviour of three of the four live nodes, and the reason this feature
    # exists. Same fixture, same run, the prompt declined.
    one_node_needs_it
    set_down "$IP3"
    tty_empty
    drive_ensure

    assert_no_file "$NODES/$IP3/.down" "sudo asked for a password and polkit said no"
    local rep; rep="$(report)"
    assert_contains "$rep" "no poweroff"
    assert_contains "$rep" "1 would NOT go off."
    assert_contains "$rep" "NOPASSWD" "and the fix it prints is the rule that was declined"
}

# ── add node ────────────────────────────────────────────────────────────────
# The record is saved before the grant is even offered, so every one of these also asserts
# that a node the user added is a node the user has.
add_node_input() {   # menu answer for the sudo grant: y | n
    # The two empty lines after the subtitle answer the pretty ask (none) and the
    # shelf-position ask (the end). The keystroke pair before the grant answer: 'y' = sshd
    # answers after a wake, 'y' = favourite.
    printf '%s\n%s\n%s\n%s\n%s\n%s\n\n\nyy%s' \
        "$IP3" "02:00:00:00:00:14" "immich-provider" "maddev" "$PW" "Sensors" "$1"
}

drive_add_node() {
    source "$SRC_DIR/nodes.sh"
    set_blob ''
    node_fs "$IP3" "$OLD_PUB"          # ssh-copy-id's work, already done
    stub sshpass 0                     # the key push itself is not what is under test
    stub curl 7; stub jq 1
    add_node_input "$1" | add_node > "$SANDBOX/out" 2>&1
}

test_add_node_installs_the_rule_when_the_user_says_yes() {
    drive_add_node y
    assert_eq "$RULE" "$(cat "$(dropin "$IP3")")" "the rule is the same one the pass writes"
    assert_eq "440" "$(stat -c %a "$(dropin "$IP3")")"
    assert_eq "$PW" "$(cat "$NODES/$IP3/.stdin_seen")" "paid for with the password in hand"
    assert_contains "$(out)" "remote power off allowed"
    assert_contains "$(written_blob)" "$IP3,immich-provider,maddev,Sensors,0,1" "and the node is saved"
}

test_add_node_installs_nothing_when_the_user_says_no() {
    drive_add_node n
    assert_eq "" "$(dropin_names "$IP3")" "a privilege change nobody asked for is not made"
    assert_no_file "$NODES/$IP3/.stdin_seen" "and no sudo session was opened at all"
    assert_contains "$(written_blob)" "$IP3,immich-provider,maddev,Sensors,0,1"
}

test_add_node_still_saves_the_node_when_the_grant_fails() {
    stub visudo 1                      # that node's visudo refuses the rule
    drive_add_node y
    assert_eq "" "$(dropin_names "$IP3")"
    assert_contains "$(out)" "could not grant it"
    assert_contains "$(out)" "ensure reachability" "with the one place that can retry it"
    assert_contains "$(written_blob)" "$IP3,immich-provider,maddev,Sensors,0,1" \
        "the node is added either way"
}

test_add_node_never_offers_the_grant_to_a_root_node() {
    source "$SRC_DIR/nodes.sh"
    set_blob ''
    node_fs "$IP0" "$OLD_PUB"
    stub sshpass 0; stub curl 7; stub jq 1
    printf '%s\n%s\n%s\n%s\n%s\n%s\n\n\ny' \
        "$IP0" "02:00:00:00:00:12" "pfsense-wall" "root" "$PW" "Gaming!" \
        | add_node > "$SANDBOX/out" 2>&1
    assert_not_contains "$(out)" "allow powering it off remotely" \
        "root does not go through sudo, so there is nothing to grant"
    assert_eq "" "$(dropin_names "$IP0")"
    assert_contains "$(written_blob)" "$IP0,pfsense-wall,root,Gaming!,0,1"
}

test_a_prompt_with_no_terminal_to_read_is_a_skip_not_a_crash() {
    # `read < /dev/tty` fails outright when there is no controlling terminal, leaving pw
    # unset - and under `set -u` that killed the entire run mid-flight instead of taking the
    # skip. A terminal we cannot read from means the user cannot answer, which is a skip.
    one_node_needs_it
    local i
    for i in 0 1 3 4; do k_st "$i" ok; done
    k_st 2 nok "luks locked"
    tty_absent
    k_grant_sudoers < /dev/null > "$SANDBOX/out" 2>&1
    local rc=$?

    assert_eq "0" "$rc" "the run survives a terminal it cannot read"
    k_st_read 3
    assert_eq "ok" "$K_S" "and the node is not failed for it"
    assert_eq "no sudo rule" "$K_D" "it is recorded as declined, like any other skip"
    assert_eq "" "$(dropin_names "$IP3")" "nothing was installed without an answer"
}
