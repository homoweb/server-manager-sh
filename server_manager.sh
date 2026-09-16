#!/bin/bash

# =========================================================================
# Ubuntu Server Manager (PHP/Laravel Stack)
# =========================================================================

# NOTE: 'set -e' is intentionally NOT used. This is an interactive menu tool;
# a single failing command (e.g. listing an empty crontab) must not kill the
# whole session.

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# Single source of truth for the PHP version (packages, FPM pool and socket)
PHP_VERSION="8.4"
# Single source of truth for the Node.js major version (NodeSource setup script)
NODE_VERSION="22"

PUSHIT_BIN="/usr/local/bin/pushit"
PUSHIT_CONFIG="/etc/pushit.conf"

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
        echo "PUSHIT_MODE=\"$mode\""
        if [ "$mode" = "ip" ]; then
            echo "PUSHIT_PORT=\"$value\""
            echo "PUSHIT_IP=\"${ip_detected:-}\""
            echo "PUSHIT_DOMAIN=\"\""
        else
            echo "PUSHIT_DOMAIN=\"$value\""
            echo "PUSHIT_PORT=\"\""
            echo "PUSHIT_IP=\"${ip_detected:-}\""
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
}

pushit_update_script() {
    local url="https://raw.githubusercontent.com/homoweb/server-manager-sh/main/server_manager.sh"
    echo -e "${YELLOW}Updating pushit from $url ...${NC}"
    local tmp
    tmp=$(mktemp /tmp/pushit.XXXXXX)
    if ! curl -fsSL "$url" -o "$tmp"; then
        echo -e "${RED}Download failed. Check internet / URL.${NC}"
        rm -f "$tmp"
        return 1
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
    # Backup current binary
    if [ -f "$PUSHIT_BIN" ]; then
        cp -a "$PUSHIT_BIN" "${PUSHIT_BIN}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || cp "$PUSHIT_BIN" "${PUSHIT_BIN}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
    install -m 0755 "$tmp" "$PUSHIT_BIN"
    rm -f "$tmp"
    echo -e "${GREEN}Updated to $PUSHIT_BIN. Run 'sudo pushit' to use the new version.${NC}"
    # If current process is not the installed binary, hint to re-exec
    if [ "$0" != "$PUSHIT_BIN" ] && [ "${BASH_SOURCE[0]:-}" != "$PUSHIT_BIN" ]; then
        echo -e "${YELLOW}Note: you are running a different copy; restart with 'sudo pushit' for the updated script.${NC}"
    fi
}

pushit_is_installed() {
    # Consider installed if we are already running as pushit, or binary exists
    if [ -x "$PUSHIT_BIN" ] && [ -f "$PUSHIT_BIN" ]; then return 0; fi
    if [ "$0" = "$PUSHIT_BIN" ] || [ "${BASH_SOURCE[0]:-}" = "$PUSHIT_BIN" ]; then return 0; fi
    return 1
}

_apply_apt_mirror() {
    local MIRROR_URL="$1"
    local CODENAME
    CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy")
    # Normalize: ensure trailing slash
    [[ "$MIRROR_URL" != */ ]] && MIRROR_URL="${MIRROR_URL}/"
    # Backup existing files
    local TS
    TS=$(date +%Y%m%d%H%M%S)
    if [ -f /etc/apt/sources.list ]; then
        cp /etc/apt/sources.list "/etc/apt/sources.list.bak.${TS}" 2>/dev/null || true
    fi
    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
        cp /etc/apt/sources.list.d/ubuntu.sources "/etc/apt/sources.list.d/ubuntu.sources.bak.${TS}" 2>/dev/null || true
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
            sed -i 's|^\(deb\)|# \1|' /etc/apt/sources.list
        fi
    else
        cat <<EOF > /etc/apt/sources.list
deb ${MIRROR_URL} $CODENAME main restricted universe multiverse
deb ${MIRROR_URL} $CODENAME-updates main restricted universe multiverse
deb ${MIRROR_URL} $CODENAME-security main restricted universe multiverse
EOF
    fi

    echo -e "${YELLOW}Updating package lists from ${MIRROR_URL} ...${NC}"
    if apt-get update; then
        echo -e "${GREEN}Mirror updated to ${MIRROR_URL}${NC}"
        return 0
    else
        echo -e "${RED}apt-get update failed for ${MIRROR_URL}. Restoring backup...${NC}"
        # Restore backup if available
        if [ -f "/etc/apt/sources.list.bak.${TS}" ]; then
            cp "/etc/apt/sources.list.bak.${TS}" /etc/apt/sources.list 2>/dev/null || true
        fi
        if [ -f "/etc/apt/sources.list.d/ubuntu.sources.bak.${TS}" ]; then
            cp "/etc/apt/sources.list.d/ubuntu.sources.bak.${TS}" /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
        fi
        return 1
    fi
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
        echo "2) ManageITCloud    (https://mirror.manageitcloud.com/ubuntu/)"
        echo "3) ArvanCloud       (https://mirror.arvancloud.ir/ubuntu/)"
        echo "4) Official Ubuntu  (http://archive.ubuntu.com/ubuntu/)"
        echo "5) Custom URL"
        echo "6) Show current APT sources"
        echo "0) Back"
        read -r -p "Choice: " MIRROR_CHOICE
        case "$MIRROR_CHOICE" in
            1) _apply_apt_mirror "https://repo.abrha.net/ubuntu/" ;;
            2) _apply_apt_mirror "https://mirror.manageitcloud.com/ubuntu/" ;;
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
            0) break ;;
            *) echo -e "${RED}Invalid choice.${NC}" ;;
        esac
    done
}

