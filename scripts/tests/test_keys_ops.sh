#!/usr/bin/env bash
# The three operations, driven against a fake node.
#
# The fake `ssh` is not a mock that returns canned strings: it authenticates the offered key
# against that node's real authorized_keys file and, for an authorized_keys command, runs
# the actual K_AK_SCRIPT against a per-node $HOME. So "rotate left the node holding exactly
# the new key" is a statement about a real file that a real script really rewrote.

OLD_PUB='ssh-ed25519 AAAAOLD allumeur-master-key'
NEW_PUB='ssh-ed25519 AAAANEW allumeur-master-key'
FOREIGN='ssh-ed25519 AAAAFOREIGN tmorolias@protonmail.com'
STALE='ssh-ed25519 AAAASTALE allumeur-master-key'

setup() {
    source "$SRC_DIR/lib.sh"
    source "$SRC_DIR/keys.sh"

    SSH_KEY="$HOME/.allumeur-scripts/encrypted/allumeur-master-key"
    printf 'PRIVOLD\n'   > "$SSH_KEY";          printf '%s\n' "$OLD_PUB" > "$SSH_KEY.pub"
    K_NEW_KEY="$SSH_KEY.new"
    printf 'PRIVNEW\n'   > "$K_NEW_KEY";        printf '%s\n' "$NEW_PUB" > "$K_NEW_KEY.pub"

    K_RUN="$SANDBOX/run"; mkdir -p "$K_RUN"
    NODES="$SANDBOX/nodes"; mkdir -p "$NODES"

    # Budgets are wall-clock waits; a test must not sit through 90s of them.
    K_ICMP_BUDGET=1; K_SSHD_BUDGET=1; K_GRACE_BUDGET=1

    # keys.sh reaches for these two from nodes.sh; the ops under test do not care what they do.
    api_toggle() { return 1; }
    wol_blast()  { :; }

    fake_ssh
    stub wakeonlan
    stub tput
    stub sshpass 1        # no password path unless a test opts in
    install_node 0 "192.168.77.12" "$OLD_PUB"
}

# A node exists as a directory with a real ~/.ssh/authorized_keys.
install_node() {
    local i=$1 ip=$2; shift 2
    mkdir -p "$NODES/$ip/.ssh"
    printf '%s\n' "$@" > "$NODES/$ip/.ssh/authorized_keys"
    chmod 700 "$NODES/$ip/.ssh"; chmod 600 "$NODES/$ip/.ssh/authorized_keys"
    K_MAC[$i]="aa:bb:cc:dd:ee:0$i"; K_IP[$i]=$ip
    K_NAME[$i]="node$i"; K_USER[$i]="maddev"; K_LUKS[$i]=0
    mkdir -p "$K_RUN/n$i"; k_st "$i" queued
    K_N=$((i + 1))
}

node_keys() { cat "$NODES/$1/.ssh/authorized_keys" 2>/dev/null; }
set_down()  { : > "$NODES/$1/.down"; }

# ── the fake node ───────────────────────────────────────────────────────────
fake_ssh() {
    cat > "$STUB_DIR/ssh" <<'FAKE'
#!/usr/bin/env bash
# Parse the bits of the ssh command line the code actually relies on.
key=""; target=""; cmd=""
args=("$@")
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

# Authenticate: the offered key's blob must be present in that node's authorized_keys.
if [ -n "$key" ] && [ -f "$key.pub" ]; then
    blob=$(awk '{print $2}' "$key.pub")
    if ! awk '{print $2}' "$nodedir/.ssh/authorized_keys" 2>/dev/null | grep -qx "$blob"; then
        echo "$target: Permission denied (publickey,password)." >&2; exit 255
    fi
else
    echo "$target: Permission denied (publickey,password)." >&2; exit 255
fi

case "$cmd" in
    "echo __KOK__") echo "__KOK__" ;;
    "sh -s -- "*)   HOME="$nodedir" sh -s -- ${cmd#sh -s -- } ;;   # runs the REAL writer
    *)              eval "$cmd" ;;
