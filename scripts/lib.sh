#!/bin/bash
# Colors & Aesthetic
PINK="\e[38;5;218m"
WHITE="\e[97m"
GRAY="\e[38;5;245m"
BOLD="\e[1m"
RESET="\e[0m"

# Crypto Functions
KEY_FILE="$HOME/.allumeur-scripts/encrypted/.root_key"
BLOB_FILE="$HOME/.allumeur-scripts/encrypted/usr_blob.enc"
# The service blob lives here too: ordering spans BOTH databases (see "the shelf" below),
# so nodes.sh has to read services and tunnel.sh has to read nodes.
SRV_BLOB="$HOME/.allumeur-scripts/encrypted/srv_blob.enc"

decrypt_blob() {
    openssl enc -aes-256-cbc -d -salt -pbkdf2 -pass file:"$KEY_FILE" -in "$BLOB_FILE" 2>/dev/null
}

decrypt_srv() {
    openssl enc -aes-256-cbc -d -salt -pbkdf2 -pass file:"$KEY_FILE" -in "$SRV_BLOB" 2>/dev/null
}

encrypt_blob() {
    openssl enc -aes-256-cbc -salt -pbkdf2 -pass file:"$KEY_FILE" -out "$BLOB_FILE"
}

# encrypt_atomic <blob-file> - encrypt stdin into "<blob-file>.tmp" and rename() it over the
# live blob. encrypt_blob opens its target with O_TRUNC, so a death mid-write leaves the
# database half a record long. The add flows keep the plain writer - their failure mode was
# always "nothing saved" - but the modify flows rewrite records that already exist, and a
# torn write there destroys data the user did not touch. They all come through here.
encrypt_atomic() {
    openssl enc -aes-256-cbc -salt -pbkdf2 -pass file:"$KEY_FILE" -out "$1.tmp" \
        && mv -f "$1.tmp" "$1" \
        || { rm -f "$1.tmp"; return 1; }
}

# fav_mark <flag> - the one-character favourite column every list view leads with: a star
# for guests-visible (favourite=1), a plain SPACE for allumeur-only, so absence reads as
# indentation ("★ name" vs "  name") - a very small field with a big consequence. One char
# plus one space is the whole cost, so adding it left every table's width where it was
# (see the measured widths on nodes_table_header / srv_table_header). Rendered pink by
# whoever prints it.
fav_mark() { [ "$1" = 1 ] && printf '★' || printf ' '; }

# fit_cell <string> <width> [glyph] - emit exactly <width> cells: truncate overlong values
# with a trailing ~ (or the given one-char glyph - the pretty column truncates with …), pad
# short ones with spaces. Both halves of that matter for a table:
#   * printf's %-Ns pads by BYTES, so a name carrying a multi-byte glyph ("Sparkle CI ✨" is
#     12 characters in 14 bytes) gets two cells fewer than its ASCII siblings and every
#     column after it slides left. Counting characters under a UTF-8 locale fixes that.
#   * %-Ns never truncates either, so one long name pushes NAME/IP/USER/STATUS right and the
#     table loses its grid. Truncating here keeps the columns absolute.
# Every padded cell in both tables goes through this, so the tables and the modify previews
# that reuse them cannot drift apart.
fit_cell() {
    local LC_ALL=C.UTF-8 s="$1" n="$2" g="${3:-~}"
    [ "${#s}" -gt "$n" ] && s="${s:0:$((n - 1))}$g"
    printf '%s%*s' "$s" "$((n - ${#s}))" ''
}

# table_rule <header-line> - a separator exactly as wide as the header it sits under, so the
# rule can never overhang when a column width changes (it used to be a hardcoded 55).
table_rule() {
    local LC_ALL=C.UTF-8
    printf '%*s' "${#1}" '' | tr ' ' '-'
}

# ── C3: which OPTIONAL columns the TUI tables show ───────────────────────────
# Plain preferences, deliberately OUTSIDE the encrypted dir: which columns a table shows is
# not a secret, and the tables must render before (and whether or not) a key is in hand.
# Absence of the file - or junk inside it - means the defaults, which are EXACTLY the v10
# column set: everything on except the new pretty column. One key=0|1 line per toggle.
TUI_FIELDS_FILE="$HOME/.allumeur-scripts/.tui-fields"