install_stack() {
    export DEBIAN_FRONTEND=noninteractive

    echo -e "${YELLOW}Updating system packages...${NC}"
    apt-get update
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

deploy_site() {
    # A previous action (e.g. Delete Site) may have removed the directory the
    # script is standing in; git would then fail with "Unable to read current
    # working directory" before even contacting the Git server.
    anchor_cwd
    read -r -p "Enter domain (e.g., example.com): " DOMAIN
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}Invalid domain format: '$DOMAIN'${NC}"
        return 1
    fi
    read -r -p "Enter system username for isolation: " USERNAME
    if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        echo -e "${RED}Invalid username: '$USERNAME'. Use lowercase letters, digits, '-' or '_' (max 32 chars).${NC}"
        return 1
    fi
    # Absolute app path, also used by the npm-build retry hint below
    local DEPLOY_DIR
    DEPLOY_DIR="/home/$USERNAME/$DOMAIN"

    # Create user and handle SSH authentication
    if id "$USERNAME" &>/dev/null; then
        echo -e "\e[33mUser '$USERNAME' already exists. Using existing user.\e[0m"
    else
        useradd -m -s /bin/bash "$USERNAME"
        echo -e "\e[32mUser '$USERNAME' created.\e[0m"
        
        echo "Select SSH authentication method for $USERNAME:"
        echo "1) Password"
        echo "2) SSH Public Key"
        read -r -p "Choice (1 or 2): " AUTH_METHOD

        case $AUTH_METHOD in
            1)
                read -r -s -p "Enter password for $USERNAME: " USER_PASS
                echo
                read -r -s -p "Confirm password: " USER_PASS_CONFIRM
                echo
                if [[ "$USER_PASS" == "$USER_PASS_CONFIRM" ]]; then
                    echo "$USERNAME:$USER_PASS" | chpasswd
                    echo -e "\e[32mPassword set successfully.\e[0m"
                    # Add override to sshd_config in case global PasswordAuthentication is disabled
                    if ! grep -q "Match User $USERNAME" /etc/ssh/sshd_config 2>/dev/null; then
                        echo -e "\nMatch User $USERNAME\n    PasswordAuthentication yes\n" >> /etc/ssh/sshd_config
                        systemctl reload ssh || systemctl reload sshd
                    fi
                else
                    echo -e "\e[31mPasswords do not match! You must set it manually using 'passwd $USERNAME'.\e[0m"
                fi
                ;;
            2)
                read -r -p "Paste the Public SSH Key (ssh-rsa ...): " SSH_KEY
                if [[ -n "$SSH_KEY" ]]; then
                    mkdir -p /home/"$USERNAME"/.ssh
                    echo "$SSH_KEY" > /home/"$USERNAME"/.ssh/authorized_keys
                    chown -R "$USERNAME":"$USERNAME" /home/"$USERNAME"/.ssh
                    chmod 700 /home/"$USERNAME"/.ssh
                    chmod 600 /home/"$USERNAME"/.ssh/authorized_keys
                    echo -e "\e[32mSSH Key configured successfully for $USERNAME.\e[0m"
                else
                    echo -e "\e[31mNo key provided. User created without SSH credentials.\e[0m"
                fi
                ;;
            *)
                echo -e "\e[31mInvalid choice. Proceeding without SSH credential configuration.\e[0m"
                ;;
        esac
    fi
    
    mkdir -p /home/"$USERNAME"
    chown "$USERNAME":"$USERNAME" /home/"$USERNAME"

    echo "Select deployment method:"
    echo "1) Git Repository"
    echo "2) Manual Upload (SFTP/SCP)"
    read -r -p "Choice (1 or 2): " DEPLOY_METHOD

    case $DEPLOY_METHOD in
        1)
            read -r -p "Enter Git Repository URL: " GIT_URL
            if ! echo "$GIT_URL" | grep -Eq '^(https?://|git@|ssh://)'; then
                echo -e "${RED}Invalid Git URL: '$GIT_URL'${NC}"
                return 1
            fi
            read -r -p "Enter branch (default: main): " GIT_BRANCH
            GIT_BRANCH=${GIT_BRANCH:-main}

            echo "Repository access:"
            echo "1) Public repository"
            echo "2) Private - Personal Access Token (HTTPS, input hidden, nothing is stored)"
            echo "3) Private - SSH Deploy Key (recommended; future 'git pull' works too)"
            read -r -p "Choice (1/2/3, default 1): " GIT_AUTH
            GIT_AUTH=${GIT_AUTH:-1}

            CLONE_ENV=()
            ASKPASS=""
            case $GIT_AUTH in
                2)
                    read -r -p "Git username (e.g., your GitHub username; Enter = git): " GIT_USER
                    GIT_USER=${GIT_USER:-git}
                    read -r -s -p "Personal Access Token (input hidden): " GIT_TOKEN
                    echo
                    if [ -z "$GIT_TOKEN" ]; then
                        echo -e "${RED}No token provided. Nothing was deployed.${NC}"
                        return 1
                    fi
                    # Generic askpass helper: git reads the credentials from these env vars,
                    # so the token never touches the disk and never lands in .git/config
                    ASKPASS="/home/$USERNAME/.askpass_tmp"
                    cat > "$ASKPASS" <<'EOF'
#!/bin/sh
case "$1" in
    Username*) echo "$GIT_USER" ;;
    *) echo "$GIT_TOKEN" ;;
