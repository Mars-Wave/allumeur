#!/usr/bin/env bash
# THE SHELF - the v10 ordering across both databases.
#
# Every record's last field is its order. Nodes and STANDALONE services share ONE global
# sequence ("the shelf", a permutation 1..K spanning both blobs); a service whose address
# exactly string-equals a node's ip is grouped under that node and ordered 1..k inside the
# group. The properties that carry the feature: an asked-for position is clamped to
# [1..current+1]; inserting at p shifts everything at or past p up one; removals close the
# gap they leave; and after EVERY operation each scope is a clean permutation again - the
# shelf renumber spans both blobs, each written atomically. The TUI tables render this
# ordering, the modify flows edit it through the same pending-preview model as every other
# field, and the add flows ask for it with the end as the default.
#
# The fixture mirrors the mock preview's spread: a multi-service group (jelly-streamer),
# a single-service group (pi-blocker), nodes with no services, and standalone services on
# the shelf at 6 and 7, with favourites and intra orders mixed.

ORD_N='02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,firewall,0,1,1,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,dns,1,0,2,
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,media,0,1,3,
02:00:00:00:00:14,192.168.77.14,immich-provider,maddev,photos,0,0,4,
02:00:00:00:00:15,192.168.77.15,vault-warden,maddev,secrets,0,1,5,'

ORD_S='jellyfin,192.168.77.13,8096,streams,1,1,
jellyseerr,192.168.77.13,5055,requests,0,2,
adguard,192.168.77.11,3000,dns admin,1,1,
gitea,git.test,3000,forge,1,6,
uptime,status.test,3001,monitor,0,7,'

USR_FILE_REL='.allumeur-scripts/encrypted/usr_blob.enc'
SRV_FILE_REL='.allumeur-scripts/encrypted/srv_blob.enc'

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

# The two-fixture rw stub test_modify.sh carries, verbatim: encrypt honors -out for real
# (so encrypt_atomic's rename lands), decrypt serves the written file once one exists and
# the per-blob fixture until then.
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

# set_blob_rw_failing <substr> [nfixture] [sfixture] - the same stub with one difference:
# every encrypt whose -out path contains <substr> FAILS without writing a byte, so
# encrypt_atomic's `&& mv` never runs and it returns 1. That is how a flow's FIRST blob
# write is made to fail without touching the code under test - the hazard being that the
# SECOND write lands anyway and leaves the shelf a broken permutation across the two blobs.
set_blob_rw_failing() {
    local fail="$1"
    export FIXTURE_BLOB="${2:-$ORD_N}" FIXTURE_SRV="${3:-$ORD_S}"
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
    case "\$out" in *$fail*) cat > /dev/null; exit 1 ;; esac
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

written_blob() { cat "$SANDBOX/written_blob" 2>/dev/null; }
written_srv()  { cat "$SANDBOX/written_srv" 2>/dev/null; }
written_usr()  { cat "$SANDBOX/written_usr" 2>/dev/null; }

load_nodes() { set_blob_rw "${1:-$ORD_N}" "${2:-$ORD_S}"; source "$SRC_DIR/nodes.sh"; }
load_tunnel() {
    set_blob_rw "${2:-$ORD_N}" "${1:-$ORD_S}"
    printf '%s\n' "${1:-$ORD_S}" > "$HOME/.allumeur-scripts/encrypted/srv_blob.enc"
    source "$SRC_DIR/tunnel.sh"
    RUNDIR="$SANDBOX/tunnels"; mkdir -p "$RUNDIR"
}

# The same two loaders over the failing stub. <substr> names the blob whose write dies.
load_nodes_failing() {
    set_blob_rw_failing "$1" "${2:-$ORD_N}" "${3:-$ORD_S}"; source "$SRC_DIR/nodes.sh"
}
load_tunnel_failing() {
    set_blob_rw_failing "$1" "${3:-$ORD_N}" "${2:-$ORD_S}"
    printf '%s\n' "${2:-$ORD_S}" > "$HOME/.allumeur-scripts/encrypted/srv_blob.enc"
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

# assert_perm <ndata> <sdata> <msg> - every ordering scope is a clean permutation again:
# the shelf (node orders + standalone service orders, across both blobs) is exactly 1..K,
# and each group's intra orders are exactly 1..k.
assert_perm() {
    local ndata="$1" sdata="$2" msg="${3:-order invariant}"
    local shelf="" line ip
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        shelf+="$(rec_ord "$line")"$'\n'
    done <<< "$ndata"
    local gips=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        IFS=',' read -r _ ip _ <<< "$line"
        if ord_is_node_ip "$ip" "$ndata"; then
            case $'\n'"$gips" in *$'\n'"$ip"$'\n'*) ;; *) gips+="$ip"$'\n' ;; esac
        else
            shelf+="$(rec_ord "$line")"$'\n'
        fi
    done <<< "$sdata"
    local n got want
    n=$(printf '%s' "$shelf" | grep -c .)
    got=$(printf '%s' "$shelf" | sort -n | tr '\n' ' ')
    want=$(seq 1 "$n" 2>/dev/null | tr '\n' ' ')
    assert_eq "$want" "$got" "$msg: the shelf is a permutation of 1..$n"
    local gip orders k
    while IFS= read -r gip; do
        [ -z "$gip" ] && continue
        orders=$(printf '%s\n' "$sdata" | awk -F, '$2 == "'"$gip"'" {print $(NF-1)}')
        k=$(printf '%s\n' "$orders" | grep -c .)
        assert_eq "$(seq 1 "$k" | tr '\n' ' ')" "$(printf '%s\n' "$orders" | sort -n | tr '\n' ' ')" \
            "$msg: group $gip is a permutation of 1..$k"
    done <<< "$gips"
}

