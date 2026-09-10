#!/usr/bin/env bash
# An operation is not one sweep of the fleet any more, it is a sequence of passes over the
# same fleet - main, then wipe, then sleep - and `k_run` is re-entered once per pass. That
# turns three previously-invisible things into properties worth pinning down: which nodes a
# pass is allowed to respawn, whose result the report is finally allowed to print, and
# whether the machines this run switched on actually went back off.
#
# The fake node is the pattern from test_keys_ops.sh: a stubbed `ssh` that authenticates the
# offered key against a real authorized_keys and pipes the real K_AK_SCRIPT into a real `sh`
# with the node's own $HOME. On top of that this file needs two things the earlier fakes did
# not model, because they are what the sleep pass is about:
#   * a machine that can be told to power off and simply does not - the measured behaviour of
#     three of the four live nodes, where sudo has no NOPASSWD rule and polkit says no;
#   * a network that drops the occasional packet, which is the difference between "asleep"
#     and "still running and lying about it".
#
# The interesting nodes are at indices 1, 2, 3 and 4. Index 0 is deliberately a boring node
# that must come out untouched: `local i=$1 v=${ARR[$i]}` silently addresses index 0 for
# every worker, and a fixture whose interesting node IS index 0 cannot see that.

OLD_PUB='ssh-ed25519 AAAAOLD allumeur-master-key'
NEW_PUB='ssh-ed25519 AAAANEW allumeur-master-key'
FOREIGN='ssh-ed25519 AAAAFOREIGN tmorolias@protonmail.com'
STALE1='ssh-ed25519 AAAASTALE1 allumeur-master-key'
STALE2='ssh-ed25519 AAAASTALE2 allumeur-master-key'

# The real fleet, in its real order, with the real LUKS box third. pfsense-wall is root and the
# rest are maddev, because that asymmetry is what the api_toggle assertions read.
FLEET_BLOB='02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,Gaming!,0,1,1,
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,Series & Movies,0,1,2,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,Workstation,1,0,3,
02:00:00:00:00:14,192.168.77.14,immich-provider,maddev,Sensors,0,1,4,
02:00:00:00:00:15,192.168.77.15,vault-warden,maddev,AI Ecosystem,0,1,5,'

IP0=192.168.77.12   # pfsense-wall,      root,   always up here
IP1=192.168.77.13   # jelly-streamer, maddev
IP2=192.168.77.11   # pi-blocker,        maddev, LUKS_BLOCKED=1
IP3=192.168.77.14   # immich-provider,    maddev
IP4=192.168.77.15   # vault-warden,     maddev

setup() {
    source "$SRC_DIR/lib.sh"
    source "$SRC_DIR/keys.sh"

    SSH_KEY="$HOME/.allumeur-scripts/encrypted/allumeur-master-key"
    printf 'PRIVOLD\n' > "$SSH_KEY"; printf '%s\n' "$OLD_PUB" > "$SSH_KEY.pub"

    NODES="$SANDBOX/nodes"; mkdir -p "$NODES"; export NODES
    export TMPDIR="$SANDBOX"          # k_begin mktemp -d's here, so teardown reaps it
    K_PREV_FRAME=''; K_PREV_ROWS=0

    # Every budget is a wall-clock wait. The sleep budget is counted down in units of the
    # `sleep 3` that is stubbed out below, so 6 means "two polls", not six seconds.
    K_ICMP_BUDGET=1; K_SSHD_BUDGET=1; K_GRACE_BUDGET=1; K_SLEEP_BUDGET=6

    # api_toggle lives in nodes.sh, so it cannot be a PATH stub. It doubles as the backend
    # simulator: when the backend answers, the machine really does change state - which is
    # what lets a test distinguish "asked it to power off" from "it powered off".
    API_TOGGLE_RC=1                   # backend absent by default
    export POWEROFF_OBEYED=1          # read by the ssh fake, hence exported
    api_toggle() {
        printf 'api_toggle\t%s\n' "$*" >> "$STUB_LOG"
        if [ "$API_TOGGLE_RC" = 0 ]; then
            case "$4" in
                on)  rm -f "$NODES/$2/.down" ;;
                off) [ "$POWEROFF_OBEYED" = 1 ] && : > "$NODES/$2/.down" ;;
            esac
        fi
        return "$API_TOGGLE_RC"
    }

    set_blob "$FLEET_BLOB"
    fake_ssh
    stub wakeonlan
    stub clear
    stub sshpass 1                    # no password path unless a test opts in
    fake_keygen
    # Silent, unlike `stub sleep`: the ICMP wait spins on it and a logged sleep would bury
    # the log the assertions read.
    printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/sleep"; chmod +x "$STUB_DIR/sleep"
    cat > "$STUB_DIR/tput" <<'EOF'