esac
EOF
                    chown "$USERNAME":"$USERNAME" "$ASKPASS"
                    chmod 700 "$ASKPASS"
                    CLONE_ENV=("GIT_ASKPASS=$ASKPASS" "GIT_TERMINAL_PROMPT=0" "GIT_USER=$GIT_USER" "GIT_TOKEN=$GIT_TOKEN")
                    ;;
                3)
                    # Deploy keys require an SSH remote; convert a GitHub HTTPS URL automatically
                    if [[ "$GIT_URL" =~ ^https://github\.com/ ]]; then
                        REPO_PATH=${GIT_URL#https://github.com/}
                        REPO_PATH=${REPO_PATH%.git}
                        GIT_URL="git@github.com:${REPO_PATH}.git"
                        echo -e "${YELLOW}URL converted to: $GIT_URL${NC}"
                    fi
                    if ! echo "$GIT_URL" | grep -Eq '^(git@|ssh://)'; then
                        echo -e "${RED}Deploy keys require an SSH URL (e.g., git@github.com:user/repo.git).${NC}"
                        return 1
                    fi
                    sudo -u "$USERNAME" mkdir -p /home/"$USERNAME"/.ssh
                    chmod 700 /home/"$USERNAME"/.ssh
                    if [ ! -f /home/"$USERNAME"/.ssh/id_ed25519 ]; then
                        sudo -u "$USERNAME" ssh-keygen -t ed25519 -N "" -f /home/"$USERNAME"/.ssh/id_ed25519 -q
                        echo -e "\e[32mDeploy key generated.\e[0m"
                    fi
                    echo -e "\n\e[33mAdd this deploy key on GitHub (repo > Settings > Deploy keys > Add deploy key; Read-only is enough):\e[0m"
                    cat /home/"$USERNAME"/.ssh/id_ed25519.pub
                    read -r -p "Press Enter ONLY AFTER the deploy key is added..."
                    sudo -u "$USERNAME" bash -c "ssh-keyscan -t ed25519,rsa github.com >> /home/$USERNAME/.ssh/known_hosts 2>/dev/null"
                    if echo "$GIT_URL" | grep -q "github.com"; then
                        SSH_TEST=$(sudo -u "$USERNAME" ssh -i /home/"$USERNAME"/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true)
                        if echo "$SSH_TEST" | grep -q "successfully authenticated"; then
                            echo -e "\e[32mDeploy key verified for GitHub.\e[0m"
                        else
                            echo -e "${RED}Deploy key verification failed:${NC}"
                            echo "$SSH_TEST"
                            echo -e "${YELLOW}Add the key (repo > Settings > Deploy keys) and re-run this deployment.${NC}"
                            return 1
                        fi
                    fi
                    CLONE_ENV=("GIT_SSH_COMMAND=ssh -i /home/$USERNAME/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new")
                    ;;
                *)
                    if [ "$GIT_AUTH" != "1" ]; then
                        echo -e "${RED}Invalid choice.${NC}"
                        return 1
                    fi
                    ;;
            esac

            # Clone into temporary folder FIRST so a failed clone
            # does not wipe the existing site directory
            rm -rf /home/"$USERNAME"/.tmp_clone
            CLONE_SUCCEEDED=0
            if sudo -u "$USERNAME" env "${CLONE_ENV[@]}" git clone -b "$GIT_BRANCH" "$GIT_URL" /home/"$USERNAME"/.tmp_clone; then
                CLONE_SUCCEEDED=1
            fi
            # Remove the temporary askpass helper if one was created
            [ -f "$ASKPASS" ] && rm -f "$ASKPASS"
            if [ "$CLONE_SUCCEEDED" -eq 1 ]; then
                # Clean home directory excluding .ssh and .tmp_clone to prevent locking out the user
                find /home/"$USERNAME" -mindepth 1 -maxdepth 1 ! -name ".ssh" ! -name ".tmp_clone" -exec rm -rf {} +
                # Place the application inside a per-domain folder: /home/<user>/<domain>
                # chown is required: mkdir above runs as root, but the mv below runs as the
                # isolated user and would fail with "Permission denied" (silently) otherwise
                mkdir -p "/home/$USERNAME/$DOMAIN"
                chown "$USERNAME":"$USERNAME" "/home/$USERNAME/$DOMAIN"
                sudo -u "$USERNAME" bash -c "shopt -s dotglob && mv /home/$USERNAME/.tmp_clone/* /home/$USERNAME/$DOMAIN/ 2>/dev/null; rmdir /home/$USERNAME/.tmp_clone"
            else
                rm -rf /home/"$USERNAME"/.tmp_clone
                echo -e "${RED}Git clone failed! Nothing was deployed and your existing files were not modified.${NC}"
                echo -e "${YELLOW}Possible causes:${NC}"
                echo -e "${YELLOW}  1) Private repo: re-run and pick access option 2 (Personal Access Token)${NC}"
                echo -e "${YELLOW}     or 3 (SSH Deploy key); account passwords are NOT accepted by GitHub.${NC}"
                echo -e "${YELLOW}  2) Branch '$GIT_BRANCH' does not exist - the default branch might be 'master'.${NC}"
                echo -e "${YELLOW}  3) Wrong URL or no network access to the Git server.${NC}"
                return 1
            fi

            # NOTE: no 'cd' into the app dir here. The script must never park its
            # own CWD inside /home/<user>/<domain>: if that directory is later
            # removed (Delete Site, manual cleanup, ...), the next run would
            # fail every git call with "Unable to read current working
            # directory". All app commands run via an explicit subshell cd.
            if [ -f "/home/$USERNAME/$DOMAIN/composer.json" ]; then
                sudo -u "$USERNAME" bash -c "cd '/home/$USERNAME/$DOMAIN' && composer install --no-dev --optimize-autoloader"
            fi
            if [ -f "/home/$USERNAME/$DOMAIN/package.json" ]; then
                # 'npm run build' can require internet (e.g. laravel:fonts downloads
                # @font-face CSS/woff2 from fonts.bunny.net / fonts.googleapis.com on
                # first run). Retry once so a single timeout does not fail the deploy.
                if sudo -u "$USERNAME" bash -c "cd '/home/$USERNAME/$DOMAIN' && npm install && npm run build"; then
                    NPM_BUILD_OK=1
                else
                    NPM_BUILD_OK=0
                fi
                if [ "$NPM_BUILD_OK" -ne 1 ]; then
                    echo -e "${RED}npm run build FAILED. The site is deployed, but assets were not built.${NC}"
                    echo -e "${YELLOW}Most likely cause: this server cannot reach the build-time font CDNs${NC}"
                    echo -e "${YELLOW}(${YELLOW}fonts.bunny.net / fonts.googleapis.com${NC}). First fix connectivity, then retry:${NC}"
                    echo -e "${YELLOW}  sudo -u $USERNAME bash -c 'cd $DEPLOY_DIR && npm install && npm run build'${NC}"
                    echo -e "${YELLOW}Note: fonts are cached in node_modules/.cache/laravel-vite-plugin/fonts,${NC}"
                    echo -e "${YELLOW}so the retry only needs one successful round of downloads.${NC}"
                    read -r -p "Retry the npm build now? (y/N): " RETRY_NPM
                    if [[ "$RETRY_NPM" =~ ^[Yy]$ ]]; then
                        if sudo -u "$USERNAME" bash -c "cd '$DEPLOY_DIR' && npm install && npm run build"; then
                            echo -e "\e[32mnpm build succeeded on retry.\e[0m"
                        else
                            echo -e "${RED}npm build failed again. Deploy the rest first, fix connectivity${NC}"
                            echo -e "${RED}(DNS/firewall), then run the command above manually.${NC}"
                        fi
                    fi
                fi
            fi
            if [ -f "/home/$USERNAME/$DOMAIN/artisan" ]; then
                sudo -u "$USERNAME" bash -c "cd '/home/$USERNAME/$DOMAIN' && cp .env.example .env && php artisan key:generate"
            fi
            ;;
        2)
            SERVER_IP=$(hostname -I | awk '{print $1}')
            
            echo -e "\n\e[33mStep 1: Upload your project's ZIP file using this command:\e[0m"
            echo "scp /local/path/to/your-project.zip $USERNAME@$SERVER_IP:/home/$USERNAME/"
            echo
            read -r -p "Press Enter ONLY AFTER the upload is finished..."
            
            # Use find instead of ls to avoid ANSI color code issues
            ZIP_FILE=$(find "/home/$USERNAME" -maxdepth 1 -type f -name "*.zip" | head -n 1)
            DOMAIN_DIR="/home/$USERNAME/$DOMAIN"
            
            if [ -n "$ZIP_FILE" ] && [ -f "$ZIP_FILE" ]; then
                echo -e "\e[32mFound zip file: $ZIP_FILE\e[0m"
                echo "Extracting project files..."
                
                sudo -u "$USERNAME" mkdir -p "$DOMAIN_DIR"
                sudo -u "$USERNAME" unzip -o -q "$ZIP_FILE" -d "$DOMAIN_DIR"
                rm -f "$ZIP_FILE"
                chown -R "$USERNAME":"$USERNAME" "$DOMAIN_DIR"
                
                echo -e "\e[32mExtraction complete and zip archive removed.\e[0m"
            else
                echo -e "\e[31mError: No .zip file found in /home/$USERNAME\e[0m"
            fi
            ;;
        *)
            echo -e "${RED}Invalid deployment method. Nothing was deployed; no changes were made to Nginx/PHP.${NC}"
            return 1
            ;;
    esac

    # Fix Permissions Automatically
    chmod 755 "/home/$USERNAME"

    if [ -d "/home/$USERNAME/$DOMAIN" ]; then
        # u=rwX,go=rX -> directories end up 755, plain files 644, and files that were
        # ALREADY executable (node_modules/.bin, vendor/bin, artisan, ...) keep their
        # exec bit. A blanket "chmod 644 every file" used to strip it and broke manual
        # runs like 'npm run build' with "sh: 1: vp: Permission denied".
        chmod -R u=rwX,go=rX "/home/$USERNAME/$DOMAIN"
        chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/$DOMAIN"
        # Secrets must not be world-readable
        if [ -f "/home/$USERNAME/$DOMAIN/.env" ]; then
            chmod 600 "/home/$USERNAME/$DOMAIN/.env"
        fi

        if [ -d "/home/$USERNAME/$DOMAIN/storage" ]; then
            chmod -R 775 "/home/$USERNAME/$DOMAIN/storage"
            chmod -R 775 "/home/$USERNAME/$DOMAIN/bootstrap/cache" 2>/dev/null || true
        fi
    fi
    
    # PHP-FPM Pool
    POOL_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/$USERNAME.conf"
    cat <<EOF > "$POOL_CONF"
