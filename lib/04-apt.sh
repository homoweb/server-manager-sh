PUSHIT_APT_BACKUP_DIR="/var/backups/pushit/apt"
_apt_clean_stale_bak() {
    local f
    for f in /etc/apt/sources.list.d/*.bak.* /etc/apt/sources.list.d/*.bak; do
        [ -e "$f" ] || continue
        mkdir -p "$PUSHIT_APT_BACKUP_DIR" 2>/dev/null || true
        mv -f "$f" "$PUSHIT_APT_BACKUP_DIR/" 2>/dev/null || rm -f "$f" 2>/dev/null || true
        echo -e "${YELLOW}Moved stale apt backup $(basename "$f") -> $PUSHIT_APT_BACKUP_DIR/${NC}"
    done 2>/dev/null || true
}
_apply_apt_mirror() {
    local MIRROR_URL="$1"
    local CODENAME
    CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy")
    # Normalize: ensure trailing slash
    [[ "$MIRROR_URL" != */ ]] && MIRROR_URL="${MIRROR_URL}/"
    # Known broken mirrors — warn upfront (manageitcloud currently returns 403 on pool/)
    if [[ "$MIRROR_URL" == *"manageitcloud.com"* ]]; then
        echo -e "${YELLOW}Warning: mirror.manageitcloud.com is currently returning 403 on some packages.${NC}"
        echo -e "${YELLOW}If apt fails, the script will auto-rollback. Recommended: Abrha or Official.${NC}"
    fi
    # Backup existing files (store OUTSIDE sources.list.d to avoid apt warning N: Ignoring file ...)
    local TS
    TS=$(date +%Y%m%d%H%M%S)
    mkdir -p "$PUSHIT_APT_BACKUP_DIR" 2>/dev/null || true
    _apt_clean_stale_bak
    if [ -f /etc/apt/sources.list ]; then
        cp /etc/apt/sources.list "${PUSHIT_APT_BACKUP_DIR}/sources.list.bak.${TS}" 2>/dev/null || true
    fi
    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
        cp /etc/apt/sources.list.d/ubuntu.sources "${PUSHIT_APT_BACKUP_DIR}/ubuntu.sources.bak.${TS}" 2>/dev/null || true
    fi

    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
        cat <<EOF > /etc/apt/sources.list.d/ubuntu.sources
Types: deb
URIs: ${MIRROR_URL}
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
        if [ -f /etc/apt/sources.list ]; then
            # Comment out classic lines so only ubuntu.sources is active (avoid duplicate)
            sed -i 's|^\(deb\)|# \1|' /etc/apt/sources.list 2>/dev/null || true
        fi
    else
        cat <<EOF > /etc/apt/sources.list
deb ${MIRROR_URL} $CODENAME main restricted universe multiverse
deb ${MIRROR_URL} $CODENAME-updates main restricted universe multiverse
deb ${MIRROR_URL} $CODENAME-security main restricted universe multiverse
EOF
    fi

    echo -e "${YELLOW}Updating package lists from ${MIRROR_URL} ...${NC}"
    local _apt_out
    _apt_out=$(mktemp /tmp/pushit_apt.XXXXXX 2>/dev/null || echo "/tmp/pushit_apt.$$")
    local _apt_rc=0
    if ! apt-get update 2>&1 | tee "$_apt_out"; then _apt_rc=$?; fi
    # apt-get update can return 0 even with Err:403 — detect it via output
    if [ "$_apt_rc" -ne 0 ] || grep -qE "403.*Forbidden|Failed to fetch" "$_apt_out" 2>/dev/null; then
        echo -e "${RED}apt-get update reported errors for ${MIRROR_URL} (403/Failed to fetch). Restoring backup...${NC}"
        cat "$_apt_out" 2>/dev/null | grep -E "403|Failed to fetch" | head -n 5
        # Restore backup if available
        if [ -f "${PUSHIT_APT_BACKUP_DIR}/sources.list.bak.${TS}" ]; then
            cp "${PUSHIT_APT_BACKUP_DIR}/sources.list.bak.${TS}" /etc/apt/sources.list 2>/dev/null || true
        fi
        if [ -f "${PUSHIT_APT_BACKUP_DIR}/ubuntu.sources.bak.${TS}" ]; then
            cp "${PUSHIT_APT_BACKUP_DIR}/ubuntu.sources.bak.${TS}" /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
        fi
        rm -f "$_apt_out" 2>/dev/null || true
        # Clean stale bak that would cause warning on next run
        _apt_clean_stale_bak
        return 1
    fi
    rm -f "$_apt_out" 2>/dev/null || true
    _apt_clean_stale_bak
    echo -e "${GREEN}Mirror updated to ${MIRROR_URL}${NC}"
    return 0
}
pushit_fix_broken_mirror() {
    local cur fallback="http://archive.ubuntu.com/ubuntu/"
    cur=$(_detect_current_mirror 2>/dev/null || echo "")
    echo -e "${YELLOW}Current mirror: ${cur}${NC}"
    # Auto-clean stale bak files first (fixes N: Ignoring file ... warning)
    _apt_clean_stale_bak
    if [[ "$cur" == *"manageitcloud.com"* ]]; then
        echo -e "${YELLOW}Detected broken mirror manageitcloud.com — switching to official...${NC}"
        if _apply_apt_mirror "$fallback"; then
            echo -e "${GREEN}Fixed: now using $fallback${NC}"
            return 0
        fi
        echo -e "${YELLOW}Official mirror also failed, trying Abrha...${NC}"
        _apply_apt_mirror "https://repo.abrha.net/ubuntu/" && return 0
        _apply_apt_mirror "https://mirror.arvancloud.ir/ubuntu/" && return 0
        return 1
    fi
    # Generic: try apt update and if 403 detected, rollback to official
    local _tmp
    _tmp=$(mktemp /tmp/pushit_apt_check.XXXXXX 2>/dev/null || echo "/tmp/pushit_apt_check.$$")
    apt-get update 2>&1 | tee "$_tmp" >/dev/null 2>&1 || true
    if grep -qE "403.*Forbidden|Failed to fetch" "$_tmp" 2>/dev/null; then
        echo -e "${RED}apt is currently failing (403). Switching to official mirror...${NC}"
        rm -f "$_tmp"
        _apply_apt_mirror "$fallback" && return 0
        _apply_apt_mirror "https://repo.abrha.net/ubuntu/" && return 0
        return 1
    fi
    rm -f "$_tmp"
    echo -e "${GREEN}No 403 detected. Mirror seems OK.${NC}"
    return 0
}