# ── clamping ────────────────────────────────────────────────────────────────
test_clamp_order_clamps_zero_huge_negative_and_junk() {
    source "$SRC_DIR/lib.sh"
    assert_eq "1" "$(clamp_order 0 5)"        "zero clamps to the front"
    assert_eq "5" "$(clamp_order 999 5)"      "a huge ask clamps to the given end"
    assert_eq "5" "$(clamp_order 12345678901234567890 5)" "even one past every integer"
    assert_eq "1" "$(clamp_order -3 5)"       "a negative clamps to the front"
    assert_eq "3" "$(clamp_order 3 5)"        "a valid position passes through"
    assert_eq "5" "$(clamp_order '' 5)"       "an empty ask is the end"
    assert_eq "5" "$(clamp_order 'abc' 5)"    "junk is the end, never an error"
    assert_eq "1" "$(clamp_order 3 0)"        "a scope of nothing still answers 1"
}

# ── modify node: the shelf move spans both blobs ────────────────────────────
test_moving_a_node_on_the_shelf_renumbers_standalone_services_too() {
    load_nodes
    : > "$STUB_LOG"
    menu_returns 0 4 5                     # pfsense-wall; order; save
    printf '7\n' | modify_node > "$SANDBOX/out" 2>&1

    assert_eq '02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,firewall,0,1,7,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,dns,1,0,1,
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,media,0,1,2,
02:00:00:00:00:14,192.168.77.14,immich-provider,maddev,photos,0,0,3,
02:00:00:00:00:15,192.168.77.15,vault-warden,maddev,secrets,0,1,4,' \
        "$(written_usr)" \
        "the node landed at the end and every node past its old slot closed the gap"
    assert_eq 'jellyfin,192.168.77.13,8096,streams,1,1,
jellyseerr,192.168.77.13,5055,requests,0,2,
adguard,192.168.77.11,3000,dns admin,1,1,
gitea,git.test,3000,forge,1,5,
uptime,status.test,3001,monitor,0,6,' \
        "$(written_srv)" \
        "the standalone services moved down the SAME shelf; the grouped ones never moved"
    assert_perm "$(written_usr)" "$(written_srv)" "after the move"
    assert_eq "" "$(stub_calls openssl | grep -- '-out' | grep -v '.tmp')" \
        "both blobs were staged-and-renamed, neither through the bare truncating encrypt"
}

test_the_order_ask_clamps_a_huge_answer_before_the_preview_shows_it() {
    load_nodes
    menu_returns 0 4 5                     # pfsense-wall; order; save
    printf '99\n' | modify_node > "$SANDBOX/out" 2>&1

    assert_contains "$(written_usr)" "pfsense-wall,root,firewall,0,1,7" \
        "99 was clamped to the shelf's real end"
    # The preview is the live table row, so the position shows in the '#' column between the
    # marker and the name - not trailing the line, which now ends with STATUS.
    assert_le 1 "$(out | grep -cE '^[★ ] +7 +pfsense-wall')" \
        "the pending preview showed the clamped position, not the raw answer"
}

test_a_pending_order_edit_is_shown_live_and_cancel_discards_it() {
    load_nodes
    local blob="$HOME/$USR_FILE_REL"
    : > "$STUB_LOG"
    menu_returns 0 4 6                     # pfsense-wall; order; CANCEL
    printf '4\n' | modify_node > "$SANDBOX/out" 2>&1

    assert_le 1 "$(out | grep -cE '^[★ ] +4 +pfsense-wall')" \
        "the pending row showed the asked-for position live, in the table's own '#' column"
    assert_contains "$(out)" "pending - nothing is written until save" \
        "under the same pending banner as every other edit"
    assert_eq "" "$(stub_calls openssl | grep -- '-out')" \
        "cancel discarded the order edit: no encrypt of any kind ran"
    assert_no_file "$blob.tmp" "and nothing was even staged"
}