[$USERNAME]
user = $USERNAME
group = $USERNAME
listen = /run/php/php${PHP_VERSION}-fpm-$USERNAME.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
EOF
    systemctl restart "php${PHP_VERSION}-fpm"
    
    # Nginx Vhost
    VHOST_CONF="/etc/nginx/sites-available/$DOMAIN"
    cat <<EOF > "$VHOST_CONF"
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    root /home/$USERNAME/$DOMAIN/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";

    index index.html index.htm index.php;

    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm-$USERNAME.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
    ln -sf "$VHOST_CONF" /etc/nginx/sites-enabled/
    systemctl reload nginx
    
    echo -e "\e[32mSite $DOMAIN deployed. Root: /home/$USERNAME/$DOMAIN\e[0m"
}



list_site_domains() {
    echo -e "\n--- Sites & Domains ---"
    if [ ! -d /etc/nginx/sites-available ] || [ -z "$(ls -A /etc/nginx/sites-available 2>/dev/null)" ]; then
        echo "No sites found."
        return 0
    fi
    for f in /etc/nginx/sites-available/*; do
        [ -f "$f" ] || continue
        DN=$(basename "$f")
        SN=$(grep -h "server_name" "$f" | head -n1 | sed 's/^[[:space:]]*server_name//;s/;//;s/^ *//')
        [ -z "$SN" ] && SN="(no server_name)"
        ROOT=$(grep -m1 "^[[:space:]]*root" "$f" | awk '{print $2}' | tr -d ';')
        USER_FROM_ROOT=$(echo "$ROOT" | cut -d'/' -f3)
        echo -e "\e[32m- $DN\e[0m"
        echo "    Server Names : $SN"
        echo "    Root         : $ROOT"
        [ -n "$USER_FROM_ROOT" ] && echo "    User         : $USER_FROM_ROOT"
        if [ -L "/etc/nginx/sites-enabled/$DN" ]; then echo "    Enabled : yes"; else echo "    Enabled : no"; fi
        ALL_COUNT=$(grep -c "server_name" "$f" 2>/dev/null || echo 0)
        if [ "$ALL_COUNT" -gt 1 ]; then
            echo "    All blocks   :"
            grep "server_name" "$f" | sed 's/^[[:space:]]*//' | sed 's/^/      /'
        fi
        echo ""
    done
}
add_site_domain() {
    anchor_cwd
    echo -e "\n--- Add Domain to Existing Site ---"
    echo "Existing sites:"
    if [ -d /etc/nginx/sites-available ] && ls /etc/nginx/sites-available/* >/dev/null 2>&1; then
        for f in /etc/nginx/sites-available/*; do
            [ -f "$f" ] || continue
            _dn=$(basename "$f")
            _sn=$(grep -h "server_name" "$f" | head -n1 | sed 's/^[[:space:]]*server_name//;s/;//;s/^ *//')
            echo "  - $_dn  =>  $_sn"
        done
    else
        echo "  (no sites found)"
        return 1
    fi
    echo ""
    read -r -p "Enter primary domain of target site (e.g., test.com): " PRIMARY
    PRIMARY=$(echo "$PRIMARY" | tr '[:upper:]' '[:lower:]' | xargs)
    if ! [[ "$PRIMARY" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}Invalid domain: '$PRIMARY'${NC}"; return 1
    fi
    VHOST_CONF="/etc/nginx/sites-available/$PRIMARY"
    if [ ! -f "$VHOST_CONF" ]; then
        echo -e "${RED}No vhost for '$PRIMARY'. Use List (option 5) to see sites.${NC}"; return 1
    fi
    CUR_LINE=$(grep "server_name" "$VHOST_CONF" | head -n1 | sed 's/^[[:space:]]*//')
    CUR_ALL=$(grep -h "server_name" "$VHOST_CONF" | sed 's/.*server_name//;s/;//' | tr ' ' '\n' | grep -v '^$' | sort -u | xargs)
    echo -e "Current: ${YELLOW}$CUR_LINE${NC}"
    echo -e "All domains: ${GREEN}$CUR_ALL${NC}"
    read -r -p "Enter new domain/alias (e.g., pay.test.com or hossein.com): " NEW_DOMAIN
    NEW_DOMAIN=$(echo "$NEW_DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)
    if ! [[ "$NEW_DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}Invalid domain: '$NEW_DOMAIN'${NC}"; return 1
    fi
    if grep -qw "$NEW_DOMAIN" "$VHOST_CONF"; then
        echo -e "${YELLOW}Domain '$NEW_DOMAIN' already attached to '$PRIMARY'.${NC}"; return 0
    fi
    if [ -f "/etc/nginx/sites-available/$NEW_DOMAIN" ] && [ "/etc/nginx/sites-available/$NEW_DOMAIN" != "$VHOST_CONF" ]; then
        echo -e "${RED}Another site uses '$NEW_DOMAIN' as primary.${NC}"; return 1
    fi
    BACKUP="${VHOST_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$VHOST_CONF" "$BACKUP"
    echo "Backup: $BACKUP"
    sed -i -E "s/(server_name[^;]*);/\1 $NEW_DOMAIN;/" "$VHOST_CONF"
    sed -i -E "s/  +/ /g" "$VHOST_CONF"
    echo "Updated server_name:"
    grep "server_name" "$VHOST_CONF" | sed 's/^[[:space:]]*/  /'
    if ! nginx -t 2>&1; then
        echo -e "${RED}nginx -t failed. Reverting.${NC}"; cp "$BACKUP" "$VHOST_CONF"; return 1
    fi
    systemctl reload nginx
    echo -e "${GREEN}Domain '$NEW_DOMAIN' added to '$PRIMARY'. Both serve same site.${NC}"
    read -r -p "Issue/expand SSL to include '$NEW_DOMAIN' now? (y/n): " SSL_ANS
    if [[ "$SSL_ANS" =~ ^[yY] ]]; then
        DOMAINS=$(grep -h "server_name" "$VHOST_CONF" | sed 's/.*server_name//;s/;//' | tr ' ' '\n' | grep -v '^$' | sort -u | xargs)
        CERT_ARGS=""; for d in $DOMAINS; do CERT_ARGS="$CERT_ARGS -d $d"; done
        echo -e "${YELLOW}Running: certbot --nginx $CERT_ARGS --expand${NC}"
        if certbot certificates 2>/dev/null | grep -q "Certificate Name: $PRIMARY"; then
            certbot --nginx --expand $CERT_ARGS || echo -e "${RED}Expand failed. Check DNS A for '$NEW_DOMAIN' and port 80.${NC}"
        else
            certbot --nginx $CERT_ARGS || echo -e "${RED}Failed. Check DNS/port 80.${NC}"
        fi
    else
        DOMAINS=$(grep -h "server_name" "$VHOST_CONF" | sed 's/.*server_name//;s/;//' | tr ' ' '\n' | grep -v '^$' | sort -u | xargs)
        CERT_ARGS=""; for d in $DOMAINS; do CERT_ARGS="$CERT_ARGS -d $d"; done
        echo -e "${YELLOW}To enable HTTPS later: certbot --nginx $CERT_ARGS --expand${NC}"
    fi
}




remove_site_domain() {
    anchor_cwd
    echo -e "\n--- Remove Domain from Site ---"
    echo "Existing sites:"
    if [ -d /etc/nginx/sites-available ] && ls /etc/nginx/sites-available/* >/dev/null 2>&1; then
        for f in /etc/nginx/sites-available/*; do
            [ -f "$f" ] || continue
            _dn=$(basename "$f"); _sn=$(grep -h "server_name" "$f" | head -n1 | sed 's/^[[:space:]]*server_name//;s/;//;s/^ *//')
            echo "  - $_dn  =>  $_sn"
        done
    else echo "  (no sites)"; return 1; fi
    echo ""
    read -r -p "Enter primary domain of site (e.g., test.com): " PRIMARY
    PRIMARY=$(echo "$PRIMARY" | tr '[:upper:]' '[:lower:]' | xargs)
    VHOST_CONF="/etc/nginx/sites-available/$PRIMARY"
    if [ ! -f "$VHOST_CONF" ]; then echo -e "${RED}No vhost for '$PRIMARY'.${NC}"; return 1; fi
    CUR_DOMAINS=$(grep -h "server_name" "$VHOST_CONF" | sed 's/.*server_name//;s/;//' | tr ' ' '\n' | grep -v '^$' | sort -u)
    echo "Domains on '$PRIMARY':"; echo "$CUR_DOMAINS" | sed 's/^/  - /'; echo ""
    read -r -p "Enter domain to remove: " RM_DOMAIN
    RM_DOMAIN=$(echo "$RM_DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)
    if ! grep -qw "$RM_DOMAIN" "$VHOST_CONF"; then echo -e "${RED}'$RM_DOMAIN' not attached.${NC}"; return 1; fi
    CNT=$(echo "$CUR_DOMAINS" | wc -l)
    if [ "$CNT" -le 1 ]; then echo -e "${RED}Cannot remove last domain. Delete site instead.${NC}"; return 1; fi
    if [ "$RM_DOMAIN" = "$PRIMARY" ]; then
        echo -e "${YELLOW}Removing primary itself; file stays named '$PRIMARY' but won't serve it.${NC}"
        read -r -p "Continue? (y/n): " C; if ! [[ "$C" =~ ^[yY] ]]; then echo "Aborted."; return 1; fi
    fi
    BACKUP="${VHOST_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$VHOST_CONF" "$BACKUP"; echo "Backup: $BACKUP"
    ESC=$(echo "$RM_DOMAIN" | sed 's/\./\\./g')
    sed -i -E "s/([[:space:]])${ESC}([[:space:];])/\1\2/g" "$VHOST_CONF"
    sed -i -E "s/  +/ /g; s/ ;/;/g" "$VHOST_CONF"
    if ! grep -q "server_name" "$VHOST_CONF"; then echo -e "${RED}No server_name left. Reverting.${NC}"; cp "$BACKUP" "$VHOST_CONF"; return 1; fi
    sed -i -E "s/server_name[[:space:]]*;/server_name $PRIMARY;/g" "$VHOST_CONF"
    echo "Updated:"; grep "server_name" "$VHOST_CONF" | sed 's/^[[:space:]]*/  /'
    if ! nginx -t 2>&1; then echo -e "${RED}nginx -t failed. Reverting.${NC}"; cp "$BACKUP" "$VHOST_CONF"; return 1; fi
    systemctl reload nginx
    echo -e "${GREEN}Removed '$RM_DOMAIN' from '$PRIMARY'.${NC}"
    REM=$(grep -h "server_name" "$VHOST_CONF" | sed 's/.*server_name//;s/;//' | tr ' ' '\n' | grep -v '^$' | sort -u | xargs)
    ARGS=""; for d in $REM; do ARGS="$ARGS -d $d"; done
    echo -e "${YELLOW}SSL still contains old domain. To update: certbot --nginx $ARGS --cert-name $PRIMARY${NC}"
}


manage_sites() {
    while true; do
        echo -e "\n--- Site Management ---"
        echo "1) Create Site (Deploy via Git or ZIP)"
        echo "2) Delete Site"
        echo "3) Add Domain to Site"
        echo "4) Remove Domain from Site"
        echo "5) List Sites & Domains"
        echo "0) Back"
        read -r -p "Choice: " SITE_CHOICE
        case $SITE_CHOICE in
            1) deploy_site ;;
            2) delete_site ;;
            3) add_site_domain ;;
            4) remove_site_domain ;;
            5) list_site_domains ;;
            0) break ;;
            *) echo -e "\e[31mInvalid choice.\e[0m" ;;
        esac
    done
}

