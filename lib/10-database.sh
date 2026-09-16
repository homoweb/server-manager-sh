# pushit DB helper — validate mysql client + daemon before any DB action
pushit_db_require() {
    if ! command -v mysql >/dev/null 2>&1; then
        echo -e "${RED}MySQL client 'mysql' not found.${NC}"
        echo -e "${YELLOW}MySQL is not installed on this server.${NC}"
        echo -e "${YELLOW}Fix: sudo pushit -> 2) Install Full Stack${NC}"
        echo -e "${YELLOW}Quick: sudo apt-get update && sudo apt-get install -y mysql-server mysql-client && sudo systemctl enable --now mysql${NC}"
        return 1
    fi
    if ! systemctl is-active --quiet mysql 2>/dev/null && ! systemctl is-active --quiet mysqld 2>/dev/null && ! pgrep -x mysqld >/dev/null 2>&1; then
        echo -e "${YELLOW}MySQL service is not running - trying to start...${NC}"
        systemctl enable --now mysql 2>/dev/null || systemctl enable --now mysqld 2>/dev/null || systemctl start mysql 2>/dev/null || systemctl start mysqld 2>/dev/null || service mysql start 2>/dev/null || true
        sleep 2
    fi
    if ! systemctl is-active --quiet mysql 2>/dev/null && ! systemctl is-active --quiet mysqld 2>/dev/null && ! pgrep -x mysqld >/dev/null 2>&1; then
        echo -e "${RED}MySQL is installed but not running.${NC}"
        echo -e "${YELLOW}Check: systemctl status mysql --no-pager | head -n 40${NC}"
        echo -e "${YELLOW}      journalctl -u mysql -n 50 --no-pager${NC}"
        return 1
    fi
    if ! mysql -e "SELECT 1" >/dev/null 2>&1; then
        echo -e "${RED}Cannot connect to MySQL (socket/auth). Is mysqld up?${NC}"
        echo -e "${YELLOW}Try: sudo mysql -e \"SELECT 1\"   (root uses auth_socket)${NC}"
        return 1
    fi
    return 0
}

download_database() {
    if ! pushit_db_require; then return 1; fi
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
        local fsize
        fsize=$(du -h "$DUMP_FILE" 2>/dev/null | cut -f1)
        echo -e "${GREEN}Backup created: ${DUMP_FILE} (${fsize})${NC}"
        # --- One-time 30-min download link ---
        if ! command -v python3 >/dev/null 2>&1; then
            echo -e "${YELLOW}python3 not found — installing for one-time link server...${NC}"
            apt-get update -qq 2>/dev/null && apt-get install -y -qq python3 2>/dev/null || true
        fi
        local token dl_file dl_meta expires expires_human dl_url
        if command -v openssl >/dev/null 2>&1; then
            token=$(openssl rand -hex 16 2>/dev/null)
        fi
        if [ -z "$token" ] || [ ${#token} -lt 16 ]; then
            token=$(head -c 24 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 32)
        fi
        if [ -z "$token" ] || [ ${#token} -lt 16 ]; then
            token=$(date +%s%N 2>/dev/null | sha256sum 2>/dev/null | head -c 32)
        fi
        token=$(echo "$token" | tr -dc 'a-zA-Z0-9' | head -c 32)
        [ -z "$token" ] && token="$(date +%s)_$$"
        mkdir -p "$PUSHIT_DL_DIR" 2>/dev/null || true
        chmod 700 "$PUSHIT_DL_DIR" 2>/dev/null || true
        dl_file="${PUSHIT_DL_DIR}/${token}"
        dl_meta="${dl_file}.meta"
        # Move dump into DL dir (keep original too for scp fallback? move to save space)
        if cp -a "$DUMP_FILE" "$dl_file" 2>/dev/null || cp "$DUMP_FILE" "$dl_file" 2>/dev/null; then
            chmod 600 "$dl_file" 2>/dev/null || true
        else
            echo -e "${RED}Failed to prepare one-time link file.${NC}"
            dl_file="$DUMP_FILE"
        fi
        expires=$(( $(date +%s) + 1800 ))
        expires_human=$(date -d "@${expires}" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || date -r "$expires" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "in 30 minutes")
        {
            echo "filename=$(basename "$DUMP_FILE")"
            echo "expires=${expires}"
            echo "db=${db_name}"
            echo "size=${fsize:-unknown}"
            echo "created=$(date +%s)"
        } > "$dl_meta" 2>/dev/null || true
        chmod 600 "$dl_meta" 2>/dev/null || true
        # Schedule local deletion after 30 min (fallback even if server not hit)
        ( sleep 1800; rm -f "$dl_file" "$dl_meta" "$DUMP_FILE" 2>/dev/null ) >/dev/null 2>&1 &
        disown 2>/dev/null || true
        if command -v at >/dev/null 2>&1; then
            echo "rm -f '$dl_file' '$dl_meta' '$DUMP_FILE' 2>/dev/null" | at now + 30 minutes 2>/dev/null || true
        fi
        # Ensure download server is running
        pushit_dl_ensure_server 2>/dev/null || pushit_dl_init_python_server 2>/dev/null || true
        dl_url=$(pushit_dl_build_url "$token" 2>/dev/null)
        echo ""
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN} One-time download link (valid 30 min, single use):${NC}"
        echo -e "  ${YELLOW}${dl_url}${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${YELLOW}curl -O \"${dl_url}\"${NC}"
        echo -e "  ${YELLOW}wget \"${dl_url}\"${NC}"
        echo -e "  Expires: ${expires_human}  |  Size: ${fsize}  |  File: $(basename "$DUMP_FILE")"
        echo -e "  ${RED}After first download OR after 30 min the file is deleted.${NC}"
        echo ""
        SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        echo -e "${YELLOW}Fallback (scp) — file also at:${NC} ${DUMP_FILE}"
        echo -e "  scp root@${SERVER_IP}:${DUMP_FILE} ./"
        echo -e "  ${YELLOW}Note: scp file will also be deleted after 30 min.${NC}"
    else
        rm -f "$DUMP_FILE"
        echo -e "${RED}Dump failed. No backup file was kept.${NC}"
        return 1
    fi
}

upload_database() {
    if ! pushit_db_require; then return 1; fi
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
                if ! pushit_db_require; then continue; fi
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
                if ! pushit_db_require; then continue; fi
                echo -e "\n--- Existing Databases ---"
                mysql -e "SHOW DATABASES;" | grep -Ev "^(Database|information_schema|performance_schema|mysql|sys)$"
                ;;
            3)
                if ! pushit_db_require; then continue; fi
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
                if ! pushit_db_require; then continue; fi
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

