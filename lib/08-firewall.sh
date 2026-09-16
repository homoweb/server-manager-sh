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