esac
FAKE
    chmod +x "$STUB_DIR/ssh"

    cat > "$STUB_DIR/ping" <<'FAKE'
#!/usr/bin/env bash
printf 'ping\t%s\n' "$*" >> "$STUB_LOG"
for a in "$@"; do case "$a" in 192.168.*|10.*) ip="$a";; esac; done
[ -f "$NODES/$ip/.down" ] && exit 1
exit 0
FAKE
    chmod +x "$STUB_DIR/ping"
    export NODES
}

trace() { cut -f2- "$STUB_LOG.trace" 2>/dev/null; }

# ── rotate ──────────────────────────────────────────────────────────────────
test_rotate_drops_every_allumeur_key_it_replaces_not_just_the_last_one() {
    # A node that missed a rotation carries more than one key of ours, and a node that had to
    # be adopted was refusing the current one - so deleting exactly $SSH_KEY left older keys
    # nobody holds still authorised, which is the opposite of what rotating means. Rotation
    # has to end with the fleet answering to exactly one key of ours.
    local OLDER='ssh-ed25519 AAAAOLDER allumeur-master-key'
    local FOREIGN='ssh-ed25519 AAAAFOREIGN tmorolias@protonmail.com'
    install_node 0 "192.168.77.12" "$OLD_PUB" "$OLDER" "$FOREIGN"

    assert_rc 0 k_op_rotate 0
    local keys; keys="$(node_keys 192.168.77.12)"
    assert_contains     "$keys" "AAAANEW"     "the new key is installed"
    assert_not_contains "$keys" "AAAAOLD "    "the superseded key is gone"
    assert_not_contains "$keys" "AAAAOLDER"   "and so is the one before it"
    # The line every other allumeur key deletion is measured against: a personal key is not
    # ours to destroy. Only `purge any other keys` may take that, and it asks first.
    assert_contains     "$keys" "AAAAFOREIGN" "a personal key is left alone"
}

test_rotate_leaves_the_node_holding_only_the_new_key() {
    assert_rc 0 k_op_rotate 0
    local keys; keys="$(node_keys 192.168.77.12)"
    assert_contains "$keys" "AAAANEW" "new key installed"
    assert_not_contains "$keys" "AAAAOLD" "old key removed"
    k_st_read 0
}

test_rotate_adds_and_verifies_the_new_key_before_dropping_the_old_one() {
    # The ordering is the whole safety property: if the delete ever raced ahead of a proven
    # working new key, a failure at the wrong moment would strand the node.
    k_op_rotate 0
    local t; t="$(trace)"
    local add_line del_line verify_line
    add_line=$(printf '%s\n' "$t" | grep -n 'sh -s -- add' | head -1 | cut -d: -f1)
    verify_line=$(printf '%s\n' "$t" | grep -n "$K_NEW_KEY.*echo __KOK__" | tail -1 | cut -d: -f1)
    del_line=$(printf '%s\n' "$t" | grep -n 'sh -s -- del' | head -1 | cut -d: -f1)
    assert_ok test -n "$add_line"
    assert_ok test -n "$del_line"
    assert_lt "$add_line" "$del_line" "add must precede del"
    assert_lt "$verify_line" "$del_line" "the new key is proven before the old one dies"
}

test_rotate_keeps_foreign_keys_untouched() {
    install_node 0 "192.168.77.12" "$OLD_PUB" "$FOREIGN"
    k_op_rotate 0
    assert_contains "$(node_keys 192.168.77.12)" "AAAAFOREIGN" "rotate is not a purge"
}

test_rotate_is_idempotent() {
    k_op_rotate 0
    : > "$STUB_LOG.trace"
    assert_rc 0 k_op_rotate 0 "a second rotate over an already-rotated node succeeds"
    assert_eq "1" "$(node_keys 192.168.77.12 | grep -c AAAANEW)" "no duplicate key"
    assert_not_contains "$(trace)" "sh -s -- add" "it recognises the new key and skips the push"
}