# ── adds ask a position, defaulting to the end ──────────────────────────────
test_add_node_asks_the_shelf_position_and_the_insert_shifts_everything_past_it() {
    load_nodes
    stub sshpass 0
    : > "$STUB_LOG"
    # ip mac name user pass subtitle, then position 2; EOF takes both menus' defaults.
    printf '192.168.77.16\n02:00:00:00:00:16\nnew-node\nmaddev\nhunter2\nfresh\n\n2\n' \
        | add_node > "$SANDBOX/out" 2>&1

    assert_contains "$(out)" "shelf position (1-8, enter = end)" \
        "the ask names the writable range: current shelf plus one"
    local u; u="$(written_usr)"
    assert_contains "$u" "02:00:00:00:00:16,192.168.77.16,new-node,maddev,fresh,0,1,2," \
        "the new node took the asked-for slot"
    assert_contains "$u" "pfsense-wall,root,firewall,0,1,1" "the node before the slot held still"
    assert_contains "$u" "pi-blocker,maddev,dns,1,0,3" "everything at or past it moved up one"
    assert_contains "$u" "vault-warden,maddev,secrets,0,1,6"
    assert_contains "$(written_srv)" "gitea,git.test,3000,forge,1,7" \
        "and the standalone services shifted on the same shelf, one write, atomic"
    assert_contains "$(written_srv)" "uptime,status.test,3001,monitor,0,8"
    assert_perm "$u" "$(written_srv)" "after the insert"
}

test_add_node_empty_answer_lands_at_the_end() {
    load_nodes
    stub sshpass 0
    printf '192.168.77.16\n02:00:00:00:00:16\nnew-node\nmaddev\nhunter2\nfresh\n\n\n' \
        | add_node > "$SANDBOX/out" 2>&1
    assert_contains "$(written_usr)" "02:00:00:00:00:16,192.168.77.16,new-node,maddev,fresh,0,1,8," \
        "enter = the end: one past everything, nothing else renumbered"
    assert_perm "$(written_usr)" "$ORD_S" "after the append"
}

# ── removals close the gap they leave ───────────────────────────────────────
test_removing_a_node_closes_the_shelf_gap_and_orphans_its_group_to_the_end() {
    load_nodes
    menu_returns 1 1                       # pi-blocker; confirm "remove it"
    remove_node < /dev/null > "$SANDBOX/out" 2>&1

    assert_eq '02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,firewall,0,1,1,
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,media,0,1,2,
02:00:00:00:00:14,192.168.77.14,immich-provider,maddev,photos,0,0,3,
02:00:00:00:00:15,192.168.77.15,vault-warden,maddev,secrets,0,1,4,' \
        "$(written_usr)" \
        "every node past the removed one closed the gap"
    assert_eq 'jellyfin,192.168.77.13,8096,streams,1,1,
jellyseerr,192.168.77.13,5055,requests,0,2,
adguard,192.168.77.11,3000,dns admin,1,7,
gitea,git.test,3000,forge,1,5,
uptime,status.test,3001,monitor,0,6,' \
        "$(written_srv)" \
        "the orphaned service joined the shelf at the END rather than colliding at the front"
    assert_perm "$(written_usr)" "$(written_srv)" "after the removal"
}

test_removing_a_grouped_endpoint_closes_the_intra_gap_and_leaves_the_shelf_alone() {
    load_tunnel
    menu_returns 0                         # jellyfin, group position 1
    remove_endpoint < /dev/null > "$SANDBOX/out" 2>&1

    assert_eq 'jellyseerr,192.168.77.13,5055,requests,0,1,
adguard,192.168.77.11,3000,dns admin,1,1,
gitea,git.test,3000,forge,1,6,
uptime,status.test,3001,monitor,0,7,' \
        "$(written_srv)" \
        "its group-mate slid into the gap; the shelf never moved"
    assert_eq "" "$(written_usr)" "so the node blob was not rewritten at all"
    assert_perm "$ORD_N" "$(written_srv)" "after the removal"
}

test_removing_a_standalone_endpoint_closes_the_shelf_gap_in_both_blobs() {
    load_tunnel
    menu_returns 3                         # gitea, shelf position 6
    remove_endpoint < /dev/null > "$SANDBOX/out" 2>&1

    assert_contains "$(written_srv)" "uptime,status.test,3001,monitor,0,6," \
        "the standalone past it moved down one"
    assert_eq "" "$(written_usr)" \
        "no node sat past shelf 6, so the node blob had nothing to renumber"
    assert_perm "$ORD_N" "$(written_srv)" "after the removal"
}