delete_site() {
    # Never stand inside a directory we are about to remove
    anchor_cwd
    read -r -p "Enter domain to delete (e.g., example.com): " DOMAIN
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}Invalid domain format: '$DOMAIN'${NC}"
        return 1
    fi

    VHOST_CONF="/etc/nginx/sites-available/$DOMAIN"
    if [ ! -f "$VHOST_CONF" ]; then
        echo -e "${RED}No Nginx vhost found for '$DOMAIN'. Nothing to delete.${NC}"
        return 1
    fi

    # Detect the isolated user from the vhost root directive: root /home/<user>/<domain>/public;
    USERNAME=$(sed -n 's/^[[:space:]]*root \/home\/\([^/]*\)\/.*/\1/p' "$VHOST_CONF" | head -n 1)
    if [ -z "$USERNAME" ]; then
        read -r -p "Could not detect the isolated user from the vhost. Enter username: " USERNAME
        if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            echo -e "${RED}Invalid username: '$USERNAME'.${NC}"
            return 1
        fi
    fi

    SITE_DIR="/home/$USERNAME/$DOMAIN"
    POOL_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/$USERNAME.conf"

    echo -e "\n\e[33mThe following will be deleted:\e[0m"
    echo "  - Nginx vhost  : $VHOST_CONF (+ sites-enabled symlink)"
    echo "  - Site files   : $SITE_DIR"
    [ -f "$POOL_CONF" ] && echo "  - PHP-FPM pool : $POOL_CONF (only if no other site uses '$USERNAME')"

    read -r -p "Also delete the SSL certificate for '$DOMAIN' (certbot)? (y/n): " DEL_CERT
    read -r -p "Also delete the isolated user '$USERNAME' and its home directory? (y/n): " DEL_USER
    read -r -p "Type the domain name again to confirm: " DEL_CONFIRM
    if [ "$DEL_CONFIRM" != "$DOMAIN" ]; then
        echo -e "${RED}Confirmation does not match. Aborted. Nothing was deleted.${NC}"
        return 1
    fi

    # 1) Nginx vhost
    rm -f "$VHOST_CONF" "/etc/nginx/sites-enabled/$DOMAIN"
    systemctl reload nginx
    echo -e "\e[32mNginx vhost removed.\e[0m"

    # 2) SSL certificate (optional)
    if [[ "$DEL_CERT" =~ ^[yY] ]]; then
        if certbot certificates 2>/dev/null | grep -q "Certificate Name: $DOMAIN"; then
            if certbot delete --cert-name "$DOMAIN" --non-interactive; then
                echo -e "\e[32mSSL certificate for '$DOMAIN' deleted.\e[0m"
            else
                echo -e "${YELLOW}Certbot deletion failed. Run it manually: certbot delete --cert-name $DOMAIN${NC}"
            fi
        else
            echo -e "${YELLOW}No certbot certificate found for '$DOMAIN'.${NC}"
        fi
    fi

    # 3) Site files
    rm -rf "$SITE_DIR"
    echo -e "\e[32mSite files removed: $SITE_DIR\e[0m"

    # 4) Isolated user + FPM pool (only when no other vhost still uses this home directory)
    if [[ "$DEL_USER" =~ ^[yY] ]]; then
        if grep -rq "/home/$USERNAME/" /etc/nginx/sites-available/ 2>/dev/null; then
            echo -e "${YELLOW}Other sites still use user '$USERNAME'. User, pool and crontab were kept.${NC}"
        else
            if [ -f "$POOL_CONF" ]; then
                rm -f "$POOL_CONF"
                systemctl restart "php${PHP_VERSION}-fpm"
                echo -e "\e[32mPHP-FPM pool removed.\e[0m"
            fi
            # Kill leftover processes (e.g. queue workers) so userdel does not fail
            pkill -u "$USERNAME" 2>/dev/null || true
            sleep 1
            crontab -r -u "$USERNAME" 2>/dev/null || true
            if userdel -r "$USERNAME" 2>/dev/null; then
                echo -e "\e[32mUser '$USERNAME' and its home directory removed.\e[0m"
            else
                echo -e "${YELLOW}Could not fully remove user '$USERNAME'. Verify with: id $USERNAME${NC}"
            fi
            if grep -rls "^user=$USERNAME$" /etc/supervisor/conf.d/ 2>/dev/null; then
                echo -e "${YELLOW}Note: supervisor configs still reference '$USERNAME'. Remove them from menu 10 if no longer needed.${NC}"
            fi
        fi
    fi

    echo -e "\e[32mSite '$DOMAIN' fully deleted.\e[0m"
}