tui_fields_load() {
    TF_NODES_IP=1 TF_NODES_USER=1 TF_NODES_ORD=1 TF_NODES_FAV=1 TF_NODES_PRETTY=0
    TF_SRV_TARGET=1 TF_SRV_ORD=1 TF_SRV_FAV=1 TF_SRV_PRETTY=0
    [ -f "$TUI_FIELDS_FILE" ] || return 0
    local k v
    while IFS='=' read -r k v; do
        case "$v" in 0|1) ;; *) continue ;; esac
        case "$k" in
            nodes.ip)        TF_NODES_IP=$v ;;
            nodes.user)      TF_NODES_USER=$v ;;
            nodes.order)     TF_NODES_ORD=$v ;;
            nodes.favourite) TF_NODES_FAV=$v ;;
            nodes.pretty)    TF_NODES_PRETTY=$v ;;
            srv.target)      TF_SRV_TARGET=$v ;;
            srv.order)       TF_SRV_ORD=$v ;;
            srv.favourite)   TF_SRV_FAV=$v ;;
            srv.pretty)      TF_SRV_PRETTY=$v ;;
        esac
    done < "$TUI_FIELDS_FILE"
    return 0
}

tui_fields_save() {
    mkdir -p "${TUI_FIELDS_FILE%/*}"
    {
        echo "nodes.ip=$TF_NODES_IP"
        echo "nodes.user=$TF_NODES_USER"
        echo "nodes.order=$TF_NODES_ORD"
        echo "nodes.favourite=$TF_NODES_FAV"
        echo "nodes.pretty=$TF_NODES_PRETTY"
        echo "srv.target=$TF_SRV_TARGET"
        echo "srv.order=$TF_SRV_ORD"
        echo "srv.favourite=$TF_SRV_FAV"
        echo "srv.pretty=$TF_SRV_PRETTY"
    } > "$TUI_FIELDS_FILE"
}

tui_onoff() { [ "$1" = 1 ] && printf 'shown' || printf 'hidden'; }
tui_flip()  { [ "$1" = 1 ] && echo 0 || echo 1; }

# ── C4: the global width budget + the loss-ordered compaction pipeline ───────
# TUI_MAX is measured, not chosen: the v10 tunnel table row - the widest fixed row this TUI
# printed - is marker(1)+sp + '#'(2)+sp + 'i'(2)+sp + name(18)+sp + target(21)+sp +
# "[ inactive ]"(12) = 61 cells; plus 5 slack = 66. No rendered table row may exceed it.
# When a layout (whatever columns are toggled on, however long the displayed values run)
# would, the per-table layout functions apply compactions in LOSS ORDER, each rung only as
# far as needed, the next only if the previous was not enough:
#   1. STATUS abbreviation - pure notation, nothing is lost:
#        "[ inactive ]" -> "[   ]"      "[ active ]"/"[ active xN ]" -> "[ ▪ ]"/"[ ▪N ]"
#        "[ up ]" -> "[ ▪ ]"            "[ down ]"     -> "[   ]"
#        "[ ~ up ~ ]" -> "[ ~▪ ]"       "[ ~ down ~ ]" -> "[ ~ ]"
#        "[ pending ]" -> "[ ? ]"
#      (a filled square ▪ = powered/reachable - NOT the favourite star; blank = dark;
#       a leading ~ = still confirming; ? = not saved yet. The " luks" suffix survives.)
#   2. PRETTY truncation - the column shrinks to the previous tab stop (multiples of 8,
#      floor 8), values keep their first chars + "…".
#   3. NAME truncation - same tab-stop shrink; fit_cell's ~ marks the cut, as it always has.
#   4. ADDRESS handling - if ALL displayed targets share a dotted prefix ending on an
#      octet/label boundary, it folds to "::" with a one-line legend under the table
#      (":: = 192.0.2"); only then, plain tab-stop truncation of the target column.
# The modify previews render through the same layout functions, so they inherit the whole
# pipeline for free.
TUI_MAX=66

# prev_tab_stop <w> - the previous tab stop: the largest multiple of 8 strictly below <w>,
# never below the floor of 8.
prev_tab_stop() {
    local s=$(( ($1 - 1) / 8 * 8 ))
    [ "$s" -lt 8 ] && s=8
    echo "$s"
}

