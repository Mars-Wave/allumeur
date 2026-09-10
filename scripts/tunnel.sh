#!/bin/bash
source "$HOME/.allumeur-scripts/lib.sh"
trap "tput cnorm; exit" INT TERM

CLOUDFLARED_BIN="$HOME/.allumeur-scripts/binaries/cloudflared"
SRV_BLOB="$HOME/.allumeur-scripts/encrypted/srv_blob.enc"

# Runtime registry: one *.meta file per LIVE tunnel. This lets a single endpoint hold
# several tunnels at once (any mix of cloudflare quick-tunnels and tailscale funnels),
# each rendered on its own line under the endpoint - the way the old view showed one CF url.
RUNDIR="/tmp/allumeur_tunnels"
mkdir -p "$RUNDIR"

if [ ! -f "$SRV_BLOB" ]; then
    echo "" | openssl enc -aes-256-cbc -salt -pbkdf2 -pass file:"$KEY_FILE" > "$SRV_BLOB"
fi

decrypt_srv() {
    openssl enc -aes-256-cbc -d -salt -pbkdf2 -pass file:"$KEY_FILE" -in "$SRV_BLOB" 2>/dev/null
}

encrypt_srv() {
    openssl enc -aes-256-cbc -salt -pbkdf2 -pass file:"$KEY_FILE" -out "$SRV_BLOB"
}

# ── registry helpers ─────────────────────────────────────────────────────────
_now() { date +%s; }
_new_id() { echo "$(date +%s)_$$_${RANDOM}"; }

# Tailscale funnel exposes on https://<magicdns>[:port]/. Port 443 needs no suffix.
_ts_dns() { tailscale status --json 2>/dev/null | jq -r '.Self.DNSName' 2>/dev/null | sed 's/\.$//'; }

# Does this endpoint speak TLS? Both providers have to be told, and getting it wrong is
# silent: point either at http:// when the service terminates TLS itself and the tunnel comes
# up, reports healthy, prints a URL - and every visitor gets an error page, with nothing
# anywhere saying why. Allumeur is that service: it binds :443 and does its own TLS with a
# self-signed cert. Every other endpoint in the blob is plain HTTP. Probed, not special-cased
# on port 443, because what decides this is what the service speaks, not where it listens.
_svc_tls() { curl -sk -o /dev/null --max-time 3 "https://${1}:${2}/" 2>/dev/null; }

_write_meta() {
    # $1 metafile  provider ip port label exp pid url logfile fport
    local m="$1"
    cat > "$m" <<EOF
provider="$2"
ip="$3"
port="$4"
label="$5"
exp="$6"
pid="$7"
url="$8"
logfile="$9"
fport="${10}"
EOF
}
_set_meta_url() { sed -i "s|^url=.*|url=\"$2\"|" "$1" 2>/dev/null; }

# alive = not past expiry, and (for cloudflare) its process still exists.
_meta_alive() {
    local provider ip port label exp pid url logfile fport
    source "$1" 2>/dev/null || return 1
    [ -z "$exp" ] && return 1
    [ "$(_now)" -ge "$exp" ] && return 1
    if [ "$provider" = "cloudflare" ]; then
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    fi
    return 0
}

