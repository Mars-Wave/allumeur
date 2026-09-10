#!/bin/bash
source "$HOME/.allumeur-scripts/lib.sh"

SSH_KEY="$HOME/.allumeur-scripts/encrypted/allumeur-master-key"

# Key lifecycle + the shared reachability ladder every flow below resolves through.
source "$HOME/.allumeur-scripts/keys.sh"

# The always-on Rust backend owns the wake/shutdown state machine. Routing the CLI
# through it (localhost HTTPS, self-signed) is what unifies the TUI and the WebGUI:
# a lever flicked here shows as confirming_* there, and vice-versa.
API="https://127.0.0.1"
api_nodes_json() { curl -sk --max-time 4 "$API/api/nodes" 2>/dev/null; }
api_toggle() {
    # args: mac ip user state("on"|"off")
    curl -sk --max-time 8 -X POST "$API/api/nodes/toggle" \
        -H 'Content-Type: application/json' \
        -d "{\"mac\":\"$1\",\"ip\":\"$2\",\"user\":\"$3\",\"state\":\"$4\"}" >/dev/null 2>&1
}

mint_master_key_if_missing() {
    [ -f "$SSH_KEY" ] && return 0
    echo -e "\n${PINK}... forging post-quantum transit master key ...${RESET}"
    ssh-keygen -t ed25519 -a 100 -f "$SSH_KEY" -N "" -q -C "allumeur-master-key"
}

# ── the table format: ONE pair for the live table AND the modify preview ─────
# Rows mirror the GUI blocks with the numbers inline: marker leftmost, then the node's
# SHELF number, then the record - "★ 1  jelly-streamer ...". nodes_table_header/row ARE the
# format: show_pending_node renders through the same pair, so the preview and the table can
# never drift apart. Cells go through fit_cell, so a long value truncates instead of
# shoving its neighbours right, and a multi-byte glyph pads by characters rather than bytes.
#
# v11: the pair renders whatever nodes_layout decided - which OPTIONAL columns are on
# (marker, '#', ip, user, pretty - the ~/.tui-fields toggles; NAME and STATUS always show),
# how wide the flexible columns run, and whether the row had to be compacted to fit
# lib.sh's TUI_MAX (the loss-ordered pipeline documented there). The NAME and PRETTY
# columns are content-sized above their bases, so nothing is chopped while there is room.

# nodes_layout <node-csv-lines> - compute this render's layout into NL_*: the toggles, the
# column widths, and NL_ABBR (rung 1). Every caller of the header/row pair goes through
# here first - show_nodes_table over the whole table, show_pending_node over its one
# pending row - which is what makes the previews inherit the compaction pipeline.
nodes_layout() {
    tui_fields_load
    NL_FAV=$TF_NODES_FAV NL_ORD=$TF_NODES_ORD NL_IP=$TF_NODES_IP NL_USER=$TF_NODES_USER
    NL_ABBR=0
    local LC_ALL=C.UTF-8
    local mac ip name user subtitle luks fav ord pretty luks_seen=0 n=15 p=6
    if [ -n "${1:-}" ]; then
        while IFS=',' read -r mac ip name user subtitle luks fav ord pretty; do
            [ -z "$ip" ] && continue
            [ "${#name}" -gt "$n" ] && n=${#name}
            [ "${#pretty}" -gt "$p" ] && p=${#pretty}
            [ "$luks" = 1 ] && luks_seen=1
        done <<< "$1"
    fi
    NL_W_NAME=$n
    NL_W_PRETTY=0
    [ "$TF_NODES_PRETTY" = 1 ] && NL_W_PRETTY=$p
    # The row this layout would print, measured. STATUS budgets its widest form -
    # "[ ~ down ~ ]" (12) - plus the " luks" suffix (5) when any displayed node carries it:
    # the suffix is part of the row, so it is part of the budget.
    local w=0 st=12 s
    [ "$NL_FAV" = 1 ] && w=$((w + 2))
    [ "$NL_ORD" = 1 ] && w=$((w + 3))
    w=$((w + NL_W_NAME + 1))
    [ "$NL_IP" = 1 ] && w=$((w + 16))
    [ "$NL_USER" = 1 ] && w=$((w + 13))
    [ "$NL_W_PRETTY" -gt 0 ] && w=$((w + NL_W_PRETTY + 1))
    [ "$luks_seen" = 1 ] && st=$((st + 5))
    [ $((w + st)) -le "$TUI_MAX" ] && return 0
    # Rung 1: abbreviate the statuses (widest abbreviated form "[ ~▪ ]" = 6).
    NL_ABBR=1
    st=6; [ "$luks_seen" = 1 ] && st=11
    # Rung 2: the pretty column shrinks tab stop by tab stop, floor 8.
    while [ $((w + st)) -gt "$TUI_MAX" ] && [ "$NL_W_PRETTY" -gt 8 ]; do
        s=$(prev_tab_stop "$NL_W_PRETTY"); w=$((w - NL_W_PRETTY + s)); NL_W_PRETTY=$s
    done
    # Rung 3: only then the name column, same technique.
    while [ $((w + st)) -gt "$TUI_MAX" ] && [ "$NL_W_NAME" -gt 8 ]; do
        s=$(prev_tab_stop "$NL_W_NAME"); w=$((w - NL_W_NAME + s)); NL_W_NAME=$s
    done
    return 0
}

# node_status_fmt <up|confirming_up|confirming_down|pending|*> - the colored STATUS cell in
# the form the layout picked (full, or the rung-1 abbreviations documented in lib.sh).
node_status_fmt() {
    if [ "${NL_ABBR:-0}" = 1 ]; then
        case "$1" in
            up)              printf '%s' "${WHITE}[ ▪ ]${RESET}" ;;
            confirming_up)   printf '%s' "${GRAY}[ ~▪ ]${RESET}" ;;
            confirming_down) printf '%s' "${GRAY}[ ~ ]${RESET}" ;;
            pending)         printf '%s' "${GRAY}[ ? ]${RESET}" ;;
            *)               printf '%s' "${PINK}[   ]${RESET}" ;;
        esac
    else
        case "$1" in
            up)              printf '%s' "${WHITE}[ up ]${RESET}" ;;
            confirming_up)   printf '%s' "${GRAY}[ ~ up ~ ]${RESET}" ;;
            confirming_down) printf '%s' "${GRAY}[ ~ down ~ ]${RESET}" ;;
            pending)         printf '%s' "${GRAY}[ pending ]${RESET}" ;;
            *)               printf '%s' "${PINK}[ down ]${RESET}" ;;
        esac
    fi
}