# _fold_prefix <target>... - the longest prefix shared by EVERY target that ends at a dot
# (an octet/label boundary - never mid-octet: 192.0.2x vs 192.0.25 folds to 192.0,
# not to a truncated octet). Empty when there is nothing worth folding (a one-char prefix
# saves nothing once "::" replaces it).
_fold_prefix() {
    [ $# -ge 1 ] || { echo ""; return; }
    local lcp="$1" t i
    shift
    for t in "$@"; do
        i=0
        while [ "$i" -lt "${#lcp}" ] && [ "$i" -lt "${#t}" ] \
              && [ "${lcp:$i:1}" = "${t:$i:1}" ]; do i=$((i + 1)); done
        lcp=${lcp:0:$i}
        [ -z "$lcp" ] && break
    done
    case "$lcp" in *.*) ;; *) echo ""; return ;; esac
    local pfx=${lcp%.*}
    [ "${#pfx}" -ge 2 ] && echo "$pfx" || echo ""
}

# valid_ipv4 <addr> - a dotted quad, each octet 0-255. The modify flows validate a new
# address before it is written: a typo'd address in the blob is a node the ladder wakes
# blind, and nothing downstream would ever say why.
valid_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done
}

# ── the v11 record tail: ...,order,pretty ────────────────────────────────────
# v11 appends PRETTY - the guest-facing display name - as every record's LAST field
# (nodes: mac,ip,name,user,subtitle,luks,favourite,order,pretty - nine fields; services:
# name,ip,port,subtitle,favourite,order,pretty - seven). The ORDER therefore rides
# PENULTIMATE now, and these two helpers are the only sanctioned way to touch it: every
# `${line##*,}` that used to mean "the order" would silently read the pretty instead.
# pretty may be empty (guest mode then falls back to the real name); commas stay forbidden
# in every field - the record is unquoted CSV.

# rec_ord <line> - the record's order field (penultimate).
rec_ord() { local t=${1%,*}; printf '%s\n' "${t##*,}"; }

# rec_set_ord <line> <ord> - the same record with only its order replaced; the pretty
# behind it (empty included) goes back byte-identical.
rec_set_ord() {
    local pretty=${1##*,} head=${1%,*}
    head=${head%,*}
    printf '%s\n' "$head,$2,$pretty"
}

# ── the shelf: one ordering across both databases ────────────────────────────
# v10 (kept whole in v11): every record's order is its ORDER FIELD (penultimate since
# pretty landed behind it). A service belongs to a node's group iff its
# address field EXACTLY string-equals that node's ip (fqdn or ip - whatever string is
# stored); otherwise it is standalone. node.order = its position in ONE global shelf shared
# by nodes AND standalone services (a permutation 1..K across BOTH blobs); a matched
# service.order = its position inside its node's group (1..k per group); a standalone
# service.order = its shelf position. The TUI tables and the website sort by exactly this.
#
# The engine below edits order fields only - record bytes and blob line order are never
# touched, so position-picked menus stay valid. Results come back in ORD_NODES / ORD_SRV.

# clamp_order <asked> <max> - a shelf/group position, clamped to [1..max]. Negatives clamp
# to the front; anything that is not a number at all (junk, empty) clamps to max, which is
# where callers put "the end".
clamp_order() {
    local asked="$1" max="$2"
    case "$max" in ''|*[!0-9]*) max=1 ;; esac
    [ "$max" -ge 1 ] || max=1
    if [[ "$asked" =~ ^-[0-9]+$ ]]; then echo 1; return; fi
    if [[ "$asked" =~ ^[0-9]+$ ]]; then
        [ "${#asked}" -gt 9 ] && asked=999999999
        if [ "$asked" -lt 1 ]; then echo 1
        elif [ "$asked" -gt "$max" ]; then echo "$max"
        else echo "$asked"; fi
        return
    fi
    echo "$max"
}

