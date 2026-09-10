#!/usr/bin/env bash
# v11: PRETTY - the guest-facing display name - and the TUI field toggles + width budget.
#
# Three features carry this file. (1) pretty is every record's LAST field (nodes nine
# fields, services seven): the add flows ask for it optionally, the modify submenus edit it
# under the label "nickname", and it rides the same pending-preview model as every other
# field. (2) "fields on tables": the OPTIONAL columns of each table are toggles persisted
# in a PLAIN dotfile outside the encrypted dir, defaulting to exactly the v10 column set -
# pretty hidden. (3) the width budget: no rendered table row may exceed TUI_MAX (the
# measured v10 tunnel row + 5 = 66), enforced by a loss-ordered compaction pipeline -
# status abbreviation, then pretty truncation, then name truncation, then address
# folding/truncation - each rung only as far as needed, in that order.

PF_N='02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,Series & Movies,0,1,1,The Cinema Box
02:00:00:00:00:12,192.168.77.12,immich-provider,maddev,Photos,0,1,2,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,DNS,0,0,3,'

PF_S='jellyfin,192.168.77.13,8096,streams,1,1,Movie Night
jellyseerr,192.168.77.13,5055,requests,0,2,
gitea,git.test,3000,forge,1,4,'

USR_FILE_REL='.allumeur-scripts/encrypted/usr_blob.enc'
SRV_FILE_REL='.allumeur-scripts/encrypted/srv_blob.enc'
LONG_PRETTY='A Very Long Pretty Name For Testing Truncation'

setup() {
    stub clear
    stub ssh-keygen
    stub tailscale
    stub curl 7
    stub jq 1
    stub ping 0
    printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/sleep"; chmod +x "$STUB_DIR/sleep"
    cat > "$STUB_DIR/tput" <<'EOF'
#!/usr/bin/env bash
[ "$1" = cols ] && { echo 40; exit 0; }
exit 0
EOF
    chmod +x "$STUB_DIR/tput"
}

# The two-fixture rw openssl stub the modify/order files carry, verbatim.
set_blob_rw() {
    export FIXTURE_BLOB="$1" FIXTURE_SRV="${2:-}"
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
    case "\$out" in
        *srv_blob*) cp -f "\$out" "$SANDBOX/written_srv" ;;
        *usr_blob*) cp -f "\$out" "$SANDBOX/written_usr" ;;
    esac
elif [ -n "\$inf" ] && [ -s "\$inf" ]; then
    cat "\$inf"
else
    case "\$inf" in
        *srv_blob*) printf '%s\n' "\$FIXTURE_SRV" ;;
        *)          printf '%s\n' "\$FIXTURE_BLOB" ;;
    esac
fi
EOF
    chmod +x "$STUB_DIR/openssl"
}
written_srv()  { cat "$SANDBOX/written_srv" 2>/dev/null; }
written_usr()  { cat "$SANDBOX/written_usr" 2>/dev/null; }

load_nodes() { set_blob_rw "${1:-$PF_N}" "${2:-$PF_S}"; source "$SRC_DIR/nodes.sh"; }
load_tunnel() {
    set_blob_rw "${2:-$PF_N}" "${1:-$PF_S}"
    printf '%s\n' "${1:-$PF_S}" > "$HOME/.allumeur-scripts/encrypted/srv_blob.enc"
    source "$SRC_DIR/tunnel.sh"
    RUNDIR="$SANDBOX/tunnels"; mkdir -p "$RUNDIR"
}