# Reap anything expired/dead: tear down the leftover funnel/process, drop the meta.
_prune_tunnels() {
    shopt -s nullglob
    local m
    for m in "$RUNDIR"/*.meta; do
        if ! _meta_alive "$m"; then
            local provider ip port label exp pid url logfile fport
            provider=""; pid=""; logfile=""; fport=""
            source "$m" 2>/dev/null
            if [ "$provider" = "cloudflare" ]; then
                [ -n "$pid" ] && kill "$pid" 2>/dev/null
                [ -n "$logfile" ] && rm -f "$logfile"
            elif [ "$provider" = "tailscale" ]; then
                [ -n "$fport" ] && tailscale funnel --https="$fport" off >/dev/null 2>&1
            fi
            rm -f "$m"
        fi
    done
    shopt -u nullglob
}

# First of the three funnel-capable ports (443/8443/10000) not already in use by us.
_ts_free_port() {
    local used=" " m
    shopt -s nullglob
    for m in "$RUNDIR"/*.meta; do
        ( local provider fport; provider=""; fport=""; source "$m" 2>/dev/null
          [ "$provider" = "tailscale" ] && echo "$fport" )
    done > /tmp/.allumeur_used_ports.$$ 2>/dev/null
    shopt -u nullglob
    used=" $(tr '\n' ' ' < /tmp/.allumeur_used_ports.$$ 2>/dev/null) "
    rm -f /tmp/.allumeur_used_ports.$$
    local p
    for p in 443 8443 10000; do
        [[ "$used" != *" $p "* ]] && { echo "$p"; return; }
    done
    echo ""
}

_time_left() {
    local exp="$1" now left h m s
    now=$(_now); left=$((exp - now))
    if [ "$left" -le 0 ]; then echo "closing..."; return; fi
    h=$((left / 3600)); m=$(((left % 3600) / 60)); s=$((left % 60))
    if [ "$h" -gt 0 ]; then echo "${h}h ${m}m left"
    elif [ "$m" -gt 0 ]; then echo "${m}m ${s}s left"
    else echo "${s}s left"; fi
}

# Count live tunnels for an endpoint. Sourcing happens in a subshell so the meta's own
# ip=/port= fields can never clobber the caller's endpoint loop variables.
_count_metas_for() {
    local c=0 m
    shopt -s nullglob
    for m in "$RUNDIR"/*.meta; do
        if ( local ip port; ip=""; port=""; source "$m" 2>/dev/null; [ "$ip" = "$1" ] && [ "$port" = "$2" ] ); then
            c=$((c + 1))
        fi
    done
    shopt -u nullglob
    echo "$c"
}

# Print the indented sub-line for one tunnel, but only if it belongs to this endpoint.
_render_meta_if_match() {
    (
        local provider ip port label exp pid url logfile fport
        source "$1" 2>/dev/null
        { [ "$ip" = "$2" ] && [ "$port" = "$3" ]; } || exit 0
        local tag disp when
        when=$(_time_left "$exp")
        [ "$provider" = "cloudflare" ] && tag="cloudflare" || tag="tailscale "
        [ -n "$url" ] && disp="$url" || disp="initializing..."
        printf "${PINK}  └─ ${GRAY}[%s]${RESET} ${WHITE}\e[4m%s\e[0m ${GRAY}(%s)${RESET}\n" "$tag" "$disp" "$when"
    )
}

# Service records in DISPLAY order: a matched service (its address string-equals a node's
# ip) sorts by (its node's shelf position, its intra-group order), a standalone by (its own
# shelf position, 0) - one shelf across both blobs, so groups come out contiguous and
# standalones interleave between them exactly where the nodes table and the website put them.
_srv_sorted() {
    local sdata="$1" ndata="$2" line sip g o
    [ -n "$sdata" ] || return 0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        IFS=',' read -r _ sip _ <<< "$line"
        o=$(_ord_num "$(rec_ord "$line")")
        if g=$(ord_node_pos "$ndata" "$sip"); then
            printf '%010d %010d %s\n' "$(_ord_num "$g")" "$o" "$line"
        else
            printf '%010d %010d %s\n' "$o" 0 "$line"
        fi
    done <<< "$sdata" | LC_ALL=C sort | cut -d' ' -f3-
}

# ── the table format: ONE pair for the live table AND the modify preview ─────
# Rows mirror the GUI blocks with the numbers inline: marker leftmost, then two small
# fixed-width numeric columns - '#' the SHELF number (a grouped service shows its NODE's
# shelf slot; a standalone shows its own) and 'i' the position inside its node's group
# ('-' when standalone: there is no group to be inside) - then the record: "★ 3  1  jellyfin
# ...". srv_table_header/row ARE the format: show_pending_endpoint renders through the same
# pair, so the preview and the table can never drift apart.
#
# v11: the pair renders whatever srv_layout decided - which OPTIONAL columns are on
# (marker, the two numbers, target, pretty - the ~/.tui-fields toggles; SERVICE NAME and
# STATUS always show), how wide the flexible columns run, and whether the row had to be
# compacted to fit lib.sh's TUI_MAX (the loss-ordered pipeline documented there). NAME,
# TARGET and PRETTY are content-sized above their bases (18 / 21 - a full
# `255.255.255.255:65535` - / the PRETTY header), so nothing is chopped while there is room.

# srv_layout <service-csv-lines> - compute this render's layout into SL_*: toggles, column
# widths, SL_ABBR (rung 1) and SL_FOLD (rung 4: the shared dotted target prefix that folds
# to "::", legend under the table). Every caller of the header/row pair goes through here -
# the live table over all its rows, show_pending_endpoint over its one pending row - which
# is what makes the previews inherit the compaction pipeline.
srv_layout() {
    tui_fields_load
    SL_FAV=$TF_SRV_FAV SL_ORD=$TF_SRV_ORD SL_TGT=$TF_SRV_TARGET
    SL_ABBR=0 SL_FOLD=''
    local LC_ALL=C.UTF-8
    local name ip port subtitle fav ord pretty n=18 t=21 p=6 tg targets=()
    if [ -n "${1:-}" ]; then
        while IFS=',' read -r name ip port subtitle fav ord pretty; do
            [ -z "$ip" ] && continue
            [ "${#name}" -gt "$n" ] && n=${#name}
            [ "${#pretty}" -gt "$p" ] && p=${#pretty}
            tg="$ip:$port"
            [ "${#tg}" -gt "$t" ] && t=${#tg}
            targets+=("$tg")
        done <<< "$1"
    fi
    SL_W_NAME=$n SL_W_TGT=$t
    SL_W_PRETTY=0
    [ "$TF_SRV_PRETTY" = 1 ] && SL_W_PRETTY=$p
    # The row this layout would print, measured. STATUS budgets its widest live form,
    # "[ active x9 ]" (14) - "[ inactive ]" is the MEASURED baseline TUI_MAX grew from,
    # but the budget must hold on active rows too.
    local w=0 st=14 s
    [ "$SL_FAV" = 1 ] && w=$((w + 2))
    [ "$SL_ORD" = 1 ] && w=$((w + 6))
    w=$((w + SL_W_NAME + 1))
    [ "$SL_TGT" = 1 ] && w=$((w + SL_W_TGT + 1))
    [ "$SL_W_PRETTY" -gt 0 ] && w=$((w + SL_W_PRETTY + 1))
    [ $((w + st)) -le "$TUI_MAX" ] && return 0
    # Rung 1: abbreviate the statuses ("[ ▪N ]" = 6).
    SL_ABBR=1 st=6
    # Rung 2: the pretty column shrinks tab stop by tab stop, floor 8.
    while [ $((w + st)) -gt "$TUI_MAX" ] && [ "$SL_W_PRETTY" -gt 8 ]; do
        s=$(prev_tab_stop "$SL_W_PRETTY"); w=$((w - SL_W_PRETTY + s)); SL_W_PRETTY=$s
    done
    # Rung 3: only then the name column, same technique.
    while [ $((w + st)) -gt "$TUI_MAX" ] && [ "$SL_W_NAME" -gt 8 ]; do
        s=$(prev_tab_stop "$SL_W_NAME"); w=$((w - SL_W_NAME + s)); SL_W_NAME=$s
    done
    # Rung 4: the target column - fold a shared dotted prefix first (representation is
    # kept whole: the legend restores it), plain tab-stop truncation only as a last resort.
    if [ $((w + st)) -gt "$TUI_MAX" ] && [ "$SL_TGT" = 1 ]; then
        local pfx nt=6 r
        pfx=$(_fold_prefix ${targets[@]+"${targets[@]}"})
        if [ -n "$pfx" ]; then
            SL_FOLD=$pfx
            for tg in ${targets[@]+"${targets[@]}"}; do
                r="::${tg#"$pfx".}"
                [ "${#r}" -gt "$nt" ] && nt=${#r}
            done
            [ "$nt" -lt 8 ] && nt=8
            w=$((w - SL_W_TGT + nt)); SL_W_TGT=$nt
        fi
        while [ $((w + st)) -gt "$TUI_MAX" ] && [ "$SL_W_TGT" -gt 8 ]; do
            s=$(prev_tab_stop "$SL_W_TGT"); w=$((w - SL_W_TGT + s)); SL_W_TGT=$s
        done
    fi
    return 0
}

# _fold_target <target> - the target as this layout displays it: behind the "::" legend
# when rung 4 folded a shared prefix, untouched otherwise.
_fold_target() {
    if [ -n "${SL_FOLD:-}" ]; then
        case "$1" in "$SL_FOLD".*) printf '::%s' "${1#"$SL_FOLD".}"; return ;; esac
    fi
    printf '%s' "$1"
}

# srv_status_fmt <0|N|pending> - the colored STATUS cell in the form the layout picked
# (full, or the rung-1 abbreviations documented in lib.sh). The argument is the live
# tunnel count; "pending" is the preview's not-saved-yet state.
srv_status_fmt() {
    if [ "${SL_ABBR:-0}" = 1 ]; then
        case "$1" in
            pending) printf '%s' "${GRAY}[ ? ]${RESET}" ;;
            0)       printf '%s' "${PINK}[   ]${RESET}" ;;
            1)       printf '%s' "${WHITE}[ ▪ ]${RESET}" ;;
            *)       printf '%s' "${WHITE}[ ▪$1 ]${RESET}" ;;
        esac
    else
        case "$1" in
            pending) printf '%s' "${GRAY}[ pending ]${RESET}" ;;
            0)       printf '%s' "${PINK}[ inactive ]${RESET}" ;;
            *)       printf '%s' "${WHITE}[ active x$1 ]${RESET}" ;;
        esac
    fi
}

srv_table_header() {
    [ -n "${SL_W_NAME:-}" ] || srv_layout ''
    local h=''
    [ "$SL_FAV" = 1 ] && h+='  '
    [ "$SL_ORD" = 1 ] && h+="$(fit_cell '#' 2) $(fit_cell i 2) "
    h+="$(fit_cell 'SERVICE NAME' "$SL_W_NAME") "
    [ "$SL_TGT" = 1 ] && h+="$(fit_cell TARGET "$SL_W_TGT") "
    [ "$SL_W_PRETTY" -gt 0 ] && h+="$(fit_cell PRETTY "$SL_W_PRETTY") "
    h+="STATUS"
    printf "${PINK}%s${RESET}\n" "$h"
    printf "${PINK}%s${RESET}\n" "$(table_rule "$h")"
}
# args: favourite shelf# intra# name target pretty status(%b)
srv_table_row() {
    [ -n "${SL_W_NAME:-}" ] || srv_layout ''
    local r=''
    [ "$SL_FAV" = 1 ] && r+="${PINK}$(fav_mark "$1") "
    [ "$SL_ORD" = 1 ] && r+="${GRAY}$(fit_cell "$2" 2) $(fit_cell "$3" 2) "
    r+="${WHITE}$(fit_cell "$4" "$SL_W_NAME") "
    [ "$SL_TGT" = 1 ] && r+="$(fit_cell "$(_fold_target "$5")" "$SL_W_TGT") "
    [ "$SL_W_PRETTY" -gt 0 ] && r+="${GRAY}$(fit_cell "$6" "$SL_W_PRETTY" …)${WHITE} "
    printf '%b%b\n' "$r" "$7"
}

show_tunnels_table() {
    _prune_tunnels
    local data=$(decrypt_srv | grep '[^[:space:]]')
    if [ -z "$data" ]; then
        echo -e "${WHITE}no tunnel endpoints configured. add one below.${RESET}"
        return
    fi
    # Read once: _srv_sorted orders the rows by it, and the per-row numbers come from it.
    local ndata=$(decrypt_blob | grep '[^[:space:]]')
    local rows; rows=$(_srv_sorted "$data" "$ndata")

    srv_layout "$rows"
    srv_table_header

    while IFS=',' read -r name ip port subtitle fav ord pretty; do
        [ -z "$ip" ] && continue
        local target="${ip}:${port}"
        local n=$(_count_metas_for "$ip" "$port")
        # The favourite leads the row (pink ★ guests-visible; plain indent allumeur-only),
        # then the numbers: (node's shelf slot, intra order) for a grouped service, (its
        # own shelf slot, '-') for a standalone - the exact numbers the GUI blocks carry.
        local gshelf intra
        if gshelf=$(ord_node_pos "$ndata" "$ip"); then
            intra="$ord"
        else
            gshelf="$ord"; intra="-"
        fi

        if [ "$n" -eq 0 ]; then
            srv_table_row "$fav" "$gshelf" "$intra" "$name" "$target" "$pretty" "$(srv_status_fmt 0)"
        else
            srv_table_row "$fav" "$gshelf" "$intra" "$name" "$target" "$pretty" "$(srv_status_fmt "$n")"
            local m
            shopt -s nullglob
            for m in "$RUNDIR"/*.meta; do
                _render_meta_if_match "$m" "$ip" "$port"
            done
            shopt -u nullglob
            echo -e "${PINK}-------------------------------------------------------${RESET}"
        fi
    done <<< "$rows"
    # The rung-4 legend: what "::" stands for on every folded target above. Rendered by
    # lib.sh in the table's own pink, so it reads as part of the table, not a gray aside.
    [ -n "$SL_FOLD" ] && fold_legend "$SL_FOLD"
    return 0
}

# ── providers ────────────────────────────────────────────────────────────────
_start_cf() {
    local svc="$1" ip="$2" port="$3" d_lbl="$4" d_sec="$5"
    local id; id=$(_new_id)
    local log="$RUNDIR/$id.log" meta="$RUNDIR/$id.meta"
    > "$log"

    # --no-tls-verify is not laxity: the origin here is our own box on the LAN carrying a
    # self-signed cert, and cloudflared would otherwise refuse it and serve a 502.
    local cf_args=(tunnel --url "http://${ip}:${port}")
    if _svc_tls "$ip" "$port"; then
        cf_args=(tunnel --url "https://${ip}:${port}" --no-tls-verify)
    fi

    echo -e "\n${PINK}... opening cloudflare tunnel for $svc ...${RESET}"
    nohup "$CLOUDFLARED_BIN" "${cf_args[@]}" > "$log" 2>&1 &
    local cf_pid=$!
    disown $cf_pid

    local exp=$(( $(_now) + d_sec ))
    _write_meta "$meta" "cloudflare" "$ip" "$port" "$svc" "$exp" "$cf_pid" "" "$log" ""

    local url="" att=0
    while [[ -z "$url" && $att -lt 15 ]]; do
        sleep 1
        url=$(grep -o 'https://.*\.trycloudflare\.com' "$log" | head -n 1)
        ((att++))
    done

    if [[ -n "$url" ]]; then
        _set_meta_url "$meta" "$url"
        echo -e "${WHITE}[*] tunnel ready! auto-closing in $d_lbl.${RESET}"
        echo -e "${PINK}    url: ${WHITE}\e[4m${url}\e[0m${RESET}"
        nohup bash -c "sleep $d_sec; kill $cf_pid 2>/dev/null; sleep 1; kill -9 $cf_pid 2>/dev/null; rm -f '$meta' '$log'" >/dev/null 2>&1 &
        disown
        sleep 2
    else
        echo -e "${WHITE}[!] timeout fetching url. check logs.${RESET}"
        kill $cf_pid 2>/dev/null
        rm -f "$meta" "$log"
        sleep 3
    fi
}

_start_ts() {
    local svc="$1" ip="$2" port="$3" d_lbl="$4" d_sec="$5"

    local fport; fport=$(_ts_free_port)
    if [ -z "$fport" ]; then
        echo -e "\n${WHITE}[!] all tailscale funnel ports (443/8443/10000) are busy. close one first.${RESET}"
        sleep 3; return
    fi
    local dns; dns=$(_ts_dns)
    if [ -z "$dns" ]; then
        echo -e "\n${WHITE}[!] couldn't resolve this node's tailscale name.${RESET}"
        sleep 3; return
    fi

    # Pre-flight: funnel can only terminate TLS if this tailnet can issue an HTTPS cert.
    # If it can't, funnel still "starts" but every visitor gets a TLS internal-error alert,
    # so bail here with actionable guidance instead. (`tailscale cert` exits 0 even on
    # failure, so we judge success by whether a non-empty cert file was actually written.
    # On a healthy tailnet the cert is cached after the first issue - funnel needs it anyway.)
    tailscale cert --cert-file /tmp/.allumeur_certprobe --key-file /tmp/.allumeur_keyprobe "$dns" >/dev/null 2>&1
    if [ ! -s /tmp/.allumeur_certprobe ]; then
        rm -f /tmp/.allumeur_certprobe /tmp/.allumeur_keyprobe
        echo -e "\n${WHITE}[!] tailscale funnel needs an HTTPS certificate this tailnet can't issue.${RESET}"
        echo -e "${GRAY}    Enable it in the admin console: DNS → HTTPS Certificates (MagicDNS must be on).${RESET}"
        echo -e "${GRAY}    Until then, use a cloudflare tunnel for this endpoint.${RESET}"
        sleep 4; return
    fi
    rm -f /tmp/.allumeur_certprobe /tmp/.allumeur_keyprobe

    # https+insecure is funnel's word for "the origin does TLS and its cert is self-signed".
    local scheme=http
    _svc_tls "$ip" "$port" && scheme="https+insecure"

    echo -e "\n${PINK}... opening tailscale funnel for $svc on :$fport ...${RESET}"
    if ! tailscale funnel --bg --https="$fport" "${scheme}://${ip}:${port}" >/dev/null 2>&1; then
        echo -e "${WHITE}[!] funnel failed. is Funnel enabled for this node in the tailnet ACLs?${RESET}"
        sleep 3; return
    fi

    local url
    if [ "$fport" = "443" ]; then url="https://${dns}/"; else url="https://${dns}:${fport}/"; fi

    local id; id=$(_new_id)
    local meta="$RUNDIR/$id.meta"
    local exp=$(( $(_now) + d_sec ))

    # Reaper: at expiry, drop the funnel on this port and remove the meta.
    nohup bash -c "sleep $d_sec; tailscale funnel --https=$fport off >/dev/null 2>&1; rm -f '$meta'" >/dev/null 2>&1 &
    local reaper=$!
    disown

    _write_meta "$meta" "tailscale" "$ip" "$port" "$svc" "$exp" "$reaper" "$url" "" "$fport"
    echo -e "${WHITE}[*] funnel ready! auto-closing in $d_lbl.${RESET}"
    echo -e "${PINK}    url: ${WHITE}\e[4m${url}\e[0m${RESET}"
    sleep 2
}

start_tunnel() {
    local provider="$1" svc="$2" ip="$3" port="$4" d_lbl="$5" d_sec="$6"
    _prune_tunnels
    case "$provider" in
        cloudflare) _start_cf "$svc" "$ip" "$port" "$d_lbl" "$d_sec" ;;
        tailscale)  _start_ts "$svc" "$ip" "$port" "$d_lbl" "$d_sec" ;;
    esac
}

new_tunnel() {
    _prune_tunnels
    local data=$(decrypt_srv | grep '[^[:space:]]')
    if [ -z "$data" ]; then
        echo -e "\n${WHITE}no endpoints configured.${RESET}"
        sleep 2; return
    fi

    local lines=()
    local names=()
    while IFS=',' read -r name ip port subtitle fav ord pretty; do
        lines+=("$name,$ip,$port")
        names+=("$name ($ip:$port)")
    done <<< "$data"
    names+=("cancel")

    # 1) pick the endpoint
    clear
    show_tunnels_table
    echo ""
    echo -e "${PINK}*~ ${WHITE}${BOLD}new temporal tunnel${PINK} ~*${RESET}"
    echo -e "${WHITE}use up/down arrows & enter${RESET}\n"

    interactive_menu "${names[@]}"
    local choice=$?
    local target="${names[$choice]}"
    if [ "$target" == "cancel" ]; then return; fi
    IFS=',' read -r t_name t_ip t_port <<< "${lines[$choice]}"

    # 2) pick the provider
    clear
    show_tunnels_table
    echo ""
    echo -e "${PINK}*~ ${WHITE}${BOLD}provider: $t_name${PINK} ~*${RESET}"
    echo -e "${WHITE}use up/down arrows & enter${RESET}\n"

    # NOTE: declare `provider` BEFORE the menu - a `local` between interactive_menu and
    # `case $?` would reset $? to 0 and always select cloudflare.
    local provider
    local p_opts=("cloudflare tunnel" "tailscale funnel" "cancel")
    interactive_menu "${p_opts[@]}"
    case $? in
        0) provider="cloudflare" ;;
        1) provider="tailscale" ;;
        *) return ;;
    esac

    # 3) pick the duration (identical submenu for both providers)
    clear
    show_tunnels_table
    echo ""
    echo -e "${PINK}*~ ${WHITE}${BOLD}duration: $t_name via $provider${PINK} ~*${RESET}"
    echo -e "${WHITE}use up/down arrows & enter${RESET}\n"

    local d_opts=("30s" "60s" "5min" "half-hour" "1 hour" "extended (3 hours)" "cancel")
    interactive_menu "${d_opts[@]}"
    case $? in
        0) start_tunnel "$provider" "$t_name" "$t_ip" "$t_port" "30 seconds" 30 ;;
        1) start_tunnel "$provider" "$t_name" "$t_ip" "$t_port" "60 seconds" 60 ;;
        2) start_tunnel "$provider" "$t_name" "$t_ip" "$t_port" "5 minutes" 300 ;;
        3) start_tunnel "$provider" "$t_name" "$t_ip" "$t_port" "30 minutes" 1800 ;;
        4) start_tunnel "$provider" "$t_name" "$t_ip" "$t_port" "1 hour" 3600 ;;
        5) start_tunnel "$provider" "$t_name" "$t_ip" "$t_port" "3 hours" 10800 ;;
        6) return ;;
    esac
}

add_endpoint() {
    clear
    show_tunnels_table
    echo ""
    echo -e "${PINK}*~ ${WHITE}${BOLD}add tunnel endpoint${PINK} ~*${RESET}"
    echo -e "${WHITE}use up/down arrows & enter${RESET}\n"

    # Every answer goes through ask_field, none through bare `read`: the record is unquoted
    # CSV with the flags interior, so a comma in ANY of these fields writes an eighth and
    # every reader slices a flag out of a neighbour - the add flow must hold the
    # same line the modify flow does, or the record is poisoned at birth. The address and
    # port also get the exact gates modify_endpoint enforces: one discipline for both faces
    # of the record.
    local name ip port subtitle
    ask_field "service name (e.g. jellyseerr)" name
    if [ -z "$name" ]; then
        echo -e "${WHITE}[!] missing fields. aborting.${RESET}"
        sleep 2; return
    fi
    while :; do
        ask_field "ip or fqdn (e.g. 192.168.77.13)" ip || return
        valid_host "$ip" && break
        echo -e "${WHITE}[!] not an ip or fqdn.${RESET}"
    done
    while :; do
        ask_field "port (e.g. 5055)" port || return
        case "$port" in
            ''|*[!0-9]*) echo -e "${WHITE}[!] digits only.${RESET}" ;;
            *) break ;;
        esac
    done
    ask_field "subtitle (short description, e.g. 'media requests')" subtitle
    # Optional, and the one field that may be empty: the guest-facing display name (guest
    # mode shows it, falling back to the real name when empty; allumeur mode shows the real
    # name). ask_field still refuses a comma; empty IS the "no alias" answer.
    local pretty=''
    ask_field "pretty name (guest-facing, enter = none)" pretty

    # Where it goes. A service whose address exactly string-equals a node's ip joins that
    # node's GROUP: its order is a position inside the group (asked only when the group
    # already holds a service - a first member is trivially position 1), and the node's own
    # shelf slot is not re-asked. Any other address is STANDALONE: the service sits on the
    # shelf itself, beside the nodes, so its shelf position is asked. Default is the end.
    local ndata0 sdata0 ord_asked g
    ndata0=$(decrypt_blob | grep '[^[:space:]]')
    sdata0=$(decrypt_srv | grep '[^[:space:]]')
    if ord_is_node_ip "$ip" "$ndata0"; then
        g=$(ord_group_size "$sdata0" "$ip")
        if [ "$g" -ge 1 ]; then
            ord_asked=$(ask_order "position in its node's group (1-$((g + 1)), enter = end)" $((g + 1)))
        else
            ord_asked=1
        fi
    else
        g=$(ord_shelf_size "$ndata0" "$sdata0")
        ord_asked=$(ask_order "shelf position (1-$((g + 1)), enter = end)" $((g + 1)))
    fi
    echo ""

    # Curation, not security: a favourite is shown to everyone on the frontend's guest view,
    # a non-favourite only surfaces in allumeur mode. yes is first so plain enter keeps the
    # service visible, which is what almost every endpoint wants.
    echo -e "${PINK}favourite? (shown to guests)${RESET}"
    interactive_menu "yes" "no"
    local fav=$?
    [ "$fav" -eq 0 ] && fav=1 || fav=0

    echo -e "\n${PINK}... saving endpoint ...${RESET}"
    # printf-built, never `echo -e`: that re-interprets backslash escapes across every
    # record already in the database - same hazard nodes.sh documents on its own writer.
    # Placement can renumber records that already exist (and a standalone insert shifts
    # NODES on the shared shelf), so the writes go through the atomic writer, node blob
    # first only when it changed.
    local current=$(decrypt_srv | grep '[^[:space:]]')
    local ndata_now=$(decrypt_blob | grep '[^[:space:]]')
    local new_entry="$name,$ip,$port,$subtitle,$fav,0,$pretty"
    local sdata_new sidx
    if [ -n "$current" ]; then
        sdata_new="$current"$'\n'"$new_entry"
        sidx=$(printf '%s\n' "$current" | grep -c .)
    else
        sdata_new="$new_entry"
        sidx=0
    fi
    if ord_is_node_ip "$ip" "$ndata_now"; then
        ord_place_group "$ndata_now" "$sdata_new" "$sidx" "$ord_asked"
    else
        ord_place_shelf "$ndata_now" "$sdata_new" s "$sidx" "$ord_asked"
    fi
    # The companion (node) blob commits FIRST and its failure is fatal to the whole add: the
    # shelf is one permutation spanning both files, so letting the service blob land after a
    # failed node write would leave the two disagreeing - duplicate or gapped positions.
    # Returning here leaves both blobs untouched, so the message is honest. Same branch
    # shape modify_endpoint's save already uses.
    if [ "$ORD_NODES" != "$ndata_now" ] && \
       ! printf '%s\n' "$ORD_NODES" | grep '[^[:space:]]' | encrypt_atomic "$BLOB_FILE"; then
        echo -e "${WHITE}[!] write failed - the endpoint was not saved.${RESET}"
        sleep 1
        return
    fi
    if printf '%s\n' "$ORD_SRV" | grep '[^[:space:]]' | encrypt_atomic "$SRV_BLOB"; then
        echo -e "${WHITE}[*] endpoint added.${RESET}"
    else
        echo -e "${WHITE}[!] write failed - the endpoint was not saved.${RESET}"
    fi
    sleep 1
}

# ask_field <prompt> <varname> - read one field of the record, re-asking on a comma. Same
# reader nodes.sh keeps for the same reason: the record is unquoted CSV with interior
# fields, so a comma in ANY field writes an eighth and every reader then slices the
# favourite flag out of a neighbouring field.
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
        echo -e "    and voids the favourite flag.${RESET}"
    done
    echo -ne "${RESET}"
}

# valid_host <addr> - a dotted quad, or an fqdn/hostname: services are addressed by LAN
# name (.test) as often as by ip, so both faces of the add_endpoint prompt are accepted here.
valid_host() {
    valid_ipv4 "$1" && return 0
    # A dotted-quad-shaped string that failed valid_ipv4 is an out-of-range address typo
    # (999.9.9.9), not a hostname - storing it as one only surfaces when a tunnel can't
    # resolve it. Reject the shape outright before falling through to the fqdn grammar.
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 1
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]]
}

# The pending record, rendered EXACTLY as the live table renders a row: the same header,
# the same columns, the same paddings, through the same srv_table_header/row pair - never a
# separate, more verbose format that could drift. The pending numbers lead beside the
# marker and update live as order edits change (the caller computes them from the PENDING
# address and orders, so a matched service shows its node's slot + its group position and a
# standalone shows its own slot + '-'). STATUS reads [ pending ]: active/inactive is a
# claim about a saved record, and this one is not saved yet. Nothing in here reads or
# writes the blob.
show_pending_endpoint() {
    # args: name ip port fav shelf# intra# pretty
    # Laid out over exactly the row it is about to print, so the preview runs the same
    # toggle + compaction pipeline the live table runs (a long pending pretty ellipsizes
    # here exactly as it would there).
    srv_layout "$1,$2,$3,x,${4:-0},0,${7:-}"
    srv_table_header
    srv_table_row "$4" "$5" "$6" "$1" "$2:$3" "${7:-}" "$(srv_status_fmt pending)"
}

# modify_endpoint - edit one record through a PENDING copy. Picked by POSITION, the way
# nodes.sh removes: names are not unique and the menu index IS the record index. The submenu
# loops: every edit lands on the pending copy alone and redraws the one-row preview above
# it - the blob is not touched until the explicit save, which commits every pending edit in
# ONE staged-and-renamed write (encrypt_atomic); cancel discards the lot and writes nothing.
# Only the chosen record is rebuilt on save; every other line goes back byte-identical, and
# the atomic writer means a death mid-encrypt can never truncate a database holding records
# this flow never touched.
modify_endpoint() {
    local data=$(decrypt_srv | grep '[^[:space:]]')
    if [ -z "$data" ]; then
        echo -e "\n${WHITE}no endpoints configured.${RESET}"
        sleep 2; return
    fi

    local names=()
    local name ip port subtitle fav ord pretty
    while IFS=',' read -r name ip port subtitle fav ord pretty; do
        names+=("$(fav_mark "$fav") $name ($ip:$port)")
    done <<< "$data"
    names+=("cancel")

    clear
    show_tunnels_table
    echo ""
    echo -e "${PINK}*~ ${WHITE}${BOLD}modify tunnel endpoint${PINK} ~*${RESET}"
    echo -e "${WHITE}use up/down arrows & enter${RESET}\n"

    interactive_menu "${names[@]}"
    local choice=$?
    [ "${names[$choice]}" = "cancel" ] && return

    local line; line=$(printf '%s\n' "$data" | sed -n "$((choice + 1))p")
    IFS=',' read -r name ip port subtitle fav ord pretty <<< "$line"

    # The pending copy. Every edit below lands here and nowhere else. p_ord is the
    # service's OWN pending order (group position when matched, shelf position when
    # standalone); p_nshelf, when set, is a pending shelf position for its NODE - the
    # second step of the two-step order edit below.
    local p_ip=$ip p_port=$port p_subtitle=$subtitle p_fav=$fav p_ord=$ord p_nshelf=''
    local p_pretty=$pretty

    while :; do
        print_header "modify $name" ""
        # The preview numbers follow the PENDING address, exactly as save will: a matched
        # service shows its node's shelf slot (the pending one, once step two of an order
        # edit has asked for it) and its own pending group position; a standalone shows
        # its own pending shelf slot and '-'.
        local pv_nodes pv_shelf pv_intra
        pv_nodes=$(decrypt_blob | grep '[^[:space:]]')
        if ord_is_node_ip "$p_ip" "$pv_nodes"; then
            pv_shelf=${p_nshelf:-$(ord_node_pos "$pv_nodes" "$p_ip")}
            pv_intra=$p_ord
        else
            pv_shelf=$p_ord
            pv_intra='-'
        fi
        show_pending_endpoint "$name" "$p_ip" "$p_port" "$p_fav" "$pv_shelf" "$pv_intra" "$p_pretty"
        echo -e "\n${GRAY}pending - nothing is written until save; cancel discards every edit${RESET}"
        echo -e "${WHITE}use up/down arrows & enter${RESET}\n"
        # Bare labels, one hotkey each, no two sharing a first letter: a p d f n o s c.
        # The pretty edit is labelled "nickname" - "pretty" would collide with "port" and
        # get digit-relabelled, and the nodes submenu says nickname for the same field.
        interactive_menu "address" "port" "description" "favourite" "nickname" "order" "save" "cancel"
        case $? in
            0)
                local new_ip
                while :; do
                    ask_field "new ip or fqdn" new_ip || return
                    valid_host "$new_ip" && break
                    echo -e "${WHITE}[!] not an ip or fqdn.${RESET}"
                done
                p_ip=$new_ip
                ;;
            1)
                local new_port
                while :; do
                    ask_field "new port" new_port || return
                    case "$new_port" in
                        ''|*[!0-9]*) echo -e "${WHITE}[!] digits only.${RESET}" ;;
                        *) break ;;
                    esac
                done
                p_port=$new_port
                ;;
            2)
                ask_field "new subtitle (short description)" p_subtitle
                ;;
            3)
                # Curation, not security: 1 = shown to everyone, 0 = allumeur mode only.
                [ "$p_fav" = 1 ] && p_fav=0 || p_fav=1
                ;;
            4)
                # The guest-facing pretty name. Empty is an answer - "drop the alias" -
                # so unlike every other free-text edit it is not re-asked when blank.
                ask_field "nickname (guest-facing, enter = none)" p_pretty
                ;;
            5)
                # The two-step order edit, driven by the PENDING address: a matched service
                # is asked (i) its position inside its node's group - only when that group
                # holds more than one service - and (ii) then its node's SHELF position; a
                # standalone service is simply asked its own shelf position. Clamped here
                # for the preview; save clamps again against whatever is stored by then.
                local ndata0 sdata0
                ndata0=$(decrypt_blob | grep '[^[:space:]]')
                sdata0=$(decrypt_srv | grep '[^[:space:]]')
                if ord_is_node_ip "$p_ip" "$ndata0"; then
                    local g; g=$(ord_group_size "$sdata0" "$p_ip")
                    [ "$ip" = "$p_ip" ] || g=$((g + 1))    # joining the group, not yet stored in it
                    if [ "$g" -gt 1 ]; then
                        p_ord=$(ask_order "position in its node's group (1-$g, enter keeps $p_ord)" "$g" "$p_ord")
                    else
                        p_ord=1
                    fi
                    local shelf_k npos
                    shelf_k=$(ord_shelf_size "$ndata0" "$sdata0")
                    npos=$(ord_node_pos "$ndata0" "$p_ip")
                    p_nshelf=$(ask_order "its node's shelf position (1-$shelf_k, enter keeps ${p_nshelf:-$npos})" "$shelf_k" "${p_nshelf:-$npos}")
                else
                    local shelf_k; shelf_k=$(ord_shelf_size "$ndata0" "$sdata0")
                    # A matched service going standalone joins the shelf: one more slot.
                    ord_is_node_ip "$ip" "$ndata0" && shelf_k=$((shelf_k + 1))
                    p_ord=$(ask_order "shelf position (1-$shelf_k, enter keeps $p_ord)" "$shelf_k" "$p_ord")
                fi
                ;;
            6)
                # Save: the one commit of the whole flow. Rebuilt line by line with printf,
                # never `echo -e` or awk -v - both re-interpret escapes, and the untouched
                # records must go back exactly as they came out.
                local out='' i=0 rec
                while IFS= read -r rec; do
                    if [ "$i" -eq "$choice" ]; then
                        out+="$name,$p_ip,$p_port,$p_subtitle,$p_fav,$ord,$p_pretty"$'\n'
                    else
                        out+="$rec"$'\n'
                    fi
                    i=$((i + 1))
                done <<< "$data"
                out=${out%$'\n'}
                # The session edits a snapshot, and the pending loop makes sessions
                # arbitrarily long - long enough for another writer to have committed.
                # Rebuilding from a stale snapshot would silently revert that commit, so
                # save re-reads and refuses to clobber rather than guess at a merge.
                if [ "$(decrypt_srv | grep '[^[:space:]]')" != "$data" ]; then
                    echo -e "\n${WHITE}[!] database changed while you were editing - nothing written. re-open the record.${RESET}"
                    sleep 2
                    return
                fi
                # Placement follows the PENDING address: whatever group membership the save
                # lands with is the one the orders are computed for. The node blob is read
                # fresh and written FIRST when it changed (an order edit can move a node on
                # the shelf, and a standalone move renumbers nodes past it) - if that write
                # dies nothing changed and the retry is clean; the service blob commits
                # second, and a retry after ITS failure finds the nodes already consistent.
                local ndata_now; ndata_now=$(decrypt_blob | grep '[^[:space:]]')
                if ord_is_node_ip "$p_ip" "$ndata_now"; then
                    ord_place_group "$ndata_now" "$out" "$choice" "$p_ord"
                    if [ -n "$p_nshelf" ]; then
                        local nidx
                        if nidx=$(ord_node_idx "$ORD_NODES" "$p_ip"); then
                            ord_place_shelf "$ORD_NODES" "$ORD_SRV" n "$nidx" "$p_nshelf"
                        fi
                    fi
                else
                    ord_place_shelf "$ndata_now" "$out" s "$choice" "$p_ord"
                fi
                if [ "$ORD_NODES" != "$ndata_now" ]; then
                    if ! printf '%s\n' "$ORD_NODES" | grep '[^[:space:]]' | encrypt_atomic "$BLOB_FILE"; then
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
                if printf '%s\n' "$ORD_SRV" | grep '[^[:space:]]' | encrypt_atomic "$SRV_BLOB"; then
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

remove_endpoint() {
    local data=$(decrypt_srv | grep '[^[:space:]]')
    if [ -z "$data" ]; then return; fi

    local names=()
    local name ip port subtitle fav ord pretty
    while IFS=',' read -r name ip port subtitle fav ord pretty; do
        # Marker leads the row, as everywhere records are listed; the hotkey stays the
        # first letter of the name.
        names+=("$(fav_mark "$fav") $name ($ip:$port)")
    done <<< "$data"
    names+=("cancel")

    clear
    show_tunnels_table
    echo ""
    echo -e "${PINK}*~ ${WHITE}${BOLD}remove endpoint${PINK} ~*${RESET}"
    echo -e "${WHITE}use up/down arrows & enter${RESET}\n"

    interactive_menu "${names[@]}"
    local choice=$?

    if [ "${names[$choice]}" != "cancel" ]; then
        # By POSITION, not by name, for exactly the reasons remove_node documents: nothing
        # enforces unique names, so a grep on the name deletes every record carrying it -
        # and the name is a REGEX to grep, so an fqdn-style 'jelly.test' also takes
        # 'jellyxtest' with it. The menu index IS the record index - `names` is built from
        # `data` in order. Atomic for the same reason as modify: this write rebuilds records
        # the user never touched, and a death mid-encrypt must not cost them.
        local rname; rname=$(printf '%s\n' "$data" | sed -n "$((choice + 1))p")
        rname="${rname%%,*}"
        # Removal closes the gap it leaves - inside its group for a matched service, on the
        # shelf for a standalone one. The shelf spans both blobs, so closing a standalone's
        # slot renumbers nodes past it: the node blob is written first when it changed.
        local sdata_new; sdata_new=$(printf '%s\n' "$data" | awk -F, "NR != $((choice + 1))")
        local ndata_now; ndata_now=$(decrypt_blob | grep '[^[:space:]]')
        ord_renumber "$ndata_now" "$sdata_new"
        # The node blob commits FIRST and its failure aborts the removal before the service
        # blob is touched: the shelf is one permutation across both files, and a service blob
        # written after a failed node write would leave the pair disagreeing. Nothing has
        # been written at that point, so "nothing changed" is literally true.
        if [ "$ORD_NODES" != "$ndata_now" ] && \
           ! printf '%s\n' "$ORD_NODES" | grep '[^[:space:]]' | encrypt_atomic "$BLOB_FILE"; then
            echo -e "\n${WHITE}[!] write failed - nothing changed.${RESET}"
            sleep 1
            return
        fi
        if printf '%s\n' "$ORD_SRV" | grep '[^[:space:]]' | encrypt_atomic "$SRV_BLOB"; then
            echo -e "\n${WHITE}[*] removed $rname.${RESET}"
        else
            # The second write is the one that failed, so the first may already have landed:
            # say so rather than claiming nothing moved. The endpoint itself is still there.
            echo -e "\n${WHITE}[!] write failed - $rname was NOT removed; the node shelf may already have been renumbered. run the removal again.${RESET}"
        fi
        sleep 1
    fi
}

# ── C3: toggle the OPTIONAL columns of the tunnel table ──────────────────────
# SERVICE NAME and STATUS always show; target, the two order numbers (one toggle - they
# tell one story), the favourite marker and pretty are preferences, persisted plainly in
# ~/.allumeur-scripts/.tui-fields (lib.sh). Each toggle saves immediately. "back" leads
# so a bare enter (or EOF) leaves instead of toggling - hotkeys stay distinct: b t o f p.
srv_fields_menu() {
    local c
    while :; do
        tui_fields_load
        print_header "fields on tables : tunnel"
        interactive_menu "back" \
            "target: $(tui_onoff "$TF_SRV_TARGET")" \
            "order numbers: $(tui_onoff "$TF_SRV_ORD")" \
            "favourite marker: $(tui_onoff "$TF_SRV_FAV")" \
            "pretty: $(tui_onoff "$TF_SRV_PRETTY")"
        c=$?
        case $c in
            1) TF_SRV_TARGET=$(tui_flip "$TF_SRV_TARGET") ;;
            2) TF_SRV_ORD=$(tui_flip "$TF_SRV_ORD") ;;
            3) TF_SRV_FAV=$(tui_flip "$TF_SRV_FAV") ;;
            4) TF_SRV_PRETTY=$(tui_flip "$TF_SRV_PRETTY") ;;
            *) return ;;
        esac
        tui_fields_save
    done
}

kill_all() {
    # cloudflared quick-tunnels
    pkill -f "cloudflared tunnel" 2>/dev/null
    # tear down every tailscale funnel we own
    shopt -s nullglob
    local m
    for m in "$RUNDIR"/*.meta; do
        ( local provider fport; provider=""; fport=""; source "$m" 2>/dev/null
          [ "$provider" = "tailscale" ] && [ -n "$fport" ] && tailscale funnel --https="$fport" off >/dev/null 2>&1 )
    done
    shopt -u nullglob
    # stop any pending reaper/sleeper processes so they don't fire later
    pkill -f "$RUNDIR" 2>/dev/null
    rm -f "$RUNDIR"/*.meta "$RUNDIR"/*.log 2>/dev/null
    echo -e "\n${WHITE}[*] all tunnels severed.${RESET}"
    sleep 2
}

main() {
    while true; do
        clear
        show_tunnels_table
        echo ""
        echo -e "${PINK}*~ ${WHITE}${BOLD}web tunnels${PINK} ~*${RESET}"
        echo -e "${WHITE}use up/down arrows & enter${RESET}\n"

        opts=("new temporal tunnel" "add tunnel endpoint" "modify tunnel endpoint" "remove tunnel endpoint" "kill all tunnels" "fields on tables" "update view" "exit")
        interactive_menu "${opts[@]}"
        case $? in
            0) new_tunnel ;;
            1) add_endpoint ;;
            2) modify_endpoint ;;
            3) remove_endpoint ;;
            4) kill_all ;;
            5) srv_fields_menu ;;
            6) continue ;;
            7) clear; exit 0 ;;
        esac
    done
}

# Sourcing this file (the test suite does) must not launch the menu. `if`, not `&&`, or
# sourcing it would return 1 - same guard nodes.sh carries.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