# ask_order <prompt> <max> [<default>] - read one position from stdin. Digits (a leading
# minus included: a negative is still a number, and clamps to the front) are clamped to
# [1..max]; an empty line, EOF, or a NON-NUMBER takes <default> (max - "the end" - when no
# default is given) - the digit guard here is what makes the prompt's promise true: in
# modify the default is keep-current, and junk must keep the current position, not be
# clamped to the end. Never re-asks: an order is a preference, not a credential.
ask_order() {
    local ans
    echo -ne "${PINK}$1: ${WHITE}" >&2
    IFS= read -r ans || true
    echo -ne "${RESET}" >&2
    # A real integer test, not a character-class glob: a glob that merely allows '-' inside
    # the set lets "-", "2-3", "5-3", "1-" and "--" through to clamp_order, which matches
    # neither of its two number shapes and so returns max - the END. In modify that silently
    # sends the record to the end of the shelf when the user typed a range, which is exactly
    # the failure the default-taking guard exists to prevent. Only ^-?[0-9]+$ is a number:
    # "-5" still clamps to the front, everything else takes the default.
    if [[ "$ans" =~ ^-?[0-9]+$ ]]; then
        clamp_order "$ans" "$2"
    else
        echo "${3:-$2}"
    fi
}

# A junk or missing order sorts to the END of its scope (the backend's parse_order sends it
# to the front instead, but the repair below renumbers it before the backend ever sees one).
_ord_num() { case "$1" in ''|*[!0-9]*) echo 9999999999 ;; *) echo "$(( 10#${1:0:10} ))" ;; esac; }

# ord_is_node_ip <addr> <ndata> - is this exact string some node's ip?
ord_is_node_ip() {
    local l ip
    [ -n "$2" ] || return 1
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        IFS=',' read -r _ ip _ <<< "$l"
        [ "$ip" = "$1" ] && return 0
    done <<< "$2"
    return 1
}

# ord_group_size <sdata> <addr> - how many services carry exactly this address.
ord_group_size() {
    local l ip c=0
    [ -n "$1" ] || { echo 0; return; }
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        IFS=',' read -r _ ip _ <<< "$l"
        [ "$ip" = "$2" ] && c=$((c + 1))
    done <<< "$1"
    echo "$c"
}

# ord_node_pos <ndata> <ip> - the first matching node's order field.
ord_node_pos() {
    local l ip
    [ -n "$1" ] || return 1
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        IFS=',' read -r _ ip _ <<< "$l"
        [ "$ip" = "$2" ] && { rec_ord "$l"; return 0; }
    done <<< "$1"
    return 1
}

# ord_node_idx <ndata> <ip> - the first matching node's 0-based line index.
ord_node_idx() {
    local l ip i=0
    [ -n "$1" ] || return 1
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        IFS=',' read -r _ ip _ <<< "$l"
        [ "$ip" = "$2" ] && { echo "$i"; return 0; }
        i=$((i + 1))
    done <<< "$1"
    return 1
}

# Internal parse state: node lines, service lines, and per-service matched flags.
_ord_load() {
    _ON=(); _OS=(); _OSM=()
    local line i ip
    if [ -n "$1" ]; then
        while IFS= read -r line; do [ -n "$line" ] && _ON+=("$line"); done <<< "$1"
    fi
    if [ -n "$2" ]; then
        while IFS= read -r line; do [ -n "$line" ] && _OS+=("$line"); done <<< "$2"
    fi
    for i in "${!_OS[@]}"; do
        IFS=',' read -r _ ip _ <<< "${_OS[$i]}"
        _OSM[$i]=0
        local l nip
        for l in ${_ON[@]+"${_ON[@]}"}; do
            IFS=',' read -r _ nip _ <<< "$l"
            [ "$nip" = "$ip" ] && { _OSM[$i]=1; break; }
        done
    done
}

_ord_set() {
    local i=${1:1}
    case "$1" in
        n*) _ON[$i]=$(rec_set_ord "${_ON[$i]}" "$2") ;;
        s*) _OS[$i]=$(rec_set_ord "${_OS[$i]}" "$2") ;;
    esac
}