test_rotate_on_a_node_that_never_wakes_is_reported_not_retried_forever() {
    set_down 192.168.77.12
    assert_rc "$K_DOWN" k_op_rotate 0
    assert_no_file "$K_NEW_KEY.deployed" "a node we never reached cannot license key deletion"
}

test_rotate_records_deployment_beside_the_key_not_in_the_run_dir() {
    # The run dir is destroyed on ^C. If the "a node took the new key" marker lived there,
    # an interrupted rotate would discard the new key while a node had already dropped the
    # old one - which is the one way this feature could strand you.
    k_op_rotate 0
    assert_file "$K_NEW_KEY.deployed"
    rm -rf "$K_RUN"
    k_rotate_finalize
    assert_eq "PRIVNEW" "$(cat "$SSH_KEY")" "promotion survives the run dir being wiped"
}

# ── the promotion rule ──────────────────────────────────────────────────────
test_finalize_destroys_the_old_key_once_a_node_has_taken_the_new_one() {
    k_op_rotate 0
    k_rotate_finalize
    assert_eq "PRIVNEW" "$(cat "$SSH_KEY")" "the new key became the master key"
    assert_eq "$NEW_PUB" "$(cat "$SSH_KEY.pub")"
    assert_no_file "$K_NEW_KEY" "the staging key is consumed"
    assert_contains "$K_ROTATE_NOTE" "old key deleted"
}

test_finalize_keeps_the_old_key_when_no_node_took_the_new_one() {
    # Fleet unreachable, or the user aborted at the first prompt. Destroying the old key
    # here would lock the user out of every node for nothing.
    set_down 192.168.77.12
    k_op_rotate 0
    k_rotate_finalize
    assert_eq "PRIVOLD" "$(cat "$SSH_KEY")" "the working key is kept"
    assert_eq "$OLD_PUB" "$(cat "$SSH_KEY.pub")"
    assert_no_file "$K_NEW_KEY" "the unused staging key is discarded"
    assert_contains "$K_ROTATE_NOTE" "old key was kept"
}

# ── purge ───────────────────────────────────────────────────────────────────
# The two guarantees, stated against the worst-shaped authorized_keys this fleet can hold:
# an allumeur key behind an options prefix, an allumeur key that is not ed25519, and a
# personal key that must survive one operation and not the other.
MESSY_OPTS='command="/bin/true",no-pty ssh-ed25519 AAAAOPTS allumeur-master-key'
MESSY_ECDSA='ecdsa-sha2-nistp256 AAAAECDSA allumeur-master-key'

test_rotate_leaves_no_allumeur_key_but_the_current_one() {
    install_node 0 "192.168.77.12" "$OLD_PUB" "$MESSY_OPTS" "$MESSY_ECDSA" "$FOREIGN"
    assert_rc 0 k_op_rotate 0
    local keys; keys="$(node_keys 192.168.77.12)"
    assert_contains     "$keys" "AAAANEW"     "the node got the current key"
    assert_not_contains "$keys" "AAAAOLD"     "the superseded key is gone"
    assert_not_contains "$keys" "AAAAOPTS"    "an options prefix does not hide one from us"
    assert_not_contains "$keys" "AAAAECDSA"   "nor does a key type we do not mint any more"
    assert_contains     "$keys" "AAAAFOREIGN" "and a personal key is not ours to destroy"
}

test_purge_leaves_the_current_key_and_absolutely_nothing_else() {
    install_node 0 "192.168.77.12" "$OLD_PUB" "$MESSY_OPTS" "$MESSY_ECDSA" "$FOREIGN"
    assert_rc 0 k_op_purge 0
    # Byte for byte, one line. Not "the others are gone" - that is a weaker claim that a
    # filter bug can satisfy while leaving something behind on a line it failed to parse.
    assert_eq "$OLD_PUB" "$(node_keys 192.168.77.12)" "exactly one key, the one in use"
}

