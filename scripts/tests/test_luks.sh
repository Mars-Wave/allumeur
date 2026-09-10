#!/usr/bin/env bash
# LUKS_BLOCKED, the sixth field.
#
# The flag says "if this box is woken on LAN it comes up at a full-disk-encryption prompt
# and no ssh will ever answer it". Two properties carry the whole feature and neither is
# visible to the rest of the suite: the new field must never bleed into the subtitle, and
# the flag must gate the *wake* and nothing else.
#
# Every fixture here puts the flagged node somewhere other than index 0. The bug this
# codebase already shipped once - `local i=$1 v=${ARR[$i]}` addressing node 0 for every
# worker - is invisible to a single-node fixture, and so is a K_LUKS that is populated by
# append rather than positionally.

OLD_PUB='ssh-ed25519 AAAAOLD allumeur-master-key'
FOREIGN='ssh-ed25519 AAAAFOREIGN tmorolias@protonmail.com'

# pi-blocker (192.168.77.11) is the real LUKS-blocked machine, and it is third here on purpose.
# The favourite (field 7) deliberately disagrees with the luks flag on pi-blocker and immich,
# so a reader off by one field is caught rather than agreed with.
BLOB_FLEET='02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,Gaming!,0,1,1,
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,Series & Movies,0,1,2,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,Workstation,1,0,3,
02:00:00:00:00:14,192.168.77.14,immich-provider,maddev,Sensors,0,1,4,'

setup() {
    source "$SRC_DIR/lib.sh"
    source "$SRC_DIR/keys.sh"

    SSH_KEY="$HOME/.allumeur-scripts/encrypted/allumeur-master-key"
    printf 'PRIVOLD\n' > "$SSH_KEY"; printf '%s\n' "$OLD_PUB" > "$SSH_KEY.pub"

    K_RUN="$SANDBOX/run"; mkdir -p "$K_RUN"
    NODES="$SANDBOX/nodes"; mkdir -p "$NODES"; export NODES
    # k_begin mktemp -d's its own run dir; point TMPDIR at the sandbox so teardown reaps it.
    export TMPDIR="$SANDBOX"
    K_PREV_FRAME=''; K_PREV_ROWS=0

    # Budgets are wall-clock waits; a test must not sit through 90s of them.
    K_ICMP_BUDGET=1; K_SSHD_BUDGET=1; K_GRACE_BUDGET=1

    # api_toggle is a nodes.sh shell function, so it cannot be a PATH stub - but almost
    # every assertion below is about a call that must NOT happen, so it still has to log.
    API_TOGGLE_RC=1          # backend absent by default, which forces the wol_blast path
    api_toggle() {
        printf 'api_toggle\t%s\n' "$*" >> "$STUB_LOG"
        return "$API_TOGGLE_RC"
    }

    set_blob "$BLOB_FLEET"
    fake_ssh
    stub wakeonlan
    stub clear
    stub sshpass 1
    cat > "$STUB_DIR/tput" <<'EOF'
#!/usr/bin/env bash
[ "$1" = cols ] && { echo 40; exit 0; }
exit 0
EOF
    chmod +x "$STUB_DIR/tput"
}

# A two-way openssl stub, so decrypt_blob/encrypt_blob work unmodified: -in emits the
# fixture, -out captures what the code would have written back.
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

# A node exists as a directory with a real ~/.ssh/authorized_keys, plus its flag.
install_node() {   # index ip name luks pubkey...
    local i=$1; local ip=$2; local name=$3; local luks=$4; shift 4
    mkdir -p "$NODES/$ip/.ssh"
    printf '%s\n' "$@" > "$NODES/$ip/.ssh/authorized_keys"
    chmod 700 "$NODES/$ip/.ssh"; chmod 600 "$NODES/$ip/.ssh/authorized_keys"
    K_MAC[$i]="aa:bb:cc:dd:ee:0$i"; K_IP[$i]=$ip
    K_NAME[$i]=$name; K_USER[$i]="maddev"; K_LUKS[$i]=$luks
    mkdir -p "$K_RUN/n$i"; k_st "$i" queued
    K_N=$((i + 1))
}