_ord_emit() {
    if [ ${#_ON[@]} -gt 0 ]; then ORD_NODES=$(printf '%s\n' "${_ON[@]}"); else ORD_NODES=""; fi
    if [ ${#_OS[@]} -gt 0 ]; then ORD_SRV=$(printf '%s\n' "${_OS[@]}"); else ORD_SRV=""; fi
}

# Renumber every scope into a clean permutation: the shelf (all nodes + standalone
# services, across BOTH blobs) becomes 1..K sorted by current order (ties and junk: nodes
# first, then file order); each group becomes 1..k the same way. Idempotent on valid data,
# which is what lets every save run through here as a repair pass.
_ord_renumber_arrays() {
    local keys="" i o pos tag
    for i in ${_ON[@]+"${!_ON[@]}"}; do
        keys+=$(printf '%010d 0 %05d n%d' "$(_ord_num "$(rec_ord "${_ON[$i]}")")" "$i" "$i")$'\n'
    done
    for i in ${_OS[@]+"${!_OS[@]}"}; do
        [ "${_OSM[$i]}" = 1 ] && continue
        keys+=$(printf '%010d 1 %05d s%d' "$(_ord_num "$(rec_ord "${_OS[$i]}")")" "$i" "$i")$'\n'
    done
    pos=0
    while read -r _ _ _ tag; do
        [ -z "$tag" ] && continue
        pos=$((pos + 1))
        _ord_set "$tag" "$pos"
    done <<< "$(printf '%s' "$keys" | LC_ALL=C sort)"

    local gips=$'\n' ip
    for i in ${_OS[@]+"${!_OS[@]}"}; do
        [ "${_OSM[$i]}" = 1 ] || continue
        IFS=',' read -r _ ip _ <<< "${_OS[$i]}"
        case "$gips" in *$'\n'"$ip"$'\n'*) continue ;; esac
        gips+="$ip"$'\n'
        _ord_group_renumber "$ip"
    done
}

_ord_group_renumber() {
    local keys="" i sip pos
    for i in ${_OS[@]+"${!_OS[@]}"}; do
        [ "${_OSM[$i]}" = 1 ] || continue
        IFS=',' read -r _ sip _ <<< "${_OS[$i]}"
        [ "$sip" = "$1" ] || continue
        keys+=$(printf '%010d %05d %d' "$(_ord_num "$(rec_ord "${_OS[$i]}")")" "$i" "$i")$'\n'
    done
    pos=0
    while read -r _ _ i; do
        [ -z "$i" ] && continue
        pos=$((pos + 1))
        _OS[$i]=$(rec_set_ord "${_OS[$i]}" "$pos")
    done <<< "$(printf '%s' "$keys" | LC_ALL=C sort)"
}

# ord_renumber <ndata> <sdata> - the plain repair pass: close gaps, fix every scope.
# The one every removal needs - deleting a record and renumbering IS closing its gap.
ord_renumber() {
    _ord_load "$1" "$2"
    _ord_renumber_arrays
    _ord_emit
}

# ord_shelf_size <ndata> <sdata> - nodes + standalone services.
ord_shelf_size() {
    _ord_load "$1" "$2"
    local c=${#_ON[@]} i
    for i in ${_OS[@]+"${!_OS[@]}"}; do [ "${_OSM[$i]}" = 0 ] && c=$((c + 1)); done
    echo "$c"
}

# ord_place_shelf <ndata> <sdata> <n|s> <idx> <asked> - put one record (a node, or a
# STANDALONE service, already present in its data at line <idx>) at shelf position <asked>:
# the shelf without it is numbered 1..M, <asked> is clamped to [1..M+1], everything at or
# past the slot shifts up one, and a renumber pass closes whatever scope it left. Both a
# move and an add are this operation - an add is simply placing the line just appended.
ord_place_shelf() {
    _ord_load "$1" "$2"
    local kind=$3 idx=$4 asked=$5
    local keys="" i m=0 pos tag t p
    for i in ${_ON[@]+"${!_ON[@]}"}; do
        [ "$kind" = n ] && [ "$i" = "$idx" ] && continue
        keys+=$(printf '%010d 0 %05d n%d' "$(_ord_num "$(rec_ord "${_ON[$i]}")")" "$i" "$i")$'\n'
        m=$((m + 1))
    done
    for i in ${_OS[@]+"${!_OS[@]}"}; do
        [ "${_OSM[$i]}" = 1 ] && continue
        [ "$kind" = s ] && [ "$i" = "$idx" ] && continue
        keys+=$(printf '%010d 1 %05d s%d' "$(_ord_num "$(rec_ord "${_OS[$i]}")")" "$i" "$i")$'\n'
        m=$((m + 1))
    done
    p=$(clamp_order "$asked" $((m + 1)))
    pos=0
    while read -r _ _ _ tag; do
        [ -z "$tag" ] && continue
        pos=$((pos + 1)); t=$pos
        [ "$t" -ge "$p" ] && t=$((t + 1))
        _ord_set "$tag" "$t"
    done <<< "$(printf '%s' "$keys" | LC_ALL=C sort)"
    _ord_set "$kind$idx" "$p"
    _ord_renumber_arrays
    _ord_emit
}

# ord_place_group <ndata> <sdata> <idx> <asked> - put service line <idx> (whose address
# matches a node) at position <asked> INSIDE its group, same clamp-shift-renumber contract
# as the shelf. If the service just joined this group, the shelf slot it left closes.
ord_place_group() {
    _ord_load "$1" "$2"
    local idx=$3 asked=$4
    local gip keys="" i sip m=0 pos t p
    IFS=',' read -r _ gip _ <<< "${_OS[$idx]}"
    for i in ${_OS[@]+"${!_OS[@]}"}; do
        [ "$i" = "$idx" ] && continue
        IFS=',' read -r _ sip _ <<< "${_OS[$i]}"
        [ "$sip" = "$gip" ] || continue
        keys+=$(printf '%010d %05d %d' "$(_ord_num "$(rec_ord "${_OS[$i]}")")" "$i" "$i")$'\n'
        m=$((m + 1))
    done
    p=$(clamp_order "$asked" $((m + 1)))
    pos=0
    while read -r _ _ i; do
        [ -z "$i" ] && continue
        pos=$((pos + 1)); t=$pos
        [ "$t" -ge "$p" ] && t=$((t + 1))
        _OS[$i]=$(rec_set_ord "${_OS[$i]}" "$t")
    done <<< "$(printf '%s' "$keys" | LC_ALL=C sort)"
    _OS[$idx]=$(rec_set_ord "${_OS[$idx]}" "$p")
    _ord_renumber_arrays
    _ord_emit
}


# ── unique addressing for every menu / pick-list ─────────────────────────────
# menu_assign_addresses <label>... - THE one assigner of hotkey addresses; every
# interactive_menu (and with it every pick-list this suite renders) routes through here.
# Each option gets a unique single-keystroke address: its first letter (case-folded; a
# leading "★ "/"  " favourite marker is presentation, not name) when no earlier option
# took it, otherwise the lowest FREE fallback key - digits 1-9 then 0, and only past ten
# collisions the free letters - tagged into the displayed label as "[k] ". The old inline
# scheme stamped '0' twice once the digits ran dry; scanning one pool of 36 keys instead
# means every option consumes at most one of them, so any list of up to 36 options is
# GUARANTEED uniquely addressable - more than any menu this TUI can ask about. Results:
#   MENU_OPTS[] - the labels as addressed ("[1] jellyseerr" for fallback-addressed rows)
#   MENU_KEYS[] - the address (keystroke) per option, parallel to MENU_OPTS
menu_assign_addresses() {
    MENU_OPTS=(); MENU_KEYS=()
    local pool="1234567890abcdefghijklmnopqrstuvwxyz"
    local opt key_src first lower used="" fb i
    for opt in "$@"; do
        key_src="$opt"
        case "$key_src" in
            "★ "*) key_src="${key_src#"★ "}" ;;
            "  "*) key_src="${key_src#"  "}" ;;
        esac
        first="${key_src:0:1}"
        lower="${first,,}"
        if [ -n "$lower" ] && [[ "$used" != *"$lower"* ]]; then
            used+="$lower"
            MENU_OPTS+=("$opt")
            MENU_KEYS+=("$lower")
        else
            fb=""
            for ((i = 0; i < ${#pool}; i++)); do
                case "$used" in *"${pool:$i:1}"*) ;; *) fb="${pool:$i:1}"; break ;; esac
            done
            # Past 36 options the single-keystroke space is spent - mathematically no
            # scheme could go on. Keep the old last resort rather than crash the menu.
            [ -n "$fb" ] || fb=0
            used+="$fb"
            MENU_OPTS+=("[$fb] $opt")
            MENU_KEYS+=("$fb")
        fi
    done
}

# menu_addr_paint <addressed-label> [<restore-sgr>] [<key>] - the label with its
# addressing token painted the suite's pink (the star's) AT RENDER TIME: a "[k] "
# fallback tag paints the whole bracket block ("<pink>[1]<reset> jellyseerr"), a
# letter-addressed label paints its addressed first letter in place
# ("<pink>j<reset>ellyfin"). <restore-sgr> re-establishes the caller's row color behind
# the token's RESET. A leading "[k] " counts as a tag only when k IS the row's assigned
# <key> - a label that merely looks like one (a name literally starting "[2] ") is
# letter-addressed on its real first character, so the paint can never point at a
# keystroke the menu would not honour. Only the echoed frame carries these bytes -
# stored labels, comparisons and hotkey matching never see them.
menu_addr_paint() {
    local l="$1" r="${2:-}" k="${3:-}"
    case "$l" in
        "["[0-9a-z]"] "*)
            if [ -z "$k" ] || [ "${l:1:1}" = "$k" ]; then
                printf '%s' "${PINK}${l:0:3}${RESET}${r}${l:3}"
                return
            fi ;;
    esac
    case "$l" in
        ?*) printf '%s' "${PINK}${l:0:1}${RESET}${r}${l:1}" ;;
        *)  printf '%s' "$l" ;;
    esac
}

