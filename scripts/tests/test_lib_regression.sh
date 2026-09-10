#!/usr/bin/env bash
# Regression tests for lib.sh - these lock in behaviour that existed BEFORE the keys
# feature. They must keep passing untouched; if one of them breaks, the refactor broke
# something the user already relies on.

# interactive_menu reads raw keystrokes from stdin and returns the chosen index as its
# exit status. Feeding it a string of keys drives it without a real TTY.
menu_choice() {
    local keys="$1"; shift
    printf '%s' "$keys" | ( source "$SRC_DIR/lib.sh"; interactive_menu "$@" >/dev/null 2>&1; echo $? )
}

# The rendered option list (what the user actually sees), first frame only. Compared with
# the colors stripped: the addressing token now paints pink in the frame, and
# test_addressing.sh pins the stripped frame byte-identical to the pre-color rendering -
# so these assertions still lock in exactly the geometry they always did.
menu_render() {
    local keys="$1"; shift
    printf '%s' "$keys" | ( source "$SRC_DIR/lib.sh"; interactive_menu "$@" 2>/dev/null ) \
        | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' | head -n $#
}

test_menu_enter_selects_first_option() {
    assert_eq "0" "$(menu_choice $'\n' "ssh to node" "hit lights" "exit")"
}

test_menu_hotkey_jumps_to_option() {
    # first letter of each option is its hotkey when unambiguous
    assert_eq "1" "$(menu_choice "h" "ssh to node" "hit lights" "exit")"
    assert_eq "2" "$(menu_choice "e" "ssh to node" "hit lights" "exit")"
}

test_menu_hotkey_is_case_insensitive() {
    assert_eq "1" "$(menu_choice "H" "ssh to node" "hit lights" "exit")"
}

test_menu_arrow_down_then_enter() {
    assert_eq "1" "$(menu_choice $'\e[B\n' "ssh to node" "hit lights" "exit")"
}

test_menu_arrow_up_wraps_to_last() {
    assert_eq "2" "$(menu_choice $'\e[A\n' "ssh to node" "hit lights" "exit")"
}

test_menu_resolves_first_letter_collisions_with_digits() {
    # "apple" collides with "alpha" on 'a', so it is relabelled "[1] apple" and keyed to 1
    local out; out="$(menu_render $'\n' "alpha" "apple" "cancel")"
    assert_contains "$out" "[1] apple" "colliding option is relabelled with a digit"
    assert_eq "1" "$(menu_choice "1" "alpha" "apple" "cancel")" "digit key selects it"
    assert_eq "0" "$(menu_choice "a" "alpha" "apple" "cancel")" "'a' still picks the first"
}

test_menu_hotkeys_for_the_top_level_menu_are_unambiguous() {
    # The top-level menu gains "keys", "modify node" and "fields on tables"; nothing may be
    # relabelled with a digit, which would mean two entries fought over a letter.
    local menu=("ssh to node" "hit lights" "keys" "add node" "modify node" "remove node" "list nodes" "fields on tables" "update view" "exit")
    local out
    out="$(menu_render $'\n' "${menu[@]}")"
    assert_not_contains "$out" "[1]" "no collision in the top-level menu"
    assert_eq "2" "$(menu_choice "k" "${menu[@]}")" "'k' selects keys"
    assert_eq "4" "$(menu_choice "m" "${menu[@]}")" "'m' selects modify node"
    assert_eq "7" "$(menu_choice "f" "${menu[@]}")" "'f' selects fields on tables"
}

test_menu_hotkeys_for_the_keys_submenu_are_unambiguous() {
    local out
    out="$(menu_render $'\n' "rotate all keys" "purge any other keys" "ensure reachability" "back")"
    assert_not_contains "$out" "[1]" "no collision in the keys submenu"
    assert_eq "0" "$(menu_choice "r" "rotate all keys" "purge any other keys" "ensure reachability" "back")"
    assert_eq "1" "$(menu_choice "p" "rotate all keys" "purge any other keys" "ensure reachability" "back")"
    assert_eq "2" "$(menu_choice "e" "rotate all keys" "purge any other keys" "ensure reachability" "back")"
}

test_crypto_helpers_call_openssl_with_the_established_cipher() {
    # The blob format is fixed by the Rust backend, which decrypts the same file: any change
    # to cipher/kdf here silently breaks the WebGUI.
    stub_out openssl "mac,ip,name,user,sub"
    local out
    out=$( source "$SRC_DIR/lib.sh"; decrypt_blob )
    assert_eq "mac,ip,name,user,sub" "$out"
    local args; args="$(stub_calls openssl)"
    assert_contains "$args" "enc -aes-256-cbc -d -salt -pbkdf2"
    assert_contains "$args" "-pass file:$HOME/.allumeur-scripts/encrypted/.root_key"
    assert_contains "$args" "-in $HOME/.allumeur-scripts/encrypted/usr_blob.enc"
}

test_encrypt_blob_writes_to_the_blob_path() {
    stub openssl
    ( source "$SRC_DIR/lib.sh"; echo "a,b,c,d,e" | encrypt_blob )
    assert_contains "$(stub_calls openssl)" "-out $HOME/.allumeur-scripts/encrypted/usr_blob.enc"
}

test_print_header_renders_the_pastel_banner() {
    local out; out=$( source "$SRC_DIR/lib.sh"; print_header "keys" 2>/dev/null )
    assert_contains "$out" "keys"
    assert_contains "$out" "use up/down arrows & enter"
}