set_down() { : > "$NODES/$1/.down"; }

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
    "echo __KOK__") echo "__KOK__" ;;
    "sh -s -- "*)   HOME="$nodedir" sh -s -- ${cmd#sh -s -- } ;;
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
}

frame() {
    K_PREV_FRAME=''; K_PREV_ROWS=0
    k_board "$1" | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\x1b\[[JK]//g'
}
widest() { frame "$1" | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }'; }

# update_node_subtitles is the only reader that rewrites every field of every record, so it
# is where a parse bug shows up as data loss. It lives in a script with a top-level menu
# loop, so the function is lifted out rather than sourced. `</dev/tty` becomes `<&0`: the
# suite has no controlling terminal to type into, and the redirection is an artefact of the
# TUI, not of the parsing under test.
subtitle_helper_src() {
    local p
    for p in "$SRC_DIR/subtitle-helper.sh" "$SRC_DIR/../refs/subtitle-helper.sh"; do
        [ -f "$p" ] || continue
        awk '/^update_node_subtitles\(\) \{/,/^\}/' "$p" | sed 's#</dev/tty#<\&0#'
        return 0
    done
    return 1
}

# ── the record ──────────────────────────────────────────────────────────────
test_the_record_round_trips_with_the_subtitle_and_the_flag_intact() {
    # The failure that matters is not a wrong flag, it is a subtitle that silently swallowed
    # ",1,0" - the record still looks fine until the next rewrite corrupts the blob. Both
    # trailing flags disagree on every record, so a shift by one is caught, not agreed with.
    set_blob '02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,Gaming!,1,0,1,Fort Gaming
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,Series & Movies,0,1,2,
02:00:00:00:00:14,192.168.77.14,immich-provider,maddev,,0,1,3,'
    local src; src="$(subtitle_helper_src)"
    assert_ok test -n "$src"
    eval "$src"
    stub sleep

    printf '\n\n\n' | update_node_subtitles >/dev/null 2>&1
    local b; b="$(written_blob)"
    assert_contains "$b" "192.168.77.12,pfsense-wall,root,Gaming!,1,0,1,Fort Gaming" \
        "the subtitle stops at the comma, both flags stand alone, and the pretty rode through"
    assert_contains "$b" "192.168.77.13,jelly-streamer,maddev,Series & Movies,0,1,2," \
        "an empty pretty is a field, not a missing one"
    assert_contains "$b" "192.168.77.14,immich-provider,maddev,,0,1,3," \
        "an empty subtitle is a field, not a missing one"
    assert_eq "1" "$(printf '%s\n' "$b" | awk -F, '$6 == 1' | grep -c .)" \
        "exactly one record carries the luks flag; a swallowed ',1' would leave none"
    assert_eq "0" "$(printf '%s\n' "$b" | awk -F, 'NF != 9' | grep -c .)" \
        "every record still has exactly nine fields"
}


test_the_subtitle_editor_round_trips_the_flag_on_the_right_node() {
    # A subtitle editor that cleared the flag on every node would be indistinguishable from
    # a working one until the next keys run woke pi-blocker into its passphrase prompt.
    set_blob '02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,Gaming!,0,1,1,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,Workstation,1,0,2,
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,Series & Movies,0,1,3,'
    local src; src="$(subtitle_helper_src)"
    assert_ok test -n "$src"
    eval "$src"
    stub sleep

    # Two prompts per node now, subtitle then "ssh on wake?". The empty second answer is the
    # point of this fixture: keeping the flag is what the editor must do when nobody touches it.
    printf 'gaming rig\n\nthe big one\n\nmedia\n\n' | update_node_subtitles >/dev/null 2>&1
    local b; b="$(written_blob)"
    assert_contains "$b" "pi-blocker,maddev,the big one,1,0" \
        "edited, still luks-flagged, and still not a favourite"
    assert_contains "$b" "pfsense-wall,root,gaming rig,0,1"
    assert_contains "$b" "jelly-streamer,maddev,media,0,1"
    assert_eq "1" "$(printf '%s\n' "$b" | awk -F, '$6 == 1' | grep -c .)" \
        "the luks flag did not spread to the nodes that never had it"
    assert_eq "1" "$(printf '%s\n' "$b" | awk -F, '$7 == 0' | grep -c .)" \
        "and the favourite flag was carried through untouched"
}

test_the_status_table_marks_only_the_flagged_node() {
    # The only way to confirm from the TUI that a node actually carries the flag.
    source "$SRC_DIR/nodes.sh"
    stub curl 7; stub jq 1          # backend absent -> ICMP fallback, which reparses the blob
    local out; out="$(show_nodes_table 2>/dev/null | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')"
    assert_contains "$(printf '%s\n' "$out" | grep pi-blocker)" "luks"
    assert_not_contains "$(printf '%s\n' "$out" | grep pfsense-wall)" "luks"
    assert_not_contains "$(printf '%s\n' "$out" | grep jelly-streamer)" "luks" \
        "an explicit 0 is not a flag"
}

# ── loading the fleet ───────────────────────────────────────────────────────
test_k_load_all_fills_K_LUKS_positionally() {
    k_begin
    k_load_all
    assert_eq "4" "$K_N"
    assert_eq "pi-blocker" "${K_NAME[2]:-}" "the flagged node is third, and stays third"
    assert_eq "192.168.77.11" "${K_IP[2]:-}"
    assert_eq "0" "${K_LUKS[0]:-UNSET}"
    assert_eq "0" "${K_LUKS[1]:-UNSET}"
    assert_eq "1" "${K_LUKS[2]:-UNSET}" "the flag landed on the node that has it"
    assert_eq "0" "${K_LUKS[3]:-UNSET}"
}



# ── the ladder ──────────────────────────────────────────────────────────────
test_a_flagged_node_that_is_off_is_never_woken() {
    # Waking it would strand it at a passphrase prompt: unreachable, and unpowerable-off,
    # since powering off is ssh too. So the run has to refuse to touch it.
    install_node 0 "192.168.77.12" pfsense-wall 0 "$OLD_PUB"
    install_node 1 "192.168.77.11" pi-blocker   1 "$OLD_PUB"
    set_down 192.168.77.11
    : > "$STUB_LOG"

    assert_rc "$K_LUKSLOCK" k_resolve 1 "$SSH_KEY"
    assert_eq "0" "$(stub_count wakeonlan)" "no magic packet"
    assert_eq "" "$(stub_calls api_toggle)" "and the backend is never asked to power it on"
}

test_a_flagged_node_that_is_answering_resolves_normally() {
    install_node 0 "192.168.77.12" pfsense-wall 0 "$OLD_PUB"
    install_node 1 "192.168.77.11" pi-blocker   1 "$OLD_PUB"
    assert_rc 0 k_resolve 1 "$SSH_KEY" "a human unlocked it; it is an ordinary node now"
    assert_eq "$SSH_KEY" "$K_ACTIVE_KEY"
    assert_eq "0" "$(stub_count wakeonlan)"
}

test_the_flag_gates_waking_and_nothing_else() {
    # Answering, but our key is gone. That is a password prompt, not a luks lock - if the
    # flag short-circuited the whole ladder the node would be written off as unrecoverable.
    install_node 0 "192.168.77.12" pfsense-wall 0 "$OLD_PUB"
    install_node 1 "192.168.77.11" pi-blocker   1 "$FOREIGN"
    K_ADOPT_PUB="$SSH_KEY.pub"; K_ADOPT_KEY="$SSH_KEY"
    assert_rc "$K_NEEDPASS" k_resolve 1 "$SSH_KEY"
    k_st_read 1
    assert_eq "need_pass" "$K_S"
}

test_an_unflagged_node_that_is_off_is_still_woken() {
    # The regression that matters: the gate must not have quietly stopped waking everything.
    install_node 0 "192.168.77.12" pfsense-wall      0 "$OLD_PUB"
    install_node 1 "192.168.77.13" jelly-streamer 0 "$OLD_PUB"
    set_down 192.168.77.13
    : > "$STUB_LOG"

    assert_rc "$K_DOWN" k_resolve 1 "$SSH_KEY"
    assert_contains "$(stub_calls api_toggle)" "192.168.77.13 maddev on" \
        "the backend is asked first, so the WebGUI shows the same confirming_up"
    assert_le 1 "$(stub_count wakeonlan)" "and WoL is blasted when it does not answer"
}

# ── the worker's vocabulary ─────────────────────────────────────────────────
test_the_worker_reports_a_luks_lock_as_a_nok_the_board_can_hold() {
    install_node 0 "192.168.77.12" pfsense-wall 0 "$OLD_PUB"
    install_node 1 "192.168.77.11" pi-blocker   1 "$OLD_PUB"
    set_down 192.168.77.11
    K_OP=resolve
    ( k_worker 1 )              # k_worker exits; a subshell keeps the test alive

    k_st_read 1
    assert_eq "nok" "$K_S"
    assert_eq "luks locked" "$K_D" "the one detail string the report keys its advice off"

    local f; f="$(frame 'ensure reachability')"
    assert_contains "$f" "luks locked" "and it reaches the board whole, not truncated"
    assert_le "$(widest 'ensure reachability')" 40 \
        "a wrapped row desynchronises the cursor-up redraw for every frame after it"
}

# ── back to sleep ───────────────────────────────────────────────────────────
test_the_woke_marker_is_written_only_when_a_node_was_actually_woken() {
    install_node 0 "192.168.77.12" pfsense-wall      0 "$OLD_PUB"
    install_node 1 "192.168.77.13" jelly-streamer 0 "$OLD_PUB"
    set_down 192.168.77.13
    ( sleep 1; rm -f "$NODES/192.168.77.13/.down" ) &     # comes back mid-wait
    K_ICMP_BUDGET=20 K_SSHD_BUDGET=20 k_resolve 1 "$SSH_KEY"
    local rc=$?
    wait
    assert_eq "0" "$rc" "it came back and answered"
    assert_file "$K_RUN/n1/woke" "this run put it on the network, so this run owes it a shutdown"
    assert_no_file "$K_RUN/n0/woke" "and only that node is marked"
}

test_a_node_that_was_already_up_is_not_marked_as_woken() {
    # Switching off a machine somebody is using, because a reachability check ran, is the
    # worst thing this feature could do. Two shapes of "already up", because they leave the
    # ladder at different points: one answers the first probe, the other walks the whole
    # sshd wait - and only the wake branch may write the marker.
    install_node 0 "192.168.77.12" pfsense-wall      0 "$OLD_PUB"
    install_node 1 "192.168.77.13" jelly-streamer 0 "$OLD_PUB"
    install_node 2 "192.168.77.14" immich-provider    0 "$FOREIGN"
    K_ADOPT_PUB="$SSH_KEY.pub"; K_ADOPT_KEY="$SSH_KEY"

    assert_rc 0 k_resolve 1 "$SSH_KEY"
    assert_no_file "$K_RUN/n1/woke"

    assert_rc "$K_NEEDPASS" k_resolve 2 "$SSH_KEY" "up, but our key is gone"
    assert_no_file "$K_RUN/n2/woke" "reaching the sshd wait is not the same as having woken it"
    assert_eq "0" "$(stub_count wakeonlan)" "and nothing was woken to get there"
}

test_a_node_that_never_came_back_is_not_marked_as_woken() {
    # Telling the backend to shut down a machine that never rose only buys a pointless
    # 60s confirming_down.
    install_node 0 "192.168.77.12" pfsense-wall      0 "$OLD_PUB"
    install_node 1 "192.168.77.13" jelly-streamer 0 "$OLD_PUB"
    set_down 192.168.77.13
    assert_rc "$K_DOWN" k_resolve 1 "$SSH_KEY"
    assert_no_file "$K_RUN/n1/woke"
}

test_sleep_woken_powers_off_exactly_the_nodes_this_run_woke() {
    k_begin
    k_add_node "aa:bb:cc:dd:ee:00" "192.168.77.12" "pfsense-wall"      "root"   0
    k_add_node "aa:bb:cc:dd:ee:01" "192.168.77.13" "jelly-streamer" "maddev" 0
    k_add_node "aa:bb:cc:dd:ee:02" "192.168.77.14" "immich-provider"    "maddev" 0
    k_add_node "aa:bb:cc:dd:ee:03" "192.168.77.15" "vault-warden"     "maddev" 0
    : > "$K_RUN/n1/woke"; : > "$K_RUN/n3/woke"
    API_TOGGLE_RC=0                # backend present, so no direct ssh poweroff
    stub sleep
    : > "$STUB_LOG"

    k_sleep_woken >/dev/null
    assert_eq "2" "$K_SLEPT"
    local calls; calls="$(stub_calls api_toggle)"
    assert_contains "$calls" "192.168.77.13 maddev off"
    assert_contains "$calls" "192.168.77.15 maddev off"
    assert_not_contains "$calls" "192.168.77.12" "a node that was already up is left running"
    assert_not_contains "$calls" "192.168.77.14" "a node that never woke is left alone"
    assert_eq "0" "$(stub_count ssh)" "the backend answered, so nothing is powered off behind it"
}

test_sleep_woken_does_nothing_when_the_run_woke_nothing() {
    k_begin
    k_add_node "aa:bb:cc:dd:ee:00" "192.168.77.12" "pfsense-wall" "root" 0
    : > "$STUB_LOG"
    k_sleep_woken >/dev/null
    assert_eq "0" "$K_SLEPT"
    assert_eq "" "$(stub_calls api_toggle)" "a fleet that was awake stays awake"
}

# ── adding a node ───────────────────────────────────────────────────────────
# The question is the inverse of the stored flag: "can it be sshd into?" answered "no" is
# LUKS_BLOCKED=1. Getting that backwards is the one mistake nothing downstream can catch.
test_add_node_stores_one_when_the_answer_is_no() {
    source "$SRC_DIR/nodes.sh"
    stub ping 0; stub sshpass 0; stub curl 7; stub jq 1
    # ip, mac, name, user, password, subtitle, then 'n' for the luks menu and 'n' for the
    # favourite menu - flagged AND hidden from guests, so the two flags cannot be confused.
    printf '192.168.77.11\naa:bb:cc:dd:ee:ff\npi-blocker\nmaddev\nhunter2\nWorkstation\n\n\nnn' \
        | add_node >/dev/null 2>&1
    assert_contains "$(written_blob)" \
        "aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,Workstation,1,0" \
        "nine fields, in MAC,IP,NAME,USER,SUBTITLE,LUKS,FAVOURITE,ORDER,PRETTY order"
    assert_not_contains "$(written_blob)" "hunter2" "the password is still never persisted"
}

test_add_node_stores_zero_when_the_answer_is_yes() {
    source "$SRC_DIR/nodes.sh"
    stub ping 0; stub sshpass 0; stub curl 7; stub jq 1
    # The empty lines answer the pretty ask (none) and the shelf-position ask (the end);
    # 'y' answers the luks menu; EOF leaves the favourite menu on its default, which is yes.
    printf '192.168.77.15\n02:00:00:00:00:15\nvault-warden\nmaddev\nhunter2\nAI Ecosystem\n\n\ny' \
        | add_node >/dev/null 2>&1
    assert_contains "$(written_blob)" \
        "02:00:00:00:00:15,192.168.77.15,vault-warden,maddev,AI Ecosystem,0,1" \
        "favourite defaults to yes: a node nobody hides is a node everyone sees"
}

test_add_node_leaves_the_existing_records_untouched() {
    # The new record is appended to a blob that already holds a flagged node; a rewrite that
    # dropped the flag here would be silent.
    source "$SRC_DIR/nodes.sh"
    stub ping 0; stub sshpass 0; stub curl 7; stub jq 1
    printf '192.168.77.15\n02:00:00:00:00:15\nvault-warden\nmaddev\nhunter2\nAI Ecosystem\n\n\ny' \
        | add_node >/dev/null 2>&1
    local b; b="$(written_blob)"
    assert_contains "$b" "192.168.77.11,pi-blocker,maddev,Workstation,1,0" "pi-blocker keeps both flags"
    assert_contains "$b" "192.168.77.14,immich-provider,maddev,Sensors,0,1" "and the others are not rewritten"
}
