#!/usr/bin/env bash
# Regression tests for nodes.sh behaviour that predates the keys feature.
# These describe what the user already relies on: the blob's CSV shape, the backend-first /
# ICMP-fallback status view, and add/remove of nodes.

BLOB='02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,Gaming!,0,1,1,
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,Series & Movies,0,1,2,
02:00:00:00:00:14,192.168.77.14,immich-provider,maddev,Cloud Storage,0,0,3,'

setup() {
    stub clear
    stub tput
    stub ssh-keygen
    # decrypt_blob is `openssl ... -in blob`; the stub ignores argv and emits the fixture.
    export FIXTURE_BLOB="$BLOB"
}

# Source nodes.sh with the menu suppressed and openssl emitting $FIXTURE_BLOB.
load_nodes() {
    stub_out openssl "$FIXTURE_BLOB"
    source "$SRC_DIR/nodes.sh"
}

test_sourcing_nodes_does_not_launch_the_menu_or_mint_a_key() {
    # The whole point of the main-guard: the suite can reach the functions without the TUI
    # starting or a stray ssh-keygen running against the sandbox.
    load_nodes
    assert_eq "0" "$(stub_count ssh-keygen)" "no key minted on source"
    assert_ok is_function show_nodes_table
    assert_ok is_function main
}

test_mint_master_key_only_when_absent() {
    load_nodes
    mint_master_key_if_missing >/dev/null
    assert_eq "1" "$(stub_count ssh-keygen)" "mints when the key file is absent"
    assert_contains "$(stub_calls ssh-keygen)" "-t ed25519 -a 100" "keeps the ed25519 params"
    assert_contains "$(stub_calls ssh-keygen)" "allumeur-master-key" "keeps the key comment"

    : > "$HOME/.allumeur-scripts/encrypted/allumeur-master-key"
    mint_master_key_if_missing >/dev/null
    assert_eq "1" "$(stub_count ssh-keygen)" "does not re-mint when the key exists"
}

test_status_table_uses_the_backend_when_it_answers() {
    load_nodes
    stub_out curl '[{"ip":"192.168.77.12","status":"up"}]'
    # jq is the backend path's parser; emit the TSV contract show_nodes_table consumes.
    stub_out jq "$(printf '192.168.77.12\tup\n192.168.77.13\tconfirming_up\n192.168.77.14\tdown')"
    local out; out="$(show_nodes_table 2>/dev/null)"

    assert_contains "$out" "pfsense-wall" "node rows rendered"
    assert_contains "$out" "[ up ]"
    assert_contains "$out" "[ ~ up ~ ]" "confirming_up keeps its grayed transitional label"
    assert_contains "$out" "[ down ]"
    assert_eq "0" "$(stub_count ping)" "backend path does not ICMP sweep"
}

test_status_table_falls_back_to_icmp_when_the_backend_is_down() {
    load_nodes
    stub curl 7          # curl: connection refused
    stub jq 1            # `jq -e .` on empty input fails -> fallback branch
    stub ping 0          # every node answers
    local out; out="$(show_nodes_table 2>/dev/null)"

    assert_contains "$out" "[ up ]" "degrades to plain up/down"
    assert_ok test "$(stub_count ping)" -ge 3
}

test_status_table_reports_empty_blob() {
    FIXTURE_BLOB=""
    load_nodes
    assert_contains "$(show_nodes_table 2>/dev/null)" "no nodes found"
}

test_api_toggle_posts_the_documented_body() {
    load_nodes
    stub curl
    api_toggle "02:00:00:00:00:12" "192.168.77.12" "root" "on"
    local args; args="$(stub_calls curl)"
    assert_contains "$args" "-X POST"
    assert_contains "$args" "/api/nodes/toggle"
    assert_contains "$args" '{"mac":"02:00:00:00:00:12","ip":"192.168.77.12","user":"root","state":"on"}'
}

# A two-way openssl stub: decrypt (-in) emits the fixture, encrypt (-out) captures stdin,
# so a test can assert on the blob the code would have written back.
load_nodes_rw() {
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
    source "$SRC_DIR/nodes.sh"
}

written_blob() { cat "$SANDBOX/written_blob" 2>/dev/null; }