nodes_table_header() {
    [ -n "${NL_W_NAME:-}" ] || nodes_layout ''
    local h=''
    [ "$NL_FAV" = 1 ] && h+='  '
    [ "$NL_ORD" = 1 ] && h+="$(fit_cell '#' 2) "
    h+="$(fit_cell NAME "$NL_W_NAME") "
    [ "$NL_IP" = 1 ] && h+="$(fit_cell IP 15) "
    [ "$NL_USER" = 1 ] && h+="$(fit_cell USER 12) "
    [ "$NL_W_PRETTY" -gt 0 ] && h+="$(fit_cell PRETTY "$NL_W_PRETTY") "
    h+="STATUS"
    printf "${PINK}%s${RESET}\n" "$h"
    printf "${PINK}%s${RESET}\n" "$(table_rule "$h")"
}
# args: favourite ord name ip user pretty status(%b)
nodes_table_row() {
    [ -n "${NL_W_NAME:-}" ] || nodes_layout ''
    local r=''
    [ "$NL_FAV" = 1 ] && r+="${PINK}$(fav_mark "$1") "
    [ "$NL_ORD" = 1 ] && r+="${GRAY}$(fit_cell "$2" 2) "
    r+="${WHITE}$(fit_cell "$3" "$NL_W_NAME") "
    [ "$NL_IP" = 1 ] && r+="$(fit_cell "$4" 15) "
    [ "$NL_USER" = 1 ] && r+="$(fit_cell "$5" 12) "
    [ "$NL_W_PRETTY" -gt 0 ] && r+="${GRAY}$(fit_cell "$6" "$NL_W_PRETTY" …)${WHITE} "
    printf '%b%b\n' "$r" "$7"
}

show_nodes_table() {
    local data=$(decrypt_blob | grep '[^[:space:]]')
    if [ -z "$data" ]; then
        echo -e "${WHITE}no nodes found. add one to see it here.${RESET}"
        return
    fi

    echo -e "${PINK}... checking reachability ...${RESET}"

    # Prefer the backend for a unified view (includes confirming_up / confirming_down).
    # Fall back to a local ICMP sweep if the service is down - degrades to plain up/down.
    declare -A ST
    local json; json=$(api_nodes_json)
    if [ -n "$json" ] && echo "$json" | jq -e . >/dev/null 2>&1; then
        while IFS=$'\t' read -r k v; do ST["$k"]="$v"; done < <(echo "$json" | jq -r '.[] | [.ip, .status] | @tsv')
    else
        local tmp_dir=$(mktemp -d)
        while IFS=',' read -r mac ip name user subtitle luks favourite ord pretty; do
            [ -z "$ip" ] && continue
            ( ping -c 1 -W 1 "$ip" >/dev/null 2>&1 && echo "up" > "$tmp_dir/$ip" || echo "down" > "$tmp_dir/$ip" ) &
        done <<< "$data"
        wait
        while IFS=',' read -r mac ip name user subtitle luks favourite ord pretty; do
            [ -z "$ip" ] && continue
            ST["$ip"]=$(cat "$tmp_dir/$ip" 2>/dev/null)
        done <<< "$data"
        rm -rf "$tmp_dir"
    fi

    clear
    nodes_layout "$data"
    nodes_table_header

    # Rendered in SHELF order (field 8), not file order: this is the one sequence the TUI
    # and the website share - and the shelf number rides inline on every row, so the table
    # tells the same story the GUI blocks do. -s keeps a damaged blob (duplicate or junk
    # orders) in file order within the tie instead of shuffling on the whole-line fallback.
    while IFS=',' read -r mac ip name user subtitle luks favourite ord pretty; do
        [ -z "$ip" ] && continue
        local status="${ST[$ip]:-down}"
        local status_fmt; status_fmt=$(node_status_fmt "$status")
        # Suffixed onto the last column rather than given one of its own: a fifth padded
        # column would widen every row by its full width even for the nodes that do not
        # carry the flag, and this is the only way to confirm from the TUI that one does.
        [ "$luks" = 1 ] && status_fmt="${status_fmt}${GRAY} luks${RESET}"
        # The favourite leads the row: a pink ★ is guests-visible; a plain indent, allumeur-only.
        # One char + one space (fav_mark), so the row width is what the header above measures;
        # the shelf number sits between the marker and the name, small and fixed-width.
        nodes_table_row "$favourite" "$ord" "$name" "$ip" "$user" "$pretty" "$status_fmt"
    done <<< "$(printf '%s\n' "$data" | sort -s -t, -k8,8n)"
}

