#!/usr/bin/env bash
# The remote authorized_keys writer, exercised for real.
#
# This is the most dangerous code in the feature: it runs on every node, and a mistake
# either locks the fleet out or silently fails to remove a key that was supposed to die.
# It is plain POSIX sh operating on files, so the tests run it exactly as a node would -
# `sh -s -- <mode> <b64>` with a sandbox $HOME - rather than mocking it.

OLD='ssh-ed25519 AAAAOLD allumeur-master-key'
NEW='ssh-ed25519 AAAANEW allumeur-master-key'
FOREIGN='ssh-ed25519 AAAAFOREIGN tmorolias@protonmail.com'

setup() {
    source "$SRC_DIR/keys.sh"
    NODE_HOME="$SANDBOX/node"
    mkdir -p "$NODE_HOME"
}

# Run the writer the way k_ak does: script on stdin, mode and base64 key as arguments.
ak() {
    local mode="$1" key="${2:-}" b64=""
    [ -n "$key" ] && b64=$(printf '%s' "$key" | base64 -w0)
    printf '%s' "$K_AK_SCRIPT" | HOME="$NODE_HOME" sh -s -- "$mode" "$b64" 2>&1
}

akfile() { cat "$NODE_HOME/.ssh/authorized_keys" 2>/dev/null; }

test_add_creates_the_ssh_dir_and_file_with_safe_modes() {
    local out; out=$(ak add "$NEW")
    assert_contains "$out" "AKOK add"
    assert_eq "$NEW" "$(akfile)"
    assert_eq "700" "$(stat -c %a "$NODE_HOME/.ssh")" ".ssh must be 700 or sshd ignores it"
    assert_eq "600" "$(stat -c %a "$NODE_HOME/.ssh/authorized_keys")"
}

test_add_repairs_pre_existing_bad_modes() {
    # immich-provider really does have a 644 authorized_keys today; sshd tolerates it, but a
    # stricter node will not, and the writer is the natural place to fix it.
    mkdir -p "$NODE_HOME/.ssh"
    printf '%s\n' "$FOREIGN" > "$NODE_HOME/.ssh/authorized_keys"
    chmod 755 "$NODE_HOME/.ssh"; chmod 644 "$NODE_HOME/.ssh/authorized_keys"
    ak add "$NEW" >/dev/null
    assert_eq "700" "$(stat -c %a "$NODE_HOME/.ssh")"
    assert_eq "600" "$(stat -c %a "$NODE_HOME/.ssh/authorized_keys")"
}

test_add_is_idempotent() {
    ak add "$NEW" >/dev/null
    ak add "$NEW" >/dev/null
    ak add "$NEW" >/dev/null
    assert_eq "1" "$(akfile | grep -c AAAANEW)" "the same key must never accumulate"
}

test_add_matches_on_key_material_not_comment() {
    # Re-minting with a different comment must not leave two copies of one key.
    ak add "$NEW" >/dev/null
    ak add "ssh-ed25519 AAAANEW some-other-comment" >/dev/null
    assert_eq "1" "$(akfile | grep -c AAAANEW)"
    assert_contains "$(akfile)" "some-other-comment" "the newest line wins"
}

test_add_preserves_other_keys() {
    ak add "$FOREIGN" >/dev/null
    ak add "$NEW" >/dev/null
    assert_contains "$(akfile)" "AAAAFOREIGN"
    assert_contains "$(akfile)" "AAAANEW"
}

test_add_survives_a_file_with_no_trailing_newline() {
    # `echo >>` onto such a file merges two keys into one corrupt line. awk terminates the
    # final record at EOF, so this stays two keys.
    mkdir -p "$NODE_HOME/.ssh"
    printf '%s' "$FOREIGN" > "$NODE_HOME/.ssh/authorized_keys"   # no \n
    ak add "$NEW" >/dev/null
    assert_eq "2" "$(akfile | grep -c '^ssh-ed25519')" "both keys survive as separate lines"
    assert_contains "$(akfile)" "$FOREIGN"
}

