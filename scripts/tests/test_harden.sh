#!/usr/bin/env bash
# The hardening, as properties rather than as diffs.
#
# Everything here is about a claim that is cheap to make and expensive to be wrong about:
# that the sudoers grant leaves nothing behind and spends the password nowhere it can be
# read, that "this node can already power itself off" is not answered by pattern-matching a
# word out of `sudo -n -l`, that a privilege change is always offered and never assumed, and
# that the record the whole fleet is loaded from is read field for field.
#
# The node under test is index 3 in every fixture. `local i=$1 v=${ARR[$i]}` addresses index
# 0 for every worker, and a one-node fixture agrees with that bug in perfect silence.
#
# The fake node keeps only what a node really has - ~/.ssh and /etc/sudoers.d. Its password,
# its reachability, and everything the stubs record live outside it in $REC, so "the
# installer left no file on the node" can be asserted as an exact listing rather than a
# hopeful grep.

OLD_PUB='ssh-ed25519 AAAAOLD allumeur-master-key'
FOREIGN='ssh-ed25519 AAAAFOREIGN tmorolias@protonmail.com'

# The real fleet in its real order: pfsense-wall is root and has nothing to grant, pi-blocker is the
# LUKS box, and immich-provider - index 3 - is the node every test below acts on.
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
# What the installer must produce, to the byte.
RULE='maddev ALL=(root) NOPASSWD: /usr/sbin/poweroff "", /sbin/poweroff ""'

setup() {
    source "$SRC_DIR/lib.sh"
    source "$SRC_DIR/keys.sh"

    SSH_KEY="$HOME/.allumeur-scripts/encrypted/allumeur-master-key"
    printf 'PRIVOLD\n' > "$SSH_KEY"; printf '%s\n' "$OLD_PUB" > "$SSH_KEY.pub"

    NODES="$SANDBOX/nodes"; mkdir -p "$NODES"; export NODES
    # Nothing the test needs to remember may live inside a node directory: that directory is
    # the assertion.
    REC="$SANDBOX/rec"; mkdir -p "$REC"; export REC
    export TMPDIR="$SANDBOX"           # k_begin mktemp -d's here, so teardown reaps it
    K_PREV_FRAME=''; K_PREV_ROWS=0

    K_ICMP_BUDGET=1; K_SSHD_BUDGET=1; K_GRACE_BUDGET=1; K_SLEEP_BUDGET=6

    # api_toggle is a nodes.sh function, not a PATH stub. Absent by default: the backend
    # being down is what forces the ssh path, which is the path the rule is for.
    API_TOGGLE_RC=1
    api_toggle() {
        printf 'api_toggle\t%s\n' "$*" >> "$STUB_LOG"
        [ "$API_TOGGLE_RC" = 0 ] || return 1
        case "$4" in on) rm -f "$REC/down.$2" ;; esac
        return 0
    }

    set_blob "$FLEET_BLOB"
    fake_ssh
    stub clear
    stub sshpass 1                     # no password path unless a test opts in
    stub visudo 0                      # the node's own syntax check, passing
    stub_script chown <<'EOF'
exit 0
EOF
    cat > "$STUB_DIR/wakeonlan" <<'EOF'
#!/usr/bin/env bash
printf 'wakeonlan\t%s\n' "$*" >> "$STUB_LOG"
for a in "$@"; do case "$a" in 192.168.*) rm -f "$REC/down.$a" ;; esac; done
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
# `sudo -n -l` answers out of the drop-in only where sudo would really read it: a dotted
# name or a mode wider than 0440 is skipped without a word, and that silence is what the
# outside verification exists to catch. `poweroff` obeys only where such a rule grants it,
# so "the machine went off" is a statement about the rule and not about the test's goodwill.
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
[ -f "$REC/down.$ip" ] && { echo "ssh: connect to host $ip port 22: No route to host" >&2; exit 255; }
if [ -n "$key" ] && [ -f "$key.pub" ]; then
    blob=$(awk '{print $2}' "$key.pub")
    awk '{print $2}' "$nodedir/.ssh/authorized_keys" 2>/dev/null | grep -qx "$blob" \
        || { echo "$target: Permission denied (publickey,password)." >&2; exit 255; }
else
    echo "$target: Permission denied (publickey,password)." >&2; exit 255
fi

