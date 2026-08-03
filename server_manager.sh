#!/bin/bash

# =========================================================================
# Ubuntu Server Manager (PHP/Laravel Stack)
# =========================================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Execute as root or with sudo.${NC}"
        exit 1
    fi
}

install_to_bin() {
    curl -fsSL https://raw.githubusercontent.com/homoweb/server-manager-sh/main/server_manager.sh -o /usr/local/bin/homoweb
    chmod +x /usr/local/bin/homoweb
    echo -e "${GREEN}Script installed. Run 'sudo homoweb' from anywhere.${NC}"
}

change_mirror() {
    CODENAME=$(lsb_release -cs)
    cat <<EOF > /etc/apt/sources.list
deb https://repo.abrha.net/ubuntu/ $CODENAME main restricted universe multiverse
deb https://repo.abrha.net/ubuntu/ $CODENAME-updates main restricted universe multiverse
deb https://repo.abrha.net/ubuntu/ $CODENAME-security main restricted universe multiverse
EOF
    apt-get update
    echo -e "${GREEN}Mirror updated to repo.abrha.net.${NC}"
}

install_stack() {
    apt-get update && apt-get upgrade -y
    apt-get install -y software-properties-common curl wget git unzip ufw fail2ban supervisor redis-server
    
    # PHP 8.4
    add-apt-repository ppa:ondrej/php -y
    apt-get update
    apt-get install -y php8.4-fpm php8.4-cli php8.4-mysql php8.4-redis php8.4-xml php8.4-mbstring php8.4-curl php8.4-zip php8.4-gd php8.4-bcmath
    
    # Nginx & MySQL
    apt-get install -y nginx mysql-server
    
    # Node.js
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
    
    # Composer
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    
    # Certbot
    apt-get install -y certbot python3-certbot-nginx

    # Fix Sudo Hostname Resolution
    echo "127.0.0.1 localhost $(hostname)" > /etc/hosts
    
    # Fix DNS Resolution (Using Google & Cloudflare)
    rm -f /etc/resolv.conf
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf

    
    echo -e "${GREEN}Stack installed successfully.${NC}"
}

deploy_site() {
    read -p "Enter domain (e.g., example.com): " DOMAIN
    read -p "Enter system username for isolation: " USERNAME
    
    # Create user and handle SSH authentication
    if id "$USERNAME" &>/dev/null; then
        echo -e "\e[33mUser '$USERNAME' already exists. Using existing user.\e[0m"
    else
        useradd -m -s /bin/bash "$USERNAME"
        echo -e "\e[32mUser '$USERNAME' created.\e[0m"
        
        echo "Select SSH authentication method for $USERNAME:"
        echo "1) Password"
        echo "2) SSH Public Key"
        read -p "Choice (1 or 2): " AUTH_METHOD

        case $AUTH_METHOD in
            1)
                read -s -p "Enter password for $USERNAME: " USER_PASS
                echo
                read -s -p "Confirm password: " USER_PASS_CONFIRM
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
                read -p "Paste the Public SSH Key (ssh-rsa ...): " SSH_KEY
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
    read -p "Choice (1 or 2): " DEPLOY_METHOD

    case $DEPLOY_METHOD in
        1)
            read -p "Enter Git Repository URL: " GIT_URL
            read -p "Enter branch (default: main): " GIT_BRANCH
            GIT_BRANCH=${GIT_BRANCH:-main}
            
            # Clean directory excluding .ssh to prevent locking out the user
            find /home/"$USERNAME" -mindepth 1 -maxdepth 1 ! -name ".ssh" -exec rm -rf {} +
            
            # Clone into temporary folder to bypass non-empty directory error caused by .ssh
            sudo -u "$USERNAME" git clone -b "$GIT_BRANCH" "$GIT_URL" /home/"$USERNAME"/.tmp_clone
            sudo -u "$USERNAME" bash -c "shopt -s dotglob && mv /home/$USERNAME/.tmp_clone/* /home/$USERNAME/ 2>/dev/null; rmdir /home/$USERNAME/.tmp_clone"
            
            cd /home/"$USERNAME"
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
            read -p "Press Enter ONLY AFTER the upload is finished..."
            
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

    # PHP-FPM Pool
    POOL_CONF="/etc/php/8.4/fpm/pool.d/$USERNAME.conf"
    cat <<EOF > "$POOL_CONF"
[$USERNAME]
user = $USERNAME
group = $USERNAME
listen = /run/php/php8.4-fpm-$USERNAME.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
EOF
    systemctl restart php8.4-fpm
    
    # Nginx Vhost
    VHOST_CONF="/etc/nginx/sites-available/$DOMAIN"
    cat <<EOF > "$VHOST_CONF"
server {
    listen 80;
    server_name $DOMAIN;
    root /home/$USERNAME/public;
    index index.php index.html index.htm;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.4-fpm-$USERNAME.sock;
    }
}
EOF
    ln -sf "$VHOST_CONF" /etc/nginx/sites-enabled/
    systemctl reload nginx
    
    echo -e "\e[32mSite $DOMAIN deployed. Root: /home/$USERNAME\e[0m"
}