# ── add endpoint: matched asks intra, standalone asks shelf ─────────────────
test_a_matched_add_asks_only_the_group_position_and_shifts_the_group() {
    load_tunnel
    # name ip port subtitle, group position 1; EOF keeps the favourite default.
    printf 'jellystat\n192.168.77.13\n3999\nstats\n\n1\n' | add_endpoint > "$SANDBOX/out" 2>&1

    assert_contains "$(out)" "position in its node's group (1-3, enter = end)" \
        "a matched service is asked its place INSIDE the group"
    assert_not_contains "$(out)" "shelf position" \
        "and never its node's shelf slot - the node already has one"
    local sv; sv="$(written_srv)"
    assert_contains "$sv" "jellystat,192.168.77.13,3999,stats,1,1," "it took the asked-for slot"
    assert_contains "$sv" "jellyfin,192.168.77.13,8096,streams,1,2" "its group-mates shifted up"
    assert_contains "$sv" "jellyseerr,192.168.77.13,5055,requests,0,3"
    assert_contains "$sv" "gitea,git.test,3000,forge,1,6" "the shelf never moved"
    assert_eq "" "$(written_usr)" "so the node blob was not rewritten at all"
    assert_perm "$ORD_N" "$sv" "after the insert"
}

test_a_matched_add_into_an_empty_group_asks_nothing() {
    load_tunnel
    # pfsense-wall (.12) holds no services: position 1 is the only truth, so no ask at all.
    printf 'fwadmin\n192.168.77.12\n8080\nfirewall ui\n' | add_endpoint > "$SANDBOX/out" 2>&1

    assert_not_contains "$(out)" "position in its node's group" "nothing to order against"
    assert_not_contains "$(out)" "shelf position" "and no shelf ask either"
    assert_contains "$(written_srv)" "fwadmin,192.168.77.12,8080,firewall ui,1,1," \
        "the first member of a group is position 1"
    assert_perm "$ORD_N" "$(written_srv)" "after the insert"
}

test_a_standalone_add_asks_the_shelf_and_a_zero_clamps_to_the_front_of_both_blobs() {
    load_tunnel
    : > "$STUB_LOG"
    printf 'grafana\ndash.test\n3006\ndashboards\n\n0\n' | add_endpoint > "$SANDBOX/out" 2>&1

    assert_contains "$(out)" "shelf position (1-8, enter = end)" \
        "a standalone service is asked for a SHELF slot, beside the nodes"
    local sv u; sv="$(written_srv)"; u="$(written_usr)"
    assert_contains "$sv" "grafana,dash.test,3006,dashboards,1,1," "0 clamped to the front"
    assert_contains "$u" "pfsense-wall,root,firewall,0,1,2" \
        "every node moved up one - the shelf renumber crossed into the node blob"
    assert_contains "$u" "vault-warden,maddev,secrets,0,1,6"
    assert_contains "$sv" "gitea,git.test,3000,forge,1,7" "and the other standalones followed"
    assert_contains "$sv" "uptime,status.test,3001,monitor,0,8"
    assert_contains "$sv" "jellyfin,192.168.77.13,8096,streams,1,1" "intra orders untouched"
    assert_eq "" "$(stub_calls openssl | grep -- '-out' | grep -v '.tmp')" \
        "both writes were staged-and-renamed"
    assert_perm "$u" "$sv" "after the insert"
}

# ── modify endpoint: the two-step vs one-step order edit ────────────────────
test_a_matched_service_in_a_multi_group_gets_the_two_step_ask() {
    load_tunnel
    : > "$STUB_LOG"
    menu_returns 1 5 6                     # jellyseerr; order; save
    # Step one: intra position 1. Step two: enter keeps the node's shelf slot.
    printf '1\n\n' | modify_endpoint > "$SANDBOX/out" 2>&1

    assert_contains "$(out)" "position in its node's group (1-2" \
        "step one: its place inside the group, because the group holds more than one"
    assert_contains "$(out)" "its node's shelf position (1-7" \
        "step two: the whole group's shelf slot, through its node"
    assert_eq 'jellyfin,192.168.77.13,8096,streams,1,2,
jellyseerr,192.168.77.13,5055,requests,0,1,
adguard,192.168.77.11,3000,dns admin,1,1,
gitea,git.test,3000,forge,1,6,
uptime,status.test,3001,monitor,0,7,' \
        "$(written_srv)" \
        "the two swapped inside the group and nothing else moved"
    assert_eq "" "$(written_usr)" "keeping the node's slot wrote no node blob"
    assert_perm "$ORD_N" "$(written_srv)" "after the swap"
}

test_the_second_step_moves_the_whole_group_by_moving_its_node() {
    load_tunnel
    menu_returns 0 5 6                     # jellyfin; order; save
    # Step one: enter keeps intra 1. Step two: the node goes to shelf 5.
    printf '\n5\n' | modify_endpoint > "$SANDBOX/out" 2>&1

    assert_eq '02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,firewall,0,1,1,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,dns,1,0,2,
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,media,0,1,5,
02:00:00:00:00:14,192.168.77.14,immich-provider,maddev,photos,0,0,3,
02:00:00:00:00:15,192.168.77.15,vault-warden,maddev,secrets,0,1,4,' \
        "$(written_usr)" \
        "the NODE moved on the shelf and the gap behind it closed"
    assert_contains "$(written_srv)" "jellyfin,192.168.77.13,8096,streams,1,1" \
        "the service kept its place inside the group"
    assert_perm "$(written_usr)" "$(written_srv)" "after the move"
}

