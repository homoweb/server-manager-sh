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

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Execute as root or with sudo.${NC}"
        exit 1
    fi
}

install_to_bin() {
    curl -fsSL https://raw.githubusercontent.com/homoweb/server-manager-sh/main/server_manager.sh -o /usr/local/bin/pushit \
        && chmod +x /usr/local/bin/pushit \
        && echo -e "${GREEN}Script installed/updated. Run 'sudo pushit' from anywhere.${NC}" \
        || echo -e "${RED}Installation failed. Check your internet connection and try again.${NC}"
}

change_mirror() {
    if ! command -v lsb_release > /dev/null 2>&1; then
        echo -e "${RED}'lsb_release' not found. Install it first: apt-get install -y lsb-release${NC}"
        return 1
    fi
    CODENAME=$(lsb_release -cs)
    MIRROR="https://repo.abrha.net/ubuntu/"

    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
        # Ubuntu 24.04+ uses the deb822 format in /etc/apt/sources.list.d/ubuntu.sources
        cat <<EOF > /etc/apt/sources.list.d/ubuntu.sources
Types: deb
URIs: ${MIRROR}
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
        # Comment out legacy entries so they cannot override the new mirror
        if [ -f /etc/apt/sources.list ]; then
            sed -i 's|^\(deb\)|# \1|' /etc/apt/sources.list
        fi
    else
        # Ubuntu 20.04 / 22.04 classic format
        cat <<EOF > /etc/apt/sources.list
deb ${MIRROR} $CODENAME main restricted universe multiverse
deb ${MIRROR} $CODENAME-updates main restricted universe multiverse
deb ${MIRROR} $CODENAME-security main restricted universe multiverse
EOF
    fi

    apt-get update
    echo -e "${GREEN}Mirror updated to repo.abrha.net.${NC}"
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
    
    # Node.js
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
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

    unset DEBIAN_FRONTEND
    echo -e "${GREEN}Stack installed successfully.${NC}"
}

deploy_site() {
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
            
            # Clean directory excluding .ssh to prevent locking out the user
            find /home/"$USERNAME" -mindepth 1 -maxdepth 1 ! -name ".ssh" -exec rm -rf {} +
            
            # Clone into temporary folder to bypass non-empty directory error caused by .ssh
            sudo -u "$USERNAME" git clone -b "$GIT_BRANCH" "$GIT_URL" /home/"$USERNAME"/.tmp_clone
            sudo -u "$USERNAME" bash -c "shopt -s dotglob && mv /home/$USERNAME/.tmp_clone/* /home/$USERNAME/ 2>/dev/null; rmdir /home/$USERNAME/.tmp_clone"
            
            cd /home/"$USERNAME" || return 1
            if [ -f "composer.json" ]; then 
                sudo -u "$USERNAME" composer install --no-dev --optimize-autoloader
            fi
            if [ -f "package.json" ]; then 
                sudo -u "$USERNAME" npm install && sudo -u "$USERNAME" npm run build
            fi
            if [ -f "artisan" ]; then
                sudo -u "$USERNAME" cp .env.example .env
                sudo -u "$USERNAME" php artisan key:generate
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



    esac

    # Fix Permissions Automatically
    chmod 755 "/home/$USERNAME"

    if [ -d "/home/$USERNAME/$DOMAIN" ]; then
        find "/home/$USERNAME/$DOMAIN" -type d -exec chmod 755 {} \;
        find "/home/$USERNAME/$DOMAIN" -type f -exec chmod 644 {} \;
        chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/$DOMAIN"

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
    
    echo -e "\e[32mSite $DOMAIN deployed. Root: /home/$USERNAME\e[0m"
}



install_ssl() {
    read -r -p "Enter domain: " DOMAIN
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}Invalid domain format: '$DOMAIN'${NC}"
        return 1
    fi
    certbot --nginx -d "$DOMAIN"
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

manage_database_menu() {
    while true; do
        echo -e "\n--- Database Management ---"
        echo "1) Create Database & User"
        echo "2) List Databases"
        echo "3) Delete Database"
        echo "4) Change Database User Password"
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
                read -r -p "Directory (e.g., /home/username): " PROG_DIR
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


show_menu() {
    echo -e "\n=== Server Manager (pushit) ==="
    echo "0) Exit"
    echo "1) Install to /usr/local/bin (pushit)"
    echo "2) Change Mirror (repo.abrha.net)"
    echo "3) Install Full Stack (Nginx, PHP ${PHP_VERSION}, MySQL, Redis, Node)"
    echo "4) Deploy Site (User Isolation + FPM Pool)"
    echo "5) Install SSL (Certbot)"
    echo "6) Manage Firewall (UFW)"
    echo "7) Harden Server (SSH)"
    echo "8) Manage DB"
    echo "9) Manage Cron"
    echo "10) Manage Supervisor"
    read -r -p "Option: " OPT
    case $OPT in
        0) exit 0 ;;
        1) install_to_bin ;;
        2) change_mirror ;;
        3) install_stack ;;
        4) deploy_site ;;
        5) install_ssl ;;
        6) manage_firewall ;;
        7) harden_server ;;
        8) manage_database_menu ;;
        9) manage_cron ;;
        10) manage_supervisor ;;
        *) echo "Invalid option." ;;
    esac
}


check_root
while true; do
    show_menu
done
