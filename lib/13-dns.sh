# ===================== DNS / resolv.conf Management =====================
_dns_backup_resolv() {
    local TS; TS=$(date +%Y%m%d%H%M%S)
    [ -f /etc/resolv.conf ] && cp -a /etc/resolv.conf "/etc/resolv.conf.bak.${TS}" 2>/dev/null || cp /etc/resolv.conf "/etc/resolv.conf.bak.${TS}" 2>/dev/null || true
    [ -f /etc/systemd/resolved.conf ] && cp -a /etc/systemd/resolved.conf "/etc/systemd/resolved.conf.bak.${TS}" 2>/dev/null || true
    echo -e "${YELLOW}Backup: /etc/resolv.conf.bak.${TS}${NC}"
}
_dns_is_valid_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'; read -r a b c d <<< "$ip"
        for o in "$a" "$b" "$c" "$d"; do [ "$o" -gt 255 ] 2>/dev/null && return 1; [ "$o" -lt 0 ] 2>/dev/null && return 1; done
        return 0
    fi
    if [[ "$ip" =~ : ]] && [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then return 0; fi
    return 1
}
_dns_show_resolv() {
    echo -e "\n--- Current DNS Config ---"
    local _resolv_target; _resolv_target=$(readlink -f /etc/resolv.conf 2>/dev/null || echo "not symlink")
    echo -e "${YELLOW}/etc/resolv.conf -> ${_resolv_target}${NC}"
    ls -l /etc/resolv.conf 2>/dev/null || echo "(no /etc/resolv.conf)"
    echo ""; echo "--- /etc/resolv.conf ---"
    cat /etc/resolv.conf 2>/dev/null || echo "(empty / missing)"
    echo ""; echo "--- /etc/systemd/resolved.conf ---"
    cat /etc/systemd/resolved.conf 2>/dev/null || echo "(no resolved.conf)"
    echo ""
    if command -v resolvectl >/dev/null 2>&1; then
        echo "--- resolvectl status ---"; resolvectl status 2>&1 | head -n 80; echo ""
    elif command -v systemd-resolve >/dev/null 2>&1; then
        echo "--- systemd-resolve --status ---"; systemd-resolve --status 2>&1 | head -n 80; echo ""
    fi
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then echo -e "systemd-resolved: ${GREEN}active${NC}"; else echo -e "systemd-resolved: ${YELLOW}inactive${NC}"; fi
    echo ""; echo "--- Parsed nameservers ---"
    if grep -q "^nameserver" /etc/resolv.conf 2>/dev/null; then grep "^nameserver" /etc/resolv.conf | cat -n; else echo "(no nameserver entries)"; fi
    grep -q "^search" /etc/resolv.conf 2>/dev/null && echo "search: $(grep "^search" /etc/resolv.conf | cut -d' ' -f2-)"
    grep -q "^options" /etc/resolv.conf 2>/dev/null && echo "options: $(grep "^options" /etc/resolv.conf | cut -d' ' -f2-)"
    grep -q "^domain" /etc/resolv.conf 2>/dev/null && echo "domain: $(grep "^domain" /etc/resolv.conf | cut -d' ' -f2-)"
    echo ""
    if [ -L /etc/resolv.conf ]; then
        echo -e "${YELLOW}Warning: /etc/resolv.conf is a symlink (systemd-resolved). Changes may revert on reboot. Use option 7.${NC}"
    fi
}
_dns_add_nameserver() {
    _dns_show_resolv
    read -r -p "Enter nameserver IP to add (e.g., 8.8.8.8): " NS
    NS=$(echo "$NS" | xargs)
    if ! _dns_is_valid_ip "$NS"; then echo -e "${RED}Invalid IP: '$NS'${NC}"; return 1; fi
    if grep -q "^nameserver[[:space:]]\\+${NS//./\\.}[[:space:]]*$" /etc/resolv.conf 2>/dev/null; then echo -e "${YELLOW}$NS already exists.${NC}"; return 0; fi
    if [ -L /etc/resolv.conf ]; then
        echo -e "${YELLOW}/etc/resolv.conf is a symlink. Will replace with real file.${NC}"
        read -r -p "Continue? (y/n): " C; if ! [[ "$C" =~ ^[yY] ]]; then echo "Aborted."; return 1; fi
        _dns_backup_resolv; local REAL=$(readlink -f /etc/resolv.conf 2>/dev/null || echo "")
        rm -f /etc/resolv.conf; [ -n "$REAL" ] && [ -f "$REAL" ] && cp "$REAL" /etc/resolv.conf 2>/dev/null || true
        [ -f /etc/resolv.conf ] || touch /etc/resolv.conf
    else _dns_backup_resolv; fi
    echo "nameserver $NS" >> /etc/resolv.conf
    echo -e "${GREEN}Added $NS${NC}"; cat /etc/resolv.conf
}
_dns_edit_nameserver() {
    if ! grep -q "^nameserver" /etc/resolv.conf 2>/dev/null; then echo -e "${RED}No nameserver to edit.${NC}"; return 1; fi
    echo "Current nameservers:"; grep "^nameserver" /etc/resolv.conf | cat -n; echo ""
    read -r -p "Enter line number or existing IP: " SEL; SEL=$(echo "$SEL" | xargs)
    local OLD=""
    if [[ "$SEL" =~ ^[0-9]+$ ]]; then OLD=$(grep "^nameserver" /etc/resolv.conf | sed -n "${SEL}p" | awk '{print $2}'); [ -z "$OLD" ] && echo -e "${RED}Invalid number.${NC}" && return 1
    else if _dns_is_valid_ip "$SEL"; then OLD="$SEL"; grep -q "^nameserver[[:space:]]\\+${OLD//./\\.}[[:space:]]*$" /etc/resolv.conf || { echo -e "${RED}$OLD not found.${NC}"; return 1; }; else echo -e "${RED}Enter number or IP.${NC}"; return 1; fi; fi
    read -r -p "Enter new IP to replace '$OLD': " NEW; NEW=$(echo "$NEW" | xargs)
    if ! _dns_is_valid_ip "$NEW"; then echo -e "${RED}Invalid IP: '$NEW'${NC}"; return 1; fi
    if grep -q "^nameserver[[:space:]]\\+${NEW//./\\.}[[:space:]]*$" /etc/resolv.conf; then echo -e "${YELLOW}$NEW already exists.${NC}"; return 1; fi
    _dns_backup_resolv
    if [ -L /etc/resolv.conf ]; then local REAL=$(readlink -f /etc/resolv.conf 2>/dev/null); rm -f /etc/resolv.conf; [ -n "$REAL" ] && [ -f "$REAL" ] && cp "$REAL" /etc/resolv.conf 2>/dev/null || true; fi
    awk -v old="$OLD" -v nw="$NEW" 'BEGIN{c=0} /^nameserver[[:space:]]+/ {ip=$2; if(ip==old && c==0){print "nameserver " nw; c=1; next}}1' /etc/resolv.conf > /tmp/resolv.tmp && cat /tmp/resolv.tmp > /etc/resolv.conf; rm -f /tmp/resolv.tmp
    echo -e "${GREEN}Replaced $OLD -> $NEW${NC}"; cat /etc/resolv.conf
}
_dns_delete_nameserver() {
    if ! grep -q "^nameserver" /etc/resolv.conf 2>/dev/null; then echo -e "${RED}No nameserver entries.${NC}"; return 1; fi
    echo "Current nameservers:"; grep "^nameserver" /etc/resolv.conf | cat -n
    read -r -p "Enter line number or IP to delete: " SEL; SEL=$(echo "$SEL" | xargs)
    local TARGET=""
    if [[ "$SEL" =~ ^[0-9]+$ ]]; then TARGET=$(grep "^nameserver" /etc/resolv.conf | sed -n "${SEL}p" | awk '{print $2}'); [ -z "$TARGET" ] && echo -e "${RED}Invalid number.${NC}" && return 1
    else if _dns_is_valid_ip "$SEL"; then TARGET="$SEL"; else echo -e "${RED}Invalid IP/number.${NC}"; return 1; fi; fi
    local COUNT=$(grep -c "^nameserver" /etc/resolv.conf)
    if [ "$COUNT" -le 1 ]; then echo -e "${YELLOW}Deleting last nameserver will leave no DNS.${NC}"; read -r -p "Continue? (y/n): " C; if ! [[ "$C" =~ ^[yY] ]]; then echo "Aborted."; return 1; fi; fi
    _dns_backup_resolv
    if [ -L /etc/resolv.conf ]; then local REAL=$(readlink -f /etc/resolv.conf 2>/dev/null); rm -f /etc/resolv.conf; [ -n "$REAL" ] && [ -f "$REAL" ] && cp "$REAL" /etc/resolv.conf 2>/dev/null || true; fi
    awk -v t="$TARGET" 'BEGIN{c=0} /^nameserver[[:space:]]+/ {ip=$2; if(ip==t && c==0){c=1; next}}1' /etc/resolv.conf > /tmp/resolv.tmp && cat /tmp/resolv.tmp > /etc/resolv.conf; rm -f /tmp/resolv.tmp
    echo -e "${GREEN}Deleted $TARGET${NC}"; cat /etc/resolv.conf
}
_dns_set_search_options() {
    echo ""; echo "Current search : $(grep "^search" /etc/resolv.conf 2>/dev/null | cut -d' ' -f2- || echo '(none)')"
    echo "Current options: $(grep "^options" /etc/resolv.conf 2>/dev/null | cut -d' ' -f2- || echo '(none)')"
    echo "Current domain : $(grep "^domain" /etc/resolv.conf 2>/dev/null | cut -d' ' -f2- || echo '(none)')"
    echo ""; echo "1) Set search domains"; echo "2) Set options (e.g., timeout:2 rotate)"; echo "3) Set domain"; echo "4) Remove search/options/domain"; echo "0) Back"
    read -r -p "Choice: " SOPT
    case "$SOPT" in
        1) read -r -p "Enter search domains (space-separated): " VAL; VAL=$(echo "$VAL" | xargs)
           _dns_backup_resolv; if [ -L /etc/resolv.conf ]; then R=$(readlink -f /etc/resolv.conf 2>/dev/null); rm -f /etc/resolv.conf; [ -n "$R" ] && [ -f "$R" ] && cp "$R" /etc/resolv.conf 2>/dev/null || true; fi
           sed -i '/^search/d' /etc/resolv.conf; [ -n "$VAL" ] && echo "search $VAL" >> /etc/resolv.conf; echo -e "${GREEN}Updated.${NC}"; cat /etc/resolv.conf ;;
        2) read -r -p "Enter options (e.g., timeout:2 attempts:3 rotate): " VAL; VAL=$(echo "$VAL" | xargs)
           _dns_backup_resolv; if [ -L /etc/resolv.conf ]; then R=$(readlink -f /etc/resolv.conf 2>/dev/null); rm -f /etc/resolv.conf; [ -n "$R" ] && [ -f "$R" ] && cp "$R" /etc/resolv.conf 2>/dev/null || true; fi
           sed -i '/^options/d' /etc/resolv.conf; [ -n "$VAL" ] && echo "options $VAL" >> /etc/resolv.conf; echo -e "${GREEN}Updated.${NC}"; cat /etc/resolv.conf ;;
        3) read -r -p "Enter domain: " VAL; VAL=$(echo "$VAL" | xargs)
           _dns_backup_resolv; if [ -L /etc/resolv.conf ]; then R=$(readlink -f /etc/resolv.conf 2>/dev/null); rm -f /etc/resolv.conf; [ -n "$R" ] && [ -f "$R" ] && cp "$R" /etc/resolv.conf 2>/dev/null || true; fi
           sed -i '/^domain/d' /etc/resolv.conf; [ -n "$VAL" ] && echo "domain $VAL" >> /etc/resolv.conf; echo -e "${GREEN}Updated.${NC}"; cat /etc/resolv.conf ;;
        4) _dns_backup_resolv; if [ -L /etc/resolv.conf ]; then R=$(readlink -f /etc/resolv.conf 2>/dev/null); rm -f /etc/resolv.conf; [ -n "$R" ] && [ -f "$R" ] && cp "$R" /etc/resolv.conf 2>/dev/null || true; fi
           sed -i '/^search/d; /^options/d; /^domain/d' /etc/resolv.conf; echo -e "${GREEN}Removed.${NC}"; cat /etc/resolv.conf ;;
        0) return 0 ;; *) echo -e "${RED}Invalid.${NC}" ;;
    esac
}
_dns_reset_defaults() {
    echo -e "${YELLOW}Reset DNS to defaults (8.8.8.8, 1.1.1.1)...${NC}"
    _dns_backup_resolv; [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
    printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf
    echo -e "${GREEN}Reset done.${NC}"; cat /etc/resolv.conf
}
_dns_make_persistent() {
    echo -e "\n--- Make DNS Persistent (systemd-resolved) ---"
    echo "This will set DNS in /etc/systemd/resolved.conf and link /etc/resolv.conf to stub."
    read -r -p "Proceed? (y/n): " C; if ! [[ "$C" =~ ^[yY] ]]; then echo "Aborted."; return 0; fi
    local NS_LIST; NS_LIST=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}' | xargs)
    [ -z "$NS_LIST" ] && NS_LIST="8.8.8.8 1.1.1.1"
    echo "Using DNS: $NS_LIST"
    _dns_backup_resolv; mkdir -p /etc/systemd 2>/dev/null || true
    if [ ! -f /etc/systemd/resolved.conf ]; then
        printf "[Resolve]\nDNS=%s\nFallbackDNS=1.1.1.1 8.8.8.8\n" "$NS_LIST" > /etc/systemd/resolved.conf
    else
        if grep -q "^\[Resolve\]" /etc/systemd/resolved.conf; then
            if grep -q "^DNS=" /etc/systemd/resolved.conf; then sed -i "s/^DNS=.*/DNS=$NS_LIST/" /etc/systemd/resolved.conf
            else sed -i "/^\[Resolve\]/a DNS=$NS_LIST" /etc/systemd/resolved.conf; fi
            if ! grep -q "^FallbackDNS=" /etc/systemd/resolved.conf; then sed -i "/^DNS=/a FallbackDNS=1.1.1.1 8.8.8.8" /etc/systemd/resolved.conf; fi
        else printf "\n[Resolve]\nDNS=%s\nFallbackDNS=1.1.1.1 8.8.8.8\n" "$NS_LIST" >> /etc/systemd/resolved.conf; fi
    fi
    cat /etc/systemd/resolved.conf
    systemctl enable systemd-resolved 2>/dev/null || true
    systemctl restart systemd-resolved 2>/dev/null || systemctl start systemd-resolved 2>/dev/null || true
    sleep 1
    if [ -f /run/systemd/resolve/stub-resolv.conf ]; then rm -f /etc/resolv.conf; ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf; echo -e "${GREEN}Linked -> stub-resolv.conf${NC}"
    elif [ -f /run/systemd/resolve/resolv.conf ]; then rm -f /etc/resolv.conf; ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf; echo -e "${GREEN}Linked -> resolv.conf${NC}"; fi
    command -v resolvectl >/dev/null 2>&1 && resolvectl status 2>&1 | head -n 40
    echo -e "${GREEN}Persistent DNS configured.${NC}"
}
_dns_test_dns() {
    read -r -p "Enter domain to test (default: google.com): " D; D=${D:-google.com}; D=$(echo "$D" | xargs)
    echo -e "\n--- getent hosts $D ---"; getent hosts "$D" 2>&1 || echo "(failed)"
    echo ""; echo "--- resolvectl query $D ---"
    if command -v resolvectl >/dev/null 2>&1; then resolvectl query "$D" 2>&1 | head -n 30; else echo "(resolvectl not found)"; fi
    echo ""; echo "--- dig $D ---"
    if command -v dig >/dev/null 2>&1; then dig "$D" +short 2>&1 | head -n 20; else echo "(dig not installed: apt install dnsutils)"; fi
    echo ""; echo "--- ping -c1 $D ---"
    ping -c1 -W3 "$D" 2>&1 | head -n 10 || echo "(ping failed)"
}
manage_dns() {
    while true; do
        if [ -L /etc/resolv.conf ]; then LINK=" -> $(readlink /etc/resolv.conf)"; else LINK=""; fi
        echo -e "\n--- DNS Management (/etc/resolv.conf) ---"
        echo -e "Current: ${YELLOW}$(grep "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}' | xargs || echo '(none)')${NC}  [file: /etc/resolv.conf${LINK}]"
        echo "1) Show full DNS config"
        echo "2) Add nameserver"
        echo "3) Edit nameserver (replace)"
        echo "4) Delete nameserver"
        echo "5) Manage search / options / domain"
        echo "6) Reset to defaults (8.8.8.8, 1.1.1.1)"
        echo "7) Make persistent (systemd-resolved)"
        echo "8) Test DNS (getent / dig / ping)"
        echo "9) Restore from backup"
        echo "0) Back"
        read -r -p "Choice: " DNS_CHOICE
        case "$DNS_CHOICE" in
            1) _dns_show_resolv ;;
            2) _dns_add_nameserver ;;
            3) _dns_edit_nameserver ;;
            4) _dns_delete_nameserver ;;
            5) _dns_set_search_options ;;
            6) _dns_reset_defaults ;;
            7) _dns_make_persistent ;;
            8) _dns_test_dns ;;
            9) echo "Backups:"; ls -lt /etc/resolv.conf.bak.* 2>/dev/null | head -n 20 || echo "(no backups)"; ls -lt /etc/systemd/resolved.conf.bak.* 2>/dev/null | head -n 5 || true
               read -r -p "Enter backup path to restore (Enter to cancel): " BK; BK=$(echo "$BK" | xargs)
               if [ -n "$BK" ] && [ -f "$BK" ]; then
                   if [[ "$BK" == *"resolved.conf"* ]]; then cp "$BK" /etc/systemd/resolved.conf && echo -e "${GREEN}Restored $BK${NC}" && systemctl restart systemd-resolved 2>/dev/null || true
                   else [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf; cp "$BK" /etc/resolv.conf && echo -e "${GREEN}Restored $BK${NC}" && cat /etc/resolv.conf; fi
               elif [ -n "$BK" ]; then echo -e "${RED}Not found: $BK${NC}"; fi ;;
            0) break ;; *) echo -e "${RED}Invalid choice.${NC}" ;;
        esac
    done
}