# Watch a node settle from confirming_* to its target (up/down), refreshing the unified
# table live. Bounded to the backend's ~66s confirm window; any key stops watching early.
watch_confirm() {
    local ip="$1" target="$2" elapsed=0
    tput civis
    while [ "$elapsed" -le 66 ]; do
        clear
        show_nodes_table
        echo ""
        echo -e "${PINK}*~ ${WHITE}${BOLD}confirming $ip → $target${PINK} ~*${RESET}"
        echo -e "${GRAY}assumed state shown grayed; polling network card - press any key to stop watching${RESET}"
        local cur
        cur=$(api_nodes_json | jq -r --arg ip "$ip" '.[]|select(.ip==$ip)|.status' 2>/dev/null)
        if [ "$cur" == "$target" ]; then
            echo -e "\n${WHITE}[*] confirmed: $ip is now $target.${RESET}"
            sleep 1.5
            break
        fi
        [ -z "$cur" ] && break   # backend stopped answering - don't hang
        read -rsn1 -t 2 _key && break
        elapsed=$((elapsed + 2))
    done
    tput cnorm
}

# ask_field <prompt> <varname> - read one field of the record, re-asking on a comma.
# The record is unquoted CSV with interior fields, so a comma in ANY field writes a tenth:
# every reader then slices the luks flag out of a neighbouring field, reads it as
# not-blocked, and wakes the one machine that must never be woken. Guarding the one field
# somebody noticed is how the others stayed open, hence one reader for all.
ask_field() {
    local -n _field=$2
    while :; do
        echo -ne "${PINK}$1: ${WHITE}"
        # EOF (dead stdin) must not feed the caller's validation retry loop forever -
        # but a final line without a trailing newline ALSO returns non-zero while still
        # filling the variable, and that answer is real. Abort only on a truly empty read.
        if ! IFS= read -r _field; then
            [ -n "$_field" ] || { echo -ne "${RESET}"; return 1; }
        fi
        [ "$_field" = "${_field//,/}" ] && break
        echo -e "${RESET}${WHITE}[!] a comma splits the record"
        echo -e "    and voids the luks flag.${RESET}"
    done
    echo -ne "${RESET}"
}

