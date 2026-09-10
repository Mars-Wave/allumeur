#!/usr/bin/env bash
# The modify menus - "modify node" in nodes.sh and "modify tunnel endpoint" in tunnel.sh -
# and the write discipline they introduce.
#
# Four properties carry the feature. A modify edits a PENDING copy behind a live one-row
# preview: nothing touches the blob until the explicit save, which commits every pending
# edit in one write, and cancel discards the lot. A save changes exactly the fields the user
# edited and puts every other byte back where it found it - the untouched records are
# somebody's fleet. The write is staged beside the blob and rename()d over it, never the
# bare truncating encrypt: an interrupted modify must not cost records the flow never
# touched. And every free-text answer goes through the same comma/format gate the add flows
# learned, because a comma in an interior field slides the trailing flags into a neighbour.
#
# Menu indexes the tests below script: modify_node's submenu is address(0) description(1)
# favourite(2) nickname(3) order(4) save(5) cancel(6); modify_endpoint's is address(0)
# port(1) description(2) favourite(3) nickname(4) order(5) save(6) cancel(7).
#
# The openssl stub here is two-way AND file-backed: -out writes the named file for real (so
# the tmp+rename in encrypt_atomic actually happens and can be observed), and decrypt reads
# the blob file back once one exists - which is what lets a toggle-twice test prove a
# byte-identical round trip through two full modify passes.

NBLOB='02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,Gaming!,0,1,1,The Wall
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,Workstation,1,0,2,
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,Series & Movies,0,1,3,'

SRV='allumeur,192.168.77.10,443,control panel,1,1,
jellyseerr,192.168.77.13,5055,media requests,0,2,Ask For Stuff'

# Nothing enforces unique service names, and a name is a REGEX to grep: 'jelly.test' as a
# pattern also matches 'jellyxtest'. This fixture holds both hazards at once, so a delete
# that matches by name instead of by position takes three records where one was asked for.
SRV_DUP='jelly.test,192.168.77.13,5055,media requests,1,1,
jellyxtest,192.168.77.14,8096,streams,0,2,
jelly.test,192.168.77.15,5056,backup requests,0,3,'

USR_FILE_REL='.allumeur-scripts/encrypted/usr_blob.enc'
SRV_FILE_REL='.allumeur-scripts/encrypted/srv_blob.enc'

setup() {
    stub clear
    stub ssh-keygen
    stub tailscale
    stub curl 7
    stub jq 1
    printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/sleep"; chmod +x "$STUB_DIR/sleep"
    cat > "$STUB_DIR/tput" <<'EOF'
#!/usr/bin/env bash
[ "$1" = cols ] && { echo 40; exit 0; }
exit 0
EOF
    chmod +x "$STUB_DIR/tput"
}

# decrypt emits the blob file once one has been written (else the per-blob fixture);
# encrypt honors -out for real, so encrypt_atomic's tmp file and rename land on the
# sandbox disk. Two fixtures now: the shelf spans both databases, so every flow under
# test reads nodes AND services.
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
written_blob() { cat "$SANDBOX/written_blob" 2>/dev/null; }
written_srv()  { cat "$SANDBOX/written_srv" 2>/dev/null; }
written_usr()  { cat "$SANDBOX/written_usr" 2>/dev/null; }

# The disk-full face of openssl: decrypt still serves the fixtures, but any encrypt (-out)
# dies before writing a byte. encrypt_atomic's contract under this is "the old blob
# survives AND the flow says so" - the second half is what these tests pin.
fail_writes() {
    cat > "$STUB_DIR/openssl" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\n' openssl "\$*" >> "$STUB_LOG"
inf=""; prev=""
for a in "\$@"; do
    [ "\$a" = "-out" ] && exit 1
    [ "\$prev" = "-in" ] && inf="\$a"
    prev="\$a"
done
case "\$inf" in
    *srv_blob*) printf '%s\n' "\${FIXTURE_SRV:-}" ;;
    *)          printf '%s\n' "\$FIXTURE_BLOB" ;;