test_a_standalone_service_gets_the_one_step_shelf_ask() {
    load_tunnel
    menu_returns 3 5 6                     # gitea; order; save
    printf '1\n' | modify_endpoint > "$SANDBOX/out" 2>&1

    assert_contains "$(out)" "shelf position (1-7" "one ask: its own shelf slot"
    assert_not_contains "$(out)" "position in its node's group" "no group to order inside"
    assert_contains "$(written_srv)" "gitea,git.test,3000,forge,1,1," "it took the front"
    assert_contains "$(written_usr)" "pfsense-wall,root,firewall,0,1,2" \
        "and every node behind it moved up one, atomically, in the other blob"
    assert_contains "$(written_srv)" "uptime,status.test,3001,monitor,0,7,"
    assert_perm "$(written_usr)" "$(written_srv)" "after the move"
}

test_a_pending_endpoint_order_edit_shows_live_and_cancel_discards_it() {
    load_tunnel
    : > "$STUB_LOG"
    menu_returns 3 5 7                     # gitea; order; CANCEL
    printf '2\n' | modify_endpoint > "$SANDBOX/out" 2>&1

    # gitea is standalone: its shelf slot is the '#' column and 'i' reads '-'.
    assert_le 1 "$(out | grep -cE '^[★ ] +2 +- +gitea')" \
        "the pending row showed the asked-for shelf position live, in the table's own '#' column"
    assert_eq "" "$(stub_calls openssl | grep -- '-out')" \
        "cancel discarded it: no encrypt of any kind ran"
    assert_eq 'jellyfin,192.168.77.13,8096,streams,1,1,
jellyseerr,192.168.77.13,5055,requests,0,2,
adguard,192.168.77.11,3000,dns admin,1,1,
gitea,git.test,3000,forge,1,6,
uptime,status.test,3001,monitor,0,7,' \
        "$(cat "$HOME/$SRV_FILE_REL")" "the database is byte-identical"
}

# ── the sorted tables ───────────────────────────────────────────────────────
test_the_nodes_table_renders_in_shelf_order_not_file_order() {
    # Same records, scrambled file order: the table must follow the order FIELD.
    load_nodes '02:00:00:00:00:15,192.168.77.15,vault-warden,maddev,secrets,0,1,5,
02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,firewall,0,1,1,
02:00:00:00:00:14,192.168.77.14,immich-provider,maddev,photos,0,0,4,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,dns,1,0,2,
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,media,0,1,3,' ''
    local t; t="$(show_nodes_table 2>/dev/null | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | grep -n . )"
    local p1 p2 p3 p4 p5
    p1=$(printf '%s\n' "$t" | grep 'pfsense-wall'    | cut -d: -f1)
    p2=$(printf '%s\n' "$t" | grep 'pi-blocker'      | cut -d: -f1)
    p3=$(printf '%s\n' "$t" | grep 'jelly-streamer'  | cut -d: -f1)
    p4=$(printf '%s\n' "$t" | grep 'immich-provider' | cut -d: -f1)
    p5=$(printf '%s\n' "$t" | grep 'vault-warden'    | cut -d: -f1)
    assert_lt "$p1" "$p2" "shelf 1 renders before shelf 2"
    assert_lt "$p2" "$p3" "shelf 2 before 3"
    assert_lt "$p3" "$p4" "shelf 3 before 4"
    assert_lt "$p4" "$p5" "shelf 4 before 5"
}

test_the_tunnel_table_renders_groups_contiguous_in_shelf_order() {
    # Scrambled file order again: rows must come out by (group's shelf slot, intra order),
    # standalones interleaved at their own shelf slots - the exact sequence the website shows.
    load_tunnel 'uptime,status.test,3001,monitor,0,7,
jellyseerr,192.168.77.13,5055,requests,0,2,
gitea,git.test,3000,forge,1,6,
adguard,192.168.77.11,3000,dns admin,1,1,
jellyfin,192.168.77.13,8096,streams,1,1,'
    local t; t="$(show_tunnels_table 2>/dev/null | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | grep -n .)"
    local pa pf ps pg pu
    pa=$(printf '%s\n' "$t" | grep 'adguard'    | cut -d: -f1)
    pf=$(printf '%s\n' "$t" | grep 'jellyfin'   | cut -d: -f1)
    ps=$(printf '%s\n' "$t" | grep 'jellyseerr' | cut -d: -f1)
    pg=$(printf '%s\n' "$t" | grep 'gitea'      | cut -d: -f1)
    pu=$(printf '%s\n' "$t" | grep 'uptime'     | cut -d: -f1)
    assert_lt "$pa" "$pf" "pi-blocker's group (shelf 2) renders before jelly-streamer's (shelf 3)"
    assert_lt "$pf" "$ps" "inside the group, intra order 1 before 2 - the group is contiguous"
    assert_lt "$ps" "$pg" "the shelf-6 standalone follows every group"
    assert_lt "$pg" "$pu" "and shelf 7 follows shelf 6"
    # The ★/indent marker column still leads every row - the inline numbers sit behind it.
    assert_contains "$(printf '%s\n' "$t" | grep 'adguard')" "★ 2  1  adguard"
    assert_contains "$(printf '%s\n' "$t" | grep 'jellyseerr')" "  3  2  jellyseerr"
}

