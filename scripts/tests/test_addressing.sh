#!/usr/bin/env bash
# Unique addressability + pink address painting + width safety.
#
# Three guarantees carry this file. (1) ADDRESSING: menu_assign_addresses in lib.sh is THE
# one assigner every interactive_menu / pick-list rendering routes through - first letter
# when unique (a leading "★ "/"  " favourite marker is presentation, not name), the lowest
# free digit 1-9 then 0 when letters collide, and free letters past ten collisions - and
# every option's address is UNIQUE for any label set that fits the single-keystroke space.
# (2) PAINT: the addressing token renders pink at that same lib level - a letter-addressed
# option paints its addressed letter in place (<pink>j<reset>ellyfin), a fallback-addressed
# option paints the whole bracket block (<pink>[1]<reset> jellyseerr) - and the rung-4
# fold legend under the tunnel table carries the same pink as the table furniture. (3)
# WIDTH SAFETY: the paint adds ONLY escape bytes - ANSI-stripped output is byte-identical
# to the pre-color rendering (every color var emptied), so no escape can ever enter
# fit_cell/TUI_MAX width math, and hotkeys/EOF-accepts-default semantics are untouched.

PINKB=$'\e[38;5;218m'   # the suite's pink (the star's, the table furniture's), as bytes
GRAYB=$'\e[38;5;245m'
RESETB=$'\e[0m'

setup() {
    stub clear
    stub ping 0
    stub curl 7
    stub jq 1
    stub tput
}

# Strip EVERY escape sequence, cursor controls included - both frames of an equivalence
# pair go through this, so tput noise cancels and only visible bytes are compared.
strip_all() { sed -e 's/\x1b\[[?0-9;]*[A-Za-z]//g'; }

# The assigner's verdict for a label set: "key<TAB>addressed-label" per option.
assign() {
    ( source "$SRC_DIR/lib.sh"; menu_assign_addresses "$@"
      local i
      for i in "${!MENU_KEYS[@]}"; do printf '%s\t%s\n' "${MENU_KEYS[$i]}" "${MENU_OPTS[$i]}"; done )
}

# One full colored frame of the REAL menu (enter accepts immediately: exactly one frame).
menu_frame() {
    printf '\n' | ( source "$SRC_DIR/lib.sh"; interactive_menu "$@" 2>/dev/null )
}

# Exit status of the real menu driven by one keystroke string.
menu_choice() {
    local keys="$1"; shift
    printf '%s' "$keys" | ( source "$SRC_DIR/lib.sh"; interactive_menu "$@" >/dev/null 2>&1; echo $? )
}

# Read-only blob stubs + loaders for the real tables.
set_blobs() {
    export FIXTURE_BLOB="$1" FIXTURE_SRV="$2"
    cat > "$STUB_DIR/openssl" <<'EOF'
#!/usr/bin/env bash
prev=""; inf=""
for a in "$@"; do [ "$prev" = "-in" ] && inf="$a"; prev="$a"; done
case "$inf" in
    *srv_blob*) printf '%s\n' "$FIXTURE_SRV" ;;
    *)          printf '%s\n' "$FIXTURE_BLOB" ;;
esac
EOF
    chmod +x "$STUB_DIR/openssl"
}

# Two services on one long LAN name: rung 4 folds the shared prefix and prints the legend.
FOLD_SRV='alpha,edge.rack-one.dmz.homelab-example.test,8001,one,1,1,
beta,edge.rack-one.dmz.homelab-example.test,8002,two,0,2,'

# A luks row pushes the nodes table through rung 1, so the compacted forms are compared too.
LUKS_N='02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,firewall,0,1,1,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,DNS,1,0,2,'

load_fold_tunnel() {
    set_blobs '' "$FOLD_SRV"
    printf '%s\n' "$FOLD_SRV" > "$HOME/.allumeur-scripts/encrypted/srv_blob.enc"
    source "$SRC_DIR/tunnel.sh"
    RUNDIR="$SANDBOX/tunnels"; mkdir -p "$RUNDIR"
}

load_luks_nodes() {
    set_blobs "$LUKS_N" ''
    source "$SRC_DIR/nodes.sh"
}

# ── T2a: one lib-level assigner, unique for every label set ─────────────────
test_interactive_menu_routes_through_the_one_lib_assigner() {
    source "$SRC_DIR/lib.sh"
    assert_ok is_function menu_assign_addresses
    assert_contains "$(declare -f interactive_menu)" "menu_assign_addresses" \
        "the menu renderer routes its addressing through the lib helper, not a private copy"
}