test_remove_node_drops_only_the_chosen_record() {
    load_nodes_rw
    # menu order: pfsense-wall(0) jelly-streamer(1) immich-provider(2) cancel(3); 'j' jumps to
    # jelly-streamer, then 'r' answers the confirmation with "remove it".
    printf 'jr' | remove_node >/dev/null 2>&1
    local blob; blob="$(written_blob)"
    assert_not_contains "$blob" "jelly-streamer" "chosen node removed"
    assert_contains "$blob" "pfsense-wall" "others kept"
    assert_contains "$blob" "immich-provider" "others kept"
}

test_remove_node_cancel_writes_nothing() {
    load_nodes_rw
    printf 'c' | remove_node >/dev/null 2>&1
    assert_eq "" "$(written_blob)" "cancel must not rewrite the blob"
}

test_add_node_deploys_the_key_before_saving_the_record() {
    load_nodes_rw
    stub ping 0
    stub sshpass 0        # ssh-copy-id succeeds
    # ip, mac, name, user, password, subtitle; EOF answers the luks and favourite menus
    # with their defaults (sshd yes -> 0, favourite yes -> 1).
    printf '192.168.77.15\n02:00:00:00:00:15\nvault-warden\nmaddev\nhunter2\nAI Ecosystem\n' \
        | add_node >/dev/null 2>&1
    assert_contains "$(stub_calls sshpass)" "ssh-copy-id" "key is pushed with the temporary password"
    assert_contains "$(written_blob)" "02:00:00:00:00:15,192.168.77.15,vault-warden,maddev,AI Ecosystem,0,1" \
        "record saved in MAC,IP,NAME,USER,SUBTITLE,LUKS,FAVOURITE order"
    assert_not_contains "$(written_blob)" "hunter2" "the password is never persisted"
}

test_add_node_aborts_when_the_host_is_unreachable() {
    load_nodes_rw
    stub ping 1
    printf '10.9.9.9\n' | add_node >/dev/null 2>&1
    assert_eq "" "$(written_blob)" "unreachable host is not added"
    assert_eq "0" "$(stub_count sshpass)" "no key push attempted"
}

test_add_node_does_not_save_when_key_deployment_fails() {
    load_nodes_rw
    stub ping 0
    stub sshpass 1        # bad credentials
    printf '192.168.77.15\nmac\nvault-warden\nmaddev\nbadpass\nsub\n' | add_node >/dev/null 2>&1
    assert_eq "" "$(written_blob)" "a node we cannot reach by key is not recorded"
}

# ── keys feature wiring ─────────────────────────────────────────────────────
test_the_top_level_menu_offers_keys() {
    load_nodes
    local body; body="$(declare -f main)"
    assert_contains "$body" '"keys"' "keys is a top-level entry"
    assert_contains "$body" "keys_menu" "and it is wired to the submenu"
    assert_ok is_function keys_menu
}

test_the_top_level_menu_keeps_every_existing_entry() {
    load_nodes
    local body; body="$(declare -f main)"
    local e
    for e in "ssh to node" "hit lights" "add node" "modify node" "remove node" "list nodes" "update view" "exit"; do
        assert_contains "$body" "$e" "existing entry '$e' must survive"
    done
    for e in enter_shell hit_lights add_node modify_node remove_node list_nodes; do
        assert_contains "$body" "$e" "existing action '$e' still wired"
    done
}

test_the_keys_submenu_offers_the_three_operations() {
    load_nodes
    local body; body="$(declare -f keys_menu)"
    assert_contains "$body" "rotate all keys"
    assert_contains "$body" "purge any other keys"
    assert_contains "$body" "ensure reachability"
    assert_contains "$body" "back"
    assert_ok is_function keys_rotate
    assert_ok is_function keys_purge
    assert_ok is_function keys_ensure
}

test_ssh_and_poweroff_resolve_through_the_shared_ladder() {
    # The requirement is that these two stop having their own ad-hoc failure handling.
    load_nodes
    assert_contains "$(declare -f enter_shell)" "k_resolve_tty" "ssh access resolves through the ladder"
    assert_contains "$(declare -f hit_lights)" "k_resolve_tty" "poweroff resolves through the same ladder"
    assert_not_contains "$(declare -f hit_lights)" "ssh -t" "the -t that the server has no tty for is gone"
}

test_ssh_no_longer_hides_offline_nodes() {
    # It used to ping-sweep and refuse to list anything that was down; now a down node is
    # simply woken by the ladder.
    load_nodes
    assert_not_contains "$(declare -f enter_shell)" "no online nodes available"
}