test_del_removes_only_the_named_key() {
    ak add "$OLD" >/dev/null
    ak add "$NEW" >/dev/null
    ak add "$FOREIGN" >/dev/null
    ak del "$OLD" >/dev/null
    assert_not_contains "$(akfile)" "AAAAOLD"
    assert_contains "$(akfile)" "AAAANEW"
    assert_contains "$(akfile)" "AAAAFOREIGN"
}

test_del_of_an_absent_key_is_a_no_op() {
    ak add "$NEW" >/dev/null
    local out; out=$(ak del "$OLD")
    assert_contains "$out" "AKOK del"
    assert_eq "$NEW" "$(akfile)"
}

test_del_refuses_to_empty_the_file() {
    # Removing the last key would lock the node out forever. The writer must refuse and
    # leave authorized_keys exactly as it was.
    ak add "$NEW" >/dev/null
    ak del "$NEW" >/dev/null
    assert_eq "$NEW" "$(akfile)" "the last key is never removed"
}

test_only_reduces_to_a_single_key() {
    ak add "$OLD" >/dev/null
    ak add "$FOREIGN" >/dev/null
    ak add 'ssh-rsa AAAAOTHER root@somewhere' >/dev/null
    ak only "$NEW" >/dev/null
    assert_eq "$NEW" "$(akfile)" "exactly one key remains"
    assert_eq "1" "$(akfile | grep -c .)"
}

test_only_removes_a_key_carrying_forced_command_options() {
    # A foreign line may start with options rather than the key type; `only` ignores prior
    # content entirely, so such a line cannot survive.
    mkdir -p "$NODE_HOME/.ssh"
    printf 'command="/bin/false",no-pty %s\n' "$FOREIGN" > "$NODE_HOME/.ssh/authorized_keys"
    ak only "$NEW" >/dev/null
    assert_not_contains "$(akfile)" "command="
    assert_eq "$NEW" "$(akfile)"
}

test_list_returns_the_file_and_a_sentinel() {
    ak add "$NEW" >/dev/null
    ak add "$FOREIGN" >/dev/null
    local out; out=$(ak list)
    assert_contains "$out" "AAAANEW"
    assert_contains "$out" "AAAAFOREIGN"
    assert_contains "$out" "AKOK list" "the sentinel is what proves the command ran"
}

test_an_unknown_mode_changes_nothing() {
    ak add "$NEW" >/dev/null
    ak wipe "$NEW" >/dev/null
    assert_eq "$NEW" "$(akfile)"
}

test_a_torn_write_never_leaves_a_temp_file_behind() {
    ak add "$NEW" >/dev/null
    ak only "$OLD" >/dev/null
    assert_eq "" "$(find "$NODE_HOME/.ssh" -name '.ak.tmp.*' 2>/dev/null)" "no temp residue"
    assert_eq "" "$(find "$NODE_HOME/.ssh" -name '.ak.lock' 2>/dev/null)" "lock released"
}

test_del_matches_a_key_that_carries_options() {
    # sshd allows a line to begin with options rather than the key type. Identifying a key
    # by "first two fields" would miss this one and leave it behind forever.
    mkdir -p "$NODE_HOME/.ssh"
    printf 'restrict,command="/bin/false" %s\n%s\n' "$OLD" "$NEW" > "$NODE_HOME/.ssh/authorized_keys"
    ak del "$OLD" >/dev/null
    assert_not_contains "$(akfile)" "AAAAOLD" "the option-prefixed copy is still our key"
    assert_contains "$(akfile)" "AAAANEW"
}

test_add_does_not_duplicate_a_key_that_carries_options() {
    mkdir -p "$NODE_HOME/.ssh"
    printf 'no-pty %s\n' "$NEW" > "$NODE_HOME/.ssh/authorized_keys"
    ak add "$NEW" >/dev/null
    assert_eq "1" "$(akfile | grep -c AAAANEW)" "the same key must not appear twice"
}
