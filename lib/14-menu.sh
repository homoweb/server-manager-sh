pushit_ensure_bootstrap() {
    # Auto-install when running via curl|bash (binary not yet present)
    if ! pushit_is_installed; then
        echo -e "${YELLOW}Installing pushit to $PUSHIT_BIN ...${NC}"
        if pushit_auto_install; then
            echo -e "${GREEN}Installed to $PUSHIT_BIN${NC}"
        else
            echo -e "${RED}Auto-install failed (non-fatal).${NC}"
        fi
    else
        # Update binary if running from a newer script file (e.g., curl re-run)
        local cur_ver="" bin_ver=""
        cur_ver=$(grep -m1 "^# Ubuntu Server Manager" "$0" 2>/dev/null || echo "")
        bin_ver=$(grep -m1 "^# Ubuntu Server Manager" "$PUSHIT_BIN" 2>/dev/null || echo "")
        # Simple heuristic: if files differ, refresh
        if [ -f "$0" ] && ! cmp -s "$0" "$PUSHIT_BIN" 2>/dev/null; then
            install -m 0755 "$0" "$PUSHIT_BIN" 2>/dev/null || true
        fi
    fi
    # First-run wizard if no config yet
    if [ ! -f "$PUSHIT_CONFIG" ]; then
        pushit_first_run_wizard
    fi
}

show_menu() {
    pushit_show_banner
    pushit_update_check
    pushit_show_update_notice
    echo -e "\n=== Server Manager (pushit) ==="
    if [ -f "$PUSHIT_CONFIG" ]; then
        . "$PUSHIT_CONFIG" 2>/dev/null || true
        if [ "${PUSHIT_MODE:-}" = "ip" ] && [ -n "${PUSHIT_PORT:-}" ]; then
            local _ip="${PUSHIT_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
            echo -e "${YELLOW} [IP mode: ${_ip:-<ip>}:${PUSHIT_PORT}]${NC}"
        elif [ "${PUSHIT_MODE:-}" = "domain" ] && [ -n "${PUSHIT_DOMAIN:-}" ]; then
            echo -e "${YELLOW} [Domain mode: ${PUSHIT_DOMAIN}]${NC}"
        fi
    fi
    echo "0) Exit"
    echo "1) Manage Mirrors (APT)"
    echo "2) Install Full Stack (Nginx, PHP ${PHP_VERSION}, MySQL, Redis, Node)"
    echo "3) Manage Sites (Deploy / Delete)"
    echo "4) Install SSL (Certbot)"
    echo "5) Manage Firewall (UFW)"
    echo "6) Harden Server (SSH)"
    echo "7) Manage DB"
    echo "8) Manage Cron"
    echo "9) Manage Supervisor"
    echo "10) Manage DNS (/etc/resolv.conf)"
    echo "11) Change Access Mode (IP:port / Domain)"
    if [ "${PUSHIT_HAS_UPDATE:-0}" = "1" ]; then
        echo -e "${YELLOW}12) ★ Update Script (v${PUSHIT_VERSION} → v${PUSHIT_REMOTE_VER}) [press 'u']${NC}"
    else
        echo "12) Update Script (from GitHub)"
    fi
    echo -e "${RED}13) Uninstall Pushit (remove script & cache)${NC}"
    read -r -p "Option [u=update]: " OPT
    # Shortcut: 'u' / 'U' triggers update when available, or anyway
    if [[ "$OPT" =~ ^[uU]$ ]]; then OPT="12"; fi
    case $OPT in
        0) exit 0 ;;
        1) change_mirror ;;
        2) install_stack ;;
        3) manage_sites ;;
        4) install_ssl ;;
        5) manage_firewall ;;
        6) harden_server ;;
        7) manage_database_menu ;;
        8) manage_cron ;;
        9) manage_supervisor ;;
        10) manage_dns ;;
        11) pushit_first_run_wizard ;;
        12) pushit_update_script ;;
        13) pushit_uninstall ;;
        *) echo "Invalid option." ;;
    esac
}


check_root
pushit_ensure_bootstrap
while true; do
    show_menu
done
