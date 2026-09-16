
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Execute as root or with sudo.${NC}"
        exit 1
    fi
}
# Anchor the script to a guaranteed-existing directory. The deploy flow used
# to 'cd' into /home/<user>/<domain>; when that directory was later removed
# (Delete Site, manual cleanup, ...), the script kept standing in a deleted
# directory and every git call died with:
#   fatal: Unable to read current working directory: No such file or directory
# even though the repo, branch and credentials were all fine.
anchor_cwd() {
    cd /root 2>/dev/null || cd /
}

install_to_bin() {
    local _src="${1:-https://raw.githubusercontent.com/homoweb/server-manager-sh/main/server_manager.sh}"
    if [ -f "$_src" ]; then
        install -m 0755 "$_src" "$PUSHIT_BIN" \
            && echo -e "${GREEN}Script installed/updated at $PUSHIT_BIN. Run 'sudo pushit' from anywhere.${NC}" \
            || echo -e "${RED}Installation failed.${NC}"
    else
        curl -fsSL "$_src" -o "$PUSHIT_BIN" \
            && chmod +x "$PUSHIT_BIN" \
            && echo -e "${GREEN}Script installed/updated at $PUSHIT_BIN. Run 'sudo pushit' from anywhere.${NC}" \
            || echo -e "${RED}Installation failed. Check your internet connection and try again.${NC}"
    fi
}
pushit_write_config() {
    local mode="$1" value="$2" ip_detected
    ip_detected=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$ip_detected" ] && ip_detected=$(hostname -i 2>/dev/null | awk '{print $1}')
    {
        echo "# Pushit config - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'PUSHIT_MODE="%s"\n' "$mode"
        if [ "$mode" = "ip" ]; then
            printf 'PUSHIT_PORT="%s"\n' "$value"
            printf 'PUSHIT_IP="%s"\n' "${ip_detected:-}"
            echo 'PUSHIT_DOMAIN=""'
        else
            printf 'PUSHIT_DOMAIN="%s"\n' "$value"
            echo 'PUSHIT_PORT=""'
            printf 'PUSHIT_IP="%s"\n' "${ip_detected:-}"
        fi
    } > "$PUSHIT_CONFIG"
    chmod 600 "$PUSHIT_CONFIG" 2>/dev/null || true
}
pushit_load_config() {
    [ -f "$PUSHIT_CONFIG" ] && . "$PUSHIT_CONFIG" 2>/dev/null || true
}
pushit_auto_install() {
    local me=""
    if [ -f "$0" ] && head -n1 "$0" 2>/dev/null | grep -q "Server Manager"; then me="$0"
    elif [ -n "${BASH_SOURCE[0]}" ] && [ -f "${BASH_SOURCE[0]}" ] && head -n1 "${BASH_SOURCE[0]}" 2>/dev/null | grep -q "Server Manager"; then me="${BASH_SOURCE[0]}"; fi
    if [ -n "$me" ] && [ -f "$me" ]; then install -m 0755 "$me" "$PUSHIT_BIN" 2>/dev/null && return 0; fi
    curl -fsSL https://raw.githubusercontent.com/homoweb/server-manager-sh/main/server_manager.sh -o "$PUSHIT_BIN" 2>/dev/null && chmod +x "$PUSHIT_BIN" 2>/dev/null && return 0
    return 1
}
pushit_first_run_wizard() {
    echo ""; echo -e "${YELLOW}Welcome to Pushit! First-time setup.${NC}"; echo ""
    echo "How will this server be accessed?"
    echo "  1) IP with port  (e.g., http://1.2.3.4:8080)"
    echo "  2) Domain        (e.g., https://example.com)"
    local choice=""
    while true; do
        read -r -p "Choice [1/2]: " choice; choice=$(echo "$choice" | xargs)
        if [ "$choice" = "1" ] || [ "$choice" = "2" ]; then break; fi
        echo -e "${RED}Please enter 1 or 2.${NC}"
    done
    if [ "$choice" = "1" ]; then
        local def_port="8080" port=""
        while true; do
            read -r -p "Enter port to use [default: $def_port]: " port; port=$(echo "$port" | xargs); [ -z "$port" ] && port="$def_port"
            if ! [[ "$port" =~ ^[0-9]+$ ]]; then echo -e "${RED}Port must be a number (1-65535).${NC}"; continue; fi
            if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then echo -e "${RED}Port out of range.${NC}"; continue; fi
            if command -v ss >/dev/null 2>&1 && ss -tlnH 2>/dev/null | grep -q ":${port} "; then
                echo -e "${YELLOW}Warning: port $port appears in use.${NC}"; read -r -p "Use it anyway? (y/n): " yn; if ! [[ "$yn" =~ ^[yY] ]]; then continue; fi
            elif command -v netstat >/dev/null 2>&1 && netstat -tln 2>/dev/null | grep -q ":${port} "; then
                echo -e "${YELLOW}Warning: port $port appears in use.${NC}"; read -r -p "Use it anyway? (y/n): " yn; if ! [[ "$yn" =~ ^[yY] ]]; then continue; fi
            fi
            break
        done
        pushit_write_config "ip" "$port"
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then ufw allow "$port/tcp" >/dev/null 2>&1 || ufw allow "$port" >/dev/null 2>&1 || true; echo -e "${GREEN}UFW: allowed $port/tcp${NC}"; fi
        echo ""; echo -e "${GREEN}Setup complete: server will run on IP with port $port${NC}"
    else
        local domain=""
        while true; do
            read -r -p "Enter domain (e.g., example.com) [Enter to skip]: " domain; domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | xargs)
            if [ -z "$domain" ]; then break; fi
            if ! [[ "$domain" =~ ^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$ ]]; then echo -e "${RED}Invalid domain. Try again or Enter to skip.${NC}"; continue; fi
            break
        done
        pushit_write_config "domain" "$domain"
        echo ""; if [ -n "$domain" ]; then echo -e "${GREEN}Setup complete: domain mode ($domain)${NC}"; else echo -e "${GREEN}Setup complete: domain mode (no default domain).${NC}"; fi
    fi
    echo -e "${GREEN}Config saved to $PUSHIT_CONFIG${NC}"; echo ""
}
pushit_show_banner() {
    pushit_load_config
    if [ -f "$PUSHIT_CONFIG" ]; then
        if [ "${PUSHIT_MODE:-}" = "ip" ] && [ -n "${PUSHIT_PORT:-}" ]; then
            local ip_disp="${PUSHIT_IP:-}"
            [ -z "$ip_disp" ] && ip_disp=$(hostname -I 2>/dev/null | awk '{print $1}')
            [ -z "$ip_disp" ] && ip_disp="<server-ip>"
            echo -e "${GREEN}Mode: IP  |  http://${ip_disp}:${PUSHIT_PORT}  (port ${PUSHIT_PORT})${NC}"
        elif [ "${PUSHIT_MODE:-}" = "domain" ]; then
            if [ -n "${PUSHIT_DOMAIN:-}" ]; then echo -e "${GREEN}Mode: Domain  |  https://${PUSHIT_DOMAIN}${NC}"
            else echo -e "${GREEN}Mode: Domain  (no default domain set)${NC}"; fi
        fi
    fi
    echo -e " pushit v${PUSHIT_VERSION}  (${PUSHIT_REPO})"
}