install_ssl() {
    read -r -p "Enter domain: " DOMAIN
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}Invalid domain format: '$DOMAIN'${NC}"
        return 1
    fi

    echo -e "${YELLOW}Obtaining certificate for '$DOMAIN'...${NC}"
    if certbot --nginx -d "$DOMAIN"; then
        echo -e "${GREEN}SSL installed successfully.${NC}"

        # Verify the automatic renewal schedule (shipped by the certbot package)
        if systemctl list-timers --all 2>/dev/null | grep -q certbot; then
            echo -e "${GREEN}Auto-renewal is active via systemd timer (runs twice daily).${NC}"
        elif [ -f "${PUSHIT_CRON_FILE:-/etc/cron.d/certbot}" ]; then
            echo -e "${GREEN}Auto-renewal is active via cron (/etc/cron.d/certbot).${NC}"
        else
            echo -e "${RED}No automatic renewal schedule found!${NC}"
            echo -e "${YELLOW}Add this cron entry manually: 0 3,15 * * * certbot renew --quiet${NC}"
        fi

        echo -e "\n${YELLOW}Test renewal safely with: certbot renew --dry-run${NC}"
        echo -e "${YELLOW}Show certificate status with: certbot certificates${NC}"
    else
        echo -e "${RED}SSL installation failed for '$DOMAIN'.${NC}"
        echo -e "${YELLOW}Make sure the domain's DNS A record points to this server and port 80 is open.${NC}"
        return 1
    fi
}

manage_firewall() {
    echo "1) Enable UFW & allow SSH/HTTP/HTTPS"
    echo "2) Allow port"
    echo "3) Deny port"
    read -r -p "Select: " FW_OPT
    case $FW_OPT in
        1) ufw allow OpenSSH; ufw allow 'Nginx Full'; ufw --force enable ;;
        2) read -r -p "Port: " PORT; ufw allow "$PORT" ;;
        3) read -r -p "Port: " PORT; ufw deny "$PORT" ;;
    esac
}