add_node() {
    clear
    show_nodes_table
    echo ""
    echo -e "${PINK}*~ ${WHITE}${BOLD}add new node${PINK} ~*${RESET}"
    echo -e "${WHITE}use up/down arrows & enter${RESET}\n"

    ask_field "ipv4 address" ip

    echo -e "\n${PINK}... checking network ...${RESET}"
    if ! ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
        echo -e "${WHITE}[!] host unreachable. aborting.${RESET}"
        sleep 2; return
    fi
    echo -e "${WHITE}[*] host found!${RESET}\n"

    ask_field "mac address (for wol)" mac
    ask_field "name (e.g. pfsense-wall)" name
    ask_field "ssh username" user
    # The one answer that is a live credential, so the one that is scoped: a global would
    # keep it in a root TUI that stays up for hours. It never reaches the record, so no guard.
    local pass
    echo -ne "${PINK}ssh password (temporary): ${WHITE}"
    IFS= read -rs pass
    echo -e "${RESET}"
    ask_field "subtitle (short description, e.g. 'gaming rig')" subtitle
    # Optional, and the one field that may be empty: the guest-facing display name. Guest
    # mode shows it (falling back to the real name when empty); allumeur mode always shows
    # the real name. Through ask_field like every other field - a comma would split the
    # record - but never re-asked for being empty: empty IS the "no alias" answer.
    pretty=''
    ask_field "pretty name (guest-facing, enter = none)" pretty

    # Where on the shelf - the one ordering nodes share with standalone services, across
    # both databases. Default is the end; a digit answer is clamped into [1..K+1].
    local sdata0 shelf_k ord_asked
    sdata0=$(decrypt_srv | grep '[^[:space:]]')
    shelf_k=$(ord_shelf_size "$(decrypt_blob | grep '[^[:space:]]')" "$sdata0")
    ord_asked=$(ask_order "shelf position (1-$((shelf_k + 1)), enter = end)" $((shelf_k + 1)))

    # Asked as the inverse of what is stored, because "can I ssh in after a wake?" is the
    # thing the user knows about a machine; "it sits at a LUKS prompt" is the reason.
    # The menu index is the flag: 0 = yes = not blocked, 1 = no = blocked.
    echo -e "\n${PINK}if woke on lan, can it be sshd into?${RESET}"
    interactive_menu "yes" "no"
    local luks=$?

    # Curation, not security: a favourite is shown to everyone on the frontend's guest view,
    # a non-favourite only surfaces in allumeur mode. The menu index is the INVERSE of the
    # stored flag - 0 = yes = favourite = 1 - and yes is first so plain enter keeps a node
    # visible, which is what almost every node wants.
    echo -e "\n${PINK}favourite? (shown to guests)${RESET}"
    interactive_menu "yes" "no"
    local fav=$?
    [ "$fav" -eq 0 ] && fav=1 || fav=0

    echo -e "\n${PINK}... pushing master key to target ...${RESET}"

    # Through the environment, never argv: /proc/<pid>/cmdline is 0444, so `-p "$pass"` hands
    # the node's password to every local account for as long as the copy runs. Same idiom as
    # k_adopt, which the sudoers grant three lines below already relies on.
    if SSHPASS=$pass sshpass -e ssh-copy-id -i "$SSH_KEY.pub" -o StrictHostKeyChecking=no "$user@$ip" >/dev/null 2>&1; then
        echo -e "${WHITE}[*] key deployed securely!${RESET}"
        echo -e "${PINK}... saving node without password ...${RESET}"

        local current=$(decrypt_blob | grep '[^[:space:]]')
        local sdata_now=$(decrypt_srv | grep '[^[:space:]]')
        # printf-built, never `echo -e`: that re-interprets backslash escapes across EVERY
        # record already in the database, so one `\c` in an existing subtitle truncates the
        # blob from that record onward, and a `\n` in the new one splits its own record and
        # drops the trailing flags - storing a machine the user just declared unwakeable as
        # wakeable. The order placeholder 0 is what ord_place_shelf overwrites; the pretty
        # rides LAST, exactly where every v11 reader expects it.
        local new_entry="$mac,$ip,$name,$user,$subtitle,$luks,$fav,0,$pretty"
        local ndata_new nidx
        if [ -n "$current" ]; then
            ndata_new="$current"$'\n'"$new_entry"
            nidx=$(printf '%s\n' "$current" | grep -c .)
        else
            ndata_new="$new_entry"
            nidx=0
        fi
        # Placing the node can shift standalone services (the shelf spans both blobs), so
        # this write is no longer append-only - both blobs go through the atomic writer.
        # The companion blob commits FIRST and its failure is fatal to the whole save: the
        # shelf is one permutation spanning both files, so letting the node blob land after
        # a failed service write would leave the two disagreeing - duplicate or gapped
        # positions, the one invariant the feature rests on. Returning here really does
        # leave both blobs untouched (atomicity holds on the failed write), so the message
        # is honest. Same branch shape modify_node's save already uses.
        ord_place_shelf "$ndata_new" "$sdata_now" n "$nidx" "$ord_asked"
        if [ "$ORD_SRV" != "$sdata_now" ] && \
           ! printf '%s\n' "$ORD_SRV" | grep '[^[:space:]]' | encrypt_atomic "$SRV_BLOB"; then
            echo -e "${WHITE}[!] write failed - the node was not saved.${RESET}"
            sleep 2
            pass=
            return
        fi
        if ! printf '%s\n' "$ORD_NODES" | grep '[^[:space:]]' | encrypt_atomic "$BLOB_FILE"; then
            echo -e "${WHITE}[!] write failed - the node was not saved.${RESET}"
            sleep 2
            pass=
            return
        fi
        sleep 1

        # The password to do this is already in hand, but writing a sudoers rule on someone's
        # machine is a privilege change and doing it unasked would be a surprise. Root is not
        # asked at all: it does not go through sudo, so there would be nothing to grant.
        if [ "$user" != root ]; then
            echo -e "\n${PINK}allow powering it off remotely?${RESET}"
            echo -e "${GRAY}adds a sudo rule for poweroff.${RESET}"
            interactive_menu "yes" "no"
            if [ $? -eq 0 ]; then
                echo -e "\n${PINK}... granting remote power off ...${RESET}"
                # Borrowed whole from the keys run: same installer, same proof over a
                # separate master-key connection. A failure here is reported and nothing
                # more - the node is added either way, and it already is.
                if k_begin; then
                    k_add_node "$mac" "$ip" "$name" "$user" "$luks"
                    K_PW[0]=$pass
                    if k_sudo_install 0 && k_sudo_state 0; then
                        echo -e "${WHITE}[*] remote power off allowed.${RESET}"
                    else
                        echo -e "${WHITE}[!] could not grant it.${RESET}"
                        echo -e "${GRAY}    fix: keys > ensure reachability${RESET}"
                    fi
                    k_cleanup
                else
                    # No run dir, so the installer never even started. Reported like any
                    # other failed grant: the node is added, the rule is not, and ensure is
                    # where it gets retried.
                    echo -e "${WHITE}[!] could not grant it.${RESET}"
                    echo -e "${GRAY}    fix: keys > ensure reachability${RESET}"
                fi
                sleep 2
            fi
        fi
    else
        echo -e "${WHITE}[!] key deployment failed. check credentials.${RESET}"
        sleep 2
    fi
    # k_cleanup's K_PW=() covers the copy the grant took; this is the original.
    pass=
}