sudo_list() {
    # A test can dictate the listing verbatim; otherwise it comes from the drop-in, and only
    # when sudo would actually read that file.
    [ -f "$REC/sudolist.$ip" ] && { cat "$REC/sudolist.$ip"; return 0; }
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
        # The collision the installer is built around: sudo takes its password from ITS own
        # stdin, one line, and the rest of that channel is nobody's.
        IFS= read -r pw
        printf '%s\n' "$pw" >> "$REC/stdin.$ip"
        if [ "$pw" != "$(cat "$REC/pw.$ip" 2>/dev/null)" ]; then
            echo "sudo: Sorry, try again." >&2; exit 1
        fi
        # The script travels inside the command line, base64'd, and the node's own shell
        # decodes it into `sh -c` with the username as $1. There is no /etc/sudoers.d to
        # write to here, so the single absolute path in it is repointed at this node's fake
        # root; the filename, the mktemp template, visudo, the mode and the order of all of
        # it are the real script's.
        b64=${cmd#*printf %s \'}; b64=${b64%%\'*}
        u64=${cmd##*allumeur \'}; u64=${u64%\'}
        printf '%s\n' "$cmd" >> "$REC/rootargv.$ip"
        printf %s "$b64" | base64 -d | sed "s#/etc/sudoers.d#$sd#g" > "$REC/rootscript.$ip"
        HOME="$nodedir" sh -c "$(cat "$REC/rootscript.$ip")" allumeur "$u64"
        exit $? ;;
    *poweroff*)
        # The measured problem, modelled: with no rule sudo asks for a password nobody can
        # type, polkit refuses the session, stderr is discarded, and the machine stays up.
        if [ "${target%@*}" = root ] || [ -n "$(sudo_list)" ]; then : > "$REC/down.$ip"; fi
        exit 0 ;;
    "echo __KOK__") echo "__KOK__" ;;
    "sh -s -- "*) HOME="$nodedir" sh -s -- ${cmd#sh -s -- } ;;
    *) HOME="$nodedir" sh -c "$cmd" ;;
esac
FAKE
    chmod +x "$STUB_DIR/ssh"

    cat > "$STUB_DIR/ping" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in 192.168.*|10.*) ip="$a";; esac; done
[ -f "$REC/down.$ip" ] && exit 1
exit 0
FAKE
    chmod +x "$STUB_DIR/ping"
}

# sshpass with the right password gets in where the key could not, and runs the real writer.
fake_sshpass() {
    cat > "$STUB_DIR/sshpass" <<'FAKE'
#!/usr/bin/env bash
printf 'sshpass\t%s\n' "$*" >> "$STUB_LOG"
args=("$@"); target=""; cmd=""
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in *@*) target="${args[$i]}"; cmd="${args[*]:$((i+1))}"; break ;; esac
done
ip="${target#*@}"
printf '%s\n' "${SSHPASS-}" >> "$REC/sshpass_env"
HOME="$NODES/$ip" sh -s -- ${cmd#sh -s -- }
FAKE
    chmod +x "$STUB_DIR/sshpass"
}

# ── fixtures ────────────────────────────────────────────────────────────────
node_fs() {   # ip pubkey... - the node's whole filesystem, and nothing of the test's
    local ip=$1; shift
    mkdir -p "$NODES/$ip/.ssh" "$NODES/$ip/etc/sudoers.d"
    printf '%s\n' "$@" > "$NODES/$ip/.ssh/authorized_keys"
    printf '%s' "$PW" > "$REC/pw.$ip"
}
node_keys()  { cat "$NODES/$1/.ssh/authorized_keys" 2>/dev/null; }
node_files() { ( cd "$NODES/$1" 2>/dev/null && find . -type f | LC_ALL=C sort | tr '\n' ' ' ); }
set_down()   { : > "$REC/down.$1"; }
sudo_says()  { printf '%s\n' "$2" > "$REC/sudolist.$1"; }
stdin_seen() { cat "$REC/stdin.$1" 2>/dev/null; }

sudoers_dir()  { printf '%s' "$NODES/$1/etc/sudoers.d"; }
dropin()       { printf '%s' "$NODES/$1/etc/sudoers.d/allumeur"; }
dropin_names() { ls -A "$(sudoers_dir "$1")" 2>/dev/null; }

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
# immich-provider - index 3 - the one node with something to do.
one_node_needs_it() {
    load_fleet
    grant_rule "$IP1"; grant_rule "$IP4"
    set_down "$IP2"
}

# The fleet as the main pass would have left it, frozen the way keys_ensure freezes it.
main_pass_done() {
    local i
    for i in 0 1 3 4; do k_st "$i" ok; done
    k_st 2 nok "luks locked"
    k_snapshot
}