#!/usr/bin/env bash
[ "$1" = cols ] && { echo 40; exit 0; }
exit 0
EOF
    chmod +x "$STUB_DIR/tput"
}

# ── the blob ────────────────────────────────────────────────────────────────
# Two-way openssl stub: -in emits the fixture, -out captures what would have been written.
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
[ -f "$nodedir/.down" ] && { echo "ssh: connect to host $ip port 22: No route to host" >&2; exit 255; }
if [ -n "$key" ] && [ -f "$key.pub" ]; then
    blob=$(awk '{print $2}' "$key.pub")
    awk '{print $2}' "$nodedir/.ssh/authorized_keys" 2>/dev/null | grep -qx "$blob" \
        || { echo "$target: Permission denied (publickey,password)." >&2; exit 255; }
else
    echo "$target: Permission denied (publickey,password)." >&2; exit 255
fi
case "$cmd" in
    # The poweroff line is matched, never eval'd - it would take the machine running the
    # suite down with it. Whether the node obeys is the whole point of these tests.
    *poweroff*)
        [ "${POWEROFF_OBEYED:-1}" = 1 ] && : > "$nodedir/.down"
        exit 0 ;;
    "echo __KOK__") echo "__KOK__" ;;
    "sh -s -- "*)
        # A node whose authorized_keys writer fails: reachable, but the operation itself
        # cannot complete. The one shape of failure the pre-sleep snapshot exists for.
        [ -f "$nodedir/.akfail" ] && { echo "sh: cannot write authorized_keys" >&2; exit 1; }
        HOME="$nodedir" sh -s -- ${cmd#sh -s -- } ;;
    *) eval "$cmd" ;;
esac
FAKE
    chmod +x "$STUB_DIR/ssh"

    # `.pingfail` holds the 1-based sequence numbers of packets to this host that are lost.
    # One dropped packet must not settle any question, which is why k_pingable asks 3 times.
    cat > "$STUB_DIR/ping" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in 192.168.*|10.*) ip="$a";; esac; done
d="$NODES/$ip"
n=$(cat "$d/.pingn" 2>/dev/null); n=$((n + 1)); printf '%s' "$n" > "$d/.pingn"
[ -f "$d/.down" ] && exit 1
[ -f "$d/.pingfail" ] && grep -qw "$n" "$d/.pingfail" && exit 1
exit 0
FAKE
    chmod +x "$STUB_DIR/ping"
}

# keys_rotate mints a real key; the fake stands in for ssh-keygen so the blob of the new key
# is one the fake node can recognise.
fake_keygen() {
    cat > "$STUB_DIR/ssh-keygen" <<'FAKE'
#!/usr/bin/env bash
printf 'ssh-keygen\t%s\n' "$*" >> "$STUB_LOG"
f=""; c="allumeur-master-key"
while [ $# -gt 0 ]; do
    case "$1" in -f) f="$2"; shift ;; -C) c="$2"; shift ;; esac
    shift
done
printf 'PRIVNEW\n' > "$f"; printf 'ssh-ed25519 AAAANEW %s\n' "$c" > "$f.pub"
FAKE
    chmod +x "$STUB_DIR/ssh-keygen"
}

# sshpass with a password gets in where the key could not, and runs the same writer.
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

# ── fixture helpers ─────────────────────────────────────────────────────────
node_fs() {   # ip pubkey... - a node's real ~/.ssh/authorized_keys
    local ip=$1; shift
    mkdir -p "$NODES/$ip/.ssh"
    printf '%s\n' "$@" > "$NODES/$ip/.ssh/authorized_keys"
    chmod 700 "$NODES/$ip/.ssh"; chmod 600 "$NODES/$ip/.ssh/authorized_keys"
}
node_keys() { cat "$NODES/$1/.ssh/authorized_keys" 2>/dev/null; }
set_down()  { : > "$NODES/$1/.down"; }

# The whole fleet, up, each node holding the master key and somebody's personal key. Tests
# override individual nodes afterwards; node_fs touches no array, so order does not matter.
load_fleet() {
    local ip
    for ip in "$IP0" "$IP1" "$IP2" "$IP3" "$IP4"; do node_fs "$ip" "$OLD_PUB" "$FOREIGN"; done
    k_begin
    k_load_all
}