install_ssl() {
    read -p "Enter domain: " DOMAIN
    certbot --nginx -d "$DOMAIN"
}

manage_firewall() {
    echo "1) Enable UFW & allow SSH/HTTP/HTTPS"
    echo "2) Allow port"
    echo "3) Deny port"
    read -p "Select: " FW_OPT
    case $FW_OPT in
        1) ufw allow OpenSSH; ufw allow 'Nginx Full'; ufw --force enable ;;
        2) read -p "Port: " PORT; ufw allow "$PORT" ;;
        3) read -p "Port: " PORT; ufw deny "$PORT" ;;
    esac
}

harden_server() {
    # SSH Hardening (Disable root login, password auth)
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    systemctl restart sshd
    echo -e "${GREEN}Server hardened.${NC}"
}

manage_database_menu() {
    while true; do
        echo -e "\n--- Database Management ---"
        echo "1) Create Database & User"
        echo "2) List Databases"
        echo "3) Delete Database"
        echo "4) Change Database User Password"
        echo "0) Back to Main Menu"
        read -p "Select an option: " db_choice

        case $db_choice in
            1)
                read -p "Enter Database Name: " db_name
                read -p "Enter Database User: " db_user
                read -sp "Enter Database Password: " db_pass
                echo ""
                if [[ -z "$db_name" || -z "$db_user" || -z "$db_pass" ]]; then
                    echo -e "\e[31mError: All fields are required.\e[0m"
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
                read -p "Enter Database Name to DELETE (or press Enter to cancel): " del_db
                if [[ -n "$del_db" ]]; then
                    mysql -e "DROP DATABASE IF EXISTS \`${del_db}\`;"
                    echo -e "\e[32mSuccess: Database '${del_db}' deleted.\e[0m"
                fi
                ;;
            4)
                read -p "Enter Database User to edit: " edit_user
                read -sp "Enter New Password: " new_pass
                echo ""
                if [[ -n "$edit_user" && -n "$new_pass" ]]; then
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
        read -p "Choice: " CRON_CHOICE

        case $CRON_CHOICE in
            1)
                read -p "Enter username (e.g., root, or isolated user): " C_USER
                crontab -u "$C_USER" -l || echo "No crontab for $C_USER"
                ;;
            2)
                read -p "Enter username to run cron as: " C_USER
                echo -e "\e[33mExample Schedule:\e[0m * * * * * (Every minute)"
                read -p "Enter schedule expression: " C_SCHED
                echo -e "\e[33mExample Command:\e[0m cd /home/user && php artisan schedule:run >> /dev/null 2>&1"
                read -p "Enter command: " C_CMD
                
                (crontab -u "$C_USER" -l 2>/dev/null; echo "$C_SCHED $C_CMD") | crontab -u "$C_USER" -
                echo -e "\e[32mJob added successfully.\e[0m"
                ;;
            3)
                read -p "Enter username to manage: " C_USER
                crontab -u "$C_USER" -l > /tmp/cron.tmp 2>/dev/null
                if [ ! -s /tmp/cron.tmp ]; then 
                    echo -e "\e[31mNo jobs found for $C_USER.\e[0m"
                    continue
                fi
                echo "Current Jobs:"
                cat -n /tmp/cron.tmp
                read -p "Enter line number to delete: " LINE_NUM
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
        read -p "Choice: " SUP_CHOICE

        case $SUP_CHOICE in
            1)
                supervisorctl status
                ;;
            2)
                read -p "Program Name (e.g., myapp-worker): " PROG_NAME
                read -p "Run as User (e.g., username): " PROG_USER
                read -p "Directory (e.g., /home/username): " PROG_DIR
                echo -e "\e[33mExample Command:\e[0m php artisan queue:work --sleep=3 --tries=3"
                read -p "Command: " PROG_CMD
                read -p "Number of processes (default 1): " PROG_NUM
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
                supervisorctl start ${PROG_NAME}:*
                echo -e "\e[32mProcess $PROG_NAME added and started.\e[0m"
                ;;
            3)
                echo "Installed Supervisor Configurations:"
                ls -1 /etc/supervisor/conf.d/ | sed 's/\.conf$//'
                read -p "Enter Program Name to delete: " PROG_NAME
                CONF_PATH="/etc/supervisor/conf.d/${PROG_NAME}.conf"
                
                if [ -f "$CONF_PATH" ]; then
                    supervisorctl stop ${PROG_NAME}:*
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
    echo -e "\n=== Server Manager (homoweb) ==="
    echo "0) Exit"
    echo "1) Install to /usr/local/bin (homoweb)"
    echo "2) Change Mirror (repo.abrha.net)"
    echo "3) Install Full Stack (Nginx, PHP 8.4, MySQL, Redis, Node)"
    echo "4) Deploy Site (User Isolation + FPM Pool)"
    echo "5) Install SSL (Certbot)"
    echo "6) Manage Firewall (UFW)"
    echo "7) Harden Server (SSH)"
    echo "8) Manage DB"
    echo "9) Manage Cron"
    echo "10) Manage Supervisor"
    read -p "Option: " OPT
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
        *) echo "Invalid option." ;;
    esac
}


check_root
while true; do
    show_menu
done
