#!/usr/bin/env bash
# The orchestrator and the interactive paths: the parts that were previously reachable only
# by a human sitting in front of the terminal.

OLD_PUB='ssh-ed25519 AAAAOLD allumeur-master-key'
NEW_PUB='ssh-ed25519 AAAANEW allumeur-master-key'
FOREIGN='ssh-ed25519 AAAAFOREIGN tmorolias@protonmail.com'
STALE='ssh-ed25519 AAAASTALE allumeur-master-key'

setup() {
    source "$SRC_DIR/lib.sh"
    source "$SRC_DIR/keys.sh"

    SSH_KEY="$HOME/.allumeur-scripts/encrypted/allumeur-master-key"
    printf 'PRIVOLD\n' > "$SSH_KEY"; printf '%s\n' "$OLD_PUB" > "$SSH_KEY.pub"
    K_NEW_KEY="$SSH_KEY.new"
    printf 'PRIVNEW\n' > "$K_NEW_KEY"; printf '%s\n' "$NEW_PUB" > "$K_NEW_KEY.pub"

    NODES="$SANDBOX/nodes"; mkdir -p "$NODES"; export NODES
    K_ICMP_BUDGET=1; K_SSHD_BUDGET=1; K_GRACE_BUDGET=1
    api_toggle() { return 1; }

    cat > "$STUB_DIR/tput" <<'EOF'
#!/usr/bin/env bash
[ "$1" = cols ] && { echo 40; exit 0; }
exit 0
EOF
    chmod +x "$STUB_DIR/tput"
    stub wakeonlan
    stub clear
    fake_ssh
}

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
for a in "$@"; do case "$a" in 192.168.*) ip="$a";; esac; done
[ -f "$NODES/$ip/.down" ] && exit 1
exit 0
FAKE
    chmod +x "$STUB_DIR/ping"
}

# Build a fleet, then hand it to k_run the way an operation does.
fleet() {
    k_begin
    local spec ip name keys
    for spec in "$@"; do
        IFS='|' read -r ip name keys <<< "$spec"
        mkdir -p "$NODES/$ip/.ssh"
        # quoted: a key line contains spaces, and ';' is the separator between keys
        printf '%s\n' "$keys" | tr ';' '\n' > "$NODES/$ip/.ssh/authorized_keys"
        chmod 700 "$NODES/$ip/.ssh"; chmod 600 "$NODES/$ip/.ssh/authorized_keys"
        k_add_node "aa:bb:cc:dd:ee:ff" "$ip" "$name" "maddev" 0
    done
}
node_keys() { cat "$NODES/$1/.ssh/authorized_keys" 2>/dev/null; }