# k_run polls stdin for the abort key; /dev/null makes every poll a no-op. K_TTY points at
# an empty file so a node that unexpectedly asks for a password is skipped rather than
# blocking the suite forever on /dev/tty.
run_op() {
    : > "$SANDBOX/empty_tty"
    K_TTY="$SANDBOX/empty_tty" k_run "$1" < /dev/null > "$SANDBOX/out" 2>&1
}

# The operations as the menu invokes them, minus the human: the confirmation is taken, the
# report is captured. Everything that decides pass order - k_snapshot, k_wipe_stale,
# k_sleep_woken - is the real thing.
drive() {
    interactive_menu() { return "${MENU_RC:-0}"; }
    : > "$SANDBOX/empty_tty"; K_TTY="$SANDBOX/empty_tty"
    case "$1" in
        rotate) keys_rotate ;;
        purge)  keys_purge ;;
        ensure) keys_ensure ;;
    esac
}
drive_op() { drive "$1" < /dev/null > "$SANDBOX/out" 2>&1; }
out() { sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' "$SANDBOX/out"; }
# What k_report printed, and nothing the board printed on its way there. The board renders
# live state, so a `2 gone` or an `op failed` asserted over the whole capture can be
# satisfied by a frame the report then goes on to contradict.
report() { out | sed -n '/- report/,$p'; }
toggles() { stub_calls api_toggle; }

# ── pass 1: who a re-entered k_run is allowed to touch ──────────────────────
test_k_run_respawns_only_the_nodes_left_queued() {
    # This is what makes an operation a sequence of passes rather than a re-run: a node that
    # already reached a verdict in an earlier pass must keep it and must not be worked on
    # again. Doing the purge twice on pfsense-wall would be harmless; doing it to a node the
    # first pass had already written off as luks-locked would not be.
    load_fleet
    k_st 0 ok
    k_st 2 nok "luks locked"
    K_OP=purge K_ADOPT_PUB="$SSH_KEY.pub" K_ADOPT_KEY="$SSH_KEY"
    : > "$STUB_LOG"
    run_op "purge any other keys"

    local calls; calls="$(stub_calls ssh)"
    assert_not_contains "$calls" "$IP0" "an ok node is not respawned"
    assert_not_contains "$calls" "$IP2" "and neither is a nok one"
    assert_contains "$calls" "$IP1" "the queued nodes still run"
    assert_contains "$calls" "$IP3"
    assert_contains "$calls" "$IP4"

    k_st_read 0; assert_eq "ok" "$K_S" "the settled result is kept"
    assert_eq "" "$K_D" "and no pass overwrote its detail"
    k_st_read 2; assert_eq "nok" "$K_S"; assert_eq "luks locked" "$K_D"
    assert_contains "$(node_keys "$IP0")" "AAAAFOREIGN" "the skipped node was not purged"
    assert_eq "$OLD_PUB" "$(node_keys "$IP1")" "and the queued ones were"
    assert_eq "$OLD_PUB" "$(node_keys "$IP4")"
}

# ── pass 3: every operation puts back what it woke ──────────────────────────
# One fixture, three operations. Nodes 1 and 4 are off and get woken; node 2 is off and
# flagged, so it is never woken and therefore never slept; nodes 0 and 3 were already up and
# belong to whoever is using them.
sleeping_fleet() {
    load_fleet
    set_down "$IP1"; set_down "$IP2"; set_down "$IP4"
    API_TOGGLE_RC=0            # backend present: it wakes them, and it can switch them off
    : > "$STUB_LOG"
}

assert_woken_nodes_were_put_back() {
    local calls; calls="$(toggles)"
    assert_contains "$calls" "$IP1 maddev on"  "the backend was asked to wake it"
    assert_contains "$calls" "$IP1 maddev off" "and to put it back"
    assert_contains "$calls" "$IP4 maddev on"
    assert_contains "$calls" "$IP4 maddev off"
    assert_not_contains "$calls" "$IP0" "a node that was already up is never touched"
    assert_not_contains "$calls" "$IP3" "nor the other one"
    assert_not_contains "$calls" "$IP2" \
        "a luks-blocked node is never woken, so there is nothing to put back"
    assert_not_contains "$(stub_calls ssh)" "poweroff" \
        "the backend answered, so nothing was shelled at a node behind its back"
    assert_eq "2" "$K_SLEPT" "exactly the two nodes this run switched on"
    assert_eq "0" "$K_SLEPT_NOK"
}

test_rotate_puts_back_the_machines_it_woke() {
    sleeping_fleet
    drive_op rotate
    assert_woken_nodes_were_put_back
    assert_contains "$(node_keys "$IP1")" "AAAANEW" "and it did rotate them on the way"
    assert_contains "$(node_keys "$IP4")" "AAAANEW"
}

test_purge_puts_back_the_machines_it_woke() {
    sleeping_fleet
    drive_op purge
    assert_woken_nodes_were_put_back
    assert_eq "$OLD_PUB" "$(node_keys "$IP1")"
    assert_eq "$OLD_PUB" "$(node_keys "$IP4")"
}

test_ensure_puts_back_the_machines_it_woke() {
    sleeping_fleet
    drive_op ensure
    assert_woken_nodes_were_put_back
}

test_the_report_says_how_many_machines_went_back_off() {
    sleeping_fleet
    drive_op ensure
    assert_contains "$(report)" "2 woken node(s) put back off." \
        "the one line that tells the user the house is not left running"
}

# ── the snapshot ────────────────────────────────────────────────────────────
test_a_node_that_failed_its_operation_is_still_put_back_to_sleep() {
    # The failure and the shutdown are independent: the operation failing is no reason to
    # leave a machine running that was off when the run started.
    sleeping_fleet
    : > "$NODES/$IP1/.akfail"
    drive_op purge
    assert_contains "$(toggles)" "$IP1 maddev off" "it was woken, so it is owed a shutdown"
}

test_the_report_shows_the_operations_failure_not_the_sleep_that_came_after_it() {
    # The sleep pass rewrites st for every node it touches, so without the snapshot the one
    # node whose purge failed would be reported `asleep` - the run would print a success for
    # the exact thing it did not do.
    sleeping_fleet
    : > "$NODES/$IP1/.akfail"
    drive_op purge
    local rep; rep="$(report)"

    assert_contains "$rep" "op failed" "the operation's own verdict survived the sleep pass"
    assert_contains "$rep" "ok 3 / 5" "and it is still counted as a failure"
    # jelly-streamer appears in the nok section with its reason; what must NOT have happened
    # is it appearing in the ok list, which is where `asleep` would have put it.
    local ok_block; ok_block=$(printf '%s\n' "$rep" | sed -n '/ ok 3 \/ 5/,/ nok /p')
    assert_not_contains "$ok_block" "jelly-streamer" "a failed node is not listed as done"
    assert_contains "$rep" "luks locked" "and the other failure keeps its own reason too"
    # `asleep` is the sleep pass's own word, and it belongs to no node's report line: the two
    # that really did go back off are reported by what the purge did, not by the shutdown.
    assert_not_contains "$rep" "asleep" "the sleep pass wrote over nobody's verdict"
}

test_a_node_that_would_not_power_off_is_reported_over_its_own_success() {
    # The inverse of the snapshot rule: a node that did its job and then refused to switch
    # off is a failure of this run, and the live nok has to beat the frozen ok. Nothing else
    # in the tool would ever say so.
    sleeping_fleet
    POWEROFF_OBEYED=0          # the measured behaviour of three of the four live nodes
    drive_op purge
    local rep; rep="$(report)"
    assert_contains "$rep" "no poweroff"
    assert_contains "$rep" "NOPASSWD" "with the fix that actually applies"
    assert_contains "$rep" "ok 2 / 5" \
        "and it counts as a failure, not just as a line of text: both nodes purged fine"
    assert_eq "2" "$K_SLEPT_NOK" "both woken nodes stayed up"
    assert_contains "$rep" "2 would NOT go off." "and the note says so out loud"
}

# ── k_op_sleep on its own ───────────────────────────────────────────────────
test_k_op_sleep_reports_nok_when_the_machine_is_still_answering() {
    # No exit status in this path means anything: sudo's stderr is discarded, polkit's answer
    # never reaches us, and api_toggle's curl has no -f. ICMP is the only witness.
    load_fleet
    : > "$K_RUN/n3/woke"
    API_TOGGLE_RC=1; POWEROFF_OBEYED=0
    assert_rc "$K_FAILED" k_op_sleep 3
    k_st_read 3
    assert_eq "nok" "$K_S"
    assert_eq "no poweroff" "$K_D" "the detail string the report keys its advice off"
    assert_no_file "$NODES/$IP3/.down" "and it really is still running"
}

test_k_op_sleep_reports_ok_once_the_machine_stops_answering() {
    load_fleet
    : > "$K_RUN/n3/woke"
    API_TOGGLE_RC=1; POWEROFF_OBEYED=1
    assert_rc 0 k_op_sleep 3
    k_st_read 3
    assert_eq "ok" "$K_S"
    assert_eq "asleep" "$K_D"
}

test_k_op_sleep_will_not_touch_a_node_this_run_did_not_wake() {
    # Being in the fleet, or merely being queued into the pass, must never be enough.
    load_fleet
    : > "$STUB_LOG"
    assert_rc 0 k_op_sleep 3
    assert_eq "" "$(toggles)" "the backend was never asked"
    assert_eq "0" "$(stub_count ssh)" "and no poweroff was sent"
    k_st_read 3; assert_eq "queued" "$K_S" "its state is left for whoever owns it"
}

test_k_op_sleep_does_not_walk_away_from_a_wake_that_never_landed() {
    # `waking` is the intent, written before the magic packet; it is NOT proof the machine
    # came up. Calling a silent node "off" is how a box with a slow POST comes up two minutes
    # after the run and stays on all night with nothing left that would switch it off. It gets
    # a bounded chance to appear, and if it never does the report says so instead of claiming
    # the machine was put back to sleep.
    load_fleet
    set_down "$IP4"
    : > "$K_RUN/n4/waking"
    : > "$STUB_LOG"
    K_SLEEP_BUDGET=6
    assert_rc "$K_FAILED" k_op_sleep 4
    k_st_read 4; assert_eq "nok" "$K_S"; assert_eq "may wake later" "$K_D"
    assert_eq "" "$(toggles)" "and nothing is ordered off that never answered"
}

test_k_op_sleep_settles_a_node_that_came_up_and_has_since_gone_off() {
    # The confirmed marker is different: this one really did answer during the run, so quiet
    # now means it has already gone off and there is nothing left to order.
    load_fleet
    set_down "$IP4"
    : > "$K_RUN/n4/waking"
    : > "$K_RUN/n4/woke"
    : > "$STUB_LOG"
    assert_rc 0 k_op_sleep 4
    k_st_read 4; assert_eq "ok" "$K_S"; assert_eq "off" "$K_D"
    assert_eq "" "$(toggles)" "nothing is ordered off that is already off"
}

test_the_sleep_pass_falls_back_to_ssh_poweroff_when_the_backend_is_unreachable() {
    load_fleet
    : > "$K_RUN/n1/woke"; : > "$K_RUN/n4/woke"
    API_TOGGLE_RC=1            # backend down, as it is whenever the service is being rebuilt
    POWEROFF_OBEYED=1
    : > "$STUB_LOG"
    k_sleep_woken > "$SANDBOX/out" 2>&1

    assert_contains "$(toggles)" "$IP1 maddev off" "the backend is still tried first"
    local calls; calls="$(stub_calls ssh)"
    assert_contains "$calls" "maddev@$IP1 sudo poweroff" "then ssh, because it did not answer"
    assert_contains "$calls" "maddev@$IP4 sudo poweroff"
    assert_not_contains "$calls" "root@$IP0" "and only the nodes this run woke"
    assert_eq "2" "$K_SLEPT"
    assert_eq "0" "$K_SLEPT_NOK" "they obeyed, so the pass is clean"
}

# ── the wipe pass ───────────────────────────────────────────────────────────
test_the_wipe_pass_removes_superseded_keys_across_the_fleet() {
    # Three nodes carrying old keys of ours, in three different shapes, and one clean node
    # that must not be dragged into the pass at all.
    load_fleet
    node_fs "$IP1" "$OLD_PUB" "$STALE1" "$FOREIGN"
    node_fs "$IP3" "$OLD_PUB" "$FOREIGN" "$STALE1" "$STALE2"
    node_fs "$IP4" "$STALE2" "$OLD_PUB"
    set_down "$IP2"                       # the luks box, off: it takes no part in any pass
    drive_op ensure

    local k
    k="$(node_keys "$IP1")"
    assert_not_contains "$k" "AAAASTALE1" "the superseded key is gone"
    assert_contains "$k" "AAAAOLD" "the key in use stays"
    assert_contains "$k" "AAAAFOREIGN" "and someone else's key is not ours to wipe"
    k="$(node_keys "$IP3")"
    assert_not_contains "$k" "AAAASTALE1"
    assert_not_contains "$k" "AAAASTALE2" "both of them, on the same node"
    assert_contains "$k" "AAAAOLD"
    assert_contains "$k" "AAAAFOREIGN"
    k="$(node_keys "$IP4")"
    assert_not_contains "$k" "AAAASTALE2"
    assert_contains "$k" "AAAAOLD"
    assert_eq "$OLD_PUB"$'\n'"$FOREIGN" "$(node_keys "$IP0")" \
        "the clean node was never queued into the wipe"
}

test_the_wipe_pass_reports_what_each_node_gave_up() {
    load_fleet
    node_fs "$IP1" "$OLD_PUB" "$STALE1" "$FOREIGN"
    node_fs "$IP3" "$OLD_PUB" "$FOREIGN" "$STALE1" "$STALE2"
    set_down "$IP2"
    drive_op ensure
    local rep; rep="$(report)"
    assert_contains "$rep" "1 gone" "jelly-streamer had one"
    assert_contains "$rep" "2 gone" "immich-provider had two"
}

test_declining_the_wipe_leaves_every_key_where_it_is() {
    load_fleet
    node_fs "$IP3" "$OLD_PUB" "$STALE1" "$FOREIGN"
    set_down "$IP2"
    MENU_RC=1                             # "keep them"
    drive_op ensure
    local k; k="$(node_keys "$IP3")"
    assert_contains "$k" "AAAASTALE1" "the user said no"
    assert_contains "$k" "AAAAOLD"
    assert_contains "$(report)" "1 stray" "it is still reported as a finding"
}

# ── the adoption purge ──────────────────────────────────────────────────────
# A node reached by password was refusing keys of ours that it still holds. Those keys are
# now held by nobody, so they go - but only at each operation's own safe point.
adopting_node() {
    # immich-provider, index 3, answering, but our key is not on it: only a personal key and two
    # keys of ours that nobody has any more. jelly-streamer is given the identical file and
    # left alone, so "the purge dropped these two keys" cannot pass by dropping them fleet-wide.
    load_fleet
    node_fs "$IP1" "$FOREIGN" "$STALE1" "$STALE2"
    node_fs "$IP3" "$FOREIGN" "$STALE1" "$STALE2"
    fake_sshpass
    K_PW[3]=hunter2
}

test_an_adopted_node_gives_up_our_other_keys_and_keeps_its_owners() {
    adopting_node
    K_ADOPT_PUB="$SSH_KEY.pub"; K_ADOPT_KEY="$SSH_KEY"
    assert_rc 0 k_op_ensure 3
    local k; k="$(node_keys "$IP3")"
    assert_contains "$k" "AAAAOLD" "the key we came in to restore is on it"
    assert_not_contains "$k" "AAAASTALE1" "a key of ours nobody holds any more"
    assert_not_contains "$k" "AAAASTALE2"
    assert_contains "$k" "AAAAFOREIGN" \
        "a personal key with a different comment is not ours to destroy"
    k_st_read 3
    assert_eq "ok" "$K_S"; assert_eq "2 gone" "$K_D"
    assert_eq "$FOREIGN"$'\n'"$STALE1"$'\n'"$STALE2" "$(node_keys "$IP1")" \
        "and no other node was touched"
}

test_rotate_records_the_deployment_before_it_destroys_anything() {
    # The ordering is the whole safety property. If the purge ran first, a worker killed in
    # between would leave k_rotate_finalize discarding the new key while the node holds only
    # keys nobody has - locked out, recoverable only by password.
    adopting_node
    K_NEW_KEY="$SSH_KEY.new"
    printf 'PRIVNEW\n' > "$K_NEW_KEY"; printf '%s\n' "$NEW_PUB" > "$K_NEW_KEY.pub"
    K_ADOPT_PUB="$K_NEW_KEY.pub"; K_ADOPT_KEY="$K_NEW_KEY"

    eval "orig_k_purge_ours() $(declare -f k_purge_ours | tail -n +2)"
    k_purge_ours() {
        [ -f "$K_NEW_KEY.deployed" ] && : > "$SANDBOX/deployed_first"
        orig_k_purge_ours "$@"
    }

    assert_rc 0 k_op_rotate 3
    assert_file "$SANDBOX/deployed_first" \
        "the deployed marker exists before the purge is allowed to run"
    local k; k="$(node_keys "$IP3")"
    assert_contains "$k" "AAAANEW"
    assert_not_contains "$k" "AAAASTALE1"
    assert_not_contains "$k" "AAAASTALE2"
    assert_contains "$k" "AAAAFOREIGN"
    assert_contains "$(node_keys "$IP1")" "AAAASTALE1" "the other node is untouched"
}

# ── F7: one lost packet decides nothing ─────────────────────────────────────
test_a_single_dropped_ping_does_not_make_the_ladder_wake_a_live_machine() {
    # Both decisions hanging off k_pingable are destructive when wrong. Here: a node that is
    # up but whose key was refused. One lost packet used to read as "off", which blasted WoL
    # at a machine somebody was working on and then, in the sleep pass, switched it off.
    load_fleet
    node_fs "$IP3" "$FOREIGN"             # up, but our key is gone: this is a password case
    printf '1\n' > "$NODES/$IP3/.pingfail"
    K_ADOPT_PUB="$SSH_KEY.pub"; K_ADOPT_KEY="$SSH_KEY"
    : > "$STUB_LOG"

    # assert_rc takes no message: anything after the command is an argument to it, and here
    # that would have been silently swallowed as an extra candidate key.
    assert_rc "$K_NEEDPASS" k_resolve 3 "$SSH_KEY"
    assert_eq "0" "$(stub_count wakeonlan)" "no magic packet at a running machine"
    assert_eq "" "$(toggles)" "and the backend was never told to switch it on"
    assert_no_file "$K_RUN/n3/waking" "nothing claims this run owns its power state"
}

test_a_single_dropped_ping_does_not_make_the_sleep_poll_call_a_machine_asleep() {
    # The same lost packet, in the poll that decides whether the poweroff worked. Reporting a
    # still-running machine as asleep is how the tool ends up lying about the fleet.
    load_fleet
    : > "$K_RUN/n3/woke"
    API_TOGGLE_RC=1; POWEROFF_OBEYED=0
    printf '2\n' > "$NODES/$IP3/.pingfail"   # packet 1 is the pre-check, 2 is the first poll

    assert_rc "$K_FAILED" k_op_sleep 3
    k_st_read 3
    assert_eq "nok" "$K_S"
    assert_eq "no poweroff" "$K_D" "it answered again on the retry, so it is not asleep"
    assert_le 3 "$(cat "$NODES/$IP3/.pingn")" "and the drop really was exercised"
}

# ── F1: removing a node by name ─────────────────────────────────────────────
test_remove_node_deletes_only_the_named_node_when_a_subtitle_shares_its_name() {
    # SUBTITLE became an interior field, so the old `,$target,` substring match also hit any
    # node whose subtitle happens to be this name - including, on the removed node itself,
    # a match that wrote the blob back empty.
    set_blob '02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,pi-blocker,0,1,1,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,Workstation,1,0,2,
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,pi-blocker,0,1,3,'
    source "$SRC_DIR/nodes.sh"
    interactive_menu() { return 1; }      # pi-blocker, the second entry
    remove_node >/dev/null 2>&1

    local b; b="$(written_blob)"
    assert_not_contains "$b" "192.168.77.11" "the named node is gone"
    assert_contains "$b" "192.168.77.12,pfsense-wall,root,pi-blocker,0,1" \
        "a node whose subtitle is that name survives whole"
    assert_contains "$b" "192.168.77.13,jelly-streamer,maddev,pi-blocker,0,1"
    assert_eq "2" "$(printf '%s\n' "$b" | grep -c .)" "exactly one record left the blob"
}

test_remove_node_cancel_still_writes_nothing() {
    set_blob '02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,pi-blocker,0,1,1,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,Workstation,1,0,2,'
    source "$SRC_DIR/nodes.sh"
    interactive_menu() { return 2; }      # "cancel"
    remove_node >/dev/null 2>&1
    assert_eq "" "$(written_blob)" "the blob is not rewritten at all"
}

# ── F2: a comma in a subtitle ───────────────────────────────────────────────
# The record is unquoted CSV and the subtitle is an interior field, so a comma writes an
# eighth field. Every reader then slices the flags out of the subtitle's tail, reads the
# luks flag as not-blocked, and wakes the one machine that must never be woken.
test_add_node_will_not_accept_a_subtitle_that_would_void_the_flag() {
    set_blob ''
    source "$SRC_DIR/nodes.sh"
    stub ping 0; stub sshpass 0; stub curl 7; stub jq 1
    # ip, mac, name, user, password, a subtitle with a comma, a clean one, an empty line
    # for the shelf-position ask (the end), then 'n' = cannot be sshd into after a wake =
    # flagged, and 'n' = not a favourite.
    printf '192.168.77.11\naa:bb:cc:dd:ee:ff\npi-blocker\nmaddev\nhunter2\nbig, encrypted\nWorkstation\n\n\nnn' \
        | add_node >/dev/null 2>&1

    local b; b="$(written_blob)"
    assert_contains "$b" "aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,Workstation,1,0" \
        "the record is nine fields and the luks flag is the sixth"
    assert_not_contains "$b" "big, encrypted" "the comma subtitle never reached the blob"
    assert_eq "0" "$(printf '%s\n' "$b" | awk -F, 'NF!=9' | grep -c .)" \
        "no record has a tenth field"
}

test_the_record_helper_will_not_accept_a_subtitle_that_would_void_the_flag() {
    # The same hazard on the retroactive editor, which is the only way an existing record's
    # subtitle ever changes.
    set_blob '02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,Gaming!,0,1,1,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,Workstation,1,0,2,'
    local src; src="$(subtitle_helper_src)"
    assert_ok test -n "$src"
    eval "$src"

    # per node: subtitle, then ssh-on-wake. pi-blocker is offered a comma first and must be asked
    # again before its flag can be written.
    printf 'gaming rig\ny\nbig, encrypted\nthe big one\nn\n' \
        | update_node_subtitles >/dev/null 2>&1

    local b; b="$(written_blob)"
    assert_contains "$b" "192.168.77.11,pi-blocker,maddev,the big one,1,0" \
        "the second answer was taken and both flags survived"
    assert_not_contains "$b" "big, encrypted"
    assert_eq "1" "$(printf '%s\n' "$b" | awk -F, '$6 == 1' | grep -c .)" \
        "exactly one record carries the luks flag; a swallowed field would leave none"
    assert_eq "0" "$(printf '%s\n' "$b" | awk -F, 'NF!=9' | grep -c .)" \
        "every record still has exactly nine fields"
}

# update_node_subtitles lives in a script with a top-level menu loop, so the function is
# lifted out rather than sourced. `</dev/tty` becomes `<&0`: the suite has no controlling
# terminal, and the redirection is an artefact of the TUI, not of the parsing under test.
subtitle_helper_src() {
    local p
    for p in "$SRC_DIR/subtitle-helper.sh" "$SRC_DIR/../refs/subtitle-helper.sh"; do
        [ -f "$p" ] || continue
        awk '/^update_node_subtitles\(\) \{/,/^\}/' "$p" | sed 's#</dev/tty#<\&0#'
        return 0
    done
    return 1
}

test_the_sleep_pass_does_not_overwrite_the_verdict_the_operation_reached() {
    # Confirmed against real hardware: a node whose rotate verdict was `never woke` had its
    # report line rewritten to `may wake later` by the sleep pass, so the one place naming WHY
    # that node was not rotated stopped saying it. A machine left running is worth reporting,
    # but not at the price of the operation's own answer - the note accounts for it instead.
    load_fleet
    k_snapshot
    k_st 4 nok "never woke"
    cp -f "$K_RUN/n4/st" "$K_RUN/n4/st.final"
    : > "$K_RUN/n4/waking"
    set_down "$IP4"
    K_SLEEP_BUDGET=6
    k_sleep_woken > /dev/null 2>&1

    local state detail
    IFS='|' read -r state _ detail < "$K_RUN/n4/st.final"
    assert_eq "nok" "$state"
    assert_eq "never woke" "$detail" "the operation's verdict survives the sleep pass"
    assert_contains "$K_SLEEP_NOTE" "would NOT go off" "and the machine still gets accounted for"
}

test_the_sleep_pass_may_speak_for_a_node_that_had_nothing_to_say() {
    # The other half: a node that finished its operation cleanly has no better verdict, so a
    # power-off that would not take is exactly what its report line should carry.
    load_fleet
    k_st 4 ok
    k_snapshot
    : > "$K_RUN/n4/waking"
    : > "$K_RUN/n4/woke"
    API_TOGGLE_RC=1; POWEROFF_OBEYED=0      # the measured reality on three of four real nodes
    K_SLEEP_BUDGET=6
    k_sleep_woken > /dev/null 2>&1

    local state detail
    IFS='|' read -r state _ detail < "$K_RUN/n4/st.final"
    assert_eq "nok" "$state" "a node that was merely ok takes the sleep failure"
    assert_eq "no poweroff" "$detail"
}