tty_says()  { printf '%s\n' "$1" > "$SANDBOX/tty"; K_TTY="$SANDBOX/tty"; }
tty_empty() { : > "$SANDBOX/tty"; K_TTY="$SANDBOX/tty"; }

drive_ensure() {
    interactive_menu() { return "${MENU_RC:-0}"; }
    keys_ensure < /dev/null > "$SANDBOX/out" 2>&1
}
out()    { sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' "$SANDBOX/out"; }
report() { out | sed -n '/- report/,$p'; }
trace()  { cut -f2- "$STUB_LOG.trace" 2>/dev/null; }

# ── nothing is left on the node ─────────────────────────────────────────────
test_the_installer_leaves_no_file_of_its_own_on_the_node() {
    # The version this replaced uploaded the script into the connecting user's $HOME and ran
    # it as root over a second connection - a window in which precisely the account that
    # cannot reach root could rewrite the file root was about to execute. Nothing is written
    # now, so there is no window and nothing to clean up, and this is how that stays true.
    load_fleet
    K_PW[3]=$PW
    assert_eq "./.ssh/authorized_keys " "$(node_files "$IP3")" "the node before"
    assert_rc 0 k_sudo_install 3
    assert_eq "./.ssh/authorized_keys ./etc/sudoers.d/allumeur " "$(node_files "$IP3")" \
        "the drop-in, and not one byte else: no uploaded script, no staged temp file"
}

test_a_refused_rule_leaves_no_file_of_its_own_on_the_node_either() {
    load_fleet
    K_PW[3]=$PW
    stub visudo 1                       # that node's own visudo says no
    assert_rc 2 k_sudo_install 3
    assert_eq "./.ssh/authorized_keys " "$(node_files "$IP3")" \
        "a rejected install is not a half-finished one"
}

test_the_installer_acts_on_the_node_it_was_given_and_not_on_node_zero() {
    load_fleet
    : > "$STUB_LOG.trace"
    K_PW[3]=$PW
    assert_rc 0 k_sudo_install 3
    local t; t="$(trace)"
    assert_contains "$t" "$IP3" "the connection went to the node it was handed"
    assert_not_contains "$t" "$IP0" "and nowhere near index 0"
    assert_eq "" "$(dropin_names "$IP0")"
    assert_eq "" "$(stdin_seen "$IP0")" "root was never asked for a password it does not have"
}

# ── the password ────────────────────────────────────────────────────────────
test_no_argv_on_either_side_ever_carries_the_sudoers_password() {
    # /proc/<pid>/cmdline is 0444 on these machines, so an argv is a broadcast. The password
    # has exactly one legitimate route: sudo's own stdin.
    load_fleet
    K_PW[3]=$PW
    : > "$STUB_LOG"; : > "$STUB_LOG.trace"
    assert_rc 0 k_sudo_install 3

    assert_eq "$PW" "$(stdin_seen "$IP3")" "sudo read it from its own stdin"
    assert_not_contains "$(cat "$STUB_LOG")" "$PW" \
        "no argv recorded on this side carried it - ssh's included"
    assert_not_contains "$(trace)" "$PW" "nor the command line the node was handed"
    assert_not_contains "$(cat "$REC/rootargv.$IP3")" "$PW" \
        "nor the argv the node's own root shell was given"
    assert_not_contains "$(cat "$REC/rootscript.$IP3")" "$PW" \
        "the script is not secret, but it is also not where the password goes"
    # It is base64 that makes the script and the username safe to put in a command line, so
    # the obvious way to leak the password is to send it the same way.
    assert_not_contains "$(cat "$STUB_LOG")" "$(printf %s "$PW" | base64 -w0)" \
        "and not encoded into one either"
    assert_eq "" "$(grep -rl "$PW" "$NODES/$IP3" 2>/dev/null)" \
        "and it is nowhere on the node's disk"
}

test_a_mistyped_sudoers_password_goes_back_to_the_prompt_rather_than_failing_the_node() {
    # sudo not taking the password is the one failure in this tool that another go can fix.
    # Anywhere else a refusal is final; here it must not be, or a typo costs a whole run.
    load_fleet
    K_PW[3]=wrong
    assert_rc "$K_NEEDPASS" k_op_sudoers 3
    k_st_read 3
    assert_eq "need_pass" "$K_S" "back to the one place a human can answer"
    assert_eq "sudoers" "$K_D" "and it still says what the password is for"
    assert_no_file "$K_RUN/n3/nogrant" "a typo is not yet a decline"
    assert_no_file "$(dropin "$IP3")"

    K_PW[3]=$PW
    assert_rc 0 k_op_sudoers 3 "the retry is an ordinary run, not a special case"
    assert_eq "$RULE" "$(cat "$(dropin "$IP3")")"
    assert_file "$K_RUN/n3/granted"
    assert_eq "wrong"$'\n'"$PW" "$(stdin_seen "$IP3")" \
        "both attempts really reached sudo, the wrong one first"
}

test_an_empty_sudoers_password_skips_the_node_without_failing_it() {
    load_fleet
    k_st 3 need_pass "sudoers"
    tty_empty
    assert_rc 1 k_prompt_pw 3 > /dev/null
    k_st_read 3
    assert_eq "ok" "$K_S" "the node is reachable, which is all ensure was ever about"
    assert_eq "no sudo rule" "$K_D" "and the board is honest about what it cannot do"
    assert_file "$K_RUN/n3/nogrant" "counted, so the note can say one still cannot"
    assert_eq "" "$(dropin_names "$IP3")" "nothing was written"
}

test_a_node_adopted_by_password_is_still_asked_before_its_sudo_is_changed() {
    # The password was given to put the master key back. Spending it on a privilege change
    # the user was never offered the chance to refuse is a different transaction.
    one_node_needs_it
    node_fs "$IP3" "$FOREIGN"          # our key is gone: this node has to be adopted first
    fake_sshpass
    tty_says "$PW"
    drive_ensure

    local o; o="$(out)"
    assert_contains "$o" "immich-provider needs a password" "asked once, to restore the key"
    assert_contains "$o" "the master key was refused here."
    assert_contains "$o" "immich-provider needs your ok" "and asked again, for the sudo rule"
    assert_contains "$o" "remote power-off needs sudo."
    # That wording is only reachable when the pass has put the adoption passwords out of its
    # own reach and offered this one back - an assumed password prints the other prompt.
    assert_contains "$o" "y = use the password you gave." \
        "the password in hand is offered, never assumed"
    assert_contains "$(node_keys "$IP3")" "AAAAOLD" "the key went back on"
    assert_eq "$RULE" "$(cat "$(dropin "$IP3")")" "and the rule went on with the same password"
    assert_eq "0" "${#K_PW[@]}" "and neither copy of it outlives the run"
    assert_eq "0" "${#K_PW_ADOPT[@]}"
}

test_the_reuse_prompt_still_takes_no_for_an_answer() {
    # Offering it is only worth something if declining still works, which is the whole
    # difference between offering and assuming.
    load_fleet
    K_PW_ADOPT[3]=$PW
    k_st 3 need_pass "sudoers"
    tty_empty
    assert_rc 1 k_prompt_pw 3 > "$SANDBOX/out"
    assert_contains "$(out)" "y = use the password you gave."
    assert_eq "" "${K_PW[3]:-}" "the adoption password was not spent on it"
    assert_file "$K_RUN/n3/nogrant"
    k_st_read 3; assert_eq "ok" "$K_S"
}

# ── reading `sudo -n -l` ────────────────────────────────────────────────────
test_a_nopasswd_on_one_line_says_nothing_about_a_poweroff_on_another() {
    # The failure this removes: a node read as already-granted is never offered the rule and
    # then silently fails to power off, which is the one failure the feature exists to fix.
    load_fleet
    sudo_says "$IP3" 'User maddev may run the following commands on this host:
    (root) NOPASSWD: /usr/bin/apt-get
    (root) PASSWD: /usr/sbin/poweroff'
    assert_rc 1 k_sudo_state 3 "the tag holds only until the end of its own line"
}

test_a_passwd_retag_inside_one_line_ends_the_nopasswd_it_follows() {
    load_fleet
    sudo_says "$IP3" 'User maddev may run the following commands on this host:
    (root) NOPASSWD: /usr/bin/apt-get, PASSWD: /usr/sbin/poweroff'
    assert_rc 1 k_sudo_state 3 "per entry, not per line"
}

test_the_grant_this_tool_installs_is_recognised() {
    # The control the three tests around it need: an answer of "not granted" is only worth
    # something if a real grant is still read as one.
    load_fleet
    sudo_says "$IP3" 'User maddev may run the following commands on this host:
    (root) NOPASSWD: /usr/sbin/poweroff "", /sbin/poweroff ""'
    assert_rc 0 k_sudo_state 3
}

test_a_blanket_root_grant_is_not_accepted_as_poweroff_ok() {
    # Somebody hand-wrote a way in, not a power switch. Reporting it as `poweroff ok` is how
    # it stays unnoticed for as long as the file lasts.
    load_fleet
    sudo_says "$IP3" 'User maddev may run the following commands on this host:
    (ALL) NOPASSWD: ALL'
    assert_rc 1 k_sudo_state 3
}

test_a_root_grant_sitting_in_our_own_drop_in_is_not_accepted_either() {
    # Same file, same name, same mode - everything except the rule. Read out of the drop-in
    # itself rather than out of a fixture, because that is where it would really be.
    load_fleet
    local f; f="$(dropin "$IP3")"
    printf '%s\n' 'maddev ALL=(ALL) NOPASSWD: ALL' > "$f"; chmod 0440 "$f"
    assert_rc 1 k_sudo_state 3 "a full root grant is not the thing this pass is looking for"

    K_PW[3]=$PW
    assert_rc 0 k_op_sudoers 3
    assert_eq "$RULE" "$(cat "$f")" \
        "and the pass replaces it with the grant it does install, wider going to narrower"
    assert_rc 0 k_sudo_state 3
}

# ── the remote guard on the username ────────────────────────────────────────
test_a_username_of_ALL_is_refused_by_the_node() {
    # `ALL ALL=(root) NOPASSWD: poweroff` passes visudo and hands the power switch to every
    # account on the host. Metacharacters are not the whole of it: a name sudoers reads as a
    # keyword is not a user.
    load_fleet
    K_USER[3]=ALL
    K_PW[3]=$PW
    assert_rc 2 k_sudo_install 3 "refused by the node, which is where the rule is written"
    assert_eq "" "$(dropin_names "$IP3")" "nothing at all is installed"
    assert_eq "./.ssh/authorized_keys " "$(node_files "$IP3")"
}

test_a_username_that_is_a_sudoers_keyword_is_refused_by_the_node() {
    load_fleet
    K_PW[3]=$PW
    local u
    for u in Defaults User_Alias Runas_Alias Host_Alias Cmnd_Alias ROOT; do
        K_USER[3]=$u
        assert_rc 2 k_sudo_install 3 "$u is a word sudoers already owns"
        assert_eq "" "$(dropin_names "$IP3")" "and nothing was written for it"
    done
}

# ── the pass may not overwrite the operation's own verdict ──────────────────
test_declining_the_grant_does_not_turn_a_reached_node_into_a_failed_ensure() {
    one_node_needs_it
    main_pass_done
    tty_empty
    k_grant_sudoers < /dev/null > "$SANDBOX/out" 2>&1
    k_report "ensure reachability" "$K_SUDO_NOTE" < /dev/null >> "$SANDBOX/out" 2>&1

    local rep; rep="$(report)"
    assert_contains "$rep" " ok 4 / 5" "the declined node still counts as reached"
    assert_contains "$rep" "1 still cannot." "and the note is honest about the power switch"
    assert_not_contains "$(printf '%s\n' "$rep" | sed -n '/ nok /,$p')" "immich-provider" \
        "declining a privilege change is not a failure of ensure"
}

test_a_node_that_drops_off_between_passes_keeps_the_verdict_the_run_earned_it() {
    # It answered a moment ago in the main pass and does not now. The sudoers pass genuinely
    # fails, and must still not be given a veto over what ensure already decided - that is
    # the whole reason the verdict is frozen rather than read live.
    one_node_needs_it
    main_pass_done
    set_down "$IP3"
    tty_says "$PW"
    k_grant_sudoers < /dev/null > "$SANDBOX/out" 2>&1

    k_st_read 3
    assert_eq "nok" "$K_S" "the pass really did fail on it"
    k_st_final 3
    assert_eq "ok" "$K_S" "and the report reads the operation's own result"

    k_report "ensure reachability" "$K_SUDO_NOTE" < /dev/null > "$SANDBOX/out" 2>&1
    assert_contains "$(report)" " ok 4 / 5"
    assert_not_contains "$(printf '%s\n' "$(report)" | sed -n '/ nok /,$p')" "immich-provider"
}

# ── add node ────────────────────────────────────────────────────────────────
# The one answer in that dialogue that is a live credential. It lives in a file and never in
# a variable of this test's, so the sweep for a leaked copy cannot find its own fixture.
secret() { cat "$SANDBOX/secret"; }

add_node_stdin() {   # name user subtitle grant-answer -> the whole conversation, in order
    # The two empty lines after the subtitle take the pretty ask's default (none) and the
    # shelf-position ask's default (the end).
    # The keystroke pair before the grant answer: 'y' = sshd answers, 'y' = favourite.
    { printf '%s\n' "$IP3" "02:00:00:00:00:14" "$1" "$2" "$(secret)" "$3" "" ""
      printf 'yy%s' "$4"; } > "$SANDBOX/in"
}

drive_add_node() {
    source "$SRC_DIR/nodes.sh"
    set_blob ''
    node_fs "$IP3" "$OLD_PUB"
    secret > "$REC/pw.$IP3"
    stub curl 7; stub jq 1
    add_node < "$SANDBOX/in" > "$SANDBOX/out" 2>&1
}

test_add_node_never_puts_the_password_in_an_argv_and_does_not_keep_it_afterwards() {
    # The password is read here and spent twice - once on ssh-copy-id, once on the sudo
    # grant. It is the only answer in this dialogue that is a live credential.
    printf 'n0d3-t3mp-secret' > "$SANDBOX/secret"
    stub_script sshpass <<EOF
printf '%s\n' "\${SSHPASS-}" >> "$REC/sshpass_env"
exit 0
EOF
    add_node_stdin immich-provider maddev Sensors y
    drive_add_node

    # Never into a variable of this test's own: the last assertion below is a sweep of every
    # variable this shell holds, and a local would answer it with itself.
    assert_eq "$(secret)" "$(cat "$REC/sshpass_env")" "the key push got it through the environment"
    local sp; sp="$(stub_calls sshpass)"
    assert_contains "$sp" "-e" "which is what -e means"
    assert_not_contains "$sp" "-p" "never -p, which would hand it to every account on the box"
    assert_not_contains "$(cat "$STUB_LOG")" "$(secret)" "no argv recorded on this side carried it"
    assert_not_contains "$(trace)" "$(secret)" "nor any command line a node was handed"
    assert_not_contains "$(written_blob)" "$(secret)" "and it never reaches the record"
    assert_eq "$(secret)" "$(stdin_seen "$IP3")" "the grant paid for itself down sudo's stdin"

    # Called with a redirect and not through a pipe, so it ran in this shell: whatever it
    # left behind is still here to be looked at.
    assert_eq "" "$(declare -p pass 2>/dev/null)" "the variable that held it is gone"
    assert_eq "" "${SSHPASS:-}" "and it was never exported into the shell that runs the TUI"
    assert_eq "0" "${#K_PW[@]}" "nor left in the run's password array"
    # `set -o posix` is what makes `set` print variables and not also every function body -
    # this file's own source would otherwise match itself. $_ is excluded because bash
    # rewrites it to the last argument of every command, which is bash's bookkeeping and not
    # anything add_node left behind. The needle is read from a file so no local of this test
    # is in the dump either.
    assert_eq "" "$( ( set -o posix; set ) | grep -F "$(secret)" | grep -Ev '^_=' )" \
        "no variable in this shell still holds it"
}

test_a_comma_in_the_name_or_the_username_cannot_write_a_malformed_record() {
    # The record is unquoted CSV with two trailing flags, so a comma in ANY field writes an
    # eighth: every reader then slices the flags out of a neighbour, reads the luks flag as
    # not-blocked, and wakes the one machine that must never be woken.
    printf 'n0d3-t3mp-secret' > "$SANDBOX/secret"
    stub sshpass 0
    { printf '%s\n' "$IP3" "02:00:00:00:00:14" "atmo,sphere" "immich-provider" \
                    "mad,dev" "maddev" "$(secret)" "Sen,sors" "Sensors" "Glam,Box" "Glam Box" ""
      printf 'yyn'; } > "$SANDBOX/in"     # order default, sshd yes, favourite yes, grant no
    drive_add_node

    local b; b="$(written_blob | grep '[^[:space:]]')"
    assert_eq "02:00:00:00:00:14,$IP3,immich-provider,maddev,Sensors,0,1,1,Glam Box" "$b" \
        "the record is the one the user meant, not the one the comma would have written"
    assert_eq "9" "$(printf '%s' "$b" | awk -F, '{print NF}')" "nine fields, two flags, the order and the pretty"
    assert_eq "4" "$(out | grep -c 'a comma splits the record')" \
        "each comma was refused where it was typed, not silently swallowed - the pretty included"
}

test_ask_field_re_asks_until_the_answer_has_no_comma_in_it() {
    source "$SRC_DIR/nodes.sh"
    local answer=''
    # Redirected, not piped: a pipeline would run ask_field in a subshell and the nameref it
    # writes through would die with it, leaving nothing to assert on.
    printf '%s\n' 'a,b' 'c,d' 'cd' > "$SANDBOX/in"
    ask_field "name" answer < "$SANDBOX/in" > /dev/null
    assert_eq "cd" "$answer" "the first comma-free answer wins, however many it took"
}

# ── the record, on both faces of the one database ───────────────────────────
# Distinct in every field, so a reader that shifts by one is caught rather than agreed with.
# The luks flag is on immich-provider and not on pi-blocker deliberately: it must follow the
# field it is in, not the name somebody recognises. The favourite (field 7) disagrees with
# the luks flag on every record where that is possible, for the same reason.
CANON='02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,Gaming!,0,1,2,The Wall
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,,0,0,5,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,operator,Workstation & NAS,0,1,1,Hole Filler
02:00:00:00:00:14,192.168.77.14,immich-provider,maddev,Sensors,1,0,4,
02:00:00:00:00:15,192.168.77.15,vault-warden,root,AI Ecosystem,0,1,3,Vault'

test_the_canonical_nine_field_record_is_read_field_for_field_by_bash() {
    set_blob "$CANON"
    k_begin; k_load_all

    assert_eq "5" "$K_N" "every record is a node - the favourite must not drop any"
    assert_eq "02:00:00:00:00:14" "${K_MAC[3]:-}"
    assert_eq "192.168.77.14"     "${K_IP[3]:-}"
    assert_eq "immich-provider"        "${K_NAME[3]:-}"
    assert_eq "maddev"            "${K_USER[3]:-}"
    assert_eq "1"                 "${K_LUKS[3]:-}" "the flag is the sixth field of that record"
    assert_eq "0" "${K_LUKS[2]:-}" "and not of the machine whose name usually carries it"
    assert_eq "operator" "${K_USER[2]:-}" "the subtitle before it did not shift anything"
    assert_eq "0" "${K_LUKS[1]:-}" "an empty subtitle is a field, not a missing one"
    assert_eq "jelly-streamer" "${K_NAME[1]:-}"
    assert_not_contains "${K_NAME[2]:-}" "Workstation" "no field is carrying its neighbour"
    assert_not_contains "${K_USER[3]:-}" "Sensors"
    assert_eq "0" "${K_LUKS[0]:-}" "a favourite of 1 beside a luks of 0 stayed in its own field"
    # The ninth field: keys.sh ignores the pretty, but it must still be split off - folded
    # into $order it would junk every shelf position the next renumber reads.
    assert_not_contains "${K_NAME[2]:-}" "Hole" "the pretty stayed out of every field a keys run uses"
}

test_the_canonical_record_survives_the_second_parse_in_nodes_sh() {
    # enter_shell and hit_lights rebuild the record and split it again before handing it to
    # the ladder, so a six-field record has to survive being read twice.
    set_blob "$CANON"
    source "$SRC_DIR/nodes.sh"
    node_fs "$IP3" "$OLD_PUB"
    stub curl 7; stub jq 1
    : > "$STUB_LOG"
    printf 'i' | enter_shell > "$SANDBOX/out" 2>&1     # 'i' = immich-provider
    assert_contains "$(out)" "shell: immich-provider" "it resolved and connected"
    assert_contains "$(stub_calls ssh)" "maddev@192.168.77.14" \
        "with the user and the ip of that record and no other"
}

# main.rs is the other reader of this database. There is no cargo on most machines that run
# this suite, so the real parser is asked where one can be built and the test stands down
# where it cannot - the same rule the real-visudo check follows.
main_rs() {
    local p
    for p in "$SRC_DIR/../backend/src/main.rs" "$SRC_DIR/../refs/backend/src/main.rs" \
             "/opt/allumeur/backend/src/main.rs"; do
        [ -f "$p" ] && { printf '%s' "$p"; return 0; }
    done
    return 1
}

# A compiler that answers --version, not merely a file on $PATH. On the server `rustc` is a
# rustup shim with no default toolchain behind it: it exists, it is executable, and every
# invocation fails. Skipping this cross-check where Rust cannot run is right - the server is
# the one machine that must never compile, which is why the binary is built on the workstation
# - but skipping it because the shim looked like a compiler would fail the deploy gate instead.
rustc_bin() {
    local c p
    c=$(command -v rustc 2>/dev/null)
    [ -n "$c" ] && "$c" --version >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }
    for p in /nix/store/*-rustc-*/bin/rustc; do
        [ -x "$p" ] && "$p" --version >/dev/null 2>&1 && { printf '%s' "$p"; return 0; }
    done
    return 1
}

