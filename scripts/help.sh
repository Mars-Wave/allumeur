#!/bin/bash
source "$HOME/.allumeur-scripts/lib.sh"
print_header "allumeur commands"

echo -e "${PINK}  nodes${WHITE}     - manage your homelab machines (add/modify/remove/list, keys)"
echo -e "${PINK}  tunnel${WHITE}    - temporary web tunneling (add/modify endpoints)"
echo -e "${PINK}  subtitles${WHITE} - add or edit subtitles on nodes & services"
echo -e "${PINK}  help${WHITE}      - show this cute little menu"
echo -e "${PINK}  ★${WHITE}         - list marker: ★ favourite (guests see it); unmarked = allumeur-only"
echo -e "${PINK}  order${WHITE}     - one shelf orders nodes & standalone services; grouped services order inside their node (edit via modify)"
echo -e "${PINK}  nickname${WHITE}  - guest-facing pretty name on nodes & services (guests see it; allumeur mode shows the real name; edit via modify > nickname); 'fields on tables' toggles optional columns"
echo ""
