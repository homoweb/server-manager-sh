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
    
    # Create user
    if id "$USERNAME" &>/dev/null; then
        echo -e "\e[33mUser '$USERNAME' already exists. Using existing user.\e[0m"
    else
        useradd -m -s /bin/bash "$USERNAME"
        echo -e "\e[32mUser '$USERNAME' created.\e[0m"
    fi
    
    mkdir -p /home/"$USERNAME"
    chown -R "$USERNAME":"$USERNAME" /home/"$USERNAME"

    echo "Select deployment method:"
    echo "1) Git Repository"
    echo "2) Manual Upload (SFTP/SCP)"
    read -p "Choice (1 or 2): " DEPLOY_METHOD

    case $DEPLOY_METHOD in
        1)
            read -p "Enter Git Repository URL: " GIT_URL
            read -p "Enter branch (default: main): " GIT_BRANCH
            GIT_BRANCH=${GIT_BRANCH:-main}
            
            # Clean directory for clone
            rm -rf /home/"$USERNAME"/* /home/"$USERNAME"/.[!.]*
            
            sudo -u "$USERNAME" git clone -b "$GIT_BRANCH" "$GIT_URL" /home/"$USERNAME"
            
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
            echo -e "\e[33mUpload your files to: /home/$USERNAME\e[0m"
            echo "Example SCP: scp -r /local/path/* root@your_server_ip:/home/$USERNAME/"
            read -p "Press Enter ONLY AFTER you have uploaded the files to continue..."
            chown -R "$USERNAME":"$USERNAME" /home/"$USERNAME"
            ;;
        *)
            echo "Invalid choice. Proceeding without deployment."
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

show_menu() {
    echo -e "\n=== Server Manager (homoweb) ==="
    echo "1) Install to /usr/local/bin (homoweb)"
    echo "2) Change Mirror (repo.abrha.net)"
    echo "3) Install Full Stack (Nginx, PHP 8.4, MySQL, Redis, Node)"
    echo "4) Deploy Site (User Isolation + FPM Pool)"
    echo "5) Install SSL (Certbot)"
    echo "6) Manage Firewall (UFW)"
    echo "7) Harden Server (SSH)"
    echo "8) Exit"
    read -p "Option: " OPT
    case $OPT in
        1) install_to_bin ;;
        2) change_mirror ;;
        3) install_stack ;;
        4) deploy_site ;;
        5) install_ssl ;;
        6) manage_firewall ;;
        7) harden_server ;;
        8) exit 0 ;;
        *) echo "Invalid option." ;;
    esac
}


check_root
while true; do
    show_menu
done