harden_server() {
    # SSH Hardening (Disable root login, password auth)
    echo -e "${YELLOW}This will disable root SSH login and password authentication.${NC}"
    echo -e "${YELLOW}Make sure you have a working SSH public key on this server, otherwise you will be locked out!${NC}"

    # Check that at least one user (root or /home/*) has an authorized key
    HAS_KEY=0
    for SSH_DIR in /root /home/*; do
        if [ -s "$SSH_DIR/.ssh/authorized_keys" ]; then
            HAS_KEY=1
            echo -e "SSH key found for: $(basename "$SSH_DIR")"
        fi
    done
    if [ "$HAS_KEY" -eq 0 ]; then
        echo -e "${RED}No authorized SSH key found for any user. Aborting to prevent lockout.${NC}"
        echo -e "${RED}Add a key first (deploy a site with option 4 and choose 'SSH Public Key').${NC}"
        return 1
    fi

    # Backup before editing
    SSH_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
    cp /etc/ssh/sshd_config "$SSH_BACKUP"

    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

    # Validate config before applying (if the sshd binary is available)
    SSHD_BIN=$(command -v sshd 2>/dev/null || true)
    if [ -n "$SSHD_BIN" ] && ! "$SSHD_BIN" -t 2>/dev/null; then
        cp "$SSH_BACKUP" /etc/ssh/sshd_config
        echo -e "${RED}sshd config validation failed. Changes were reverted.${NC}"
        return 1
    fi

    # Service name differs: 'ssh' on modern Ubuntu, 'sshd' on older releases
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
        || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null

    echo -e "${GREEN}Server hardened. Backup saved to: $SSH_BACKUP${NC}"
    echo -e "${YELLOW}IMPORTANT: Keep this session open and test a new SSH login before closing it!${NC}"
}

download_database() {
    if ! command -v mysqldump > /dev/null 2>&1; then
        echo -e "${RED}'mysqldump' not found. Install it first: apt-get install -y mysql-client${NC}"
        return 1
    fi

    echo -e "\n--- Existing Databases ---"
    mysql -e "SHOW DATABASES;" | grep -Ev "^(Database|information_schema|performance_schema|mysql|sys)$"
    echo ""
    read -r -p "Enter Database Name to download: " db_name
    if ! [[ "$db_name" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo -e "${RED}Invalid database name.${NC}"
        return 1
    fi
    if ! mysql -N -e "SHOW DATABASES LIKE '${db_name}';" | grep -q .; then
        echo -e "${RED}Database '${db_name}' not found.${NC}"
        return 1
    fi

    BACKUP_DIR="${PUSHIT_DB_BACKUP_DIR:-/root/db-backups}"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    DUMP_FILE="${BACKUP_DIR}/${db_name}_${TIMESTAMP}.sql.gz"
    mkdir -p "$BACKUP_DIR"

    echo -e "${YELLOW}Dumping '${db_name}'... This may take a while for large databases.${NC}"
    if (set -o pipefail; mysqldump --single-transaction --routines --triggers --events --hex-blob "${db_name}" | gzip > "$DUMP_FILE"); then
        chmod 600 "$DUMP_FILE"
        SERVER_IP=$(hostname -I | awk '{print $1}')
        echo -e "${GREEN}Backup created: ${DUMP_FILE} ($(du -h "$DUMP_FILE" | cut -f1))${NC}"
        echo -e "\n${YELLOW}Download it to your local machine with this command:${NC}"
        echo "scp root@${SERVER_IP}:${DUMP_FILE} ./"
    else
        rm -f "$DUMP_FILE"
        echo -e "${RED}Dump failed. No backup file was kept.${NC}"
        return 1
    fi
}

upload_database() {
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "${YELLOW}Step 1: Upload your backup file to this server with a command like:${NC}"
    echo "scp ./backup.sql.gz root@${SERVER_IP}:/root/"
    echo ""
    read -r -p "Enter path of the SQL file on this server (e.g., /root/backup.sql or /root/backup.sql.gz): " SQL_FILE
    if [ ! -f "$SQL_FILE" ]; then
        echo -e "${RED}File not found: '${SQL_FILE}'${NC}"
        return 1
    fi

    read -r -p "Enter target Database Name: " db_name
    if ! [[ "$db_name" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo -e "${RED}Invalid database name.${NC}"
        return 1
    fi

    if ! mysql -N -e "SHOW DATABASES LIKE '${db_name}';" | grep -q .; then
        read -r -p "Database '${db_name}' does not exist. Create it now? (y/n): " CREATE_ANS
        case $CREATE_ANS in
            [yY]*)
                mysql -e "CREATE DATABASE \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
                echo -e "${GREEN}Database '${db_name}' created.${NC}"
                ;;
            *)
                echo -e "${RED}Aborted: target database does not exist.${NC}"
                return 1
                ;;
        esac
    fi

    echo -e "${YELLOW}Importing '${SQL_FILE}' into '${db_name}'... This may take a while.${NC}"
    case "$SQL_FILE" in
        *.gz)
            if (set -o pipefail; gunzip -c "$SQL_FILE" | mysql "${db_name}"); then
                echo -e "${GREEN}Success: '${SQL_FILE}' imported into '${db_name}'.${NC}"
            else
                echo -e "${RED}Import failed. Check the dump file and try again.${NC}"
                return 1
            fi
            ;;
        *)
            if mysql "${db_name}" < "$SQL_FILE"; then
                echo -e "${GREEN}Success: '${SQL_FILE}' imported into '${db_name}'.${NC}"
            else
                echo -e "${RED}Import failed. Check the dump file and try again.${NC}"
                return 1
            fi
            ;;
    esac
    TABLE_COUNT=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db_name}';")
    echo -e "${GREEN}'${db_name}' now contains ${TABLE_COUNT} table(s).${NC}"
}

manage_database_menu() {
    while true; do
        echo -e "\n--- Database Management ---"
        echo "1) Create Database & User"
        echo "2) List Databases"
        echo "3) Delete Database"
        echo "4) Change Database User Password"
        echo "5) Download Database (Backup)"
        echo "6) Upload / Restore Database"
        echo "0) Back to Main Menu"
        read -r -p "Select an option: " db_choice

        case $db_choice in
            1)
                read -r -p "Enter Database Name: " db_name
                read -r -p "Enter Database User: " db_user
                read -r -sp "Enter Database Password: " db_pass
                echo ""
                if [[ -z "$db_name" || -z "$db_user" || -z "$db_pass" ]]; then
                    echo -e "\e[31mError: All fields are required.\e[0m"
                elif ! [[ "$db_name" =~ ^[A-Za-z0-9_]+$ && "$db_user" =~ ^[A-Za-z0-9_]+$ ]]; then
                    echo -e "${RED}Database name and user may only contain letters, digits and underscore.${NC}"
                else
                    mysql -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
                    mysql -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"
                    mysql -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';"
                    mysql -e "FLUSH PRIVILEGES;"
                    echo -e "\e[32mSuccess: Database '${db_name}' and user '${db_user}' created.\e[0m"
                fi
                ;;
            2)
                echo -e "\n--- Existing Databases ---"
                mysql -e "SHOW DATABASES;" | grep -Ev "^(Database|information_schema|performance_schema|mysql|sys)$"
                ;;
            3)
                echo -e "\n--- Existing Databases ---"
                mysql -e "SHOW DATABASES;" | grep -Ev "^(Database|information_schema|performance_schema|mysql|sys)$"
                echo ""
                read -r -p "Enter Database Name to DELETE (or press Enter to cancel): " del_db
                if [[ -n "$del_db" ]]; then
                    if ! [[ "$del_db" =~ ^[A-Za-z0-9_]+$ ]]; then
                        echo -e "${RED}Invalid database name.${NC}"
                        continue
                    fi
                    read -r -p "Type the database name again to confirm: " del_confirm
                    if [ "$del_db" != "$del_confirm" ]; then
                        echo -e "${RED}Confirmation does not match. Aborted.${NC}"
                        continue
                    fi
                    mysql -e "DROP DATABASE IF EXISTS \`${del_db}\`;"
                    echo -e "\e[32mSuccess: Database '${del_db}' deleted.\e[0m"
                fi
                ;;
            4)
                read -r -p "Enter Database User to edit: " edit_user
                read -r -sp "Enter New Password: " new_pass
                echo ""
                if [[ -n "$edit_user" && -n "$new_pass" ]]; then
                    if ! [[ "$edit_user" =~ ^[A-Za-z0-9_]+$ ]]; then
                        echo -e "${RED}Invalid database user name.${NC}"
                        continue
                    fi
                    mysql -e "ALTER USER '${edit_user}'@'localhost' IDENTIFIED BY '${new_pass}';"
                    mysql -e "FLUSH PRIVILEGES;"
                    echo -e "\e[32mSuccess: Password updated for user '${edit_user}'.\e[0m"
                else
                    echo -e "\e[31mError: User and password are required.\e[0m"
                fi
                ;;
            5) download_database ;;
            6) upload_database ;;
            0)
                break
                ;;
            *)
                echo -e "\e[31mInvalid option.\e[0m"
                ;;
        esac
    done
}

manage_cron() {
    while true; do
        echo -e "\n--- Cron Management ---"
        echo "1) List Jobs"
        echo "2) Add Job"
        echo "3) Delete Job"
        echo "0) Back"
        read -r -p "Choice: " CRON_CHOICE

        case $CRON_CHOICE in
            1)
                read -r -p "Enter username (e.g., root, or isolated user): " C_USER
                crontab -u "$C_USER" -l || echo "No crontab for $C_USER"
                ;;
            2)
                read -r -p "Enter username to run cron as: " C_USER
                echo -e "\e[33mExample Schedule:\e[0m * * * * * (Every minute)"
                read -r -p "Enter schedule expression: " C_SCHED
                echo -e "\e[33mExample Command:\e[0m cd /home/user && php artisan schedule:run >> /dev/null 2>&1"
                read -r -p "Enter command: " C_CMD
                
                (crontab -u "$C_USER" -l 2>/dev/null; echo "$C_SCHED $C_CMD") | crontab -u "$C_USER" -
                echo -e "\e[32mJob added successfully.\e[0m"
                ;;
            3)
                read -r -p "Enter username to manage: " C_USER
                crontab -u "$C_USER" -l > /tmp/cron.tmp 2>/dev/null
                if [ ! -s /tmp/cron.tmp ]; then 
                    echo -e "\e[31mNo jobs found for $C_USER.\e[0m"
                    continue
                fi
                echo "Current Jobs:"
                cat -n /tmp/cron.tmp
                read -r -p "Enter line number to delete: " LINE_NUM
                if [[ "$LINE_NUM" =~ ^[0-9]+$ ]]; then
                    sed -i "${LINE_NUM}d" /tmp/cron.tmp
                    crontab -u "$C_USER" /tmp/cron.tmp
                    echo -e "\e[32mJob deleted.\e[0m"
                else
                    echo -e "\e[31mInvalid line number.\e[0m"
                fi
                rm -f /tmp/cron.tmp
                ;;
            0) break ;;
            *) echo -e "\e[31mInvalid choice.\e[0m" ;;
        esac
    done
}

manage_supervisor() {
    while true; do
        echo -e "\n--- Supervisor Management ---"
        echo "1) List Processes"
        echo "2) Add Process"
        echo "3) Delete Process"
        echo "0) Back"
        read -r -p "Choice: " SUP_CHOICE

        case $SUP_CHOICE in
            1)
                supervisorctl status
                ;;
            2)
                read -r -p "Program Name (e.g., myapp-worker): " PROG_NAME
                read -r -p "Run as User (e.g., username): " PROG_USER
                read -r -p "Directory (e.g., /home/username/example.com): " PROG_DIR
                echo -e "\e[33mExample Command:\e[0m php artisan queue:work --sleep=3 --tries=3"
                read -r -p "Command: " PROG_CMD
                read -r -p "Number of processes (default 1): " PROG_NUM
                PROG_NUM=${PROG_NUM:-1}
                
                CONF_PATH="/etc/supervisor/conf.d/${PROG_NAME}.conf"
                cat <<EOF > "$CONF_PATH"
[program:${PROG_NAME}]
process_name=%(program_name)s_%(process_num)02d
command=${PROG_CMD}
autostart=true
autorestart=true
user=${PROG_USER}
numprocs=${PROG_NUM}
redirect_stderr=true
stdout_logfile=${PROG_DIR}/${PROG_NAME}_worker.log
directory=${PROG_DIR}
EOF
                supervisorctl reread
                supervisorctl update
                supervisorctl start "${PROG_NAME}":*
                echo -e "\e[32mProcess $PROG_NAME added and started.\e[0m"
                ;;
            3)
                echo "Installed Supervisor Configurations:"
                find /etc/supervisor/conf.d/ -maxdepth 1 -type f -name '*.conf' -exec basename {} .conf \;
                read -r -p "Enter Program Name to delete: " PROG_NAME
                CONF_PATH="/etc/supervisor/conf.d/${PROG_NAME}.conf"
                
                if [ -f "$CONF_PATH" ]; then
                    supervisorctl stop "${PROG_NAME}":*
                    rm -f "$CONF_PATH"
                    supervisorctl reread
                    supervisorctl update
                    echo -e "\e[32mProcess $PROG_NAME deleted.\e[0m"
                else
                    echo -e "\e[31mConfiguration not found.\e[0m"
                fi
                ;;
            0) break ;;
            *) echo -e "\e[31mInvalid choice.\e[0m" ;;
        esac
    done
}

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
    echo -e "${YELLOW}/etc/resolv.conf -> $(readlink -f /etc/resolv.conf 2>/dev/null || echo \"(not symlink)\")${NC}"
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
    echo "12) Update Script (from GitHub)"
    read -r -p "Option: " OPT
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
        *) echo "Invalid option." ;;
    esac
}


check_root
pushit_ensure_bootstrap
while true; do
    show_menu
done
