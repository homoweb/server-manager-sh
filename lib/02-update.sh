# --- Update check (no branch, semver compare via PUSHIT_VERSION) ---
pushit_version_gt() {
    local a="$1" b="$2"
    [ -z "$a" ] || [ -z "$b" ] && return 1
    [ "$a" = "$b" ] && return 1
    local smallest
    smallest=$(printf "%s\n%s\n" "$a" "$b" | sort -V 2>/dev/null | head -n1)
    [ "$smallest" = "$b" ] && [ "$a" != "$b" ]
}

pushit_fetch_remote_version() {
    mkdir -p "$PUSHIT_UPDATE_CACHE_DIR" 2>/dev/null || true
    local tmp
    tmp=$(mktemp /tmp/pushit_ver.XXXXXX 2>/dev/null || echo "/tmp/pushit_ver.$$")
    # Bypass CDN cache; short timeout so menu never hangs
    if curl -fsSL --max-time 4 --connect-timeout 3 -H "Cache-Control: no-cache" -H "Pragma: no-cache" "$PUSHIT_REMOTE_URL" -o "$tmp" 2>/dev/null; then
        local rv=""
        rv=$(grep -m1 '^PUSHIT_VERSION=' "$tmp" 2>/dev/null | sed -E 's/^PUSHIT_VERSION="([^"]+)".*/\1/' | xargs 2>/dev/null)
        [ -z "$rv" ] && rv=$(grep -m1 '^PUSHIT_VERSION=' "$tmp" 2>/dev/null | cut -d= -f2 | tr -d '"'\'' ' | xargs 2>/dev/null)
        if [ -n "$rv" ]; then
            printf '{"remote":"%s","checked":%s}\n' "$rv" "$(date +%s)" > "${PUSHIT_UPDATE_CACHE_FILE}.tmp" 2>/dev/null && mv -f "${PUSHIT_UPDATE_CACHE_FILE}.tmp" "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null
            chmod 644 "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null || true
        fi
    fi
    rm -f "$tmp" 2>/dev/null || true
}

# Sets globals: PUSHIT_HAS_UPDATE (0/1), PUSHIT_REMOTE_VER
PUSHIT_HAS_UPDATE=0
PUSHIT_REMOTE_VER=""
pushit_update_check() {
    local now cache_mtime=0 cached_remote=""
    now=$(date +%s 2>/dev/null || echo 0)
    if [ -f "$PUSHIT_UPDATE_CACHE_FILE" ]; then
        cache_mtime=$(stat -c %Y "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null || stat -f %m "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null || echo 0)
        cached_remote=$(grep -o '"remote"[[:space:]]*:[[:space:]]*"[^"]*"' "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null | head -n1 | cut -d'"' -f4)
        # Stale -> refresh (with timeout, non-fatal)
        if [ "$now" -gt 0 ] && [ "$cache_mtime" -gt 0 ] && [ $((now - cache_mtime)) -gt "$PUSHIT_UPDATE_TTL" ]; then
            pushit_fetch_remote_version
            cached_remote=$(grep -o '"remote"[[:space:]]*:[[:space:]]*"[^"]*"' "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null | head -n1 | cut -d'"' -f4)
        fi
    else
        pushit_fetch_remote_version
        cached_remote=$(grep -o '"remote"[[:space:]]*:[[:space:]]*"[^"]*"' "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null | head -n1 | cut -d'"' -f4)
    fi
    PUSHIT_REMOTE_VER="$cached_remote"
    PUSHIT_HAS_UPDATE=0
    if [ -n "$PUSHIT_REMOTE_VER" ] && pushit_version_gt "$PUSHIT_REMOTE_VER" "$PUSHIT_VERSION"; then
        PUSHIT_HAS_UPDATE=1
    fi
}

pushit_show_update_notice() {
    if [ "${PUSHIT_HAS_UPDATE:-0}" = "1" ] && [ -n "${PUSHIT_REMOTE_VER:-}" ]; then
        echo ""
        echo -e "${YELLOW}┌──────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}│  ★ Update available: v${PUSHIT_VERSION} → v${PUSHIT_REMOTE_VER}                     │${NC}"
        echo -e "${YELLOW}│  Run option 12 or press 'u' to update now.           │${NC}"
        echo -e "${YELLOW}└──────────────────────────────────────────────────────┘${NC}"
    fi
}

pushit_update_script() {
    local url="${PUSHIT_REMOTE_URL}"
    echo -e "${YELLOW}Checking for updates...${NC}"
    echo -e " Current: v${PUSHIT_VERSION}"
    # Force fresh fetch when user explicitly asks to update
    pushit_fetch_remote_version
    local remote_ver=""
    remote_ver=$(grep -o '"remote"[[:space:]]*:[[:space:]]*"[^"]*"' "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null | head -n1 | cut -d'"' -f4)
    if [ -n "$remote_ver" ]; then
        echo -e " Remote : v${remote_ver}"
        if ! pushit_version_gt "$remote_ver" "$PUSHIT_VERSION"; then
            if [ "$remote_ver" = "$PUSHIT_VERSION" ]; then
                echo -e "${GREEN}Already up to date (v${PUSHIT_VERSION}).${NC}"
                read -r -p "Force re-download anyway? (y/n): " _force
                if ! [[ "$_force" =~ ^[yY] ]]; then return 0; fi
            else
                echo -e "${YELLOW}Local version newer than remote (dev build?). Continuing anyway.${NC}"
            fi
        else
            echo -e "${YELLOW}Update available: v${PUSHIT_VERSION} → v${remote_ver}${NC}"
        fi
    fi
    echo -e "${YELLOW}Downloading from $url ...${NC}"
    local tmp
    tmp=$(mktemp /tmp/pushit.XXXXXX)
    if ! curl -fsSL -H "Cache-Control: no-cache" -H "Pragma: no-cache" "${url}?v=$(date +%s)" -o "$tmp" 2>/dev/null; then
        if ! curl -fsSL "$url" -o "$tmp" 2>/dev/null; then
            echo -e "${RED}Download failed. Check internet / URL.${NC}"
            rm -f "$tmp"
            return 1
        fi
    fi
    if ! head -n1 "$tmp" 2>/dev/null | grep -q "Server Manager"; then
        echo -e "${RED}Downloaded file looks invalid (missing header). Aborted.${NC}"
        rm -f "$tmp"
        return 1
    fi
    if ! bash -n "$tmp" 2>&1; then
        echo -e "${RED}Downloaded script has syntax errors. Aborted.${NC}"
        rm -f "$tmp"
        return 1
    fi
    local new_ver=""
    new_ver=$(grep -m1 '^PUSHIT_VERSION=' "$tmp" 2>/dev/null | cut -d= -f2 | tr -d '"'\'' ' | xargs 2>/dev/null)
    # Backup current binary
    if [ -f "$PUSHIT_BIN" ]; then
        cp -a "$PUSHIT_BIN" "${PUSHIT_BIN}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || cp "$PUSHIT_BIN" "${PUSHIT_BIN}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
    install -m 0755 "$tmp" "$PUSHIT_BIN"
    rm -f "$tmp"
    # Refresh cache so banner disappears after update
    if [ -n "$new_ver" ]; then
        mkdir -p "$PUSHIT_UPDATE_CACHE_DIR" 2>/dev/null || true
        printf '{"remote":"%s","checked":%s}\n' "$new_ver" "$(date +%s)" > "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null || true
        PUSHIT_REMOTE_VER="$new_ver"; PUSHIT_HAS_UPDATE=0; PUSHIT_VERSION="$new_ver"
    fi
    echo -e "${GREEN}Updated to $PUSHIT_BIN ${new_ver:+ (v$new_ver)}. Restart with 'sudo pushit'.${NC}"
    if [ "$0" != "$PUSHIT_BIN" ] && [ "${BASH_SOURCE[0]:-}" != "$PUSHIT_BIN" ]; then
        echo -e "${YELLOW}Note: you are running a different copy; restart with 'sudo pushit' for the updated script.${NC}"
    fi
}

pushit_uninstall() {
    echo -e "${RED}=== Uninstall Pushit ===${NC}"
    echo "This will remove:"
    echo "  - $PUSHIT_BIN"
    echo "  - $PUSHIT_CONFIG"
    echo "  - ${PUSHIT_BIN}.bak.* (backups)"
    echo "  - /tmp/pushit.* (temp downloads)"
    echo "  - $PUSHIT_DL_DIR (one-time links)"
    echo "  - $PUSHIT_DL_SERVER + systemd units"
    echo "  - $PUSHIT_UPDATE_CACHE_DIR (update check cache)"
    local cur=""
    if [ -f "$0" ] && [ "$0" != "$PUSHIT_BIN" ] && head -n1 "$0" 2>/dev/null | grep -q "Server Manager"; then cur="$0"
    elif [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ] && [ "${BASH_SOURCE[0]}" != "$PUSHIT_BIN" ] && head -n1 "${BASH_SOURCE[0]}" 2>/dev/null | grep -q "Server Manager"; then cur="${BASH_SOURCE[0]}"
    fi
    if [ -n "$cur" ]; then echo "  - $cur (current file)"; fi
    echo ""
    read -r -p "Type 'yes' to confirm uninstall: " CONF
    if [ "$CONF" != "yes" ]; then echo "Aborted."; return 1; fi
    echo -e "${YELLOW}Removing...${NC}"
    rm -f "$PUSHIT_BIN" 2>/dev/null || true
    rm -f "$PUSHIT_CONFIG" 2>/dev/null || true
    rm -f "${PUSHIT_BIN}.bak."* 2>/dev/null || true
    rm -f /tmp/pushit.* 2>/dev/null || true
    rm -rf "$PUSHIT_UPDATE_CACHE_DIR" 2>/dev/null || true
    systemctl disable --now pushit-dl.service 2>/dev/null || true
    systemctl disable --now pushit-dl-prune.timer 2>/dev/null || true
    rm -f /etc/systemd/system/pushit-dl.service /etc/systemd/system/pushit-dl-prune.service /etc/systemd/system/pushit-dl-prune.timer 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    pkill -f "$PUSHIT_DL_SERVER" 2>/dev/null || true
    rm -rf "$PUSHIT_DL_DIR" 2>/dev/null || true
    rm -f "$PUSHIT_DL_SERVER" "$PUSHIT_DL_LOG" 2>/dev/null || true
    if command -v ufw >/dev/null 2>&1; then ufw delete allow "${PUSHIT_DL_PORT}/tcp" 2>/dev/null || true; fi
    hash -r 2>/dev/null || true
    if [ -n "$cur" ]; then
        read -r -p "Also remove current file '$cur'? (y/n): " RM_CUR
        if [[ "$RM_CUR" =~ ^[yY] ]]; then rm -f "$cur" 2>/dev/null && echo "Removed $cur" || echo "Could not remove $cur"; fi
    fi
    # Verify
    local remain=0
    [ -f "$PUSHIT_BIN" ] && remain=1
    [ -f "$PUSHIT_CONFIG" ] && remain=1
    if [ "$remain" -eq 0 ]; then echo -e "${GREEN}Pushit completely removed. Restart your shell.${NC}"
    else echo -e "${RED}Some files remain (check permissions).${NC}"; ls -l "$PUSHIT_BIN" "$PUSHIT_CONFIG" 2>&1 | head -n 10; fi
    echo -e "${YELLOW}Exiting.${NC}"
    exit 0
}