enter_shell() {
    local data=$(decrypt_blob | grep '[^[:space:]]')
    if [ -z "$data" ]; then
        echo -e "${WHITE}no nodes found.${RESET}"
        sleep 1; return
    fi

    # Every node is offered, not just the ones answering ping: a node that is off gets woken
    # and one whose key was lost gets it back, both through the shared ladder.
    local lines=()
    local names=()
    while IFS=',' read -r mac ip name user subtitle luks favourite ord pretty; do
        [ -z "$ip" ] && continue
        lines+=("$mac,$ip,$name,$user,$subtitle,$luks,$favourite,$ord,$pretty")
        names+=("$name")
    done <<< "$data"
    names+=("cancel")

    print_header "enter ssh shell"
    interactive_menu "${names[@]}"
    local choice=$?

    local target="${names[$choice]}"
    if [ "$target" != "cancel" ]; then
        IFS=',' read -r t_mac t_ip t_name t_user t_subtitle t_luks t_fav <<< "${lines[$choice]}"
        clear
        if k_resolve_tty "$t_mac" "$t_ip" "$t_name" "$t_user" "reaching $t_name" "$t_luks"; then
            clear
            echo -e "${PINK}*~ ${WHITE}shell: $t_name ${PINK}~*${RESET}\n"
            k_opts_tty "$SSH_KEY"
            ssh "${K_OPTS[@]}" "$t_user@$t_ip"
            echo -e "\n${PINK}[ connection closed. press any key to return ]${RESET}"
        else
            echo -e "\n${PINK}[!] could not reach $t_name - ${K_LAST_NOK}${RESET}"
            # Same advice k_report gives for the same detail string. Sending a luks lock to
            # ensure is a loop: ensure is the one operation that refuses to touch a flagged
            # node, so it can only ever come back with the message the user just read.
            if [ "$K_LAST_NOK" = "luks locked" ]; then
                echo -e "${GRAY}    fix: unlock at its console,${RESET}"
                echo -e "${GRAY}         then run again${RESET}"
            else
                echo -e "${GRAY}    fix: keys > ensure reachability${RESET}"
            fi
            echo -e "\n${PINK}[ press any key to return ]${RESET}"
        fi
        read -rsn1
    fi
}

hit_lights() {
    local data=$(decrypt_blob | grep '[^[:space:]]')
    if [ -z "$data" ]; then
        echo -e "${WHITE}no nodes found.${RESET}"
        sleep 1; return
    fi

    local lines=()
    local names=()
    while IFS=',' read -r mac ip name user subtitle luks favourite ord pretty; do
        [ -z "$ip" ] && continue
        lines+=("$mac,$ip,$name,$user,$subtitle,$luks,$favourite,$ord,$pretty")
        names+=("$name")
    done <<< "$data"
    names+=("cancel")

    print_header "hit lights"
    interactive_menu "${names[@]}"
    local choice=$?

    local target="${names[$choice]}"
    if [ "$target" != "cancel" ]; then
        IFS=',' read -r t_mac t_ip t_name t_user t_subtitle t_luks t_fav <<< "${lines[$choice]}"

        print_header "lights : $t_name"
        local opts=("wake up (wol)" "power off (ssh)" "back")
        interactive_menu "${opts[@]}"
        case $? in
            0)
                # A luks-blocked node is still woken on request: the user asking for this is
                # usually about to walk over and type the passphrase. Only the ladder, which
                # wakes on its own initiative, has to care about the flag.
                echo -e "\n${PINK}... flicking $t_name ON - assuming state, polling network card ...${RESET}"
                if api_toggle "$t_mac" "$t_ip" "$t_user" "on"; then
                    watch_confirm "$t_ip" "up"
                else
                    # Backend unreachable: direct WoL blast (no confirming state available).
                    echo -e "${PINK}[!] backend unreachable - direct WoL fallback ...${RESET}"
                    wol_blast "$t_mac" "$t_ip"
                    echo -e "${WHITE}[*] magic packets sent (unicast + subnet + broadcast, ports 9 & 7).${RESET}"
                    sleep 2
                fi
                ;;
            1)
                # Powering off is an ssh operation, so it resolves like any other: if the key
                # no longer works we get it back first. It must never *wake* a node in order
                # to shut it down, hence K_NOWAKE.
                clear
                if K_NOWAKE=1 k_resolve_tty "$t_mac" "$t_ip" "$t_name" "$t_user" "reaching $t_name" "$t_luks"; then
                    echo -e "\n${PINK}... flicking $t_name OFF - assuming state, polling network card ...${RESET}"
                    if api_toggle "$t_mac" "$t_ip" "$t_user" "off"; then
                        watch_confirm "$t_ip" "down"
                    else
                        echo -e "${PINK}[!] backend unreachable - direct SSH poweroff fallback ...${RESET}"
                        # No -t: the server has no TTY, same reason the backend omits it.
                        k_opts_batch "$SSH_KEY"
                        ssh "${K_OPTS[@]}" "$t_user@$t_ip" "sudo poweroff 2>/dev/null || poweroff"
                        echo -e "${WHITE}[*] power sequence initiated.${RESET}"
                        sleep 2
                    fi
                elif [ "$K_LAST_NOK" = "never woke" ]; then
                    # Still tell the backend: it may be mid confirming_up from an earlier
                    # wake, and this is how that gets cancelled.
                    api_toggle "$t_mac" "$t_ip" "$t_user" "off"
                    echo -e "\n${WHITE}[*] $t_name is already off.${RESET}"
                    sleep 2
                else
                    echo -e "\n${PINK}[!] could not reach $t_name - ${K_LAST_NOK}${RESET}"
                    echo -e "${GRAY}    fix: keys > ensure reachability${RESET}"
                    sleep 3
                fi
                ;;
        esac
    fi
}

