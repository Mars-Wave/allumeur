#!/usr/bin/env bash
# The live board. This is driven from a phone over SSH, so the binding constraint is that
# no line may ever wrap: a wrapped line occupies two physical rows, which desynchronises the
# cursor-up redraw and corrupts every frame after it.

setup() {
    source "$SRC_DIR/lib.sh"
    source "$SRC_DIR/keys.sh"
    K_RUN="$SANDBOX/run"; mkdir -p "$K_RUN"
    K_PREV_FRAME=''; K_PREV_ROWS=0
    COLS=40
    cat > "$STUB_DIR/tput" <<'EOF'
#!/usr/bin/env bash
[ "$1" = cols ] && { echo "${COLS:-40}"; exit 0; }
exit 0
EOF
    chmod +x "$STUB_DIR/tput"
    export COLS
}

add() {   # index name state [detail]
    K_NAME[$1]=$2; K_IP[$1]="192.168.77.2$1"; K_USER[$1]=maddev; K_MAC[$1]="aa:0$1"
    mkdir -p "$K_RUN/n$1"
    k_st "$1" "$3" "${4:-}"
    K_N=$(( $1 + 1 ))
}

# Rendered frame with the escape sequences stripped - what the eye actually sees.
frame() {
    K_PREV_FRAME=''; K_PREV_ROWS=0
    k_board "$1" | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\x1b\[[JK]//g'
}

widest() { frame "$1" | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }'; }

test_no_line_wraps_at_forty_columns() {
    COLS=40
    add 0 pfsense-wall      ok
    add 1 jelly-streamer push
    add 2 immich-provider    sshd
    add 3 pi-blocker        need_pass
    add 4 vault-warden     queued
    local w; w=$(widest "rotate all keys")
    assert_le "$w" 40 "widest rendered line was $w columns, budget is 40"
}

test_no_line_wraps_on_a_very_narrow_terminal() {
    COLS=30
    add 0 jelly-streamer push
    add 1 pi-blocker        need_pass
    local w; w=$(widest "purge any other keys")
    assert_le "$w" 30 "widest rendered line was $w columns, budget is 30"
}

test_the_longest_real_node_name_survives_intact() {
    COLS=40
    add 0 immich-provider push
    assert_contains "$(frame 'rotate all keys')" "immich-provider" \
        "the longest name in the fleet must not be truncated"
}

test_an_overlong_name_is_truncated_with_a_tilde() {
    COLS=40
    add 0 averyveryverylongnodename push
    local f; f="$(frame 'rotate all keys')"
    assert_contains "$f" "averyveryveryl~" "truncated to the name column with a trailing ~"
    assert_not_contains "$f" "averyveryverylongnodename" "the full name would have wrapped"
}

test_every_node_and_a_running_tally_are_visible() {
    COLS=40
    add 0 pfsense-wall      ok
    add 1 jelly-streamer push
    add 2 pi-blocker        need_pass
    add 3 vault-warden     nok "no sshd"
    local f; f="$(frame 'rotate all keys')"
    assert_contains "$f" "pfsense-wall"
    assert_contains "$f" "jelly-streamer"
    assert_contains "$f" "pi-blocker"
    assert_contains "$f" "vault-warden"
    assert_contains "$f" "1 ok" "the tally counts what is done"
    assert_contains "$f" "1 ask" "and what is waiting on a human"
    assert_contains "$f" "1 nok" "and what failed"
}

test_states_read_as_words_not_just_colour() {
    # A phone terminal may render none of the SGR colours; the label has to carry it.
    COLS=40
    add 0 a ok; add 1 b push; add 2 c sshd; add 3 d need_pass; add 4 e nok "never woke"
    local f; f="$(frame 'rotate all keys')"
    assert_contains "$f" "done"
    assert_contains "$f" "push key"
    assert_contains "$f" "wait sshd"
    assert_contains "$f" "NEEDS PASS" "the one thing needing the user's eye is the one thing shouting"
    assert_contains "$f" "FAILED"
}

test_the_board_uses_no_unicode() {
    COLS=40
    add 0 pfsense-wall ok
    add 1 pi-blocker need_pass
    local f; f="$(frame 'rotate all keys')"
    assert_eq "" "$(printf '%s' "$f" | LC_ALL=C grep -P '[^\x00-\x7F]' || true)" \
        "non-ascii on the board may render as blocks over ssh from a phone"
}

test_a_frame_that_did_not_change_is_not_reprinted() {
    # Reprinting an identical frame every second is pure noise on a slow link.
    COLS=40
    add 0 pfsense-wall ok
    # Not $(...): the frame cache is shell state, and a subshell would discard it.
    K_PREV_FRAME=''; K_PREV_ROWS=0
    k_board "rotate all keys" > "$SANDBOX/f1"
    k_board "rotate all keys" > "$SANDBOX/f2"
    assert_ok test -s "$SANDBOX/f1"
    assert_eq "" "$(cat "$SANDBOX/f2")" "an unchanged board emits nothing"
}

test_elapsed_time_is_short_enough_for_the_column() {
    assert_eq "9s" "$(k_elapsed 9)"
    assert_eq "59s" "$(k_elapsed 59)"
    assert_eq "1:00" "$(k_elapsed 60)"
    assert_eq "2:05" "$(k_elapsed 125)"
    local longest; longest=$(k_elapsed 3599)
    assert_le "${#longest}" 5 "the elapsed column is 5 wide"
}

test_truncation_helper() {
    assert_eq "short" "$(k_trunc short 15)"
    assert_eq "immich-provider" "$(k_trunc immich-provider 15)"
    assert_eq "averyverylongn~" "$(k_trunc averyverylongname 15)"
}

test_a_long_failure_reason_does_not_widen_the_row() {
    # The reason is printed in the timer column; unclamped it pushed rows to 37 columns and
    # wrapped on a terminal reporting 34-36.
    COLS=36
    add 0 jelly-streamer nok "never woke and will not"
    assert_le "$(widest 'rotate all keys')" 36 "a long reason must be clamped, not wrap"
}

test_a_settled_node_stops_counting() {
    COLS=40
    add 0 pfsense-wall ok
    local f; f="$(frame 'rotate all keys')"
    assert_contains "$f" "done"
    assert_not_contains "$f" "0s" "a finished node showing a climbing timer is a lie"
}