# k_run polls stdin for the abort key; /dev/null makes every poll a no-op. K_TTY points at
# an empty file so a node that unexpectedly asks for a password is skipped rather than
# blocking the whole suite forever on /dev/tty.
run_op() {
    : > "$SANDBOX/empty_tty"
    K_TTY="$SANDBOX/empty_tty" k_run "$1" < /dev/null > "$SANDBOX/board" 2>&1
}
board() { sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' "$SANDBOX/board"; }

test_a_run_drives_every_node_to_a_terminal_state() {
    fleet "192.168.77.12|pfsense-wall|$OLD_PUB;$FOREIGN" \
          "192.168.77.13|jelly-streamer|$OLD_PUB;$FOREIGN"
    K_OP=purge K_ADOPT_PUB="$SSH_KEY.pub" K_ADOPT_KEY="$SSH_KEY"
    run_op "purge any other keys"
    assert_ok k_all_terminal
    k_st_read 0; assert_eq "ok" "$K_S" "pfsense-wall finished"
    k_st_read 1; assert_eq "ok" "$K_S" "jelly-streamer finished"
    assert_eq "$OLD_PUB" "$(node_keys 192.168.77.12)"
    assert_eq "$OLD_PUB" "$(node_keys 192.168.77.13)"
}

test_a_run_keeps_going_when_one_node_is_unreachable() {
    # The LUKS-box case: one node never comes back and must not hold the others hostage.
    fleet "192.168.77.12|pfsense-wall|$OLD_PUB;$FOREIGN" \
          "192.168.77.13|jelly-streamer|$OLD_PUB"
    : > "$NODES/192.168.77.13/.down"
    K_OP=purge K_ADOPT_PUB="$SSH_KEY.pub" K_ADOPT_KEY="$SSH_KEY"
    run_op "purge any other keys"
    assert_ok k_all_terminal "the run still finished"
    k_st_read 0; assert_eq "ok" "$K_S" "the reachable node was still done"
    k_st_read 1; assert_eq "nok" "$K_S" "the unreachable one is queued as a nok"
    assert_eq "never woke" "$K_D" "with a reason the user can act on"
    assert_eq "$OLD_PUB" "$(node_keys 192.168.77.12)"
}

test_the_board_shows_the_whole_fleet_and_the_tally() {
    fleet "192.168.77.12|pfsense-wall|$OLD_PUB" "192.168.77.13|jelly-streamer|$OLD_PUB"
    K_OP=purge K_ADOPT_PUB="$SSH_KEY.pub" K_ADOPT_KEY="$SSH_KEY"
    run_op "purge any other keys"
    local b; b="$(board)"
    assert_contains "$b" "purge any other keys" "the title"
    assert_contains "$b" "pfsense-wall"
    assert_contains "$b" "jelly-streamer"
    assert_contains "$b" "2 ok"
}

test_a_rotate_run_end_to_end_leaves_the_fleet_on_the_new_key() {
    fleet "192.168.77.12|pfsense-wall|$OLD_PUB" "192.168.77.13|jelly-streamer|$OLD_PUB"
    K_OP=rotate K_ADOPT_PUB="$K_NEW_KEY.pub" K_ADOPT_KEY="$K_NEW_KEY"
    run_op "rotate all keys"
    k_rotate_finalize
    assert_contains "$(node_keys 192.168.77.12)" "AAAANEW"
    assert_not_contains "$(node_keys 192.168.77.12)" "AAAAOLD"
    assert_contains "$(node_keys 192.168.77.13)" "AAAANEW"
    assert_not_contains "$(node_keys 192.168.77.13)" "AAAAOLD"
    assert_eq "PRIVNEW" "$(cat "$SSH_KEY")" "the new key is now the master key"
}

# ── the password prompt ─────────────────────────────────────────────────────
test_a_typed_password_is_kept_in_memory_and_the_node_is_retried() {
    fleet "192.168.77.12|pfsense-wall|$FOREIGN"       # our key is not on it
    K_TTY="$SANDBOX/tty"; printf 'hunter2\n' > "$K_TTY"
    assert_ok k_prompt_pw 0
    assert_eq "hunter2" "${K_PW[0]}" "held for the respawned worker"
    assert_no_file "$K_RUN/pw" "and never written to disk"
    assert_eq "" "$(grep -rl hunter2 "$K_RUN" 2>/dev/null)" "no trace of it in the run dir"
}

test_an_empty_password_skips_the_node_instead_of_hanging() {
    fleet "192.168.77.12|pfsense-wall|$FOREIGN"
    K_TTY="$SANDBOX/tty"; printf '\n' > "$K_TTY"
    assert_fail k_prompt_pw 0
    k_st_read 0
    assert_eq "nok" "$K_S"
    assert_eq "skipped" "$K_D"
}

test_the_prompt_names_the_node_that_is_asking() {
    fleet "192.168.77.12|pfsense-wall|$FOREIGN"
    K_TTY="$SANDBOX/tty"; printf 'pw\n' > "$K_TTY"
    local out; out=$(k_prompt_pw 0 | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')
    assert_contains "$out" "pfsense-wall" "which node"
    assert_contains "$out" "maddev@192.168.77.12" "and which account"
    assert_contains "$out" "empty = skip"
}

# ── the wipe step ───────────────────────────────────────────────────────────
test_wiping_superseded_keys_removes_only_those() {
    fleet "192.168.77.12|pfsense-wall|$OLD_PUB;$STALE;$FOREIGN"
    K_OP=ensure K_ADOPT_PUB="$SSH_KEY.pub" K_ADOPT_KEY="$SSH_KEY"
    k_op_ensure 0
    assert_file "$K_RUN/n0/stale"
    k_wipe_stale
    local keys; keys="$(node_keys 192.168.77.12)"
    assert_not_contains "$keys" "AAAASTALE" "our superseded key is gone"
    assert_contains "$keys" "AAAAOLD" "the key in use stays"
    assert_contains "$keys" "AAAAFOREIGN" "someone else's key is not ours to wipe here"
}

# ── stopping ────────────────────────────────────────────────────────────────
test_stopping_a_run_settles_every_unfinished_node() {
    fleet "192.168.77.12|pfsense-wall|$OLD_PUB" "192.168.77.13|jelly-streamer|$OLD_PUB"
    k_st 0 ok
    k_st 1 push
    K_PID=()
    k_stop_run
    assert_ok k_all_terminal "nothing is left mid-flight"
    k_st_read 1
    assert_eq "nok" "$K_S"
    assert_eq "stopped" "$K_D" "and it says why"
    k_st_read 0
    assert_eq "ok" "$K_S" "an already-finished node keeps its result"
}

# ── the prompt must not repeat itself ───────────────────────────────────────
test_a_node_is_prompted_for_its_password_only_once() {
    # A respawned worker does not rewrite its state until it is actually running, so the
    # board loop could still see need_pass on the very next tick and ask again - the user
    # would be stuck typing the same password over and over while the run never progressed.
    fake_sshpass
    local trials=8 repeats=0 t
    for ((t=0; t<trials; t++)); do
        PROMPTS=0
        # Stand in for the human: always supplies a password, and gives up loudly if the
        # loop asks more than the one time it should.
        k_prompt_pw() {
            PROMPTS=$((PROMPTS+1))
            [ "$PROMPTS" -gt 3 ] && { k_st "$1" nok bail; return 1; }
            K_PW[$1]=hunter2; K_PREV_FRAME=''; K_PREV_ROWS=0; return 0
        }
        rm -rf "$NODES"; mkdir -p "$NODES"
        fleet "192.168.77.12|pfsense-wall|$FOREIGN" "192.168.77.13|jelly-streamer|$FOREIGN"
        K_OP=ensure K_ADOPT_PUB="$SSH_KEY.pub" K_ADOPT_KEY="$SSH_KEY"
        run_op "ensure reachability"
        [ "$PROMPTS" -gt 2 ] && repeats=$((repeats+1))
        rm -rf "$K_RUN"
    done
    assert_eq "0" "$repeats" "$repeats of $trials runs asked a node for its password twice"
}

test_a_password_actually_puts_the_key_back_on_the_node() {
    fake_sshpass
    fleet "192.168.77.12|pfsense-wall|$FOREIGN"
    k_prompt_pw() { K_PW[$1]=hunter2; K_PREV_FRAME=''; K_PREV_ROWS=0; return 0; }
    K_OP=ensure K_ADOPT_PUB="$SSH_KEY.pub" K_ADOPT_KEY="$SSH_KEY"
    run_op "ensure reachability"
    k_st_read 0
    assert_eq "ok" "$K_S" "the node is reachable again"
    assert_contains "$(node_keys 192.168.77.12)" "AAAAOLD" "the master key was redeployed"
    assert_contains "$(node_keys 192.168.77.12)" "AAAAFOREIGN" "without disturbing what was there"
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

test_a_fully_successful_run_reports_no_failures() {
    # `[ ok ] && ((ok++)) || ((nok++))` counted the FIRST success as a failure too, because
    # ((ok++)) evaluates to the old value, which is 0, which is false.
    fleet "192.168.77.12|pfsense-wall|$OLD_PUB" "192.168.77.13|jelly-streamer|$OLD_PUB"
    K_OP=purge K_ADOPT_PUB="$SSH_KEY.pub" K_ADOPT_KEY="$SSH_KEY"
    run_op "purge any other keys"
    stub clear
    local rep; rep=$(printf 'x' | k_report "purge any other keys" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')
    assert_contains "$rep" "ok 2 / 2"
    assert_not_contains "$rep" "nok 1" "a clean run must not invent a failure"
    assert_not_contains "$rep" "nok" "and must not print a nok section at all"
}

test_the_report_tells_you_what_to_do_about_each_kind_of_failure() {
    fleet "192.168.77.12|pfsense-wall|$OLD_PUB" "192.168.77.13|jelly-streamer|$OLD_PUB"
    : > "$NODES/192.168.77.13/.down"
    K_OP=purge K_ADOPT_PUB="$SSH_KEY.pub" K_ADOPT_KEY="$SSH_KEY"
    run_op "purge any other keys"
    stub clear
    local rep; rep=$(printf 'x' | k_report "purge any other keys" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')
    assert_contains "$rep" "ok 1 / 2"
    assert_contains "$rep" "jelly-streamer"
    assert_contains "$rep" "never woke"
    assert_contains "$rep" "power it on" "the advice matches the actual failure"
}