_detect_current_mirror() {
    local cur=""
    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
        cur=$(grep -m1 "^URIs:" /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null | awk '{print $2}')
    fi
    if [ -z "$cur" ] && [ -f /etc/apt/sources.list ]; then
        cur=$(grep -m1 "^deb " /etc/apt/sources.list 2>/dev/null | awk '{print $2}')
        # skip commented
        if [[ "$cur" == "#"* ]]; then
            cur=$(grep -m1 "^deb " /etc/apt/sources.list 2>/dev/null | sed 's/^# *//' | awk '{print $2}')
        fi
    fi
    echo "${cur:-unknown}"
}

change_mirror() {
    if ! command -v lsb_release > /dev/null 2>&1; then
        echo -e "${RED}'lsb_release' not found. Install it first: apt-get install -y lsb-release${NC}"
        return 1
    fi
    local CODENAME
    CODENAME=$(lsb_release -cs)
    local CURRENT
    CURRENT=$(_detect_current_mirror)

    while true; do
        CURRENT=$(_detect_current_mirror)
        echo -e "\n--- Manage Mirrors (APT) ---"
        echo -e "Current mirror: ${GREEN}${CURRENT}${NC}  (codename: ${CODENAME})"
        echo -e "Ubuntu version: $(lsb_release -ds 2>/dev/null || echo $CODENAME)"
        echo ""
        echo "1) Abrha            (https://repo.abrha.net/ubuntu/)"
        echo -e "2) ManageITCloud    (https://mirror.manageitcloud.com/ubuntu/) ${RED}[BROKEN 403]${NC}"
        echo "3) ArvanCloud       (https://mirror.arvancloud.ir/ubuntu/)"
        echo "4) Official Ubuntu  (http://archive.ubuntu.com/ubuntu/)  ${GREEN}[recommended if 403]${NC}"
        echo "5) Custom URL"
        echo "6) Show current APT sources"
        echo "7) Auto-fix broken mirror (detects 403 -> switch to Official)"
        echo "0) Back"
        read -r -p "Choice: " MIRROR_CHOICE
        case "$MIRROR_CHOICE" in
            1) _apply_apt_mirror "https://repo.abrha.net/ubuntu/" ;;
            2)
                echo -e "${RED}This mirror is currently returning 403 Forbidden on noble-updates/pool.${NC}"
                read -r -p "Try it anyway? (y/N): " _c; if ! [[ "$_c" =~ ^[yY] ]]; then echo "Skipped."; continue; fi
                _apply_apt_mirror "https://mirror.manageitcloud.com/ubuntu/"
                ;;
            3) _apply_apt_mirror "https://mirror.arvancloud.ir/ubuntu/" ;;
            4) _apply_apt_mirror "http://archive.ubuntu.com/ubuntu/" ;;
            5)
                read -r -p "Enter custom mirror URL (e.g., https://mirror.example.com/ubuntu/): " CUSTOM_URL
                CUSTOM_URL=$(echo "$CUSTOM_URL" | xargs)
                if [ -z "$CUSTOM_URL" ]; then
                    echo -e "${RED}Empty URL.${NC}"
                    continue
                fi
                # Basic validation: must look like http(s)://...
                if ! [[ "$CUSTOM_URL" =~ ^https?:// ]]; then
                    echo -e "${RED}URL must start with http:// or https://${NC}"
                    continue
                fi
                _apply_apt_mirror "$CUSTOM_URL"
                ;;
            6)
                echo -e "\n--- /etc/apt/sources.list ---"
                cat /etc/apt/sources.list 2>/dev/null || echo "(no sources.list)"
                echo -e "\n--- /etc/apt/sources.list.d/ubuntu.sources ---"
                cat /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || echo "(no ubuntu.sources)"
                echo ""
                ;;
            7) pushit_fix_broken_mirror ;;
            0) break ;;
            *) echo -e "${RED}Invalid choice.${NC}" ;;
        esac
    done
}