remove_node() {
    local data=$(decrypt_blob | grep '[^[:space:]]')
    if [ -z "$data" ]; then return; fi

    local names=()
    while IFS=',' read -r mac ip name user subtitle luks favourite ord pretty; do
        # The favourite marker leads each row here too; interactive_menu renders it pink
        # and still keys the row off the first letter of the NAME, not the glyph.
        names+=("$(fav_mark "$favourite") $name")
    done <<< "$data"
    names+=("cancel")

    print_header "remove node"
    interactive_menu "${names[@]}"
    local choice=$?

    local target="${names[$choice]}"
    if [ "$target" != "cancel" ]; then
        # The marker was presentation for the pick; the confirmation talks about the NAME.
        target="${target#"★ "}"; target="${target#"  "}"
        # interactive_menu fires on the first matching letter, so in a fleet holding a node
        # whose name starts with c, `cancel` is rebound to [1] and the c keystroke meant to
        # back out selects that node instead. Every other menu in this tool is recoverable;
        # this one re-encrypts the database, so it asks before it does.
        print_header "remove $target?"
        echo -e "${WHITE}this deletes the record. the machine is untouched.${RESET}\n"
        interactive_menu "keep it" "remove it"
        [ $? -ne 1 ] && return
        # By POSITION, not by name. Matching on a name deletes every record carrying it, and
        # nothing enforces that names are unique - two machines called `pi-blocker` and removing
        # one takes the other with it. Matching as a substring was worse still: the sixth
        # field turned SUBTITLE into an interior field, so ",$target," also hit any node whose
        # subtitle happened to be this name, including the one being removed, which wrote the
        # blob back empty. The menu index IS the record index - `names` is built from `data`
        # in order - so the one record the user pointed at is the one that goes.
        # -v is not used for the index: awk -v processes escape sequences in its value, which
        # is also why the name is no longer passed that way.
        # Staged-and-renamed like remove_endpoint: this write rebuilds every record the user
        # never touched, and a death mid-encrypt through the bare writer could truncate the
        # whole node database. encrypt_atomic failing leaves the old blob intact, and saying
        # "removed" then would be a lie.
        #
        # Removal closes the shelf gap, and the shelf spans BOTH blobs: everything past the
        # node moves down one, standalone services included. Services that were grouped
        # under the removed node's ip become standalone; they land at the END of the shelf,
        # in the order they held inside their group, rather than colliding with the front.
        local removed_ip; IFS=',' read -r _ removed_ip _ <<< "$(printf '%s\n' "$data" | sed -n "$((choice + 1))p")"
        local ndata_new; ndata_new=$(printf '%s\n' "$data" | awk -F, "NR != $((choice + 1))")
        local sdata_now; sdata_now=$(decrypt_srv | grep '[^[:space:]]')
        local sdata_adj='' sline sip o
        if [ -n "$sdata_now" ]; then
            while IFS= read -r sline; do
                [ -z "$sline" ] && continue
                IFS=',' read -r _ sip _ <<< "$sline"
                if [ "$sip" = "$removed_ip" ] && ! ord_is_node_ip "$removed_ip" "$ndata_new"; then
                    o=$(rec_ord "$sline")
                    case "$o" in ''|*[!0-9]*) o=9999999 ;; esac
                    sline=$(rec_set_ord "$sline" $((o + 1000000)))
                fi
                sdata_adj+="$sline"$'\n'
            done <<< "$sdata_now"
            sdata_adj=${sdata_adj%$'\n'}
        fi
        ord_renumber "$ndata_new" "$sdata_adj"
        # The service blob commits FIRST and its failure aborts the removal before the node
        # blob is touched: the shelf is one permutation across both files, and a node blob
        # written after a failed service write would leave the pair disagreeing. Nothing has
        # been written at that point, so "nothing changed" is literally true.
        if [ "$ORD_SRV" != "$sdata_now" ] && \
           ! printf '%s\n' "$ORD_SRV" | grep '[^[:space:]]' | encrypt_atomic "$SRV_BLOB"; then
            echo -e "\n${WHITE}[!] write failed - nothing changed.${RESET}"
            sleep 2
            return
        fi
        if printf '%s\n' "$ORD_NODES" | grep '[^[:space:]]' | encrypt_atomic "$BLOB_FILE"; then
            echo -e "\n${WHITE}[*] removed $target.${RESET}"
        else
            # The second write is the one that failed, so the first may already have landed:
            # say so rather than claiming nothing moved. The node itself is still there.
            echo -e "\n${WHITE}[!] write failed - $target was NOT removed; the service shelf may already have been renumbered. run the removal again.${RESET}"
        fi
        sleep 1
    fi
}