test_the_accepted_scheme_stands_jellyfin_j_jellyseerr_digit() {
    local out; out="$(assign jellyfin jellyseerr cancel)"
    assert_eq $'j\tjellyfin' "$(printf '%s\n' "$out" | sed -n 1p)" \
        "first letter when unique, the label untouched"
    assert_eq $'1\t[1] jellyseerr' "$(printf '%s\n' "$out" | sed -n 2p)" \
        "letter collision: digit fallback, tagged into the label"
    assert_eq $'c\tcancel' "$(printf '%s\n' "$out" | sed -n 3p)"
}

test_property_arbitrary_label_sets_are_all_uniquely_addressable() {
    # Property: for ANY set of up to 36 labels (each option consumes at most one of the 36
    # digit+letter fallback keys, so 36 is the whole single-keystroke space) every option
    # gets an address and no two addresses collide. Seeded, so a failure reproduces.
    RANDOM=20260909
    local pool=(jellyfin jellyseerr jellystat jelly-streamer "★ jekyll" "  jasmine" cancel \
                "" "édith" "über" "1password" "2fa-gate" back pfsense pi-blocker prometheus \
                paperless Grafana gitea "★ gitea-mirror" "  giteator" exit save order)
    local trial n i labels keys
    for trial in 1 2 3 4 5 6 7 8 9 10 11 12; do
        n=$(( (RANDOM % 36) + 1 ))
        labels=()
        for ((i = 0; i < n; i++)); do labels+=("${pool[RANDOM % ${#pool[@]}]}"); done
        keys="$(assign "${labels[@]}" | cut -f1)"
        assert_eq "$n" "$(printf '%s\n' "$keys" | grep -c '')" \
            "trial $trial: every one of the $n options got an address"
        assert_eq "" "$(printf '%s\n' "$keys" | sort | uniq -d)" \
            "trial $trial: no two of the $n addresses collide"
    done
}

test_thirteen_first_letter_collisions_stay_unique_past_the_digit_pool() {
    # 13 labels on one letter: the first takes 'x', nine take digits 1-9, the eleventh 0 -
    # and the two the old inline scheme would have BOTH stamped '0' take free letters
    # instead. Uniqueness holds to the last row.
    local labels=() i
    for ((i = 1; i <= 13; i++)); do labels+=("xray-$i"); done
    local keys; keys="$(assign "${labels[@]}" | cut -f1)"
    assert_eq "" "$(printf '%s\n' "$keys" | sort | uniq -d)" "all 13 addresses unique"
    assert_eq "x" "$(printf '%s\n' "$keys" | sed -n 1p)"
    assert_eq "1" "$(printf '%s\n' "$keys" | sed -n 2p)"
    assert_eq "0" "$(printf '%s\n' "$keys" | sed -n 11p)" "the digit pool ends on 0"
    assert_eq "a" "$(printf '%s\n' "$keys" | sed -n 12p)" "then the free letters begin"
    assert_eq "b" "$(printf '%s\n' "$keys" | sed -n 13p)"
}

# ── T2b: the address token paints pink at render time ───────────────────────
test_letter_addressed_options_paint_the_addressed_letter_pink_in_place() {
    local f; f="$(menu_frame "jellyfin" "exit")"
    assert_contains "$f" "${PINKB}j${RESETB}" "the selected row's addressed letter is pink"
    assert_contains "$f" "ellyfin" "and the rest of the label follows in place"
    assert_contains "$f" "${PINKB}e${RESETB}" "the unselected row is painted the same way"
}

test_digit_addressed_options_paint_the_whole_bracket_block_pink() {
    local f; f="$(menu_frame "jellyfin" "jellyseerr" "cancel")"
    assert_contains "$f" "${PINKB}[1]${RESETB}" "the WHOLE bracket block is pink"
    assert_contains "$f" " jellyseerr" "the label behind it carries no paint"
}