# ── the new submenus: bare labels, distinct hotkeys, driven for real ────────
test_modify_node_submenu_hotkeys_are_distinct_and_o_reaches_the_order_ask() {
    load_nodes
    : > "$STUB_LOG"
    # The REAL interactive_menu end to end: 'p' picks pfsense-wall, 'o' jumps to order,
    # the ask reads "3", 's' saves. If any two submenu labels shared a first letter one of
    # them would be digit-relabelled and its letter would not land.
    printf 'po3\ns' | modify_node > "$SANDBOX/out" 2>&1

    assert_contains "$(written_usr)" "pfsense-wall,root,firewall,0,1,3," \
        "'o' then 's' really were order and save"
    assert_eq "0" "$(out | grep -cE '\[[0-9]\] (address|description|favourite|nickname|order|save|cancel)')" \
        "no submenu label was digit-relabelled: a d f n o s c are all distinct"
    assert_perm "$(written_usr)" "$(written_srv)" "after the hotkey-driven move"
}

test_modify_endpoint_submenu_hotkeys_are_distinct_and_o_reaches_the_order_ask() {
    load_tunnel
    : > "$STUB_LOG"
    # 'g' picks gitea (standalone), 'o' its order, "2" the new shelf slot, 's' saves.
    printf 'go2\ns' | modify_endpoint > "$SANDBOX/out" 2>&1

    assert_contains "$(written_srv)" "gitea,git.test,3000,forge,1,2," \
        "'o' then 's' really were order and save"
    assert_contains "$(written_usr)" "pi-blocker,maddev,dns,1,0,3," \
        "and the shelf renumber reached the node blob"
    assert_eq "0" "$(out | grep -cE '\[[0-9]\] (address|port|description|favourite|nickname|order|save|cancel)')" \
        "no submenu label was digit-relabelled: a p d f n o s c are all distinct"
    assert_perm "$(written_usr)" "$(written_srv)" "after the hotkey-driven move"
}

# ── the ask itself: only a real NUMBER moves the record ─────────────────────
# clamp_order is covered above; this pins the guard standing in front of it. The guard is
# the whole of D1: in modify the default is keep-current, so anything that is not a number
# must leave the record where it is. A character-class glob that merely allows '-' inside
# the set is not that guard - "-", "2-3", "1-" and "--" walk straight through it into
# clamp_order, which matches neither of its number shapes and answers max: the END. A user
# typing a range at the shelf prompt would silently send the record to the back of the shelf.
test_ask_order_takes_the_default_for_every_answer_that_is_not_a_number() {
    source "$SRC_DIR/lib.sh"
    local a
    # max 7 ("the end"), default 3 (what modify passes: keep the current position).
    for a in 'abc' '' ' ' '3 ' ' 3' '+2' '2x' '1.5' '-' '--' '2-3' '5-3' '1-' '-1-' '7-' '1,2'; do
        assert_eq "3" "$(printf '%s\n' "$a" | ask_order "p" 7 3 2>/dev/null)" \
            "a non-number answer ([$a]) keeps the current position, never the end"
    done
    # A number - a leading minus included - really is a number, and clamps.
    assert_eq "1" "$(printf '%s\n' '-5' | ask_order "p" 7 3 2>/dev/null)" "a negative is still a number: it clamps to the FRONT"
    assert_eq "1" "$(printf '%s\n' '0'  | ask_order "p" 7 3 2>/dev/null)" "zero clamps to the front"
    assert_eq "2" "$(printf '%s\n' '2'  | ask_order "p" 7 3 2>/dev/null)" "a valid position passes through"
    assert_eq "7" "$(printf '%s\n' '99' | ask_order "p" 7 3 2>/dev/null)" "a huge ask clamps to the end"
    # With no default given, "the end" IS the fallback - which is what the add flows want.
    assert_eq "7" "$(printf '%s\n' '2-3' | ask_order "p" 7 2>/dev/null)" "no default given: junk means the end"
    assert_eq "7" "$(printf '%s\n' ''    | ask_order "p" 7 2>/dev/null)" "and so does a bare enter"
    assert_eq "7" "$(ask_order "p" 7 </dev/null 2>/dev/null)"            "and so does EOF"
}