test_purge_reduces_the_node_to_the_key_in_use() {
    install_node 0 "192.168.77.12" "$OLD_PUB" "$FOREIGN" "$STALE"
    assert_rc 0 k_op_purge 0
    assert_eq "$OLD_PUB" "$(node_keys 192.168.77.12)" "exactly the key in use remains"
}

test_purge_reports_how_many_keys_it_destroyed() {
    install_node 0 "192.168.77.12" "$OLD_PUB" "$FOREIGN" "$STALE"
    k_op_purge 0
    k_st_read 0
    assert_eq "ok" "$K_S"
    assert_eq "2 gone" "$K_D" "the report says what was removed"
}

test_purge_on_an_already_clean_node_is_a_no_op() {
    k_op_purge 0
    k_st_read 0
    assert_eq "0 gone" "$K_D"
    assert_eq "$OLD_PUB" "$(node_keys 192.168.77.12)"
}

# ── ensure reachability ─────────────────────────────────────────────────────
test_ensure_flags_superseded_keys_minted_by_this_server() {
    install_node 0 "192.168.77.12" "$OLD_PUB" "$STALE" "$FOREIGN"
    assert_rc 0 k_op_ensure 0
    assert_file "$K_RUN/n0/stale"
    assert_contains "$(cat "$K_RUN/n0/stale")" "AAAASTALE"
    assert_not_contains "$(cat "$K_RUN/n0/stale")" "AAAAFOREIGN" \
        "someone else's key is not ours to call superseded"
    assert_not_contains "$(cat "$K_RUN/n0/stale")" "AAAAOLD" "the key in use is not stale"
}

test_ensure_leaves_keys_alone_by_itself() {
    # Wiping is offered to the user afterwards; the scan itself must not delete anything.
    install_node 0 "192.168.77.12" "$OLD_PUB" "$STALE" "$FOREIGN"
    k_op_ensure 0
    assert_contains "$(node_keys 192.168.77.12)" "AAAASTALE"
    assert_contains "$(node_keys 192.168.77.12)" "AAAAFOREIGN"
}

test_ensure_is_quiet_when_there_is_nothing_stale() {
    k_op_ensure 0
    assert_no_file "$K_RUN/n0/stale"
    k_st_read 0
    assert_eq "" "$K_D"
}

# ── the ladder ──────────────────────────────────────────────────────────────
test_resolve_reports_a_node_that_never_answers_as_down() {
    set_down 192.168.77.12
    assert_rc "$K_DOWN" k_resolve 0 "$SSH_KEY"
}

test_resolve_asks_for_a_password_when_the_key_is_refused() {
    install_node 0 "192.168.77.12" "$FOREIGN"     # our key is not there
    K_ADOPT_PUB="$SSH_KEY.pub"; K_ADOPT_KEY="$SSH_KEY"
    assert_rc "$K_NEEDPASS" k_resolve 0 "$SSH_KEY"
    k_st_read 0
    assert_eq "need_pass" "$K_S" "the board shows it is waiting on a human"
}

test_resolve_prefers_the_first_working_candidate_key() {
    install_node 0 "192.168.77.12" "$NEW_PUB"
    assert_rc 0 k_resolve 0 "$K_NEW_KEY" "$SSH_KEY"
    assert_eq "$K_NEW_KEY" "$K_ACTIVE_KEY"
}

test_poweroff_style_resolve_never_wakes_a_sleeping_node() {
    set_down 192.168.77.12
    : > "$STUB_LOG"
    local rc=0
    K_NOWAKE=1 k_resolve 0 "$SSH_KEY" || rc=$?
    assert_eq "$K_DOWN" "$rc" "an off node reports down immediately"
    assert_eq "0" "$(stub_count wakeonlan)" "no magic packet is sent in order to shut a node down"
}

