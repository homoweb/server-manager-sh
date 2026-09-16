install_stack() {
    export DEBIAN_FRONTEND=noninteractive

    echo -e "${YELLOW}Updating system packages...${NC}"
    _apt_clean_stale_bak 2>/dev/null || true
    # If current mirror is 403-broken, auto-fix before touching apt
    local _cur_mir
    _cur_mir=$(_detect_current_mirror 2>/dev/null || echo "")
    if [[ "$_cur_mir" == *"manageitcloud.com"* ]]; then
        echo -e "${YELLOW}Current mirror ${_cur_mir} looks broken (known 403) — auto-fixing...${NC}"
        pushit_fix_broken_mirror || true
    fi
    if ! apt-get update; then
        echo -e "${RED}apt-get update failed. Checking for 403/mirror issue...${NC}"
        if ! pushit_fix_broken_mirror; then
            echo -e "${RED}Mirror auto-fix failed. Fix APT manually (pushit -> 1 -> 4 or 7).${NC}"
            return 1
        fi
        echo -e "${YELLOW}Retrying apt-get update/upgrade...${NC}"
        apt-get update || { echo -e "${RED}Still failing after mirror fix. Aborting stack install.${NC}"; return 1; }
    fi
    # Detect stale 403 even when exit code is 0 (apt can return 0 with Err:403 lines)
    local _chk
    _chk=$(mktemp /tmp/pushit_apt_install_chk.XXXXXX 2>/dev/null || echo "/tmp/pushit_apt_install_chk.$$")
    apt-get update 2>&1 | tee "$_chk" >/dev/null 2>&1 || true
    if grep -qE "403.*Forbidden|Failed to fetch" "$_chk" 2>/dev/null; then
        echo -e "${RED}apt update still reports 403 after mirror check. Auto-fixing...${NC}"
        rm -f "$_chk"
        pushit_fix_broken_mirror || true
        apt-get update || { echo -e "${RED}Still failing. Aborting.${NC}"; return 1; }
    else
        rm -f "$_chk"
    fi
    apt-get upgrade -y

    echo -e "${YELLOW}Installing base packages...${NC}"
    apt-get install -y lsb-release software-properties-common curl wget git unzip ufw fail2ban supervisor redis-server
    
    # PHP (the ondrej/php PPA only supports Ubuntu LTS codenames)
    CODENAME=$(lsb_release -cs)
    case "$CODENAME" in
        focal|jammy|noble)
            add-apt-repository ppa:ondrej/php -y
            apt-get update
            apt-get install -y "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-mysql" \
                "php${PHP_VERSION}-redis" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-mbstring" \
                "php${PHP_VERSION}-curl" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-gd" "php${PHP_VERSION}-bcmath"
            ;;
        *)
            echo -e "${YELLOW}Codename '$CODENAME' is not supported by the ondrej/php PPA.${NC}"
            echo -e "${YELLOW}Install PHP ${PHP_VERSION} manually, then re-run this option.${NC}"
            ;;
    esac
    
    # Nginx & MySQL
    apt-get install -y nginx mysql-server
    
    # Node.js (re-running this option also upgrades an existing Node 20 to the version above)
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
    apt-get install -y nodejs
    
    # Composer (requires PHP CLI)
    if command -v php > /dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    else
        echo -e "${RED}PHP CLI not found; Composer was not installed.${NC}"
    fi
    
    # Certbot
    apt-get install -y certbot python3-certbot-nginx

    # Fix Sudo Hostname Resolution
    echo "127.0.0.1 localhost $(hostname)" > /etc/hosts
    
    # Fix DNS Resolution (Using Google & Cloudflare)
    rm -f /etc/resolv.conf
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf

    # Heads-up: some frontend builds need extra outbound hosts. The laravel:fonts
    # plugin (laravel-vite-plugin) downloads @font-face CSS + woff2 files from
    # fonts.bunny.net / fonts.googleapis.com during 'npm run build'. If these are
    # unreachable, the build dies with "[plugin laravel:fonts] TypeError: fetch
    # failed ... ETIMEDOUT". Once downloaded they are cached under
    # node_modules/.cache/laravel-vite-plugin/fonts and no network is needed again.
    echo -e "${YELLOW}Reminder: 'npm run build' for Laravel apps may need access to fonts.bunny.net / fonts.googleapis.com.${NC}"
    echo -e "${YELLOW}If a site build later fails with '[plugin laravel:fonts] fetch failed / ETIMEDOUT',${NC}"
    echo -e "${YELLOW}check DNS (just configured above), UFW rules and any provider-side filtering.${NC}"

    unset DEBIAN_FRONTEND
    echo -e "${GREEN}Stack installed successfully.${NC}"
}