# fold_legend <prefix> - the rung-4 legend line under a folded table (":: = <prefix>").
# Printed in the SAME pink as the table furniture (header and rule): the fold is the
# target column's representation, so its legend must read as part of the table, not as a
# gray aside beneath it.
fold_legend() { echo -e "${PINK}:: = $1${RESET}"; }

# UI Function (keystroke collisions auto-resolve via the lib assigner above)
interactive_menu() {
    menu_assign_addresses "$@"
    local options=(${MENU_OPTS[@]+"${MENU_OPTS[@]}"})
    local keys=(${MENU_KEYS[@]+"${MENU_KEYS[@]}"})

    local selected=0
    tput civis
    while true; do
        for i in "${!options[@]}"; do
            # Pull a favourite marker out of the row (past any "[k] " collision tag) and
            # render it pink in a column of its own, leftmost, so the labels behind the
            # markers stay aligned with each other whatever the selection state.
            local disp="${options[$i]}" mark="" tag=""
            case "$disp" in "["[0-9a-z]"] "*)
                [ "${disp:1:1}" = "${keys[$i]}" ] && { tag="${disp:0:4}"; disp="${disp#"$tag"}"; } ;;
            esac
            case "$disp" in
                "★ "*) mark="${PINK}★${RESET} "; disp="${disp#"★ "}" ;;
                "  "*) mark="  "; disp="${disp#"  "}" ;;
            esac
            disp="$tag$disp"
            # The addressing token paints pink at render time only (menu_addr_paint): the
            # escape bytes live in this frame alone, never in options[]/keys[] - so the
            # hotkey matching below and every caller's label comparison stay byte-clean.
            if [[ $i -eq $selected ]]; then
                echo -e "${PINK}${BOLD}  > ${RESET}${mark}${PINK}${BOLD}$(menu_addr_paint "$disp" "${PINK}${BOLD}" "${keys[$i]}")${RESET}"
            else
                echo -e "${WHITE}    ${RESET}${mark}${WHITE}$(menu_addr_paint "$disp" "${WHITE}" "${keys[$i]}")${RESET}"
            fi
        done
        
        # On EOF read leaves key empty, which the "" branch below treats exactly like
        # Enter: the menu accepts the current (default) selection and exits. Scripted
        # drives and the tests rely on that - EOF here is an answer, not a hang.
        read -rsn1 key
        case "$key" in
            $'\e')
                read -rsn2 -t 0.1 key2
                if [[ "$key2" == "[A" ]]; then
                    ((selected--))
                    if [[ $selected -lt 0 ]]; then selected=$((${#options[@]} - 1)); fi
                elif [[ "$key2" == "[B" ]]; then
                    ((selected++))
                    if [[ $selected -ge ${#options[@]} ]]; then selected=0; fi
                fi
                ;;
            "") 
                break 
                ;;
            *)
                # Jump and execute immediately mapping to the unique keys array
                local lower_key="${key,,}"
                for i in "${!keys[@]}"; do
                    if [[ "${keys[$i]}" == "$lower_key" ]]; then
                        selected=$i
                        break 2 
                    fi
                done
                ;;
        esac
        tput cuu ${#options[@]}
    done
    tput cnorm
    return $selected
}

print_header() {
    clear
    echo -e "${PINK}*~ ${WHITE}${BOLD}$1${PINK} ~*${RESET}"
    # The hint is about a menu. A screen that only informs passes "" rather than telling the
    # reader to press arrows at a page with nothing on it to select.
    [ "${2-unset}" = "" ] && { echo ""; return; }
    echo -e "${WHITE}${2:-use up/down arrows & enter}${RESET}\n"
}