# The pending record, rendered EXACTLY as the live nodes table renders a row: the same
# header, the same columns, the same paddings, through the same nodes_table_header/row pair
# - never a separate, more verbose format that could drift. The pending SHELF number leads
# beside the marker and updates live as order edits change, the way every other pending
# edit is watched. STATUS reads [ pending ]: reachability is a claim about a saved record,
# and this one is not saved yet. Nothing in here reads or writes the blob.
show_pending_node() {
    # args: name ip user fav ord pretty
    # Laid out over exactly the row it is about to print, so the preview runs the same
    # toggle + compaction pipeline the live table runs (a long pending pretty ellipsizes
    # here exactly as it would there).
    nodes_layout "x,$2,$1,x,x,0,${4:-0},${5:-0},${6:-}"
    nodes_table_header
    nodes_table_row "$4" "$5" "$1" "$2" "$3" "${6:-}" "$(node_status_fmt pending)"
}

# modify_node - edit one record through a PENDING copy. Picked by POSITION exactly as
# remove_node deletes: names are not unique, so the menu index IS the record index. The
# submenu loops: every edit lands on the pending copy alone and redraws the one-row preview
# above it - the blob is not touched until the explicit save, which commits every pending
# edit in ONE staged-and-renamed write (encrypt_atomic); cancel discards the lot and writes
# nothing. Only the chosen record is rebuilt on save; every other line goes back
# byte-identical, and the atomic writer means a death mid-encrypt can never truncate a
# database holding records this flow never touched.
modify_node() {
    local data=$(decrypt_blob | grep '[^[:space:]]')
    if [ -z "$data" ]; then
        echo -e "${WHITE}no nodes found.${RESET}"
        sleep 1; return
    fi

    local names=()
    local mac ip name user subtitle luks fav ord pretty
    while IFS=',' read -r mac ip name user subtitle luks fav ord pretty; do
        names+=("$(fav_mark "$fav") $name")
    done <<< "$data"
    names+=("cancel")

    print_header "modify node"
    interactive_menu "${names[@]}"
    local choice=$?
    [ "${names[$choice]}" = "cancel" ] && return

    local line; line=$(printf '%s\n' "$data" | sed -n "$((choice + 1))p")
    IFS=',' read -r mac ip name user subtitle luks fav ord pretty <<< "$line"

    # The pending copy. Every edit below lands here and nowhere else.
    local p_ip=$ip p_subtitle=$subtitle p_fav=$fav p_ord=$ord p_pretty=$pretty

    while :; do
        print_header "modify $name" ""
        show_pending_node "$name" "$p_ip" "$user" "$p_fav" "$p_ord" "$p_pretty"
        echo -e "\n${GRAY}pending - nothing is written until save; cancel discards every edit${RESET}"
        echo -e "${WHITE}use up/down arrows & enter${RESET}\n"
        # Bare labels, one hotkey each, no two sharing a first letter: a d f n o s c.
        # The pretty edit is labelled "nickname" for exactly that reason - "pretty" would
        # not collide here, but the tunnel submenu says nickname too ("pretty" fights
        # "port" there) and the two menus must not teach two names for one field.
        interactive_menu "address" "description" "favourite" "nickname" "order" "save" "cancel"
        case $? in
            0)
                local new_ip
                while :; do
                    ask_field "new ipv4 address" new_ip || return
                    valid_ipv4 "$new_ip" && break
                    echo -e "${WHITE}[!] not a dotted-quad address.${RESET}"
                done
                p_ip=$new_ip
                ;;
            1)
                ask_field "new subtitle (short description)" p_subtitle
                ;;
            2)
                # Curation, not security: 1 = shown to everyone, 0 = allumeur mode only.
                [ "$p_fav" = 1 ] && p_fav=0 || p_fav=1
                ;;
            3)
                # The guest-facing pretty name. Empty is an answer - "drop the alias" -
                # so unlike every other free-text edit it is not re-asked when blank.
                ask_field "nickname (guest-facing, enter = none)" p_pretty
                ;;
            4)
                # The node's SHELF position - the one sequence it shares with standalone
                # services. Clamped here for the preview; save clamps again against
                # whatever the shelf holds by then.
                local shelf_k
                shelf_k=$(ord_shelf_size "$data" "$(decrypt_srv | grep '[^[:space:]]')")
                p_ord=$(ask_order "shelf position (1-$shelf_k, enter keeps $p_ord)" "$shelf_k" "$p_ord")
                ;;
            5)
                # Save: the one commit of the whole flow. Rebuilt line by line with printf,
                # never awk -v or `echo -e` - both re-interpret escapes, and the untouched
                # records must go back exactly as they came out.
                local out='' i=0 rec
                while IFS= read -r rec; do
                    if [ "$i" -eq "$choice" ]; then
                        out+="$mac,$p_ip,$name,$user,$p_subtitle,$luks,$p_fav,$ord,$p_pretty"$'\n'
                    else
                        out+="$rec"$'\n'
                    fi
                    i=$((i + 1))
                done <<< "$data"
                out=${out%$'\n'}
                # The session edits a snapshot, and the pending loop makes sessions
                # arbitrarily long - long enough for another writer (a second TUI, the
                # subtitle helper) to have committed. Rebuilding from a stale snapshot
                # would silently revert that commit, so save re-reads and refuses to
                # clobber rather than guess at a merge.
                if [ "$(decrypt_blob | grep '[^[:space:]]')" != "$data" ]; then
                    echo -e "\n${WHITE}[!] database changed while you were editing - nothing written. re-open the record.${RESET}"
                    sleep 2
                    return
                fi
                # The shelf spans both blobs: placing this node can renumber standalone
                # services too. The service blob is read fresh and written FIRST - if that
                # write dies, nothing changed and the retry below is clean; the node blob
                # commits second, and a retry after ITS failure finds the service blob
                # already consistent and only rewrites the nodes.
                local sdata_now; sdata_now=$(decrypt_srv | grep '[^[:space:]]')
                ord_place_shelf "$out" "$sdata_now" n "$choice" "$p_ord"
                if [ "$ORD_SRV" != "$sdata_now" ]; then
                    if ! printf '%s\n' "$ORD_SRV" | grep '[^[:space:]]' | encrypt_atomic "$SRV_BLOB"; then
                        echo -e "\n${WHITE}[!] write failed - nothing changed. your edits are kept; save again or cancel.${RESET}"
                        sleep 2
                        continue
                    fi
                fi
                # Branch on the writer: encrypt_atomic failing (disk full at the tmp write,
                # say) leaves the old blob intact - atomicity holds - but saying "updated"
                # then would send the user away believing a change that was never written.
                # A failure the user never chose must not cost the pending edits either:
                # only cancel discards, so a failed save falls back into the loop to retry.
                if printf '%s\n' "$ORD_NODES" | grep '[^[:space:]]' | encrypt_atomic "$BLOB_FILE"; then
                    echo -e "\n${WHITE}[*] updated $name.${RESET}"
                    sleep 1
                    return
                fi
                echo -e "\n${WHITE}[!] write failed - nothing changed. your edits are kept; save again or cancel.${RESET}"
                sleep 2
                ;;
            *) return ;;
        esac
    done
}

