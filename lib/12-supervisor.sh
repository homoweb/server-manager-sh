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

