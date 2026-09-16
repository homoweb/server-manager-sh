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