test_a_range_answered_at_the_shelf_prompt_leaves_the_node_where_it_was() {
    load_nodes
    menu_returns 0 4 5                     # pfsense-wall (shelf 1); order; save
    printf '2-3\n' | modify_node > "$SANDBOX/out" 2>&1

    assert_eq "$ORD_N" "$(written_usr)" \
        "the range was not a number, so the record kept its current slot - the blob is byte-identical"
    assert_eq "" "$(written_srv)" \
        "and nothing crossed into the service blob: no shelf position actually moved"
    assert_perm "$(written_usr)" "$ORD_S" "after the no-op"
}

# ── R2: the preview is the LIVE table's format, pinned structurally ─────────
test_the_node_pending_preview_reuses_the_live_tables_own_header_and_row() {
    load_nodes
    stub ping 0
    local strip='s/\x1b\[[0-9;]*[A-Za-z]//g'
    local hdr live pv lrow prow
    hdr="$(nodes_table_header | sed "$strip")"
    live="$(show_nodes_table 2>/dev/null | sed "$strip")"
    pv="$(show_pending_node pfsense-wall 192.168.77.12 root 1 1 | sed "$strip")"

    assert_contains "$live" "$hdr" "the live table prints the shared header + rule"
    assert_eq "$hdr" "$(printf '%s\n' "$pv" | head -n 2)" \
        "and the preview prints the SAME two lines byte for byte - not a second, verbose format"
    lrow="$(printf '%s\n' "$live" | grep 'pfsense-wall' | sed 's/\[.*//')"
    prow="$(printf '%s\n' "$pv"   | grep 'pfsense-wall' | sed 's/\[.*//')"
    assert_eq "$lrow" "$prow" \
        "every column ahead of STATUS is identical: same marker, same number, same paddings"
    assert_contains "$(printf '%s\n' "$pv" | tail -n 1)" "[ pending ]" \
        "only the STATUS cell differs - this record is not saved yet"
}

test_the_endpoint_pending_preview_reuses_the_live_tables_own_header_and_row() {
    load_tunnel
    local strip='s/\x1b\[[0-9;]*[A-Za-z]//g'
    local hdr live pv lrow prow
    hdr="$(srv_table_header | sed "$strip")"
    live="$(show_tunnels_table 2>/dev/null | sed "$strip")"
    pv="$(show_pending_endpoint gitea git.test 3000 1 6 - | sed "$strip")"

    assert_contains "$live" "$hdr" "the live table prints the shared header + rule"
    assert_eq "$hdr" "$(printf '%s\n' "$pv" | head -n 2)" \
        "and the preview prints the SAME two lines byte for byte"
    lrow="$(printf '%s\n' "$live" | grep 'gitea' | sed 's/\[.*//')"
    prow="$(printf '%s\n' "$pv"   | grep 'gitea' | sed 's/\[.*//')"
    assert_eq "$lrow" "$prow" \
        "every column ahead of STATUS is identical, the two number columns included"
    assert_contains "$(printf '%s\n' "$pv" | tail -n 1)" "[ pending ]"
}

# ── the inline numbers themselves ───────────────────────────────────────────
test_every_node_row_carries_its_shelf_number_inline() {
    # Scrambled file order: the printed number is the record's ORDER field, never its line.
    load_nodes '02:00:00:00:00:15,192.168.77.15,vault-warden,maddev,secrets,0,1,5,
02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,firewall,0,1,1,
02:00:00:00:00:14,192.168.77.14,immich-provider,maddev,photos,0,0,4,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,dns,1,0,2,
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,media,0,1,3,' ''
    stub ping 0
    local t; t="$(show_nodes_table 2>/dev/null | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')"
    assert_contains "$t" "  #  NAME" "the header names the number column '#'"
    assert_le 1 "$(printf '%s\n' "$t" | grep -cE '^[★ ] +1 +pfsense-wall')"    "shelf 1 rides on its own row"
    assert_le 1 "$(printf '%s\n' "$t" | grep -cE '^[★ ] +2 +pi-blocker')"      "shelf 2"
    assert_le 1 "$(printf '%s\n' "$t" | grep -cE '^[★ ] +3 +jelly-streamer')"  "shelf 3"
    assert_le 1 "$(printf '%s\n' "$t" | grep -cE '^[★ ] +4 +immich-provider')" "shelf 4"
    assert_le 1 "$(printf '%s\n' "$t" | grep -cE '^[★ ] +5 +vault-warden')"    "shelf 5"
}