list_nodes() {
    clear
    show_nodes_table
    echo -e "\n${PINK}[ press any key to return ]${RESET}"
    read -rsn1
}

# ── C3: toggle the OPTIONAL columns of the nodes table ───────────────────────
# NAME and STATUS always show; everything else is a preference, persisted plainly in
# ~/.allumeur-scripts/.tui-fields (lib.sh). Each toggle saves immediately - a preference
# is not a database edit and needs no pending model. "back" leads the menu so a bare
# enter (or EOF, which interactive_menu answers as enter) leaves instead of toggling -
# hotkeys stay distinct: b i u o f p.
nodes_fields_menu() {
    local c
    while :; do
        tui_fields_load
        print_header "fields on tables : nodes"
        interactive_menu "back" \
            "ip: $(tui_onoff "$TF_NODES_IP")" \
            "user: $(tui_onoff "$TF_NODES_USER")" \
            "order: $(tui_onoff "$TF_NODES_ORD")" \
            "favourite marker: $(tui_onoff "$TF_NODES_FAV")" \
            "pretty: $(tui_onoff "$TF_NODES_PRETTY")"
        c=$?
        case $c in
            1) TF_NODES_IP=$(tui_flip "$TF_NODES_IP") ;;
            2) TF_NODES_USER=$(tui_flip "$TF_NODES_USER") ;;
            3) TF_NODES_ORD=$(tui_flip "$TF_NODES_ORD") ;;
            4) TF_NODES_FAV=$(tui_flip "$TF_NODES_FAV") ;;
            5) TF_NODES_PRETTY=$(tui_flip "$TF_NODES_PRETTY") ;;
            *) return ;;
        esac
        tui_fields_save
    done
}

main() {
    trap "tput cnorm; exit" INT TERM
    mint_master_key_if_missing

    while true; do
        clear
        show_nodes_table
        echo ""
        echo -e "${PINK}*~ ${WHITE}${BOLD}nodes manager${PINK} ~*${RESET}"
        echo -e "${WHITE}use up/down arrows & enter${RESET}\n"

        opts=("ssh to node" "hit lights" "keys" "add node" "modify node" "remove node" "list nodes" "fields on tables" "update view" "exit")
        interactive_menu "${opts[@]}"
        case $? in
            0) enter_shell ;;
            1) hit_lights ;;
            2) keys_menu ;;
            3) add_node ;;
            4) modify_node ;;
            5) remove_node ;;
            6) list_nodes ;;
            7) nodes_fields_menu ;;
            8) continue ;;
            9) clear; exit 0 ;;
        esac
    done
}

# Sourcing this file (the test suite does) must not launch the menu. `if`, not `&&`, or
# sourcing it would return 1.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
