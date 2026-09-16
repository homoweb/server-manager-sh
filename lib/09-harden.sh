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