# The record as the shell scripts read it, in the shape every one of them uses.
bash_reads() {
    local mac ip name user subtitle luks fav order pretty
    IFS=',' read -r mac ip name user subtitle luks fav order pretty <<< "$1"
    # The flags are compared, not printed: what has to match main.rs is the DECISION bash
    # makes - `[ "$luks" = 1 ]` for the wake gate, the same reading for the favourite, and
    # for the order the integer it parses to (junk or padding is not a position: 0, the
    # same deterministic fallback parse_order takes). The pretty is carried verbatim -
    # empty included: it is a display string, not a flag.
    [ "$luks" = 1 ] && luks=1 || luks=0
    [ "$fav" = 1 ] && fav=1 || fav=0
    case "$order" in ''|*[!0-9]*) order=0 ;; *) order=$((10#$order)) ;; esac
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s' "$mac" "$ip" "$name" "$user" "$subtitle" "$luks" "$fav" "$order" "$pretty"
}

test_the_canonical_record_is_read_the_same_by_the_backend() {
    # A database that answers differently to the WebGUI and the CLI is one that disagrees
    # about which machines are safe to wake.
    local rustc src
    rustc=$(rustc_bin) || return 0
    src=$(main_rs) || return 0

    mkdir -p "$SANDBOX/rs"
    { awk '/^fn parse_order/,/^\}/' "$src"
      awk '/^fn parse_node_record/,/^\}/' "$src"
      cat <<'EOF'
fn main() {
    let line = std::env::args().nth(1).unwrap_or_default();
    match parse_node_record(&line) {
        None => println!("NONE"),
        Some((m, i, n, u, s, l, f, o, p)) => println!("{}|{}|{}|{}|{}|{}|{}|{}|{}", m, i, n, u, s,
            if l { 1 } else { 0 }, if f { 1 } else { 0 }, o, p),
    }
}
EOF
    } > "$SANDBOX/rs/p.rs"
    assert_ok "$rustc" --edition 2021 -o "$SANDBOX/rs/p" "$SANDBOX/rs/p.rs" || return 1

    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        assert_eq "$(bash_reads "$line")" "$("$SANDBOX/rs/p" "$line")" \
            "the two faces read this record identically: [$line]"
    done <<< "$CANON"

    # The flags are written by this system and by nothing else, so each is 0 or 1 and is
    # compared byte-for-byte on both sides. What matters is that neither face invents a
    # reading the other does not share: "1 " is not a flag anywhere, and k_load_all refuses
    # such a luks outright rather than let the ladder read it as safe to wake.
    local padded='aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,Workstation,1 ,1,2,Racky'
    assert_eq "$(bash_reads "$padded")" "$("$SANDBOX/rs/p" "$padded")" \
        "both faces read a padded luks flag the same way"
    # Compared whole, not by substring: every field is |-joined and this node's IP begins
    # with a 1, so a "does it contain |1" test answers yes no matter what the flag says.
    assert_eq 'aa:bb:cc:dd:ee:ff|192.168.77.11|pi-blocker|maddev|Workstation|0|1|2|Racky' \
              "$("$SANDBOX/rs/p" "$padded")" "a padded flag is not the flag"
    local padfav='aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,Workstation,1,1 ,2,Racky'
    assert_eq "$(bash_reads "$padfav")" "$("$SANDBOX/rs/p" "$padfav")" \
        "and a padded favourite reads the same on both faces too"
    assert_eq 'aa:bb:cc:dd:ee:ff|192.168.77.11|pi-blocker|maddev|Workstation|1|0|2|Racky' \
              "$("$SANDBOX/rs/p" "$padfav")"
    local padord='aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,Workstation,1,1,2 ,Racky'
    assert_eq "$(bash_reads "$padord")" "$("$SANDBOX/rs/p" "$padord")" \
        "and a padded order reads the same on both faces: not a position at all"
    assert_eq 'aa:bb:cc:dd:ee:ff|192.168.77.11|pi-blocker|maddev|Workstation|1|1|0|Racky' \
              "$("$SANDBOX/rs/p" "$padord")"
}