test_a_label_merely_shaped_like_a_collision_tag_is_not_painted_as_one() {
    # A stored label literally named "[2] weird" collides with nothing: its address is its
    # real first character "[", so the paint sits on that "[" alone - never on a "[2]"
    # block the menu would not honour. A REAL tag (its k == the row's assigned key) still
    # paints whole.
    local f; f="$(menu_frame "[2] weird" "jellyfin" "cancel")"
    assert_contains "$f" "${PINKB}[${RESETB}" "the literal bracket is the addressed letter"
    assert_not_contains "$f" "${PINKB}[2]${RESETB}" "its lookalike block gains no tag paint"
    assert_eq "0" "$(menu_choice "[" "[2] weird" "jellyfin" "cancel")" \
        "and the honoured hotkey really is the bracket"
    f="$(menu_frame "watch" "weird" "cancel")"
    assert_contains "$f" "${PINKB}[1]${RESETB}" "an assigner-added tag still paints whole"
}

test_the_favourite_marker_keeps_its_own_pink_and_the_letter_keys_the_row() {
    # A pick-list row "★ jellyfin": the star renders pink in its own column as it always
    # has, and the ADDRESS is still the name's first letter - painted behind the marker.
    local f; f="$(menu_frame "★ jellyfin" "  pi-blocker" "cancel")"
    assert_contains "$f" "${PINKB}★${RESETB}" "the star column is untouched"
    assert_contains "$f" "${PINKB}j${RESETB}" "the addressed letter is the name's, not the glyph"
    assert_eq "0" "$(menu_choice "j" "★ jellyfin" "  pi-blocker" "cancel")" \
        "and the hotkey really is that letter"
}

test_painting_leaves_hotkeys_and_eof_default_semantics_untouched() {
    assert_eq "1" "$(menu_choice "1" jellyfin jellyseerr cancel)" "the digit address selects its row"
    assert_eq "2" "$(menu_choice "c" jellyfin jellyseerr cancel)" "letters still jump"
    assert_eq "0" "$( ( source "$SRC_DIR/lib.sh"; interactive_menu jellyfin jellyseerr cancel >/dev/null 2>&1; echo $? ) </dev/null )" \
        "EOF answers as enter and accepts the default BY DESIGN"
}

# ── T1: the rung-4 fold legend is table furniture, so it wears the table's pink ──
test_the_fold_legend_renderer_is_the_tables_pink_not_gray() {
    local out; out=$( source "$SRC_DIR/lib.sh"; fold_legend "192.0.2" )
    assert_contains "$out" "${PINKB}:: = 192.0.2${RESETB}" \
        "the lib renderer prints the legend in the same pink as the header and rule"
    assert_not_contains "$out" "$GRAYB" "and none of the old gray"
}

test_the_rung4_legend_under_the_real_table_renders_pink() {
    load_fold_tunnel
    local legend; legend="$(show_tunnels_table 2>/dev/null | grep ':: =')"
    assert_contains "$legend" "${PINKB}:: = edge.rack-one.dmz.homelab-example${RESETB}" \
        "the legend under the folded table reads as part of the table"
    assert_not_contains "$legend" "$GRAYB" "no longer the gray remark it was"
}

# ── T3: ANSI never enters width math - stripped output IS the pre-color output ──
test_stripped_menu_frame_is_byte_identical_to_the_pre_color_rendering() {
    # The paint may add ONLY escape bytes: with every color var emptied the renderer emits
    # the pre-color frame, and the colored frame stripped of ANSI must equal it byte for
    # byte - markers, collision tags, paddings, everything.
    local opts=("★ jellyfin" "  jellyseerr" "  jellystat" "★ gitea" "cancel")
    local colored plain
    colored=$(printf '\n' | ( source "$SRC_DIR/lib.sh"; interactive_menu "${opts[@]}" 2>/dev/null ) | strip_all)
    plain=$(printf '\n' | ( source "$SRC_DIR/lib.sh"; PINK=""; WHITE=""; GRAY=""; BOLD=""; RESET=""
                            interactive_menu "${opts[@]}" 2>/dev/null ) | strip_all)
    assert_eq "$plain" "$colored" "the paint added no visible byte to any menu row"
    assert_contains "$colored" "[1] jellyseerr" "the collision tag is visible bytes, not color"
}

test_stripped_tunnel_table_is_byte_identical_to_the_pre_color_rendering() {
    load_fold_tunnel
    local colored plain
    colored="$(show_tunnels_table 2>/dev/null | strip_all)"
    plain="$( ( PINK=""; WHITE=""; GRAY=""; BOLD=""; RESET=""; show_tunnels_table 2>/dev/null ) | strip_all )"
    assert_eq "$plain" "$colored" \
        "colors add zero visible bytes: fit_cell/TUI_MAX math never saw an escape"
    assert_contains "$colored" ":: = " "the legend line is part of the compared frame"
}

test_stripped_nodes_table_is_byte_identical_to_the_pre_color_rendering() {
    load_luks_nodes
    local colored plain
    colored="$(show_nodes_table 2>/dev/null | strip_all)"
    plain="$( ( PINK=""; WHITE=""; GRAY=""; BOLD=""; RESET=""; show_nodes_table 2>/dev/null ) | strip_all )"
    assert_eq "$plain" "$colored" "the rung-1 compacted nodes table included"
    assert_contains "$colored" "luks" "the suffix rode along, uncolored geometry intact"
}
