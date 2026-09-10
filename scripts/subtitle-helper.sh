#!/bin/bash
source "$HOME/.allumeur-scripts/lib.sh"
trap "tput cnorm; exit" INT TERM

SRV_BLOB="$HOME/.allumeur-scripts/encrypted/srv_blob.enc"

decrypt_srv() {
    openssl enc -aes-256-cbc -d -salt -pbkdf2 -pass file:"$KEY_FILE" -in "$SRV_BLOB" 2>/dev/null
}

# No encrypt_srv here anymore: both editors below rewrite whole databases of records that
# already exist, which is precisely the case lib.sh's encrypt_atomic exists for - a death
# mid-encrypt through the bare truncating writer would cost records these loops never touched.

update_node_subtitles() {
    local data
    data=$(decrypt_blob | grep '[^[:space:]]')
    if [ -z "$data" ]; then
        echo -e "${WHITE}no nodes found.${RESET}"
        sleep 2; return
    fi

    local new_data=""
    # Read loop uses fd 3 so the inner `read` can still take input from the terminal (fd 0).
    # Nine fields: favourite ($7), order ($8) and pretty ($9) are not edited here, but they
    # must be split off and put back, or they would ride along inside $luks and be
    # re-emitted as a malformed flag.
    while IFS=',' read -r mac ip name user subtitle luks fav ord pretty <&3; do
        # Defaulted, never skipped: this loop rewrites the whole blob from what it iterates,
        # so a skipped line is a node deleted from the database. A record predating the sixth
        # field reads 0 per the schema, and this editor is exactly where the user sets it to 1
        # if that is wrong.
        [ -z "$ip" ] && continue
        local ssh_ok=yes; [ "$luks" = 1 ] && ssh_ok=no
        clear
        echo -e "${PINK}*~ ${WHITE}${BOLD}record helper: nodes${PINK} ~*${RESET}\n"
        echo -e "${PINK}node:    ${WHITE}${BOLD}${name}${RESET}  ${PINK}(${ip})${RESET}"
        echo -e "${PINK}current: ${WHITE}${subtitle:-(none)}${RESET}"
        echo -e "${PINK}ssh on wake: ${WHITE}${ssh_ok}${RESET}\n"
        echo -ne "${PINK}new subtitle (enter to keep current): ${WHITE}"
        read -r new_sub </dev/tty
        # The record is unquoted CSV and the subtitle is an interior field now, so a comma
        # writes a tenth field and every reader slices the flag out of its tail.
        while [ "$new_sub" != "${new_sub//,/}" ]; do
            echo -e "${RESET}${WHITE}[!] a comma splits the record"
            echo -e "    and voids the luks flag.${RESET}"
            echo -ne "${PINK}new subtitle (no commas): ${WHITE}"
            read -r new_sub </dev/tty
        done
        echo -ne "${RESET}"
        [ -n "$new_sub" ] && subtitle="$new_sub"
        # Asked here because a machine acquires full-disk encryption long after it was
        # added, and remove+add is not a migration path: remove_node commits the shortened
        # blob before add_node can fail, and the record is gone. Phrased the way add_node
        # phrases it - what the user knows is whether ssh answers, not what LUKS is doing.
        echo -ne "${PINK}ssh on wake? y/n (enter keeps ${ssh_ok}): ${WHITE}"
        read -r new_ssh </dev/tty
        echo -ne "${RESET}"
        case "$new_ssh" in
            [Yy]*) luks=0 ;;
            [Nn]*) luks=1 ;;
        esac
        new_data="${new_data}${mac},${ip},${name},${user},${subtitle},${luks},${fav},${ord},${pretty}"$'\n'
    done 3<<< "$data"

    if echo "$new_data" | grep '[^[:space:]]' | encrypt_atomic "$BLOB_FILE"; then
        echo -e "\n${WHITE}[*] node records saved!${RESET}"
    else
        echo -e "\n${WHITE}[!] write failed - nothing changed.${RESET}"
    fi
    sleep 2
}

update_service_subtitles() {
    local data
    data=$(decrypt_srv | grep '[^[:space:]]')
    if [ -z "$data" ]; then
        echo -e "${WHITE}no services found.${RESET}"
        sleep 2; return
    fi

    local new_data=""
    # Read loop uses fd 3 so the inner `read` can still take input from the terminal (fd 0).
    # Seven fields: favourite ($5), order ($6) and pretty ($7) are preserved, not edited -
    # same rule as the node loop above.
    while IFS=',' read -r name ip port subtitle fav ord pretty <&3; do
        [ -z "$ip" ] && continue
        clear
        echo -e "${PINK}*~ ${WHITE}${BOLD}subtitle helper: services${PINK} ~*${RESET}\n"
        echo -e "${PINK}service: ${WHITE}${BOLD}${name}${RESET}  ${PINK}(${ip}:${port})${RESET}"
        echo -e "${PINK}current: ${WHITE}${subtitle:-(none)}${RESET}\n"
        echo -ne "${PINK}new subtitle (enter to keep current): ${WHITE}"
        read -r new_sub </dev/tty
        # The subtitle is no longer this record's last field either: a comma here writes an
        # eighth field and every reader slices the favourite flag out of the subtitle's tail.
        while [ "$new_sub" != "${new_sub//,/}" ]; do
            echo -e "${RESET}${WHITE}[!] a comma splits the record"
            echo -e "    and voids the favourite flag.${RESET}"
            echo -ne "${PINK}new subtitle (no commas): ${WHITE}"
            read -r new_sub </dev/tty
        done
        echo -ne "${RESET}"
        [ -n "$new_sub" ] && subtitle="$new_sub"
        new_data="${new_data}${name},${ip},${port},${subtitle},${fav},${ord},${pretty}"$'\n'
    done 3<<< "$data"

    if echo "$new_data" | grep '[^[:space:]]' | encrypt_atomic "$SRV_BLOB"; then
        echo -e "\n${WHITE}[*] service subtitles saved!${RESET}"
    else
        echo -e "\n${WHITE}[!] write failed - nothing changed.${RESET}"
    fi
    sleep 2
}

while true; do
    clear
    echo -e "${PINK}*~ ${WHITE}${BOLD}record helper${PINK} ~*${RESET}"
    echo -e "${WHITE}edit saved records retroactively${RESET}\n"

    opts=("edit node records" "edit service subtitles" "exit")
    interactive_menu "${opts[@]}"
    case $? in
        0) update_node_subtitles ;;
        1) update_service_subtitles ;;
        2) clear; exit 0 ;;
    esac
done