esac
EOF
    chmod +x "$STUB_DIR/openssl"
}

# Feed the menus by return code, one call at a time, so the record picker and the field
# submenu can be scripted independently while ask_field still reads stdin.
menu_returns() {
    MENU_Q=("$@"); MENU_I=0
    interactive_menu() {
        local r=${MENU_Q[$MENU_I]:-0}
        MENU_I=$((MENU_I + 1))
        return "$r"
    }
}

load_nodes()  { set_blob_rw "$NBLOB" ""; source "$SRC_DIR/nodes.sh"; }
load_tunnel() {
    # $1: the service fixture; $2: the node fixture ("" = no nodes, every service standalone).
    set_blob_rw "${2:-}" "${1:-$SRV}"
    # Pre-created for real: tunnel.sh's source-time init would otherwise pipe a blind
    # encrypt into the file, and the stub cannot tell that call's target apart.
    printf '%s\n' "${1:-$SRV}" > "$HOME/.allumeur-scripts/encrypted/srv_blob.enc"
    source "$SRC_DIR/tunnel.sh"
    # The registry must be the sandbox's, not the machine's: show_tunnels_table prunes it.
    RUNDIR="$SANDBOX/tunnels"; mkdir -p "$RUNDIR"
}
out() { sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' "$SANDBOX/out" 2>/dev/null; }

# ── modify node ─────────────────────────────────────────────────────────────
test_modify_node_rewrites_only_the_chosen_field_and_leaves_the_rest_byte_identical() {
    load_nodes
    menu_returns 1 1 5                     # pi-blocker, description, save
    printf 'the big one\n' | modify_node > "$SANDBOX/out" 2>&1

    assert_eq '02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,Gaming!,0,1,1,The Wall
aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,maddev,the big one,1,0,2,
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,Series & Movies,0,1,3,' \
        "$(written_blob)" \
        "one subtitle changed; every other byte of the database is exactly as it was"
}

test_modify_node_address_change_validates_a_dotted_quad() {
    load_nodes
    menu_returns 1 0 5                     # pi-blocker, address, save
    printf 'not.an.ip\n999.1.2.3\n10.0.0.5\n' | modify_node > "$SANDBOX/out" 2>&1

    assert_contains "$(written_blob)" "aa:bb:cc:dd:ee:ff,10.0.0.5,pi-blocker,maddev,Workstation,1,0,2" \
        "the first valid answer is the one written, with every other field intact"
    assert_not_contains "$(written_blob)" "999.1.2.3" "an octet above 255 is not an address"
    assert_eq "2" "$(out | grep -c 'not a dotted-quad')" \
        "both bad answers were refused where they were typed"
}

test_modify_node_favourite_toggle_round_trips() {
    load_nodes
    local blob="$HOME/$USR_FILE_REL"
    menu_returns 1 2 5                     # pi-blocker, favourite, save
    modify_node < /dev/null > "$SANDBOX/out" 2>&1
    assert_contains "$(cat "$blob")" "pi-blocker,maddev,Workstation,1,1,2" \
        "the favourite flipped and neither the luks flag nor the order beside it moved"

    # The second toggle reads the blob the first one wrote, so this is a full round trip
    # through decrypt -> rebuild -> atomic encrypt, twice.
    menu_returns 1 2 5
    modify_node < /dev/null > "$SANDBOX/out" 2>&1
    assert_eq "$NBLOB" "$(cat "$blob")" \
        "two toggles leave the database byte-identical to where it started"
}

test_modify_node_comma_in_description_is_refused() {
    load_nodes
    menu_returns 0 1 5                     # pfsense-wall, description, save
    printf 'gam,ing\ngaming rig\n' | modify_node > "$SANDBOX/out" 2>&1

    assert_contains "$(written_blob)" "192.168.77.12,pfsense-wall,root,gaming rig,0,1,1" \
        "the clean retype was taken and both flags survived in their own fields"
    assert_not_contains "$(written_blob)" "gam,ing"
    assert_contains "$(out)" "a comma splits the record" "and the refusal said why"
}

test_modify_node_writes_go_through_tmp_and_rename() {
    load_nodes
    local blob="$HOME/$USR_FILE_REL"
    menu_returns 0 2 5 6                   # pfsense-wall, favourite, save, cancel
    modify_node < /dev/null > "$SANDBOX/out" 2>&1

    assert_contains "$(stub_calls openssl)" "-out $blob.tmp" \
        "the encrypt was staged beside the blob, never aimed at it"
    assert_eq "" "$(stub_calls openssl | grep -- '-out' | grep -v "$USR_FILE_REL.tmp")" \
        "no write in this flow used the bare truncating encrypt"
    assert_no_file "$blob.tmp" "the staged file was consumed by the rename"
    assert_contains "$(cat "$blob")" "pfsense-wall,root,Gaming!,0,0,1" "and the rename landed"
}

test_modify_node_reports_a_failed_write_and_leaves_the_blob_alone() {
    load_nodes
    local blob="$HOME/$USR_FILE_REL"
    fail_writes
    menu_returns 0 2 5 6                   # pfsense-wall, favourite, save (fails), cancel
    modify_node < /dev/null > "$SANDBOX/out" 2>&1

    assert_contains "$(out)" "write failed" "a failed stage is reported, not papered over"
    assert_not_contains "$(out)" "updated" "and never claimed as an update"
    assert_no_file "$blob" "no write reached the blob"
    assert_no_file "$blob.tmp" "and no staged file was left behind"
}

test_modify_node_cancel_and_back_write_nothing() {
    load_nodes
    menu_returns 3                         # cancel on the picker (three records + cancel)
    modify_node < /dev/null > "$SANDBOX/out" 2>&1
    assert_eq "" "$(written_blob)" "cancel must not rewrite the blob"

    menu_returns 0 6                       # pick a node, then cancel the submenu
    modify_node < /dev/null > "$SANDBOX/out" 2>&1
    assert_eq "" "$(written_blob)" "and neither may cancelling out of the submenu"
}

# ── the pending copy: nothing lands until save, cancel discards everything ──
test_modify_node_pending_edits_do_not_touch_the_blob_until_save() {
    load_nodes
    local blob="$HOME/$USR_FILE_REL"
    printf '%s\n' "$NBLOB" > "$blob"       # a real blob on disk, so decrypt reads THIS
    # A menu stub that snapshots the database before answering: every frame the user sees
    # while editing is a frame where the blob is still the original.
    MENU_Q=(1 0 1 5); MENU_I=0             # pi-blocker; address; description; save
    interactive_menu() {
        cp -f "$HOME/.allumeur-scripts/encrypted/usr_blob.enc" "$SANDBOX/blob_at_menu_$MENU_I" 2>/dev/null
        local r=${MENU_Q[$MENU_I]:-0}
        MENU_I=$((MENU_I + 1))
        return "$r"
    }
    printf '10.0.0.9\nthe big one\n' | modify_node > "$SANDBOX/out" 2>&1

    assert_eq "$NBLOB" "$(cat "$SANDBOX/blob_at_menu_2")" \
        "after the address edit the blob is still the original"
    assert_eq "$NBLOB" "$(cat "$SANDBOX/blob_at_menu_3")" \
        "and still is at the save prompt, two pending edits in"
    assert_contains "$(cat "$blob")" "aa:bb:cc:dd:ee:ff,10.0.0.9,pi-blocker,maddev,the big one,1,0,2" \
        "save then landed both pending edits"
    local o; o="$(out)"
    assert_contains "$o" "10.0.0.9" "the one-row preview showed the pending address live"
    assert_contains "$o" "[ pending ]" \
        "in a row whose STATUS says pending - the table's own format, not a verbose preview"
}

test_modify_node_cancel_after_multiple_edits_leaves_the_blob_byte_identical() {
    load_nodes
    local blob="$HOME/$USR_FILE_REL"
    printf '%s\n' "$NBLOB" > "$blob"       # a real blob on disk, so decrypt reads THIS
    : > "$STUB_LOG"
    menu_returns 1 0 1 2 6                 # pi-blocker; address, description, favourite; CANCEL
    printf '10.0.0.9\nthe big one\n' | modify_node > "$SANDBOX/out" 2>&1

    assert_eq "$NBLOB" "$(cat "$blob")" \
        "cancel discarded all three pending edits: the blob is byte-identical"
    assert_eq "" "$(stub_calls openssl | grep -- '-out')" "no encrypt of any kind ran"
    assert_no_file "$blob.tmp" "and nothing was even staged"
    assert_contains "$(out)" "★ 2  pi-blocker" \
        "yet the preview had shown the pending favourite toggled to a star, leading the row ahead of the shelf number"
    assert_not_contains "$(out)" "updated" "cancel never claims an update"
}

test_modify_node_save_commits_all_pending_edits_in_one_atomic_write() {
    load_nodes
    : > "$STUB_LOG"
    menu_returns 1 0 1 2 5                 # pi-blocker; address, description, favourite; SAVE
    printf '10.0.0.9\nthe big one\n' | modify_node > "$SANDBOX/out" 2>&1

    assert_eq '02:00:00:00:00:12,192.168.77.12,pfsense-wall,root,Gaming!,0,1,1,The Wall
aa:bb:cc:dd:ee:ff,10.0.0.9,pi-blocker,maddev,the big one,1,1,2,
02:00:00:00:00:13,192.168.77.13,jelly-streamer,maddev,Series & Movies,0,1,3,' \
        "$(written_blob)" \
        "all three pending edits landed together and the other records are untouched"
    assert_eq "1" "$(stub_calls openssl | grep -c -- '-out')" \
        "in exactly one write for the whole editing session"
    assert_contains "$(stub_calls openssl)" "-out $HOME/$USR_FILE_REL.tmp" \
        "staged beside the blob, as every modify write is"
}

test_modify_endpoint_cancel_after_multiple_edits_leaves_the_blob_byte_identical() {
    load_tunnel
    local blob="$HOME/$SRV_FILE_REL"
    printf '%s\n' "$SRV" > "$blob"         # a real blob on disk, so decrypt reads THIS
    : > "$STUB_LOG"
    menu_returns 1 0 1 3 7                 # jellyseerr; address, port, favourite; CANCEL
    printf 'jelly.test\n5056\n' | modify_endpoint > "$SANDBOX/out" 2>&1

    assert_eq "$SRV" "$(cat "$blob")" \
        "cancel discarded all three pending edits: the blob is byte-identical"
    assert_eq "" "$(stub_calls openssl | grep -- '-out')" "no encrypt of any kind ran"
    assert_no_file "$blob.tmp" "and nothing was even staged"
    assert_contains "$(out)" "jelly.test:5056" \
        "yet the preview had shown the pending target live"
}

test_modify_endpoint_save_commits_all_pending_edits_in_one_atomic_write() {
    load_tunnel
    : > "$STUB_LOG"
    menu_returns 1 0 1 3 6                 # jellyseerr; address, port, favourite; SAVE
    printf 'jelly.test\n5056\n' | modify_endpoint > "$SANDBOX/out" 2>&1

    assert_eq 'allumeur,192.168.77.10,443,control panel,1,1,
jellyseerr,jelly.test,5056,media requests,1,2,Ask For Stuff' \
        "$(written_blob)" \
        "all three pending edits landed together and the other record is untouched"
    assert_eq "1" "$(stub_calls openssl | grep -c -- '-out')" \
        "in exactly one write for the whole editing session"
    assert_contains "$(out)" "★ 2  -  jellyseerr" \
        "the preview showed the toggled favourite before the save committed it, still leftmost of the number columns"
}

test_the_nodes_menu_offers_modify() {
    load_nodes
    local body; body="$(declare -f main)"
    assert_contains "$body" '"modify node"' "modify node is a top-level entry"
    assert_contains "$body" "modify_node" "and it is wired to the flow"
    assert_ok is_function modify_node
}

# ── modify tunnel endpoint ──────────────────────────────────────────────────
test_modify_endpoint_changes_only_the_port_and_validates_digits() {
    load_tunnel
    menu_returns 1 1 6                     # jellyseerr, port, save
    printf '50 55\nabc\n5056\n' | modify_endpoint > "$SANDBOX/out" 2>&1

    assert_eq 'allumeur,192.168.77.10,443,control panel,1,1,
jellyseerr,192.168.77.13,5056,media requests,0,2,Ask For Stuff' \
        "$(written_blob)" \
        "one port changed; the other record and every neighbouring field are untouched"
    assert_eq "2" "$(out | grep -c 'digits only')" "both bad ports were refused"
}

test_modify_endpoint_accepts_an_fqdn_and_rejects_garbage() {
    load_tunnel
    menu_returns 1 0 6                     # jellyseerr, address, save
    printf 'bad host!\njelly.test\n' | modify_endpoint > "$SANDBOX/out" 2>&1

    assert_contains "$(written_blob)" "jellyseerr,jelly.test,5055,media requests,0,2" \
        "services are addressed by LAN name as often as by ip, so an fqdn is a valid answer"
    assert_contains "$(out)" "not an ip or fqdn" "but not any string at all"
}

test_modify_endpoint_favourite_toggle_round_trips() {
    load_tunnel
    local blob="$HOME/$SRV_FILE_REL"
    menu_returns 0 3 6 7                   # allumeur, favourite, save, cancel
    modify_endpoint < /dev/null > "$SANDBOX/out" 2>&1
    assert_contains "$(cat "$blob")" "allumeur,192.168.77.10,443,control panel,0,1" \
        "the favourite flipped off"

    menu_returns 0 3 6
    modify_endpoint < /dev/null > "$SANDBOX/out" 2>&1
    assert_eq "$SRV" "$(cat "$blob")" \
        "two toggles leave the service database byte-identical to where it started"
}

test_modify_endpoint_writes_go_through_tmp_and_rename() {
    load_tunnel
    local blob="$HOME/$SRV_FILE_REL"
    : > "$STUB_LOG"
    menu_returns 0 3 6
    modify_endpoint < /dev/null > "$SANDBOX/out" 2>&1

    assert_contains "$(stub_calls openssl)" "-out $blob.tmp" \
        "the encrypt was staged beside the blob, never aimed at it"
    assert_eq "" "$(stub_calls openssl | grep -- '-out' | grep -v "$SRV_FILE_REL.tmp")" \
        "no write in this flow used the bare truncating encrypt"
    assert_no_file "$blob.tmp" "the staged file was consumed by the rename"
}

test_modify_endpoint_comma_in_description_is_refused() {
    load_tunnel
    menu_returns 0 2 6                     # allumeur, description, save
    printf 'panel, of control\ncontrol panel v2\n' | modify_endpoint > "$SANDBOX/out" 2>&1

    assert_contains "$(written_blob)" "allumeur,192.168.77.10,443,control panel v2,1,1" \
        "the clean retype was taken and the favourite stayed in its own field"
    assert_not_contains "$(written_blob)" "panel, of control"
    assert_contains "$(out)" "a comma splits the record"
}

test_modify_endpoint_reports_a_failed_write_and_keeps_the_blob() {
    load_tunnel
    local blob="$HOME/$SRV_FILE_REL"
    fail_writes
    menu_returns 0 3 6 7                   # allumeur, favourite, save (fails), cancel
    modify_endpoint < /dev/null > "$SANDBOX/out" 2>&1

    assert_contains "$(out)" "write failed" "a failed stage is reported, not papered over"
    assert_not_contains "$(out)" "updated" "and never claimed as an update"
    assert_eq "$SRV" "$(cat "$blob")" "the database is byte-identical to before the attempt"
    assert_no_file "$blob.tmp" "and no staged file was left behind"
}

# ── remove endpoint, by position ────────────────────────────────────────────
test_remove_endpoint_deletes_by_position_not_by_name() {
    load_tunnel "$SRV_DUP"
    local blob="$HOME/$SRV_FILE_REL"
    : > "$STUB_LOG"
    menu_returns 0                         # the FIRST jelly.test
    remove_endpoint < /dev/null > "$SANDBOX/out" 2>&1

    assert_eq 'jellyxtest,192.168.77.14,8096,streams,0,1,
jelly.test,192.168.77.15,5056,backup requests,0,2,' \
        "$(cat "$blob")" \
        "exactly one record went, the duplicate name and the regex near-miss survived, and the shelf gap closed"
    assert_contains "$(stub_calls openssl)" "-out $blob.tmp" \
        "the delete was staged beside the blob, never aimed at it"
    assert_eq "" "$(stub_calls openssl | grep -- '-out' | grep -v "$SRV_FILE_REL.tmp")" \
        "no write in this flow used the bare truncating encrypt"
    assert_no_file "$blob.tmp" "the staged file was consumed by the rename"
    assert_contains "$(out)" "removed jelly.test"
}

test_remove_endpoint_cancel_writes_nothing() {
    load_tunnel
    menu_returns 2                         # two records, then cancel
    remove_endpoint < /dev/null > "$SANDBOX/out" 2>&1
    assert_eq "" "$(written_blob)" "cancel must not rewrite the blob"
}

# ── add endpoint, on the five-field record ──────────────────────────────────
test_add_endpoint_writes_seven_fields_and_favourite_defaults_yes() {
    load_tunnel
    # name, ip, port, subtitle; EOF answers the pretty ask (none) and the shelf-position
    # ask (the end) with their defaults and leaves the favourite menu on yes.
    printf 'gitea\n192.168.77.30\n3000\ncode forge\n' | add_endpoint > "$SANDBOX/out" 2>&1
    local b; b="$(written_blob)"
    assert_contains "$b" "gitea,192.168.77.30,3000,code forge,1,3" \
        "favourite defaults to yes and the shelf position to the end"
    assert_contains "$b" "allumeur,192.168.77.10,443,control panel,1,1" "existing records kept"
    assert_contains "$b" "jellyseerr,192.168.77.13,5055,media requests,0,2"
    assert_eq "0" "$(printf '%s\n' "$b" | awk -F, 'NF != 7' | grep -c .)" \
        "every record has exactly seven fields"
}

test_add_endpoint_records_a_declined_favourite() {
    load_tunnel
    # The empty lines answer the pretty ask (none) and the shelf-position ask (the end);
    # 'n' declines the favourite.
    printf 'hidden\n192.168.77.31\n8443\nquiet admin\n\n\nn' | add_endpoint > "$SANDBOX/out" 2>&1
    assert_contains "$(written_blob)" "hidden,192.168.77.31,8443,quiet admin,0,3" \
        "'no' stores 0: the service exists only in allumeur mode"
}

test_add_endpoint_comma_in_any_field_is_refused() {
    load_tunnel
    # A comma is offered in the name AND in the subtitle. The subtitle is an interior
    # field, so 'media, requests' would write a seven-field record and every reader would
    # slice the trailing flags out of a neighbour - losing the star the user just asked for.
    printf 'git,ea\ngitea\n192.168.77.30\n3000\nmedia, requests\ncode forge\n' \
        | add_endpoint > "$SANDBOX/out" 2>&1

    local b; b="$(written_blob)"
    assert_contains "$b" "gitea,192.168.77.30,3000,code forge,1,3" \
        "both clean retypes were taken and the favourite survived in its own field"
    assert_not_contains "$b" "git,ea"
    assert_not_contains "$b" "media, requests"
    assert_eq "2" "$(out | grep -c 'a comma splits the record')" \
        "each comma was refused where it was typed"
    assert_eq "0" "$(printf '%s\n' "$b" | awk -F, 'NF != 7' | grep -c .)" \
        "every record has exactly seven fields"
}

test_add_endpoint_gates_address_and_port_like_modify_does() {
    load_tunnel
    printf 'gitea\nbad host!\ngitea.test\n30 00\nabc\n3000\ncode forge\n' \
        | add_endpoint > "$SANDBOX/out" 2>&1

    assert_contains "$(written_blob)" "gitea,gitea.test,3000,code forge,1,3" \
        "an fqdn is a valid address and the first all-digits port is the one written"
    assert_contains "$(out)" "not an ip or fqdn" "garbage is not an address"
    assert_eq "2" "$(out | grep -c 'digits only')" "both bad ports were refused"
    assert_not_contains "$(written_blob)" "bad host!"
}

test_add_endpoint_aborts_on_an_empty_name() {
    load_tunnel
    printf '\n' | add_endpoint > "$SANDBOX/out" 2>&1
    assert_eq "" "$(written_blob)" "nothing was written"
    assert_contains "$(out)" "missing fields"
}

test_the_tunnel_menu_offers_modify_and_keeps_every_existing_entry() {
    load_tunnel
    local body; body="$(declare -f main)"
    assert_contains "$body" '"modify tunnel endpoint"' "modify is a menu entry"
    assert_contains "$body" "modify_endpoint" "and it is wired to the flow"
    local e
    for e in "new temporal tunnel" "add tunnel endpoint" "remove tunnel endpoint" \
             "kill all tunnels" "fields on tables" "update view" "exit"; do
        assert_contains "$body" "$e" "existing entry '$e' must survive"
    done
}

test_the_tunnel_table_leads_each_row_with_the_favourite_marker() {
    load_tunnel
    local t; t="$(show_tunnels_table 2>/dev/null | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')"
    # The marker column is still leftmost; the two number columns sit between it and the name.
    assert_contains "$(printf '%s\n' "$t" | grep allumeur)" "★ 1  -  allumeur" \
        "the favourite leads its row with the star, ahead of the shelf/intra numbers"
    assert_contains "$(printf '%s\n' "$t" | grep jellyseerr)" "  2  -  jellyseerr" \
        "a non-favourite leads with the plain indent"
    assert_not_contains "$(printf '%s\n' "$t" | grep jellyseerr)" "★" \
        "and never the star"
}

test_the_nodes_table_leads_each_row_with_the_favourite_marker() {
    load_nodes
    stub ping 0                            # backend stubs (curl 7, jq 1) force the ICMP path
    local t; t="$(show_nodes_table 2>/dev/null | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')"
    # The marker column is still leftmost; the shelf number sits between it and the name.
    assert_contains "$(printf '%s\n' "$t" | grep pfsense-wall)" "★ 1  pfsense-wall" \
        "favourite=1 renders the star at the left of the row, ahead of the shelf number"
    assert_contains "$(printf '%s\n' "$t" | grep pi-blocker)" "  2  pi-blocker" \
        "favourite=0 renders the plain indent"
    assert_contains "$(printf '%s\n' "$t" | grep jelly-streamer)" "★ 3  jelly-streamer"
    assert_contains "$(printf '%s\n' "$t" | grep NAME)" "  #  NAME" \
        "the header is indented past the marker column, keeping the columns aligned"
}

test_the_pick_menus_lead_with_the_marker_and_keep_letter_hotkeys() {
    load_nodes
    # remove_node's picker uses the REAL interactive_menu: 'j' must still jump to
    # jelly-streamer even though every record row now begins with a marker glyph, and the
    # two p-nodes must still resolve their collision on the letter, not on the marker.
    printf 'jr' | remove_node > "$SANDBOX/out" 2>&1
    local o; o="$(out)"
    assert_contains "$o" "★ pfsense-wall" "a favourite row leads with the star"
    assert_contains "$o" "★ jelly-streamer"
    assert_contains "$o" "  [1] pi-blocker" \
        "the digit tag sits between the marker and the label, so the marker column holds"
    assert_not_contains "$(written_blob)" "jelly-streamer" "'j' keyed on the name and removed it"
    assert_contains "$(written_blob)" "pi-blocker" "the marker never became a hotkey"
    assert_contains "$(written_blob)" "pfsense-wall"
    assert_contains "$o" "removed jelly-streamer" "and the confirmation names the node, not the glyph"
}

# ── the service subtitle helper, on the five-field record ───────────────────
# Lifted out the same way test_luks lifts the node editor: the script carries a top-level
# menu loop, and `</dev/tty` is an artefact of the TUI, not of the parsing under test.
service_helper_src() {
    awk '/^update_service_subtitles\(\) \{/,/^\}/' "$SRC_DIR/subtitle-helper.sh" \
        | sed 's#</dev/tty#<\&0#'
}

test_the_service_subtitle_helper_preserves_the_favourite() {
    load_tunnel
    local src; src="$(service_helper_src)"
    assert_ok test -n "$src"
    eval "$src"
    # allumeur's subtitle is offered a comma first - with the favourite now the record's
    # tail, a comma here is the same flag-voiding hazard the node editor already guards.
    printf 'pan,el\nthe panel\n\n' | update_service_subtitles > "$SANDBOX/out" 2>&1

    local b; b="$(written_blob)"
    assert_contains "$b" "allumeur,192.168.77.10,443,the panel,1,1" \
        "edited, and the favourite rode through"
    assert_contains "$b" "jellyseerr,192.168.77.13,5055,media requests,0,2" \
        "an untouched record keeps its 0 - the flag did not spread"
    assert_not_contains "$b" "pan,el"
    assert_contains "$(out)" "a comma splits the record"
}

test_the_service_subtitle_helper_writes_through_tmp_and_rename() {
    load_tunnel
    local blob="$HOME/$SRV_FILE_REL"
    local src; src="$(service_helper_src)"
    assert_ok test -n "$src"
    eval "$src"
    : > "$STUB_LOG"
    # Enter twice: keep both subtitles. A whole-blob rewrite that changes nothing is the
    # cheapest way to prove the writer, and that the round trip is byte-identical.
    printf '\n\n' | update_service_subtitles > "$SANDBOX/out" 2>&1

    assert_contains "$(stub_calls openssl)" "-out $blob.tmp" \
        "the whole-blob rewrite is staged beside the blob, never aimed at it"
    assert_eq "" "$(stub_calls openssl | grep -- '-out' | grep -v "$SRV_FILE_REL.tmp")" \
        "no write in this flow used the bare truncating encrypt"
    assert_no_file "$blob.tmp" "the staged file was consumed by the rename"
    assert_eq "$SRV" "$(cat "$blob")" "enter-to-keep round-trips the database byte-identical"
}

# The node-record editor, lifted the same way the service one is above.
node_helper_src() {
    awk '/^update_node_subtitles\(\) \{/,/^\}/' "$SRC_DIR/subtitle-helper.sh" \
        | sed 's#</dev/tty#<\&0#'
}

test_the_node_record_helper_writes_through_tmp_and_rename() {
    load_nodes
    local blob="$HOME/$USR_FILE_REL"
    local src; src="$(node_helper_src)"
    assert_ok test -n "$src"
    eval "$src"
    : > "$STUB_LOG"
    # Two prompts per node (subtitle, ssh-on-wake), three nodes, all kept.
    printf '\n\n\n\n\n\n' | update_node_subtitles > "$SANDBOX/out" 2>&1

    assert_contains "$(stub_calls openssl)" "-out $blob.tmp" \
        "the whole-blob rewrite is staged beside the blob, never aimed at it"
    assert_eq "" "$(stub_calls openssl | grep -- '-out' | grep -v "$USR_FILE_REL.tmp")" \
        "no write in this flow used the bare truncating encrypt"
    assert_no_file "$blob.tmp" "the staged file was consumed by the rename"
    assert_eq "$NBLOB" "$(cat "$blob")" \
        "enter-to-keep round-trips all nine fields of every record byte-identical"
}