test_a_grouped_service_row_carries_two_numbers_and_a_standalone_a_dash() {
    load_tunnel
    local t; t="$(show_tunnels_table 2>/dev/null | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')"
    assert_contains "$t" "  #  i  SERVICE NAME" "the header names both number columns"
    # A grouped service: its NODE's shelf slot, then its position inside the group.
    # adguard is pi-blocker's only service - node shelf 2, group position 1.
    assert_le 1 "$(printf '%s\n' "$t" | grep -cE '^[★ ] +2 +1 +adguard')" \
        "adguard carries its node's shelf slot (2) and its own intra slot (1)"
    assert_le 1 "$(printf '%s\n' "$t" | grep -cE '^[★ ] +3 +1 +jellyfin')" \
        "jelly-streamer is shelf 3; jellyfin is first inside its group"
    assert_le 1 "$(printf '%s\n' "$t" | grep -cE '^[★ ] +3 +2 +jellyseerr')" \
        "its group-mate carries the SAME shelf slot and the next intra slot"
    # A standalone: its OWN shelf slot, then '-' - there is no group to be inside.
    assert_le 1 "$(printf '%s\n' "$t" | grep -cE '^[★ ] +6 +- +gitea')"  "gitea sits on the shelf at 6, ungrouped"
    assert_le 1 "$(printf '%s\n' "$t" | grep -cE '^[★ ] +7 +- +uptime')" "uptime at 7"
    assert_eq "0" "$(printf '%s\n' "$t" | grep -E 'gitea|uptime' | grep -cE '^[★ ] +[0-9]+ +[0-9]+ ')" \
        "no standalone ever prints a NUMBER in the intra column"
}

# ── a failed companion write must not let the second blob land ──────────────
# The shelf is ONE permutation spanning both databases. Every add/remove that touches it
# writes two blobs; if the first write dies and the second lands anyway, the pair disagrees
# - duplicate or gapped positions - which is the single invariant the feature rests on.
test_a_failed_service_write_aborts_the_node_removal_before_the_node_blob() {
    load_nodes_failing srv_blob
    menu_returns 1 1                       # pi-blocker; confirm "remove it"
    remove_node < /dev/null > "$SANDBOX/out" 2>&1

    assert_eq "" "$(written_srv)" "the service write failed, so nothing landed there"
    assert_eq "" "$(written_usr)" \
        "and the node blob was never written: the flow bailed before the second write"
    assert_contains "$(out)" "nothing changed" "which is what it told the user"
    assert_not_contains "$(out)" "removed pi-blocker" "it never claimed the removal happened"
    assert_perm "$ORD_N" "$ORD_S" "both databases are exactly as they were"
}

test_a_failed_service_write_aborts_the_node_add_before_the_node_blob() {
    load_nodes_failing srv_blob
    stub sshpass 0
    printf '192.168.77.16\n02:00:00:00:00:16\nnew-node\nmaddev\nhunter2\nfresh\n\n2\n' \
        | add_node > "$SANDBOX/out" 2>&1

    assert_eq "" "$(written_srv)" "the shifted standalones never landed"
    assert_eq "" "$(written_usr)" "and neither did the new node - no half-written shelf"
    assert_contains "$(out)" "the node was not saved" "and the flow said so"
    assert_perm "$ORD_N" "$ORD_S" "both databases are exactly as they were"
}

test_a_failed_node_write_aborts_the_endpoint_add_before_the_service_blob() {
    load_tunnel_failing usr_blob
    printf 'grafana\ndash.test\n3006\ndashboards\n\n0\n' | add_endpoint > "$SANDBOX/out" 2>&1

    assert_eq "" "$(written_usr)" "the node renumber failed"
    assert_eq "" "$(written_srv)" \
        "so the service blob was never written: the new endpoint would have collided at shelf 1"
    assert_contains "$(out)" "the endpoint was not saved" "and the flow said so"
    assert_perm "$ORD_N" "$ORD_S" "both databases are exactly as they were"
}

test_a_failed_node_write_aborts_the_endpoint_removal_before_the_service_blob() {
    # A standalone at shelf 1 with nodes behind it: removing it MUST renumber the node blob,
    # which is the companion write this test kills.
    local n='02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,firewall,0,1,2,
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,dns,1,0,3,'
    local s='gitea,git.test,3000,forge,1,1,
adguard,192.168.77.11,3000,dns admin,1,1,'
    load_tunnel_failing usr_blob "$s" "$n"
    menu_returns 0                         # gitea, the shelf-1 standalone
    remove_endpoint < /dev/null > "$SANDBOX/out" 2>&1

    assert_eq "" "$(written_usr)" "the node renumber failed"
    assert_eq "" "$(written_srv)" \
        "so the service blob was never written: the shelf would have been left with a hole at 1"
    assert_contains "$(out)" "nothing changed" "which is what it told the user"
    assert_not_contains "$(out)" "removed gitea" "it never claimed the removal happened"
    assert_perm "$n" "$s" "both databases are exactly as they were"
}