menu_returns() {
    MENU_Q=("$@"); MENU_I=0
    interactive_menu() {
        local r=${MENU_Q[$MENU_I]:-0}
        MENU_I=$((MENU_I + 1))
        return "$r"
    }
}
out() { sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' "$SANDBOX/out" 2>/dev/null; }
strip() { sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g'; }

# Character length under a UTF-8 locale - ★, ▪ and … are one cell each.
clen() { local LC_ALL=C.UTF-8 s="$1"; printf '%s\n' "${#s}"; }

# The longest CHARACTER length of any line on stdin (colors already stripped by caller).
max_line_len() {
    local LC_ALL=C.UTF-8 l m=0
    while IFS= read -r l; do [ "${#l}" -gt "$m" ] && m=${#l}; done
    printf '%s\n' "$m"
}

# ── pretty in the add flows ─────────────────────────────────────────────────
test_add_node_asks_an_optional_pretty_and_stores_it_last() {
    load_nodes
    stub sshpass 0
    # ip mac name user pass subtitle, a comma'd pretty (refused), the clean retype,
    # shelf position default (end); EOF keeps the luks and favourite menus' defaults.
    printf '192.168.77.16\n02:00:00:00:00:16\nnew-node\nmaddev\nhunter2\nfresh\nGlow,Box\nGlow Box\n\n' \
        | add_node > "$SANDBOX/out" 2>&1

    assert_contains "$(out)" "pretty name (guest-facing, enter = none)" "the add asks for it"
    assert_contains "$(out)" "a comma splits the record" "a comma'd pretty is refused like any field"
    local u; u="$(written_usr)"
    assert_contains "$u" "02:00:00:00:00:16,192.168.77.16,new-node,maddev,fresh,0,1,5,Glow Box" \
        "the pretty is the record's LAST field, behind the shelf order"
    assert_eq "0" "$(printf '%s\n' "$u" | awk -F, 'NF != 9' | grep -c .)" \
        "every node record has exactly nine fields"
    assert_not_contains "$u" "Glow,Box"
}

test_add_node_empty_pretty_stores_an_empty_ninth_field() {
    load_nodes
    stub sshpass 0
    # Enter at the pretty ask = no alias; the field still exists, empty, at the tail.
    printf '192.168.77.16\n02:00:00:00:00:16\nnew-node\nmaddev\nhunter2\nfresh\n\n\n' \
        | add_node > "$SANDBOX/out" 2>&1
    assert_contains "$(written_usr)" "02:00:00:00:00:16,192.168.77.16,new-node,maddev,fresh,0,1,5," \
        "an empty pretty is a field, not a missing one"
    assert_eq "0" "$(written_usr | awk -F, 'NF != 9' | grep -c .)"
}

test_add_endpoint_asks_an_optional_pretty_and_stores_it_last() {
    load_tunnel
    # name ip port subtitle, comma'd pretty (refused), retype, group position 1.
    printf 'jellystat\n192.168.77.13\n3999\nstats\nStat,Attack\nStat Attack\n1\n' \
        | add_endpoint > "$SANDBOX/out" 2>&1

    assert_contains "$(out)" "pretty name (guest-facing, enter = none)"
    assert_contains "$(out)" "a comma splits the record"
    local sv; sv="$(written_srv)"
    assert_contains "$sv" "jellystat,192.168.77.13,3999,stats,1,1,Stat Attack" \
        "the pretty is the record's LAST field, behind the intra order"
    assert_eq "0" "$(printf '%s\n' "$sv" | awk -F, 'NF != 7' | grep -c .)" \
        "every service record has exactly seven fields"
}

# ── nickname in the modify submenus, on the pending model ───────────────────
test_modify_node_nickname_saves_and_an_empty_answer_clears_it() {
    load_nodes
    menu_returns 0 3 5                     # jelly-streamer; nickname; save
    printf 'The Movie Palace\n' | modify_node > "$SANDBOX/out" 2>&1
    assert_contains "$(written_usr)" "jelly-streamer,maddev,Series & Movies,0,1,1,The Movie Palace" \
        "the nickname edit landed in the ninth field and nothing else moved"
    # The pretty column is OFF by default, so the preview row does not print the alias -
    # that is the toggle honoured, not an omission; the preview-follows-toggles test shows
    # the same edit surfacing once the column is on.
    assert_not_contains "$(out)" "The Movie Palace  " "no ad-hoc pretty column appeared"

    # Second pass reads the blob the first one wrote: enter clears the alias.
    menu_returns 0 3 5
    printf '\n' | modify_node > "$SANDBOX/out" 2>&1
    assert_eq "" "$(written_usr | awk -F, '$3 == "jelly-streamer" {print $9}')" \
        "an empty answer clears the nickname - the only way to drop an alias"
    assert_eq "0" "$(written_usr | awk -F, 'NF != 9' | grep -c .)" "still nine fields"
}

test_modify_node_nickname_cancel_discards_the_pending_edit() {
    load_nodes
    : > "$STUB_LOG"
    menu_returns 0 3 6                     # jelly-streamer; nickname; CANCEL
    printf 'Never Saved\n' | modify_node > "$SANDBOX/out" 2>&1
    assert_eq "" "$(stub_calls openssl | grep -- '-out')" "cancel wrote nothing at all"
    assert_contains "$(out)" "nickname (guest-facing, enter = none)" \
        "the edit was really taken before being discarded"
}

test_modify_endpoint_nickname_saves_through_the_pending_model() {
    load_tunnel
    menu_returns 1 4 6                     # jellyseerr; nickname; save
    printf 'Ask,Machine\nAsk Machine\n' | modify_endpoint > "$SANDBOX/out" 2>&1
    assert_contains "$(written_srv)" "jellyseerr,192.168.77.13,5055,requests,0,2,Ask Machine" \
        "the nickname landed last; the comma'd first answer was refused"
    assert_contains "$(out)" "a comma splits the record"
    assert_contains "$(written_srv)" "jellyfin,192.168.77.13,8096,streams,1,1,Movie Night" \
        "the neighbour's pretty went back byte-identical"
}

test_the_modify_submenus_keep_distinct_hotkeys_with_nickname_added() {
    load_nodes
    : > "$STUB_LOG"
    # The REAL interactive_menu: 'j' picks jelly-streamer, 'n' jumps to nickname, the ask
    # reads a name, 's' saves. "pretty" as a label would collide with "port" in the tunnel
    # submenu - "nickname" is the label precisely so n stays a bare, distinct key.
    printf 'jnShine\ns' | modify_node > "$SANDBOX/out" 2>&1
    assert_contains "$(written_usr)" "jelly-streamer,maddev,Series & Movies,0,1,1,Shine" \
        "'n' then 's' really were nickname and save"
    assert_eq "0" "$(out | grep -cE '\[[0-9]\] (address|description|favourite|nickname|order|save|cancel)')" \
        "no node submenu label was digit-relabelled: a d f n o s c"

    load_tunnel
    : > "$STUB_LOG"
    printf 'gnForge Face\ns' | modify_endpoint > "$SANDBOX/out" 2>&1
    assert_contains "$(written_srv)" "gitea,git.test,3000,forge,1,4,Forge Face" \
        "'n' then 's' in the endpoint submenu too"
    assert_eq "0" "$(out | grep -cE '\[[0-9]\] (address|port|description|favourite|nickname|order|save|cancel)')" \
        "no endpoint submenu label was digit-relabelled: a p d f n o s c"
}

# ── the field toggles: defaults, persistence, junk tolerance ────────────────
test_field_toggles_default_to_the_v10_column_set_when_the_file_is_absent() {
    source "$SRC_DIR/lib.sh"
    assert_no_file "$HOME/.allumeur-scripts/.tui-fields" "a fresh HOME has no prefs file"
    tui_fields_load
    assert_eq "1 1 1 1 0" "$TF_NODES_IP $TF_NODES_USER $TF_NODES_ORD $TF_NODES_FAV $TF_NODES_PRETTY" \
        "nodes: everything v10 on, pretty hidden"
    assert_eq "1 1 1 0" "$TF_SRV_TARGET $TF_SRV_ORD $TF_SRV_FAV $TF_SRV_PRETTY" \
        "tunnel: everything v10 on, pretty hidden"
}

test_a_junk_prefs_file_falls_back_to_the_defaults_it_cannot_parse() {
    source "$SRC_DIR/lib.sh"
    mkdir -p "$HOME/.allumeur-scripts"
    printf 'nodes.ip=banana\nutter garbage\nsrv.pretty=1\nnodes.user=0\n' \
        > "$HOME/.allumeur-scripts/.tui-fields"
    tui_fields_load
    assert_eq "1" "$TF_NODES_IP" "a junk value is ignored, the default stands"
    assert_eq "0" "$TF_NODES_USER" "a clean line beside it still lands"
    assert_eq "1" "$TF_SRV_PRETTY"
    assert_eq "1" "$TF_SRV_TARGET" "unmentioned keys keep their defaults"
}

test_the_fields_menus_toggle_and_persist_in_a_plain_dotfile_outside_the_encrypted_dir() {
    load_nodes
    : > "$STUB_LOG"
    # The REAL interactive_menu: 'p' toggles pretty, then EOF answers the redrawn menu as
    # enter on "back" - which is why back leads the list.
    printf 'p' | nodes_fields_menu > "$SANDBOX/out" 2>&1
    local f="$HOME/.allumeur-scripts/.tui-fields"
    assert_file "$f" "the preference persisted"
    assert_file_contains "$f" "nodes.pretty=1"
    assert_eq "" "$(stub_calls openssl)" "a preference is plain: no crypto ran at all"
    tui_fields_load
    assert_eq "1" "$TF_NODES_PRETTY" "and the loader reads it back"
    assert_eq "0" "$(out | grep -cE '\[[0-9]\] (back|ip|user|order|favourite|pretty)')" \
        "no toggle label was digit-relabelled: b i u o f p"

    load_tunnel
    printf 'p' | srv_fields_menu > "$SANDBOX/out" 2>&1
    assert_file_contains "$f" "srv.pretty=1" "the tunnel menu writes the same file"
    assert_file_contains "$f" "nodes.pretty=1" "without clobbering the nodes half"
    assert_eq "0" "$(out | grep -cE '\[[0-9]\] (back|target|order|favourite|pretty)')" \
        "no tunnel toggle label was digit-relabelled: b t o f p"

    # Toggle back off through the same menu: the file follows.
    printf 'p' | srv_fields_menu > /dev/null 2>&1
    tui_fields_load
    assert_eq "0" "$TF_SRV_PRETTY"
}

test_the_fields_menu_backs_out_on_eof_without_writing() {
    load_nodes
    nodes_fields_menu < /dev/null > /dev/null 2>&1
    assert_no_file "$HOME/.allumeur-scripts/.tui-fields" \
        "EOF is back, not a toggle: nothing was written"
}

test_the_main_menus_offer_fields_on_tables_on_a_distinct_hotkey() {
    load_nodes
    assert_contains "$(declare -f main)" '"fields on tables"' "the nodes menu offers it"
    assert_contains "$(declare -f main)" "nodes_fields_menu" "and wires it"
    local nopts=("ssh to node" "hit lights" "keys" "add node" "modify node" "remove node" "list nodes" "fields on tables" "update view" "exit")
    local rc render
    rc=$(printf 'f' | ( source "$SRC_DIR/lib.sh"; interactive_menu "${nopts[@]}" >/dev/null 2>&1; echo $? ))
    assert_eq "7" "$rc" "'f' jumps straight to it"
    render=$(printf '\n' | ( source "$SRC_DIR/lib.sh"; interactive_menu "${nopts[@]}" 2>/dev/null ) | head -n ${#nopts[@]})
    assert_not_contains "$render" "[1]" "no digit relabel: s h k a m r l f u e are all distinct"

    load_tunnel
    assert_contains "$(declare -f main)" "srv_fields_menu" "the tunnel menu wires it too"
    local topts=("new temporal tunnel" "add tunnel endpoint" "modify tunnel endpoint" "remove tunnel endpoint" "kill all tunnels" "fields on tables" "update view" "exit")
    rc=$(printf 'f' | ( source "$SRC_DIR/lib.sh"; interactive_menu "${topts[@]}" >/dev/null 2>&1; echo $? ))
    assert_eq "5" "$rc"
    render=$(printf '\n' | ( source "$SRC_DIR/lib.sh"; interactive_menu "${topts[@]}" 2>/dev/null ) | head -n ${#topts[@]})
    assert_not_contains "$render" "[1]" "n a m r k f u e are all distinct"
}

# ── the renderers honour the toggles; the previews follow ───────────────────
test_the_default_tables_render_the_v10_format_untouched() {
    # DEFAULT = exactly the v10 column set, at the v10 widths, statuses unabbreviated.
    load_nodes
    local hdr; hdr="$(nodes_table_header | strip | head -n 1)"
    assert_eq "  #  NAME            IP              USER         STATUS" "$hdr" \
        "the default nodes header is byte-identical to v10 - pretty hidden"
    local t; t="$(show_nodes_table 2>/dev/null | strip)"
    assert_contains "$t" "[ up ]" "statuses stay long: the default row fits the budget"
    assert_not_contains "$t" "The Cinema Box" "the pretty column is hidden by default"

    load_tunnel
    hdr="$(srv_table_header | strip | head -n 1)"
    assert_eq "  #  i  SERVICE NAME       TARGET                STATUS" "$hdr" \
        "the default tunnel header is byte-identical to v10"
    t="$(show_tunnels_table 2>/dev/null | strip)"
    assert_contains "$t" "[ inactive ]" "full statuses"
    assert_not_contains "$t" "Movie Night" "pretty hidden by default"
    assert_not_contains "$t" "…" "and nothing was truncated"
}

test_the_nodes_table_honours_the_toggles() {
    load_nodes
    tui_fields_load
    TF_NODES_IP=0 TF_NODES_USER=0 TF_NODES_PRETTY=1
    tui_fields_save
    local t; t="$(show_nodes_table 2>/dev/null | strip)"
    assert_contains "$t" "PRETTY" "the pretty column came on"
    assert_contains "$t" "The Cinema Box" "and shows the alias"
    assert_not_contains "$t" "192.168.77.13" "the ip column went off"
    assert_not_contains "$t" "USER" "the user column went off"
    assert_not_contains "$t" "maddev" "data and header both"
    assert_contains "$t" "[ up ]" "narrow enough that nothing had to compact"
    assert_le "$(printf '%s\n' "$t" | max_line_len)" "$TUI_MAX" "and the budget holds"
}

test_the_tunnel_table_honours_the_toggles() {
    load_tunnel
    tui_fields_load
    TF_SRV_TARGET=0 TF_SRV_ORD=0 TF_SRV_FAV=0 TF_SRV_PRETTY=1
    tui_fields_save
    local t; t="$(show_tunnels_table 2>/dev/null | strip)"
    assert_contains "$t" "Movie Night" "pretty on"
    assert_not_contains "$t" "192.168.77.13:8096" "target off"
    assert_not_contains "$t" "★" "favourite marker off"
    assert_not_contains "$t" "  #  i" "order numbers off"
    assert_le "$(printf '%s\n' "$t" | max_line_len)" "$TUI_MAX"
}

test_the_pending_previews_follow_the_toggles_and_the_pipeline() {
    load_nodes
    tui_fields_load; TF_NODES_PRETTY=1; tui_fields_save
    # Default columns + pretty pushes the row over budget: the preview must apply rung 1
    # itself - [ pending ] abbreviates to [ ? ] - because it runs the same layout.
    local pv; pv="$(show_pending_node jelly-streamer 192.168.77.13 maddev 1 1 Sparkles | strip)"
    assert_contains "$pv" "PRETTY" "the preview grew the toggled column"
    assert_contains "$pv" "Sparkles" "and shows the pending nickname"
    assert_contains "$pv" "[ ? ]" "rung 1 reached the preview: pending abbreviates too"
    assert_le "$(printf '%s\n' "$pv" | max_line_len)" "$TUI_MAX"

    load_tunnel
    tui_fields_load; TF_SRV_PRETTY=1; tui_fields_save
    pv="$(show_pending_endpoint jellystat 192.168.77.13 3999 1 3 1 "$LONG_PRETTY" | strip)"
    assert_contains "$pv" "…" "an overlong pending pretty ellipsizes exactly as the table would"
    assert_not_contains "$pv" "$LONG_PRETTY" "never printed whole"
    assert_contains "$pv" "[ ? ]"
    assert_le "$(printf '%s\n' "$pv" | max_line_len)" "$TUI_MAX"
}

# ── the width budget and the loss-ordered pipeline ──────────────────────────
test_the_budget_is_the_measured_v10_tunnel_row_plus_five() {
    load_tunnel
    # The measurement, taken off the real renderer: the widest fixed v10 row - marker,
    # both numbers, an 18 name, a 21 target, "[ inactive ]" - is 61 cells. TUI_MAX = 61+5.
    srv_layout ''
    local row; row="$(srv_table_row 1 1 - jellyfin 192.168.77.13:8096 '' '[ inactive ]' | strip)"
    assert_eq "61" "$(clen "$row")" "the measured v10 row"
    assert_eq "66" "$TUI_MAX" "and the budget is that plus five"
}

test_rung1_status_abbreviation_is_applied_alone_when_it_is_enough() {
    load_tunnel
    tui_fields_load; TF_SRV_ORD=0 TF_SRV_PRETTY=1; tui_fields_save
    # fav(2)+name(19)+target(22)+pretty("Movie Night"=11+1)+status(14) = 69 > 66; dropping
    # the status to its 6-cell form lands on 61. Rung 2 must NOT run: the pretty stays whole.
    local t; t="$(show_tunnels_table 2>/dev/null | strip)"
    assert_not_contains "$t" "[ inactive ]" "the long statuses are gone"
    assert_contains "$t" "[   ]" "replaced by the abbreviated form"
    assert_contains "$t" "Movie Night" "the pretty was NOT truncated"
    assert_not_contains "$t" "…" "rung 2 never ran: rung 1 already fit the table"
    assert_le "$(printf '%s\n' "$t" | max_line_len)" "$TUI_MAX"
}

test_rung2_truncates_pretty_to_tab_stops_only_after_rung1() {
    load_tunnel "jellyfin,192.168.77.13,8096,streams,1,1,Movie Night
radarr,192.168.77.13,7878,movies,0,2,$LONG_PRETTY
gitea,git.test,3000,forge,1,4,"
    tui_fields_load; TF_SRV_PRETTY=1; tui_fields_save
    # The 46-char pretty blows the budget; statuses abbreviate first, then the pretty
    # column walks down the tab stops (46 -> 40 -> ... -> 8) until the row fits at 8.
    local t; t="$(show_tunnels_table 2>/dev/null | strip)"
    assert_not_contains "$t" "[ inactive ]" "rung 1 ran first"
    assert_contains "$t" "…" "rung 2 then ellipsized the overlong pretty"
    assert_not_contains "$t" "$LONG_PRETTY" "which is never printed whole"
    assert_contains "$t" "radarr" "the name column was NOT touched: rung 3 never ran"
    assert_not_contains "$t" "~" "no name or target truncation anywhere"
    assert_le "$(printf '%s\n' "$t" | max_line_len)" "$TUI_MAX"
}

test_rung3_truncates_the_name_only_when_pretty_cannot_give_more() {
    # Pretty is OFF here, so rung 2 has nothing to shrink: a 28-char node name must ride
    # through rung 1 (statuses) into rung 3 (name to the previous tab stop, ~-marked).
    load_nodes '02:00:00:00:00:12,192.168.77.12,observability-dashboard-node,maddev,graphs,0,1,1,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,DNS,0,0,2,' ''
    local t; t="$(show_nodes_table 2>/dev/null | strip)"
    assert_contains "$t" "[ ▪ ]" "rung 1: the nodes statuses abbreviate to the documented forms"
    assert_not_contains "$t" "[ up ]"
    assert_contains "$t" "observability-dashboard~" \
        "rung 3: the name column shrank to the previous tab stop, fit_cell's ~ marking the cut"
    assert_not_contains "$t" "observability-dashboard-node" "never printed whole"
    assert_le "$(printf '%s\n' "$t" | max_line_len)" "$TUI_MAX"
}

test_rung4_folds_a_shared_dotted_prefix_and_prints_the_legend() {
    # Two services on one long LAN name: after statuses (rung 1) and names (rung 3) have
    # given all they can, the shared prefix folds to :: with a legend line under the table.
    load_tunnel 'alpha,edge.rack-one.dmz.homelab-example.test,8001,one,1,1,
beta,edge.rack-one.dmz.homelab-example.test,8002,two,0,2,' ''
    local t; t="$(show_tunnels_table 2>/dev/null | strip)"
    assert_contains "$t" "::test:8001" "the shared prefix folded on an octet/label boundary"
    assert_contains "$t" "::test:8002"
    assert_contains "$t" ":: = edge.rack-one.dmz.homelab-example" \
        "and the legend under the table says what :: stands for"
    assert_eq "0" "$(printf '%s\n' "$t" | grep -v ':: =' | grep -c 'homelab-example')" \
        "no table row still carries the unfolded address"
    assert_le "$(printf '%s\n' "$t" | max_line_len)" "$TUI_MAX"
}

test_rung4_falls_back_to_target_truncation_when_nothing_is_shared() {
    # Same widths, but the two hosts share no leading prefix: nothing folds, no legend -
    # the target column takes the tab-stop truncation the table always had.
    load_tunnel 'gamma,graf.observability.internal.longhouse.example,3000,dash,1,1,
delta,prom.metrics.other-house.instruments.example,9090,scrape,0,2,' ''
    local t; t="$(show_tunnels_table 2>/dev/null | strip)"
    assert_not_contains "$t" ":: =" "no legend: there was nothing to fold"
    assert_contains "$t" "~" "the overlong targets truncated instead"
    assert_not_contains "$t" "graf.observability.internal.longhouse.example:3000" \
        "never printed whole"
    assert_le "$(printf '%s\n' "$t" | max_line_len)" "$TUI_MAX"
}

test_the_luks_suffix_survives_abbreviation_and_counts_against_the_budget() {
    # " luks" rides the STATUS cell, so a fleet holding a flagged node budgets 5 more
    # cells - the default column set then abbreviates, and the suffix still prints.
    load_nodes '02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,firewall,0,1,1,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,DNS,1,0,2,' ''
    local t; t="$(show_nodes_table 2>/dev/null | strip)"
    assert_not_contains "$t" "[ up ]" "the row with the suffix would overflow: rung 1 ran"
    assert_contains "$t" "[ ▪ ]" "abbreviated"
    assert_contains "$(printf '%s\n' "$t" | grep pi-blocker)" "luks" \
        "and the flag's one TUI witness survived the compaction"
    assert_le "$(printf '%s\n' "$t" | max_line_len)" "$TUI_MAX"
}

test_global_max_is_never_exceeded_across_stress_rows() {
    # Long pretty + long names + wide shared targets, every column toggled on: whatever
    # the pipeline had to do, no rendered line may pass the budget.
    load_tunnel "verylongservicename-of-doom,edge.rack-one.dmz.homelab-example.test,8001,sub,1,1,$LONG_PRETTY
second-verylongservicename,edge.rack-one.dmz.homelab-example.test,8002,sub,0,2,Another Quite Long Alias Here" ''
    tui_fields_load; TF_SRV_PRETTY=1; tui_fields_save
    local t; t="$(show_tunnels_table 2>/dev/null | strip)"
    assert_le "$(printf '%s\n' "$t" | max_line_len)" "$TUI_MAX" \
        "tunnel: header, rule, rows and legend all inside TUI_MAX"

    tui_fields_load; TF_NODES_PRETTY=1; tui_fields_save
    load_nodes "02:00:00:00:00:12,192.168.77.12,observability-dashboard-node,maddev,graphs,1,1,1,$LONG_PRETTY
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,DNS,0,0,2,Short" ''
    t="$(show_nodes_table 2>/dev/null | strip)"
    assert_le "$(printf '%s\n' "$t" | max_line_len)" "$TUI_MAX" \
        "nodes: the luks row included"
}

test_node_statuses_abbreviate_to_the_documented_forms() {
    load_nodes
    stub_out curl '[]'
    stub_out jq "$(printf '192.168.77.13\tup\n192.168.77.12\tconfirming_up\n192.168.77.11\tconfirming_down')"
    tui_fields_load; TF_NODES_PRETTY=1; tui_fields_save   # pushes the row over: rung 1 fires
    local t; t="$(show_nodes_table 2>/dev/null | strip)"
    assert_contains "$(printf '%s\n' "$t" | grep 'jelly-streamer')"  "[ ▪ ]"  "up -> a filled square (not the star)"
    assert_contains "$(printf '%s\n' "$t" | grep 'immich-provider')" "[ ~▪ ]" "confirming up -> ~ then the square"
    assert_contains "$(printf '%s\n' "$t" | grep 'pi-blocker')"      "[ ~ ]"  "confirming down -> the ~ alone"
    assert_not_contains "$t" "[ up ]" "no long form remains"
    assert_le "$(printf '%s\n' "$t" | max_line_len)" "$TUI_MAX"
}

# ── the helpers and keys keep loading the nine/seven-field records ──────────
test_the_subtitle_helpers_preserve_a_populated_pretty() {
    load_tunnel
    local src
    src="$(awk '/^update_service_subtitles\(\) \{/,/^\}/' "$SRC_DIR/subtitle-helper.sh" | sed 's#</dev/tty#<\&0#')"
    assert_ok test -n "$src"
    eval "$src"
    printf '\n\n\n' | update_service_subtitles > "$SANDBOX/out" 2>&1
    assert_contains "$(written_srv)" "jellyfin,192.168.77.13,8096,streams,1,1,Movie Night" \
        "enter-to-keep carries the pretty through the whole-blob rewrite"
    assert_contains "$(written_srv)" "jellyseerr,192.168.77.13,5055,requests,0,2," \
        "an empty pretty stays an (empty) field"
}