# ── multi-node addressing ───────────────────────────────────────────────────
test_each_worker_acts_on_its_own_node() {
    # Regression: `local i=$1 ip=${K_IP[$i]}` declares every name before assigning any, so
    # the subscript saw an unset i and silently resolved to index 0 - every node would have
    # been addressed as the first one. Single-node tests cannot see this.
    install_node 0 "192.168.77.12" "$OLD_PUB" "$FOREIGN"
    install_node 1 "192.168.77.13" "$OLD_PUB" "$FOREIGN"
    assert_rc 0 k_op_purge 1
    assert_eq "$OLD_PUB" "$(node_keys 192.168.77.13)" "the targeted node was purged"
    assert_contains "$(node_keys 192.168.77.12)" "AAAAFOREIGN" "the other node was left alone"
}

test_rotate_addresses_the_right_node_in_a_fleet() {
    install_node 0 "192.168.77.12" "$OLD_PUB"
    install_node 1 "192.168.77.13" "$OLD_PUB"
    k_op_rotate 1
    assert_contains "$(node_keys 192.168.77.13)" "AAAANEW"
    assert_not_contains "$(node_keys 192.168.77.12)" "AAAANEW" "node 0 was not touched"
}

# ── regressions from review ─────────────────────────────────────────────────
test_rotate_does_not_demand_a_password_for_a_node_that_still_has_the_old_key() {
    # rotate offers the NEW key first, which is of course not on the node yet. Escalating on
    # the first refusal would ask for a password on every single node of every rotate.
    install_node 0 "192.168.77.12" "$OLD_PUB"
    : > "$NODES/192.168.77.12/.down"     # force the wake path, which is where it escalated
    K_ADOPT_PUB="$K_NEW_KEY.pub"; K_ADOPT_KEY="$K_NEW_KEY"
    ( sleep 1; rm -f "$NODES/192.168.77.12/.down" ) &   # comes back mid-wait
    K_ICMP_BUDGET=20 K_SSHD_BUDGET=20 k_resolve 0 "$K_NEW_KEY" "$SSH_KEY"
    local rc=$?
    wait
    assert_eq "0" "$rc" "the old key resolved it; no human needed"
    assert_eq "$SSH_KEY" "$K_ACTIVE_KEY" "and it is the old key that answered"
}

test_a_marker_left_by_a_killed_rotate_is_adopted_not_destroyed() {
    # A previous rotate was killed after a node took the staged key - and possibly after that
    # node dropped the old one. Minting fresh over the top would delete the only key that
    # still opens part of the fleet.
    printf 'PRIVSURVIVOR\n' > "$K_NEW_KEY"
    printf '%s\n' "$NEW_PUB"  > "$K_NEW_KEY.pub"
    : > "$K_NEW_KEY.deployed"
    k_rotate_finalize                      # what keys_rotate now does before staging anew
    assert_eq "PRIVSURVIVOR" "$(cat "$SSH_KEY")" "the surviving key was promoted"
    assert_eq "$NEW_PUB" "$(cat "$SSH_KEY.pub")"
    assert_no_file "$K_NEW_KEY.deployed" "and the marker cleared, so it promotes only once"
}

test_ensure_will_not_call_the_live_key_superseded_if_the_pubkey_is_unreadable() {
    # cur would come back empty and every allumeur line would match as stale - the wipe we
    # offer afterwards would then strip the live key off the whole fleet.
    install_node 0 "192.168.77.12" "$OLD_PUB" "$STALE"
    # Still authenticates (ssh uses the private key), but carries no parseable key type, so
    # the identity scan comes back empty - which is the condition being guarded.
    printf 'garbled AAAAOLD junk\n' > "$SSH_KEY.pub"
    assert_rc 0 k_op_ensure 0
    assert_no_file "$K_RUN/n0/stale" "nothing is proposed for wiping"
}
