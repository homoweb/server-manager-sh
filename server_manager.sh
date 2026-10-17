#!/bin/bash

# =========================================================================
# Ubuntu Server Manager (PHP/Laravel Stack) — pushit
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
# Single source of truth for npm version (pinned after Node install)
NPM_VERSION="12.0.2"

PUSHIT_BIN="/usr/local/bin/pushit"
PUSHIT_CONFIG="/etc/pushit.conf"
PUSHIT_VERSION="0.1.24"
PUSHIT_REPO="homoweb/server-manager-sh"
PUSHIT_REMOTE_URL="https://raw.githubusercontent.com/${PUSHIT_REPO}/main/server_manager.sh"
PUSHIT_UPDATE_TTL=21600
PUSHIT_UPDATE_CACHE_DIR="/var/cache/pushit"
PUSHIT_UPDATE_CACHE_FILE="${PUSHIT_UPDATE_CACHE_DIR}/update.json"
PUSHIT_DL_DIR="/var/lib/pushit/downloads"
PUSHIT_DL_PORT="8787"
PUSHIT_DL_SERVER="/usr/local/bin/pushit-dl-server.py"
PUSHIT_DL_LOG="/var/log/pushit-dl.log"

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
        printf 'PUSHIT_MODE="%s"\n' "$mode"
        if [ "$mode" = "ip" ]; then
            printf 'PUSHIT_PORT="%s"\n' "$value"
            printf 'PUSHIT_IP="%s"\n' "${ip_detected:-}"
            echo 'PUSHIT_DOMAIN=""'
        else
            printf 'PUSHIT_DOMAIN="%s"\n' "$value"
            echo 'PUSHIT_PORT=""'
            printf 'PUSHIT_IP="%s"\n' "${ip_detected:-}"
        fi
    } > "$PUSHIT_CONFIG"
    chmod 600 "$PUSHIT_CONFIG" 2>/dev/null || true
}
pushit_load_config() {
    [ -f "$PUSHIT_CONFIG" ] && . "$PUSHIT_CONFIG" 2>/dev/null || true
}
pushit_ssh_port() {
    local _port=""
    _port=$(grep -Eh "^\s*Port\s+" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | grep -v "^#" | awk '{print $2}' | tail -n1 | tr -d '[:space:]')
    if [ -z "$_port" ]; then
        _port=$(sshd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | tail -n1 | tr -d '[:space:]')
    fi
    if ! [[ "$_port" =~ ^[0-9]+$ ]]; then _port="22"; fi
    echo "$_port"
}

pushit_ufw_apply_baseline() {
    local sshd_bin ssh_ports port
    if ! command -v ufw >/dev/null 2>&1; then
        echo -e "${RED}UFW is not installed; firewall defaults were not changed.${NC}"
        return 1
    fi
    sshd_bin=$(command -v sshd) || {
        echo -e "${RED}OpenSSH server was not found; refusing to enable UFW without protecting SSH access.${NC}"
        return 1
    }
    ssh_ports=$("$sshd_bin" -T 2>/dev/null | awk '$1 == "port" && $2 ~ /^[0-9]+$/ {print $2}' | sort -nu)
    if [ -z "$ssh_ports" ]; then
        echo -e "${RED}Could not determine the active SSH port; UFW was not enabled.${NC}"
        return 1
    fi
    for port in $ssh_ports; do
        if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ] || ! ufw allow "${port}/tcp"; then
            echo -e "${RED}Could not allow SSH port ${port}/tcp; UFW defaults were not changed.${NC}"
            return 1
        fi
    done
    ufw allow 80/tcp || return 1
    ufw allow 443/tcp || return 1
    ufw default deny incoming || return 1
    ufw default allow outgoing || return 1
    if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw --force enable || return 1
    else
        ufw reload || return 1
    fi
    echo -e "${GREEN}UFW active: SSH (${ssh_ports}), HTTP (80) and HTTPS (443) allowed; other unsolicited inbound traffic denied.${NC}"
    echo -e "${YELLOW}Existing explicit UFW rules were preserved. Review them with menu 5 and remove rules you no longer need.${NC}"
}

pushit_ufw_validate_rule() {
    local input="$1" port protocol
    if ! [[ "$input" =~ ^([0-9]{1,5})(/(tcp|udp))?$ ]]; then return 1; fi
    port="${BASH_REMATCH[1]}"
    protocol="${BASH_REMATCH[3]:-tcp}"
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    printf '%s/%s\n' "$port" "$protocol"
}

pushit_ufw_validate_source() {
    python3 - "$1" <<'PYIP'
import ipaddress, sys
try:
    print(ipaddress.ip_network(sys.argv[1], strict=False))
except ValueError:
    sys.exit(1)
PYIP
}

pushit_is_laravel() {
    local _dir="$1"
    [ -f "${_dir}/artisan" ] && return 0
    [ -f "${_dir}/bootstrap/app.php" ] && return 0
    if [ -f "${_dir}/composer.json" ] && grep -q '"laravel/framework"' "${_dir}/composer.json" 2>/dev/null; then return 0; fi
    return 1
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
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
            echo -e "${YELLOW}UFW is active. Open ${port}/tcp from menu 5 only if this custom port must be public.${NC}"
        fi
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
    echo -e " pushit v${PUSHIT_VERSION}  (${PUSHIT_REPO})"
}

# --- Update check (no branch, semver compare via PUSHIT_VERSION) ---
pushit_version_gt() {
    local a="$1" b="$2"
    [ -z "$a" ] || [ -z "$b" ] && return 1
    [ "$a" = "$b" ] && return 1
    local smallest
    smallest=$(printf "%s\n%s\n" "$a" "$b" | sort -V 2>/dev/null | head -n1)
    [ "$smallest" = "$b" ] && [ "$a" != "$b" ]
}

pushit_fetch_remote_version() {
    mkdir -p "$PUSHIT_UPDATE_CACHE_DIR" 2>/dev/null || true
    local tmp
    tmp=$(mktemp /tmp/pushit_ver.XXXXXX 2>/dev/null || echo "/tmp/pushit_ver.$$")
    # Bypass CDN cache; short timeout so menu never hangs
    if curl -fsSL --max-time 4 --connect-timeout 3 -H "Cache-Control: no-cache" -H "Pragma: no-cache" "$PUSHIT_REMOTE_URL" -o "$tmp" 2>/dev/null; then
        local rv=""
        rv=$(grep -m1 '^PUSHIT_VERSION=' "$tmp" 2>/dev/null | sed -E 's/^PUSHIT_VERSION="([^"]+)".*/\1/' | xargs 2>/dev/null)
        [ -z "$rv" ] && rv=$(grep -m1 '^PUSHIT_VERSION=' "$tmp" 2>/dev/null | cut -d= -f2 | tr -d '"'\'' ' | xargs 2>/dev/null)
        if [ -n "$rv" ]; then
            printf '{"remote":"%s","checked":%s}\n' "$rv" "$(date +%s)" > "${PUSHIT_UPDATE_CACHE_FILE}.tmp" 2>/dev/null && mv -f "${PUSHIT_UPDATE_CACHE_FILE}.tmp" "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null
            chmod 644 "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null || true
        fi
    fi
    rm -f "$tmp" 2>/dev/null || true
}

# Sets globals: PUSHIT_HAS_UPDATE (0/1), PUSHIT_REMOTE_VER
PUSHIT_HAS_UPDATE=0
PUSHIT_REMOTE_VER=""
pushit_update_check() {
    local now cache_mtime=0 cached_remote=""
    now=$(date +%s 2>/dev/null || echo 0)
    if [ -f "$PUSHIT_UPDATE_CACHE_FILE" ]; then
        cache_mtime=$(stat -c %Y "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null || stat -f %m "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null || echo 0)
        cached_remote=$(grep -o '"remote"[[:space:]]*:[[:space:]]*"[^"]*"' "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null | head -n1 | cut -d'"' -f4)
        # Stale -> refresh (with timeout, non-fatal)
        if [ "$now" -gt 0 ] && [ "$cache_mtime" -gt 0 ] && [ $((now - cache_mtime)) -gt "$PUSHIT_UPDATE_TTL" ]; then
            pushit_fetch_remote_version
            cached_remote=$(grep -o '"remote"[[:space:]]*:[[:space:]]*"[^"]*"' "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null | head -n1 | cut -d'"' -f4)
        fi
    else
        pushit_fetch_remote_version
        cached_remote=$(grep -o '"remote"[[:space:]]*:[[:space:]]*"[^"]*"' "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null | head -n1 | cut -d'"' -f4)
    fi
    PUSHIT_REMOTE_VER="$cached_remote"
    PUSHIT_HAS_UPDATE=0
    if [ -n "$PUSHIT_REMOTE_VER" ] && pushit_version_gt "$PUSHIT_REMOTE_VER" "$PUSHIT_VERSION"; then
        PUSHIT_HAS_UPDATE=1
    fi
}

pushit_show_update_notice() {
    if [ "${PUSHIT_HAS_UPDATE:-0}" = "1" ] && [ -n "${PUSHIT_REMOTE_VER:-}" ]; then
        echo ""
        echo -e "${YELLOW}┌──────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}│  ★ Update available: v${PUSHIT_VERSION} → v${PUSHIT_REMOTE_VER}                     │${NC}"
        echo -e "${YELLOW}│  Run option 12 or press 'u' to update now.           │${NC}"
        echo -e "${YELLOW}└──────────────────────────────────────────────────────┘${NC}"
    fi
}

pushit_update_script() {
    local url="${PUSHIT_REMOTE_URL}"
    echo -e "${YELLOW}Checking for updates...${NC}"
    echo -e " Current: v${PUSHIT_VERSION}"
    # Force fresh fetch when user explicitly asks to update
    pushit_fetch_remote_version
    local remote_ver=""
    remote_ver=$(grep -o '"remote"[[:space:]]*:[[:space:]]*"[^"]*"' "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null | head -n1 | cut -d'"' -f4)
    if [ -n "$remote_ver" ]; then
        echo -e " Remote : v${remote_ver}"
        if ! pushit_version_gt "$remote_ver" "$PUSHIT_VERSION"; then
            if [ "$remote_ver" = "$PUSHIT_VERSION" ]; then
                echo -e "${GREEN}Already up to date (v${PUSHIT_VERSION}).${NC}"
                read -r -p "Force re-download anyway? (y/n): " _force
                if ! [[ "$_force" =~ ^[yY] ]]; then return 0; fi
            else
                echo -e "${YELLOW}Local version newer than remote (dev build?). Continuing anyway.${NC}"
            fi
        else
            echo -e "${YELLOW}Update available: v${PUSHIT_VERSION} → v${remote_ver}${NC}"
        fi
    fi
    echo -e "${YELLOW}Downloading from $url ...${NC}"
    local tmp
    tmp=$(mktemp /tmp/pushit.XXXXXX)
    if ! curl -fsSL -H "Cache-Control: no-cache" -H "Pragma: no-cache" "${url}?v=$(date +%s)" -o "$tmp" 2>/dev/null; then
        if ! curl -fsSL "$url" -o "$tmp" 2>/dev/null; then
            echo -e "${RED}Download failed. Check internet / URL.${NC}"
            rm -f "$tmp"
            return 1
        fi
    fi
    if ! head -n 20 "$tmp" 2>/dev/null | grep -qE "Server Manager|PUSHIT_VERSION"; then
        echo -e "${RED}Downloaded file looks invalid (missing header). Aborted.${NC}"
        echo -e "${YELLOW}First 5 lines of download:${NC}"
        head -n 5 "$tmp" 2>/dev/null | sed 's/^/  /' || true
        rm -f "$tmp"
        return 1
    fi
    if ! bash -n "$tmp" 2>&1; then
        echo -e "${RED}Downloaded script has syntax errors. Aborted.${NC}"
        rm -f "$tmp"
        return 1
    fi
    local new_ver=""
    new_ver=$(grep -m1 '^PUSHIT_VERSION=' "$tmp" 2>/dev/null | cut -d= -f2 | tr -d '"'\'' ' | xargs 2>/dev/null)
    # Backup current binary
    if [ -f "$PUSHIT_BIN" ]; then
        cp -a "$PUSHIT_BIN" "${PUSHIT_BIN}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || cp "$PUSHIT_BIN" "${PUSHIT_BIN}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
    install -m 0755 "$tmp" "$PUSHIT_BIN"
    rm -f "$tmp"
    # Refresh cache so banner disappears after update
    if [ -n "$new_ver" ]; then
        mkdir -p "$PUSHIT_UPDATE_CACHE_DIR" 2>/dev/null || true
        printf '{"remote":"%s","checked":%s}\n' "$new_ver" "$(date +%s)" > "$PUSHIT_UPDATE_CACHE_FILE" 2>/dev/null || true
        PUSHIT_REMOTE_VER="$new_ver"; PUSHIT_HAS_UPDATE=0; PUSHIT_VERSION="$new_ver"
    fi
    echo -e "${GREEN}Updated to $PUSHIT_BIN ${new_ver:+ (v$new_ver)}. Restart with 'sudo pushit'.${NC}"
    if [ "$0" != "$PUSHIT_BIN" ] && [ "${BASH_SOURCE[0]:-}" != "$PUSHIT_BIN" ]; then
        echo -e "${YELLOW}Note: you are running a different copy; restart with 'sudo pushit' for the updated script.${NC}"
    fi
}

pushit_uninstall() {
    echo -e "${RED}=== Uninstall Pushit ===${NC}"
    echo "This will remove:"
    echo "  - $PUSHIT_BIN"
    echo "  - $PUSHIT_CONFIG"
    echo "  - ${PUSHIT_BIN}.bak.* (backups)"
    echo "  - /tmp/pushit.* (temp downloads)"
    echo "  - $PUSHIT_DL_DIR (download links)"
    echo "  - $PUSHIT_DL_SERVER + systemd units"
    echo "  - $PUSHIT_UPDATE_CACHE_DIR (update check cache)"
    local cur=""
    if [ -f "$0" ] && [ "$0" != "$PUSHIT_BIN" ] && head -n1 "$0" 2>/dev/null | grep -q "Server Manager"; then cur="$0"
    elif [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ] && [ "${BASH_SOURCE[0]}" != "$PUSHIT_BIN" ] && head -n1 "${BASH_SOURCE[0]}" 2>/dev/null | grep -q "Server Manager"; then cur="${BASH_SOURCE[0]}"
    fi
    if [ -n "$cur" ]; then echo "  - $cur (current file)"; fi
    echo ""
    read -r -p "Type 'yes' to confirm uninstall: " CONF
    if [ "$CONF" != "yes" ]; then echo "Aborted."; return 1; fi
    echo -e "${YELLOW}Removing...${NC}"
    rm -f "$PUSHIT_BIN" 2>/dev/null || true
    rm -f "$PUSHIT_CONFIG" 2>/dev/null || true
    rm -f "${PUSHIT_BIN}.bak."* 2>/dev/null || true
    rm -f /tmp/pushit.* 2>/dev/null || true
    rm -rf "$PUSHIT_UPDATE_CACHE_DIR" 2>/dev/null || true
    systemctl disable --now pushit-dl.service 2>/dev/null || true
    systemctl disable --now pushit-dl-prune.timer 2>/dev/null || true
    rm -f /etc/systemd/system/pushit-dl.service /etc/systemd/system/pushit-dl-prune.service /etc/systemd/system/pushit-dl-prune.timer 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    pkill -f "$PUSHIT_DL_SERVER" 2>/dev/null || true
    rm -rf "$PUSHIT_DL_DIR" 2>/dev/null || true
    rm -f "$PUSHIT_DL_SERVER" "$PUSHIT_DL_LOG" 2>/dev/null || true
    hash -r 2>/dev/null || true
    if [ -n "$cur" ]; then
        read -r -p "Also remove current file '$cur'? (y/n): " RM_CUR
        if [[ "$RM_CUR" =~ ^[yY] ]]; then rm -f "$cur" 2>/dev/null && echo "Removed $cur" || echo "Could not remove $cur"; fi
    fi
    # Verify
    local remain=0
    [ -f "$PUSHIT_BIN" ] && remain=1
    [ -f "$PUSHIT_CONFIG" ] && remain=1
    if [ "$remain" -eq 0 ]; then echo -e "${GREEN}Pushit completely removed. Restart your shell.${NC}"
    else echo -e "${RED}Some files remain (check permissions).${NC}"; ls -l "$PUSHIT_BIN" "$PUSHIT_CONFIG" 2>&1 | head -n 10; fi
    echo -e "${YELLOW}Exiting.${NC}"
    exit 0
}

pushit_dl_init_python_server() {
    mkdir -p "$PUSHIT_DL_DIR" 2>/dev/null || true
    chmod 700 "$PUSHIT_DL_DIR" 2>/dev/null || true
    find "$PUSHIT_DL_DIR" -maxdepth 1 -name "*.meta" -mmin +10 -exec rm -f {} \; 2>/dev/null || true
    for m in "$PUSHIT_DL_DIR"/*.meta; do
        [ -e "$m" ] || continue
        [ -f "$m" ] || continue
        local tok="${m##*/}"; tok="${tok%.meta}"
        local f="$PUSHIT_DL_DIR/$tok"
        local exp
        exp=$(grep -m1 "^expires=" "$m" 2>/dev/null | cut -d= -f2)
        if [ -n "$exp" ] && [ "$(date +%s)" -ge "$exp" ]; then rm -f "$f" "$m" 2>/dev/null || true; fi
    done 2>/dev/null || true
    cat > "$PUSHIT_DL_SERVER" <<'PYEOF'
#!/usr/bin/env python3
import os, sys, time, threading, http.server, socketserver, urllib.parse
DL_DIR = "/var/lib/pushit/downloads"
PORT = 8787
class Handler(http.server.BaseHTTPRequestHandler):
    def _serve_token(self, token):
        if token == "favicon.ico":
            self.send_response(404); self.end_headers(); return
        if not token or "/" in token or ".." in token or not token.replace("_","").replace("-","").isalnum():
            self.send_response(400); self.end_headers(); self.wfile.write(b"Invalid token\n"); return
        fpath = os.path.join(DL_DIR, token)
        mpath = os.path.join(DL_DIR, token + ".meta")
        if not os.path.isfile(fpath):
            self.send_response(404); self.end_headers(); self.wfile.write(b"Not found or expired\n"); return
        meta = {}
        if os.path.isfile(mpath):
            try:
                with open(mpath) as mf:
                    for line in mf:
                        if "=" in line:
                            k, v = line.strip().split("=", 1)
                            meta[k] = v
            except:
                pass
            exp = int(meta.get("expires", "0") or 0)
            if exp and time.time() >= exp:
                try: os.remove(fpath)
                except: pass
                try: os.remove(mpath)
                except: pass
                self.send_response(410); self.end_headers(); self.wfile.write(b"Link expired (10 min)\n"); return
        fname = meta.get("filename", token) if meta else token
        try:
            fsize = os.path.getsize(fpath)
        except:
            self.send_response(404); self.end_headers(); self.wfile.write(b"Not found or expired\n"); return
        range_header = self.headers.get("Range")
        start, end = 0, fsize - 1
        is_range = False
        if range_header and range_header.startswith("bytes="):
            try:
                spec = range_header[6:].strip().split(",")[0]
                if "-" in spec:
                    s, e = spec.split("-", 1)
                    if s == "":
                        suffix = int(e)
                        start = max(0, fsize - suffix)
                    elif e == "":
                        start = int(s)
                    else:
                        start, end = int(s), int(e)
                    start = max(0, min(start, fsize - 1))
                    end = max(start, min(end, fsize - 1))
                    is_range = True
            except:
                is_range = False
                start, end = 0, fsize - 1
        length = end - start + 1
        if is_range:
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{fsize}")
        else:
            self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(length))
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % fname.replace('"', ''))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        if not is_range:
            self.send_header("Content-Transfer-Encoding", "binary")
        self.end_headers()
        if self.command == "HEAD":
            return
        try:
            with open(fpath, "rb") as fh:
                fh.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = fh.read(min(1024*1024, remaining))
                    if not chunk:
                        break
                    try:
                        self.wfile.write(chunk)
                    except (BrokenPipeError, ConnectionResetError):
                        break
                    remaining -= len(chunk)
        except:
            return
    def do_GET(self):
        p = urllib.parse.urlparse(self.path)
        self._serve_token(p.path.lstrip("/").split("?")[0].split("#")[0].strip())
    def do_HEAD(self):
        p = urllib.parse.urlparse(self.path)
        self._serve_token(p.path.lstrip("/").split("?")[0].split("#")[0].strip())
    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" % (self.client_address[0], self.log_date_time_string(), fmt%args))
class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True
if __name__ == "__main__":
    os.makedirs(DL_DIR, exist_ok=True)
    with ThreadedTCPServer(("", PORT), Handler) as httpd:
        httpd.serve_forever()
PYEOF
    chmod +x "$PUSHIT_DL_SERVER" 2>/dev/null || true
}

pushit_is_installed() {
    # Consider installed if we are already running as pushit, or binary exists
    if [ -x "$PUSHIT_BIN" ] && [ -f "$PUSHIT_BIN" ]; then return 0; fi
    if [ "$0" = "$PUSHIT_BIN" ] || [ "${BASH_SOURCE[0]:-}" = "$PUSHIT_BIN" ]; then return 0; fi
    return 1
}

pushit_dl_ensure_server() {
    pushit_dl_init_python_server
    # Systemd: (re)create units and restart to pick up new python code
    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        cat > /etc/systemd/system/pushit-dl.service <<EOF2
[Unit]
Description=Pushit download server
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 $PUSHIT_DL_SERVER
Restart=always
RestartSec=5
EOF2
        cat > /etc/systemd/system/pushit-dl-prune.service <<EOF2
[Unit]
Description=Prune expired pushit downloads
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'find $PUSHIT_DL_DIR -maxdepth 1 -name "*.meta" -mmin +10 -delete; for m in $PUSHIT_DL_DIR/*.meta; do [ -f "\$m" ] || continue; exp=\$(grep -m1 "^expires=" "\$m" | cut -d= -f2); tok=\$(basename "\$m" .meta); if [ -n "\$exp" ] && [ "\$(date +%s)" -ge "\$exp" ]; then rm -f "$PUSHIT_DL_DIR/\$tok" "\$m"; fi; done'
EOF2
        cat > /etc/systemd/system/pushit-dl-prune.timer <<EOF2
[Unit]
Description=Prune expired pushit downloads every 5 min
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF2
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now pushit-dl.service 2>/dev/null || true
        systemctl restart pushit-dl.service 2>/dev/null || systemctl start pushit-dl.service 2>/dev/null || true
        systemctl enable --now pushit-dl-prune.timer 2>/dev/null || true
        sleep 1
        if command -v ss >/dev/null 2>&1; then
            ss -tlnH 2>/dev/null | grep -q ":${PUSHIT_DL_PORT} " && return 0
        elif command -v netstat >/dev/null 2>&1; then
            netstat -tln 2>/dev/null | grep -q ":${PUSHIT_DL_PORT} " && return 0
        fi
        # fall through to nohup fallback if systemd failed to listen
    fi
    # Fallback: ensure no stale instance, then start via nohup
    if command -v ss >/dev/null 2>&1; then
        if ss -tlnH 2>/dev/null | grep -q ":${PUSHIT_DL_PORT} "; then
            pkill -f "$PUSHIT_DL_SERVER" 2>/dev/null || true
            sleep 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tln 2>/dev/null | grep -q ":${PUSHIT_DL_PORT} "; then
            pkill -f "$PUSHIT_DL_SERVER" 2>/dev/null || true
            sleep 1
        fi
    fi
    nohup python3 "$PUSHIT_DL_SERVER" >> "$PUSHIT_DL_LOG" 2>&1 &
    disown 2>/dev/null || true
    sleep 1
}

pushit_dl_build_url() {
    local token="$1"
    pushit_load_config
    if [ "${PUSHIT_MODE:-}" = "domain" ] && [ -n "${PUSHIT_DOMAIN:-}" ]; then
        if [ -f "/etc/letsencrypt/live/${PUSHIT_DOMAIN}/fullchain.pem" ]; then
            echo "https://${PUSHIT_DOMAIN}:${PUSHIT_DL_PORT}/${token}"
        else
            echo "http://${PUSHIT_DOMAIN}:${PUSHIT_DL_PORT}/${token}"
        fi
    else
        local ip="${PUSHIT_IP:-}"
        [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        [ -z "$ip" ] && ip=$(hostname -i 2>/dev/null | awk '{print $1}')
        [ -z "$ip" ] && ip="SERVER_IP"
        echo "http://${ip}:${PUSHIT_DL_PORT}/${token}"
    fi
}

PUSHIT_APT_BACKUP_DIR="/var/backups/pushit/apt"
_apt_clean_stale_bak() {
    local f
    for f in /etc/apt/sources.list.d/*.bak.* /etc/apt/sources.list.d/*.bak; do
        [ -e "$f" ] || continue
        mkdir -p "$PUSHIT_APT_BACKUP_DIR" 2>/dev/null || true
        mv -f "$f" "$PUSHIT_APT_BACKUP_DIR/" 2>/dev/null || rm -f "$f" 2>/dev/null || true
        echo -e "${YELLOW}Moved stale apt backup $(basename "$f") -> $PUSHIT_APT_BACKUP_DIR/${NC}"
    done 2>/dev/null || true
}
_apply_apt_mirror() {
    local MIRROR_URL="$1"
    local CODENAME
    CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy")
    # Normalize: ensure trailing slash
    [[ "$MIRROR_URL" != */ ]] && MIRROR_URL="${MIRROR_URL}/"
    # Known broken mirrors — warn upfront (manageitcloud currently returns 403 on pool/)
    if [[ "$MIRROR_URL" == *"manageitcloud.com"* ]]; then
        echo -e "${YELLOW}Warning: mirror.manageitcloud.com is currently returning 403 on some packages.${NC}"
        echo -e "${YELLOW}If apt fails, the script will auto-rollback. Recommended: Abrha or Official.${NC}"
    fi
    # Backup existing files (store OUTSIDE sources.list.d to avoid apt warning N: Ignoring file ...)
    local TS
    TS=$(date +%Y%m%d%H%M%S)
    mkdir -p "$PUSHIT_APT_BACKUP_DIR" 2>/dev/null || true
    _apt_clean_stale_bak
    if [ -f /etc/apt/sources.list ]; then
        cp /etc/apt/sources.list "${PUSHIT_APT_BACKUP_DIR}/sources.list.bak.${TS}" 2>/dev/null || true
    fi
    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
        cp /etc/apt/sources.list.d/ubuntu.sources "${PUSHIT_APT_BACKUP_DIR}/ubuntu.sources.bak.${TS}" 2>/dev/null || true
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
            # Comment out classic lines so only ubuntu.sources is active (avoid duplicate)
            sed -i 's|^\(deb\)|# \1|' /etc/apt/sources.list 2>/dev/null || true
        fi
    else
        cat <<EOF > /etc/apt/sources.list
deb ${MIRROR_URL} $CODENAME main restricted universe multiverse
deb ${MIRROR_URL} $CODENAME-updates main restricted universe multiverse
deb ${MIRROR_URL} $CODENAME-security main restricted universe multiverse
EOF
    fi

    echo -e "${YELLOW}Updating package lists from ${MIRROR_URL} ...${NC}"
    local _apt_out
    _apt_out=$(mktemp /tmp/pushit_apt.XXXXXX 2>/dev/null || echo "/tmp/pushit_apt.$$")
    local _apt_rc=0
    if ! apt-get update 2>&1 | tee "$_apt_out"; then _apt_rc=$?; fi
    # apt-get update can return 0 even with Err:403 — detect it via output
    if [ "$_apt_rc" -ne 0 ] || grep -qE "403.*Forbidden|Failed to fetch" "$_apt_out" 2>/dev/null; then
        echo -e "${RED}apt-get update reported errors for ${MIRROR_URL} (403/Failed to fetch). Restoring backup...${NC}"
        cat "$_apt_out" 2>/dev/null | grep -E "403|Failed to fetch" | head -n 5
        # Restore backup if available
        if [ -f "${PUSHIT_APT_BACKUP_DIR}/sources.list.bak.${TS}" ]; then
            cp "${PUSHIT_APT_BACKUP_DIR}/sources.list.bak.${TS}" /etc/apt/sources.list 2>/dev/null || true
        fi
        if [ -f "${PUSHIT_APT_BACKUP_DIR}/ubuntu.sources.bak.${TS}" ]; then
            cp "${PUSHIT_APT_BACKUP_DIR}/ubuntu.sources.bak.${TS}" /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
        fi
        rm -f "$_apt_out" 2>/dev/null || true
        # Clean stale bak that would cause warning on next run
        _apt_clean_stale_bak
        return 1
    fi
    rm -f "$_apt_out" 2>/dev/null || true
    _apt_clean_stale_bak
    echo -e "${GREEN}Mirror updated to ${MIRROR_URL}${NC}"
    return 0
}
pushit_fix_broken_mirror() {
    local cur fallback="http://archive.ubuntu.com/ubuntu/"
    cur=$(_detect_current_mirror 2>/dev/null || echo "")
    echo -e "${YELLOW}Current mirror: ${cur}${NC}"
    # Auto-clean stale bak files first (fixes N: Ignoring file ... warning)
    _apt_clean_stale_bak
    if [[ "$cur" == *"manageitcloud.com"* ]]; then
        echo -e "${YELLOW}Detected broken mirror manageitcloud.com — switching to official...${NC}"
        if _apply_apt_mirror "$fallback"; then
            echo -e "${GREEN}Fixed: now using $fallback${NC}"
            return 0
        fi
        echo -e "${YELLOW}Official mirror also failed, trying Abrha...${NC}"
        _apply_apt_mirror "https://repo.abrha.net/ubuntu/" && return 0
        _apply_apt_mirror "https://mirror.arvancloud.ir/ubuntu/" && return 0
        return 1
    fi
    # Generic: try apt update and if 403 detected, rollback to official
    local _tmp
    _tmp=$(mktemp /tmp/pushit_apt_check.XXXXXX 2>/dev/null || echo "/tmp/pushit_apt_check.$$")
    apt-get update 2>&1 | tee "$_tmp" >/dev/null 2>&1 || true
    if grep -qE "403.*Forbidden|Failed to fetch" "$_tmp" 2>/dev/null; then
        echo -e "${RED}apt is currently failing (403). Switching to official mirror...${NC}"
        rm -f "$_tmp"
        _apply_apt_mirror "$fallback" && return 0
        _apply_apt_mirror "https://repo.abrha.net/ubuntu/" && return 0
        return 1
    fi
    rm -f "$_tmp"
    echo -e "${GREEN}No 403 detected. Mirror seems OK.${NC}"
    return 0
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
        echo -e "2) ManageITCloud    (https://mirror.manageitcloud.com/ubuntu/) ${RED}[BROKEN 403]${NC}"
        echo "3) ArvanCloud       (https://mirror.arvancloud.ir/ubuntu/)"
        echo "4) Official Ubuntu  (http://archive.ubuntu.com/ubuntu/)  ${GREEN}[recommended if 403]${NC}"
        echo "5) Custom URL"
        echo "6) Show current APT sources"
        echo "7) Auto-fix broken mirror (detects 403 -> switch to Official)"
        echo "0) Back"
        read -r -p "Choice: " MIRROR_CHOICE
        case "$MIRROR_CHOICE" in
            1) _apply_apt_mirror "https://repo.abrha.net/ubuntu/" ;;
            2)
                echo -e "${RED}This mirror is currently returning 403 Forbidden on noble-updates/pool.${NC}"
                read -r -p "Try it anyway? (y/N): " _c; if ! [[ "$_c" =~ ^[yY] ]]; then echo "Skipped."; continue; fi
                _apply_apt_mirror "https://mirror.manageitcloud.com/ubuntu/"
                ;;
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
            7) pushit_fix_broken_mirror ;;
            0) break ;;
            *) echo -e "${RED}Invalid choice.${NC}" ;;
        esac
    done
}

pushit_stack_report_add() {
    local state="$1" component="$2" details="$3" color
    case "$state" in
        OK) color="$GREEN"; PUSHIT_STACK_OK_COUNT=$((PUSHIT_STACK_OK_COUNT + 1)) ;;
        WARN) color="$YELLOW"; PUSHIT_STACK_WARN_COUNT=$((PUSHIT_STACK_WARN_COUNT + 1)) ;;
        ERROR) color="$RED"; PUSHIT_STACK_ERROR_COUNT=$((PUSHIT_STACK_ERROR_COUNT + 1)) ;;
        *) color="$NC" ;;
    esac
    printf '  %b[%-5s]%b %-22s %s\n' "$color" "$state" "$NC" "$component" "$details"
}

pushit_stack_active_unit() {
    local unit
    for unit in "$@"; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            printf '%s' "$unit"
            return 0
        fi
    done
    return 1
}

pushit_stack_report_commands() {
    local component="$1" command_name
    shift
    local -a missing=()
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        pushit_stack_report_add OK "$component" "All required commands are available."
    else
        pushit_stack_report_add ERROR "$component" "Missing commands: ${missing[*]}"
    fi
}

pushit_stack_report_install_messages() {
    local install_log="$1" installer_status="$2" line component state
    local warning_lines="" error_lines=""
    if [ -z "$install_log" ] || [ ! -r "$install_log" ]; then
        pushit_stack_report_add WARN "Installer output" "Could not capture the installation output."
        return
    fi
    warning_lines=$(sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' "$install_log" 2>/dev/null \
        | grep -Eai 'SyntaxWarning:|DeprecationWarning:|(^|[[:space:]])W:|(^|[[:space:]])warn([[:space:]:]|$)' \
        | awk 'NF && !seen[$0]++' || true)
    error_lines=$(sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' "$install_log" 2>/dev/null \
        | grep -Eai '(^|[[:space:]])E:|(^|[[:space:]])Err:|dpkg:.*error|(^|[[:space:]])error:|Failed to fetch|failed([[:space:]]+to|[[:space:]]+with|[[:space:]]*$|:[[:space:]]*|[.]([[:space:]]|$))|ERROR([[:space:]:]|$)|npm ERR!|curl: \([0-9]+\)' \
        | awk 'NF && !seen[$0]++' || true)

    if [ -z "$warning_lines" ] && [ -z "$error_lines" ]; then
        pushit_stack_report_add OK "Installer output" "No package warnings or errors were recorded."
        return
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        component="Installer warning"
        [[ "${line,,}" == *fail2ban* ]] && component="Fail2ban warning"
        pushit_stack_report_add WARN "$component" "$line"
    done <<< "$warning_lines"
    state=WARN
    [ "$installer_status" -ne 0 ] && state=ERROR
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        component="Installer diagnostic"
        [[ "${line,,}" == *fail2ban* ]] && component="Fail2ban diagnostic"
        pushit_stack_report_add "$state" "$component" "$line"
    done <<< "$error_lines"
}

pushit_stack_health_report() {
    local install_log="${1:-}" installer_status="${2:-0}"
    local active output version module_result
    local ufw_output ufw_default ssh_ports port
    local -a missing_ports=()

    PUSHIT_STACK_OK_COUNT=0
    PUSHIT_STACK_WARN_COUNT=0
    PUSHIT_STACK_ERROR_COUNT=0
    echo ""
    echo "========== Full Stack Health Report =========="

    pushit_stack_report_commands "Base utilities" lsb_release add-apt-repository curl wget git unzip

    if ! command -v ufw >/dev/null 2>&1; then
        pushit_stack_report_add ERROR "UFW" "Command not found."
    else
        ufw_output=$(LC_ALL=C ufw status verbose 2>&1)
        if ! grep -q '^Status: active' <<< "$ufw_output"; then
            pushit_stack_report_add ERROR "UFW" "Firewall is not active."
        else
            ufw_default=$(sed -n 's/^Default: //p' <<< "$ufw_output" | head -n 1)
            ssh_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" && $2 ~ /^[0-9]+$/ {print $2}' | sort -nu)
            [ -n "$ssh_ports" ] || ssh_ports=$(pushit_ssh_port 2>/dev/null || true)
            for port in 80 443 ${ssh_ports}; do
                grep -Eq "^${port}/tcp[[:space:]]+ALLOW IN([[:space:]]|$)" <<< "$ufw_output" || missing_ports+=("$port/tcp")
            done
            if [[ "$ufw_default" == *"deny (incoming)"* && "$ufw_default" == *"allow (outgoing)"* ]] && [ "${#missing_ports[@]}" -eq 0 ]; then
                pushit_stack_report_add OK "UFW" "Active; incoming denied, outgoing allowed; SSH/HTTP/HTTPS rules found."
            elif [ "${#missing_ports[@]}" -gt 0 ]; then
                pushit_stack_report_add ERROR "UFW" "Required allow rules are missing: ${missing_ports[*]}."
            else
                pushit_stack_report_add ERROR "UFW" "Unexpected firewall defaults: ${ufw_default:-unavailable}."
            fi
        fi
    fi

    output=""
    active=$(pushit_stack_active_unit fail2ban.service fail2ban 2>/dev/null || true)
    if [ -n "$active" ] && command -v fail2ban-client >/dev/null 2>&1 && output=$(fail2ban-client ping 2>&1) && [[ "$output" == *pong* ]]; then
        pushit_stack_report_add OK "Fail2ban" "Service active and client ping succeeded."
    else
        pushit_stack_report_add ERROR "Fail2ban" "Service or client ping failed: ${output:-not active or fail2ban-client missing}."
    fi

    output=""
    active=$(pushit_stack_active_unit supervisor.service supervisor 2>/dev/null || true)
    if [ -n "$active" ] && command -v supervisorctl >/dev/null 2>&1 && output=$(supervisorctl pid 2>&1); then
        pushit_stack_report_add OK "Supervisor" "Service active; supervisor PID $output."
    else
        pushit_stack_report_add ERROR "Supervisor" "Service is inactive or supervisorctl could not connect: ${output:-not active or command missing}."
    fi

    output=""
    active=$(pushit_stack_active_unit redis-server.service redis.service 2>/dev/null || true)
    if [ -n "$active" ] && command -v redis-cli >/dev/null 2>&1 && output=$(redis-cli ping 2>&1) && [ "$output" = "PONG" ]; then
        pushit_stack_report_add OK "Redis" "Service active and local PING returned PONG."
    else
        pushit_stack_report_add ERROR "Redis" "Service or local PING failed: ${output:-not active or redis-cli missing}."
    fi

    output=""
    if ! command -v nginx >/dev/null 2>&1; then
        pushit_stack_report_add ERROR "Nginx" "Command not found."
    else
        if output=$(nginx -t 2>&1); then
            active=$(pushit_stack_active_unit nginx.service nginx 2>/dev/null || true)
            if [ -n "$active" ]; then
                pushit_stack_report_add OK "Nginx" "Configuration test passed; service active."
            else
                pushit_stack_report_add ERROR "Nginx" "Configuration is valid, but the service is not active."
            fi
        else
            pushit_stack_report_add ERROR "Nginx" "Configuration test failed: ${output:-no details}."
        fi
    fi

    if ! command -v php >/dev/null 2>&1; then
        pushit_stack_report_add ERROR "PHP CLI" "Command not found."
        pushit_stack_report_add ERROR "PHP extensions" "Cannot check extensions without PHP CLI."
    else
        version=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || true)
        if [ "$version" = "$PHP_VERSION" ]; then
            pushit_stack_report_add OK "PHP CLI" "Version $version installed."
        else
            pushit_stack_report_add ERROR "PHP CLI" "Expected $PHP_VERSION; found ${version:-unavailable}."
        fi
        if module_result=$(php -r '$required=["mysqli","pdo_mysql","pgsql","pdo_pgsql","redis","xml","mbstring","curl","zip","gd","bcmath"]; $missing=[]; foreach ($required as $name) { if (!extension_loaded($name)) $missing[]=$name; } if ($missing) { echo implode(", ", $missing); exit(1); }' 2>&1); then
            pushit_stack_report_add OK "PHP extensions" "MySQL, PostgreSQL, Redis and requested runtime extensions are loaded."
        else
            pushit_stack_report_add ERROR "PHP extensions" "Missing or unavailable: ${module_result:-could not inspect PHP modules}."
        fi
    fi

    output=""
    active=$(pushit_stack_active_unit "php${PHP_VERSION}-fpm.service" "php${PHP_VERSION}-fpm" 2>/dev/null || true)
    if command -v "php-fpm${PHP_VERSION}" >/dev/null 2>&1 && output=$("php-fpm${PHP_VERSION}" -t 2>&1) && [ -n "$active" ]; then
        pushit_stack_report_add OK "PHP-FPM" "Configuration test passed; service $active is active."
    else
        pushit_stack_report_add ERROR "PHP-FPM" "Configuration test or service failed: ${output:-command missing or service inactive}."
    fi

    active=$(pushit_stack_active_unit mysql.service mysqld.service mysql mysqld 2>/dev/null || true)
    output=""
    if [ -z "$active" ]; then
        pushit_stack_report_add ERROR "MySQL" "MySQL service is not active."
    elif ! command -v mysql >/dev/null 2>&1; then
        pushit_stack_report_add ERROR "MySQL" "mysql client command is not installed."
    elif output=$(mysql -Nse 'SELECT 1' 2>&1) && [ "$(printf '%s' "$output" | tr -d '[:space:]')" = "1" ]; then
        pushit_stack_report_add OK "MySQL" "Service active and local SELECT 1 succeeded."
    else
        pushit_stack_report_add ERROR "MySQL" "Local SQL check failed: ${output:-query returned an unexpected result}."
    fi

    output=""
    if command -v psql >/dev/null 2>&1 && output=$(pushit_pg_psql --dbname=postgres -Atc 'SELECT 1' 2>&1) \
        && [ "$(printf '%s' "$output" | tr -d '[:space:]')" = "1" ]; then
        pushit_stack_report_add OK "PostgreSQL" "Local postgres query succeeded."
    else
        pushit_stack_report_add ERROR "PostgreSQL" "Local postgres query failed: ${output:-psql or local service unavailable}."
    fi

    version=$(node --version 2>/dev/null || true)
    if [[ "$version" == "v${NODE_VERSION}."* ]]; then
        pushit_stack_report_add OK "Node.js" "Version $version installed."
    else
        pushit_stack_report_add ERROR "Node.js" "Expected major $NODE_VERSION; found ${version:-unavailable}."
    fi

    version=$(npm --version 2>/dev/null || true)
    if [ "$version" = "$NPM_VERSION" ]; then
        pushit_stack_report_add OK "npm" "Pinned version $version installed."
    else
        pushit_stack_report_add ERROR "npm" "Expected $NPM_VERSION; found ${version:-unavailable}."
    fi

    output=""
    if command -v composer >/dev/null 2>&1 && output=$(composer --version --no-ansi 2>&1); then
        pushit_stack_report_add OK "Composer" "$output"
    else
        pushit_stack_report_add ERROR "Composer" "${output:-Command not found or version check failed}."
    fi

    output=""
    version=""
    if command -v certbot >/dev/null 2>&1 && version=$(certbot --version 2>&1); then
        if output=$(certbot plugins 2>&1) && grep -qi nginx <<< "$output"; then
            pushit_stack_report_add OK "Certbot" "$version; Nginx plugin available."
        else
            pushit_stack_report_add WARN "Certbot" "$version; Nginx plugin was not detected."
        fi
    else
        pushit_stack_report_add ERROR "Certbot" "${version:-Command not found or version check failed}."
    fi

    pushit_stack_report_install_messages "$install_log" "$installer_status"
    if [ "$installer_status" -ne 0 ]; then
        pushit_stack_report_add ERROR "Full Stack installer" "Installer returned status $installer_status; review the output above."
    fi

    echo "-----------------------------------------------"
    printf 'Result: %d OK, %d warning(s), %d error(s)\n' "$PUSHIT_STACK_OK_COUNT" "$PUSHIT_STACK_WARN_COUNT" "$PUSHIT_STACK_ERROR_COUNT"
    if [ "$PUSHIT_STACK_ERROR_COUNT" -gt 0 ]; then
        echo "Full Stack check completed with errors."
        return 1
    elif [ "$PUSHIT_STACK_WARN_COUNT" -gt 0 ]; then
        echo "Full Stack check completed with warnings."
    else
        echo "All Full Stack checks passed."
    fi
}

_pushit_install_stack_body() {
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
    if ! apt-get install -y ufw; then
        echo -e "${RED}Could not install UFW; stack installation stopped before changing SSH access.${NC}"
        unset DEBIAN_FRONTEND
        return 1
    fi
    if ! pushit_ufw_apply_baseline; then
        echo -e "${RED}Could not establish the firewall baseline. Stack installation stopped before upgrading or installing public services.${NC}"
        unset DEBIAN_FRONTEND
        return 1
    fi
    apt-get upgrade -y

    echo -e "${YELLOW}Installing base packages...${NC}"
    apt-get install -y lsb-release software-properties-common curl wget git unzip fail2ban supervisor redis-server
    
    # PHP (the ondrej/php PPA only supports Ubuntu LTS codenames)
    CODENAME=$(lsb_release -cs)
    case "$CODENAME" in
        focal|jammy|noble)
            add-apt-repository ppa:ondrej/php -y
            apt-get update
            apt-get install -y "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-pgsql" \
                "php${PHP_VERSION}-redis" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-mbstring" \
                "php${PHP_VERSION}-curl" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-gd" "php${PHP_VERSION}-bcmath"
            ;;
        *)
            echo -e "${YELLOW}Codename '$CODENAME' is not supported by the ondrej/php PPA.${NC}"
            echo -e "${YELLOW}Install PHP ${PHP_VERSION} manually, then re-run this option.${NC}"
            ;;
    esac
    
    # Nginx & MySQL (verify — previous 403 mirror left MySQL uninstalled)
    apt-get install -y nginx mysql-server mysql-client || apt-get install -y nginx mysql-server || true
    if ! command -v mysql >/dev/null 2>&1; then
        echo -e "${RED}MySQL still not installed after 'apt-get install mysql-server'. Trying fallback...${NC}"
        apt-get update -qq 2>/dev/null || true
        apt-get install -y mysql-server mysql-client 2>&1 | tail -n 30 || true
    fi
    # Ensure MySQL daemon is enabled & running (otherwise Laravel gets Connection refused)
    if command -v mysql >/dev/null 2>&1; then
        systemctl enable --now mysql 2>/dev/null || systemctl enable --now mysqld 2>/dev/null || systemctl start mysql 2>/dev/null || service mysql start 2>/dev/null || true
        sleep 2
        if ! mysql -e "SELECT 1" >/dev/null 2>&1; then
            echo -e "${YELLOW}Warning: MySQL installed but 'mysql -e SELECT 1' failed.${NC}"
            echo -e "${YELLOW}Check: systemctl status mysql --no-pager | head -n 30 ; journalctl -u mysql -n 30 --no-pager${NC}"
        else
            echo -e "${GREEN}MySQL is up: $(mysql --version 2>/dev/null)${NC}"
        fi
    else
        echo -e "${RED}MySQL client still missing — DB features will not work until installed.${NC}"
        echo -e "${YELLOW}Manual: sudo apt-get update && sudo apt-get install -y mysql-server mysql-client && sudo systemctl enable --now mysql${NC}"
    fi
    
    local postgres_ready=1
    if ! install_postgresql; then
        postgres_ready=0
        echo -e "${YELLOW}PostgreSQL setup failed. Retry from Manage DB -> PostgreSQL -> Install PostgreSQL.${NC}"
    fi

    # Node.js (re-running this option also upgrades an existing Node 20 to the version above)
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
    apt-get install -y nodejs
    if command -v npm >/dev/null 2>&1; then
        echo -e "${YELLOW}Pinning npm to v${NPM_VERSION}...${NC}"
        npm install -g "npm@${NPM_VERSION}" 2>&1 | tail -n 20 || npm install -g "npm@${NPM_VERSION}" --force 2>&1 | tail -n 20 || true
        echo -e "${GREEN}npm version: $(npm --version 2>/dev/null || echo unknown)${NC}"
    else
        echo -e "${YELLOW}npm not found after Node install — skipping pin to ${NPM_VERSION}.${NC}"
    fi
    
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
    if [ "$postgres_ready" -ne 1 ]; then
        echo -e "${YELLOW}Stack installation finished, but PostgreSQL is not ready. Retry its installation from Manage DB.${NC}"
        return 1
    fi
    echo -e "${GREEN}Stack installed successfully.${NC}"
}

install_stack() {
    local install_log="" installer_status report_status
    install_log=$(mktemp /tmp/pushit-fullstack.XXXXXX 2>/dev/null) || install_log=""
    if [ -n "$install_log" ]; then
        _pushit_install_stack_body 2>&1 | tee "$install_log"
        installer_status=${PIPESTATUS[0]}
    else
        _pushit_install_stack_body
        installer_status=$?
    fi
    if pushit_stack_health_report "$install_log" "$installer_status"; then
        report_status=0
    else
        report_status=$?
    fi
    [ -n "$install_log" ] && rm -f "$install_log"
    if [ "$installer_status" -ne 0 ] || [ "$report_status" -ne 0 ]; then return 1; fi
    return 0
}

pushit_render_site_vhost() {
    local DOMAIN="$1" USERNAME="$2" SN_LINE dot_count
    dot_count=$(printf '%s' "$DOMAIN" | tr -cd '.' | wc -c)
    if [ "$dot_count" -ge 2 ]; then
        SN_LINE="server_name ${DOMAIN};"
    else
        SN_LINE="server_name ${DOMAIN} www.${DOMAIN};"
    fi
    cat <<EOF
server {
    listen 80;
    $SN_LINE
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
}

pushit_nginx_diagnostics() {
    systemctl status nginx --no-pager -l 2>&1 || true
    journalctl -u nginx -n 40 --no-pager 2>&1 || true
}

pushit_activate_site_vhost() {
    local domain="$1" username="$2" candidate backup status=0 action
    local available="${PUSHIT_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
    local enabled="${PUSHIT_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
    local vhost="$available/$domain" link="$enabled/$domain"
    if ! [[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ && "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        echo -e "${RED}Invalid site domain or username.${NC}"
        return 1
    fi
    if [ -d "$vhost" ] || [ -d "$link" ]; then
        echo -e "${RED}A directory occupies the site's Nginx configuration path.${NC}"
        return 1
    fi
    mkdir -p "$available" "$enabled" || return 1
    candidate=$(mktemp "$available/.pushit-vhost.XXXXXX") || return 1
    if ! pushit_render_site_vhost "$domain" "$username" > "$candidate" || ! chmod 644 "$candidate"; then
        rm -f "$candidate"
        return 1
    fi
    backup=$(mktemp -d "$available/.pushit-vhost-backup.XXXXXX") || { rm -f "$candidate"; return 1; }
    if [ -e "$vhost" ] || [ -L "$vhost" ]; then
        cp -a "$vhost" "$backup/vhost" || { rm -f "$candidate"; rm -rf "$backup"; return 1; }
    fi
    if [ -e "$link" ] || [ -L "$link" ]; then
        cp -a "$link" "$backup/enabled" || { rm -f "$candidate"; rm -rf "$backup"; return 1; }
    fi
    if ! mv -f "$candidate" "$vhost" || ! ln -sfn "$vhost" "$link"; then
        echo -e "${RED}Could not install the site's Nginx configuration.${NC}"
        status=1
    elif ! nginx -t 2>&1; then
        echo -e "${RED}Nginx configuration test failed. Restoring the previous site configuration.${NC}"
        status=1
    else
        action=reload
        if ! systemctl is-active --quiet nginx; then action=start; fi
        if ! systemctl "$action" nginx; then
            echo -e "${RED}Nginx ${action} failed. Restoring the previous site configuration.${NC}"
            pushit_nginx_diagnostics
            status=1
        fi
    fi
    if [ "$status" -ne 0 ]; then
        # Restore both the original vhost and the enabled/disabled state.
        if ! rm -f "$vhost" "$link"; then
            echo -e "${RED}Rollback failed. Previous configurations are in '${backup}'.${NC}"
            return 1
        fi
        if [ -e "$backup/vhost" ] || [ -L "$backup/vhost" ]; then
            mv "$backup/vhost" "$vhost" || { echo "Restore manually from $backup"; return 1; }
        fi
        if [ -e "$backup/enabled" ] || [ -L "$backup/enabled" ]; then
            mv "$backup/enabled" "$link" || { echo "Restore manually from $backup"; return 1; }
        fi
        rm -f "$candidate"
        rm -rf "$backup"
        # A service action may have failed after partially applying a config.
        if [ "${action:-}" = reload ] && nginx -t >/dev/null 2>&1; then
            systemctl reload nginx || echo -e "${YELLOW}Previous files restored, but reload still failed. Check nginx.service.${NC}"
        fi
        echo -e "${YELLOW}Site files were kept. Run 'sudo nginx -t' and fix any remaining server configuration errors.${NC}"
        return 1
    fi
    rm -rf "$backup"
    return 0
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
            if pushit_is_laravel "/home/$USERNAME/$DOMAIN"; then
                for _d in "/home/$USERNAME/$DOMAIN/storage" "/home/$USERNAME/$DOMAIN/bootstrap/cache" "/home/$USERNAME/$DOMAIN/storage/framework/cache" "/home/$USERNAME/$DOMAIN/storage/framework/sessions" "/home/$USERNAME/$DOMAIN/storage/framework/views" "/home/$USERNAME/$DOMAIN/storage/logs"; do
                    mkdir -p "$_d" 2>/dev/null || true
                done
                # Fix ownership for ALL Laravel-critical paths including parent 'bootstrap' dir
                chown -R "$USERNAME:$USERNAME" \
                    "/home/$USERNAME/$DOMAIN/storage" \
                    "/home/$USERNAME/$DOMAIN/bootstrap" 2>/dev/null || true
                # Set directory permissions to 775 and file permissions to 664
                find "/home/$USERNAME/$DOMAIN/storage" "/home/$USERNAME/$DOMAIN/bootstrap/cache" \
                    -type d -exec chmod 775 {} \; 2>/dev/null || true
                find "/home/$USERNAME/$DOMAIN/storage" "/home/$USERNAME/$DOMAIN/bootstrap/cache" \
                    -type f -exec chmod 664 {} \; 2>/dev/null || true
            fi
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
            if pushit_is_laravel "/home/$USERNAME/$DOMAIN" && [ -f "/home/$USERNAME/$DOMAIN/artisan" ]; then
                mkdir -p "/home/$USERNAME/$DOMAIN/storage" "/home/$USERNAME/$DOMAIN/bootstrap/cache" 2>/dev/null || true
                mkdir -p "/home/$USERNAME/$DOMAIN/storage/framework/cache" "/home/$USERNAME/$DOMAIN/storage/framework/sessions" "/home/$USERNAME/$DOMAIN/storage/framework/views" "/home/$USERNAME/$DOMAIN/storage/logs" 2>/dev/null || true
                # Fix ownership for ALL Laravel-critical paths including parent 'bootstrap' dir
                chown -R "$USERNAME:$USERNAME" \
                    "/home/$USERNAME/$DOMAIN/storage" \
                    "/home/$USERNAME/$DOMAIN/bootstrap" 2>/dev/null || true
                # Set directory permissions to 775 and file permissions to 664
                find "/home/$USERNAME/$DOMAIN/storage" "/home/$USERNAME/$DOMAIN/bootstrap/cache" \
                    -type d -exec chmod 775 {} \; 2>/dev/null || true
                find "/home/$USERNAME/$DOMAIN/storage" "/home/$USERNAME/$DOMAIN/bootstrap/cache" \
                    -type f -exec chmod 664 {} \; 2>/dev/null || true
                if [ -f "/home/$USERNAME/$DOMAIN/.env.example" ] && [ ! -f "/home/$USERNAME/$DOMAIN/.env" ]; then
                    sudo -u "$USERNAME" bash -c "cd '/home/$USERNAME/$DOMAIN' && cp .env.example .env"
                fi
                sudo -u "$USERNAME" bash -c "cd '/home/$USERNAME/$DOMAIN' && php artisan key:generate --force 2>/dev/null || php artisan key:generate"
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

        # Laravel writable dirs — only for Laravel projects (fixes bootstrap/cache error)
        if pushit_is_laravel "/home/$USERNAME/$DOMAIN"; then
            for _d in "/home/$USERNAME/$DOMAIN/storage" "/home/$USERNAME/$DOMAIN/bootstrap/cache" "/home/$USERNAME/$DOMAIN/storage/framework/cache" "/home/$USERNAME/$DOMAIN/storage/framework/sessions" "/home/$USERNAME/$DOMAIN/storage/framework/views" "/home/$USERNAME/$DOMAIN/storage/logs"; do
                mkdir -p "$_d" 2>/dev/null || true
            done
            # Fix ownership for ALL Laravel-critical paths including parent 'bootstrap' dir
            chown -R "$USERNAME:$USERNAME" \
                "/home/$USERNAME/$DOMAIN/storage" \
                "/home/$USERNAME/$DOMAIN/bootstrap" 2>/dev/null || true
            # Set directory permissions to 775 and file permissions to 664
            find "/home/$USERNAME/$DOMAIN/storage" "/home/$USERNAME/$DOMAIN/bootstrap/cache" \
                -type d -exec chmod 775 {} \; 2>/dev/null || true
            find "/home/$USERNAME/$DOMAIN/storage" "/home/$USERNAME/$DOMAIN/bootstrap/cache" \
                -type f -exec chmod 664 {} \; 2>/dev/null || true
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
    if ! systemctl restart "php${PHP_VERSION}-fpm"; then
        echo -e "${RED}PHP-FPM restart failed. Site activation stopped.${NC}"
        systemctl status "php${PHP_VERSION}-fpm" --no-pager -l || true
        return 1
    fi

    if ! pushit_activate_site_vhost "$DOMAIN" "$USERNAME"; then
        echo -e "${RED}Application files are in ${DEPLOY_DIR}, but Nginx activation failed. Fix the reported error before retrying.${NC}"
        return 1
    fi
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
        # Skip nginx config backups
        case "$DN" in *.bak.*) continue ;; esac
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
    rm -f "$BACKUP" 2>/dev/null || true
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
    rm -f "$BACKUP" 2>/dev/null || true
    echo -e "${GREEN}Removed '$RM_DOMAIN' from '$PRIMARY'.${NC}"
    REM=$(grep -h "server_name" "$VHOST_CONF" | sed 's/.*server_name//;s/;//' | tr ' ' '\n' | grep -v '^$' | sort -u | xargs)
    ARGS=""; for d in $REM; do ARGS="$ARGS -d $d"; done
    echo -e "${YELLOW}SSL still contains old domain. To update: certbot --nginx $ARGS --cert-name $PRIMARY${NC}"
}


# Local human accounts created by site deployment (including pre-existing users).
pushit_server_user_records() {
    local uid_min
    uid_min=$(awk '$1 == "UID_MIN" {print $2; exit}' "${PUSHIT_USERS_LOGIN_DEFS:-/etc/login.defs}" 2>/dev/null) || uid_min=""
    [[ "$uid_min" =~ ^[0-9]+$ ]] || uid_min=1000
    awk -F: -v minimum="$uid_min" '$1 != "root" && $3 > 0 && $3 >= minimum && $3 < 65534 && $6 == "/home/" $1 {print}' "${PUSHIT_USERS_PASSWD_FILE:-/etc/passwd}"
}

pushit_server_user_require() {
    local username="$1" record
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        echo -e "${RED}Invalid system username.${NC}" >&2
        return 1
    fi
    record=$(pushit_server_user_records | awk -F: -v name="$username" '$1 == name {print; exit}') || return 1
    if [ -z "$record" ]; then
        echo -e "${RED}User '${username}' is not a local non-system account with home /home/${username}.${NC}" >&2
        return 1
    fi
}

# Normalize Nginx directives so one-line server/location blocks are recognized.
pushit_user_config_lines() {
    awk '{sub(/#.*/, ""); gsub(/[{};]/, "\n"); print}' "$1"
}

pushit_user_site_files() {
    local username="$1" file other base
    local available="${PUSHIT_USERS_NGINX_AVAILABLE:-/etc/nginx/sites-available}"
    local enabled="${PUSHIT_USERS_NGINX_ENABLED:-/etc/nginx/sites-enabled}"
    for file in "$available"/* "$enabled"/*; do
        [ -f "$file" ] || continue
        base=$(basename "$file")
        case "$base" in *.bak.*|*.dpkg-*|*~) continue ;; esac
        other="$available/$base"
        if [[ "$file" == "$enabled/"* ]] && [ -f "$other" ] && [ "$file" -ef "$other" ]; then continue; fi
        # Match complete root prefixes and dedicated FPM sockets; ignore comments.
        if pushit_user_config_lines "$file" | awk -v home="/home/$username" -v socket="-fpm-$username.sock" '
            {sub(/#.*/, ""); gsub(/["\047]/, "")}
            $1 == "root" {path=$2; sub(/;$/, "", path); if (path == home || index(path, home "/") == 1) found=1}
            $1 == "fastcgi_pass" && index($2, socket) > 0 {found=1}
            END {exit !found}
        '; then printf '%s\n' "$file"; fi
    done
}

pushit_show_user_sites() {
    local username="$1" file names found=0 state
    local enabled="${PUSHIT_USERS_NGINX_ENABLED:-/etc/nginx/sites-enabled}"
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        found=1
        names=$(pushit_user_config_lines "$file" | awk '{sub(/#.*/, "")} $1 == "server_name" {sub(/^[[:space:]]*server_name[[:space:]]+/, ""); gsub(/;/, ""); print}' | xargs)
        state=disabled
        if [[ "$file" == "$enabled/"* ]] || [ "$file" -ef "$enabled/$(basename "$file")" ]; then state=enabled; fi
        printf '    - %s | domains: %s | %s\n' "$(basename "$file")" "${names:-(no server_name)}" "$state"
    done < <(pushit_user_site_files "$username")
    if [ "$found" -eq 0 ]; then echo '    - No Nginx sites assigned.'; fi
}

list_server_users() {
    local username _password uid _gid _comment home login_shell found=0
    echo -e "\n--- Server Users & Sites ---"
    while IFS=: read -r username _password uid _gid _comment home login_shell; do
        [ -n "$username" ] || continue
        found=1
        printf '\nUser: %s | UID: %s | Home: %s | Shell: %s\n' "$username" "$uid" "$home" "$login_shell"
        pushit_show_user_sites "$username"
    done < <(pushit_server_user_records)
    if [ "$found" -eq 0 ]; then echo 'No local server users found.'; fi
}

change_server_user_password() {
    local username password confirmation
    read -r -p 'Enter server username (Enter to cancel): ' username || return 1
    [ -n "$username" ] || return 0
    pushit_server_user_require "$username" || return 1
    read -r -sp 'Enter new password: ' password || return 1
    echo ''
    read -r -sp 'Repeat new password: ' confirmation || return 1
    echo ''
    if [ -z "$password" ] || [ "$password" != "$confirmation" ]; then
        echo -e "${RED}Passwords must be nonempty and match. Nothing was changed.${NC}"
        return 1
    fi
    if (set -o pipefail; printf '%s:%s\n' "$username" "$password" | chpasswd); then
        unset password confirmation
        echo -e "${GREEN}Password updated for server user '${username}'.${NC}"
        echo 'SSH password login still follows the existing SSH authentication policy.'
    else
        unset password confirmation
        echo -e "${RED}Password update failed.${NC}"
        return 1
    fi
}

pushit_server_user_delete_require() {
    local username="$1" groups uid duplicates
    pushit_server_user_require "$username" || return 1
    if [ "$username" = "${SUDO_USER:-}" ] || [ "$username" = "${USER:-}" ] || who 2>/dev/null | awk -v name="$username" '$1 == name {found=1} END {exit !found}'; then
        echo -e "${RED}Cannot delete the current session user or a logged-in user.${NC}" >&2
        return 1
    fi
    if ! groups=$(id -nG "$username" 2>/dev/null); then
        echo -e "${RED}Cannot verify the user's groups.${NC}" >&2
        return 1
    fi
    if printf '%s\n' "$groups" | tr ' ' '\n' | grep -Eq '^(sudo|admin|wheel)$'; then
        echo -e "${RED}Administrator accounts cannot be deleted from this menu.${NC}" >&2
        return 1
    fi
    uid=$(awk -F: -v name="$username" '$1 == name {print $3; exit}' "${PUSHIT_USERS_PASSWD_FILE:-/etc/passwd}")
    duplicates=$(awk -F: -v uid="$uid" '$3 == uid {count++} END {print count+0}' "${PUSHIT_USERS_PASSWD_FILE:-/etc/passwd}")
    if [ "$duplicates" -ne 1 ]; then
        echo -e "${RED}Cannot delete an account with a shared UID.${NC}" >&2
        return 1
    fi
}

pushit_user_service_configs() {
    local username="$1" file
    local php_dir="${PUSHIT_USERS_PHP_DIR:-/etc/php}"
    local supervisor_dir="${PUSHIT_USERS_SUPERVISOR_DIR:-/etc/supervisor/conf.d}"
    for file in "$php_dir"/*/fpm/pool.d/*.conf "$supervisor_dir"/*.conf; do
        [ -f "$file" ] || continue
        if awk -F= -v name="$username" '
            {sub(/[;#].*/, ""); key=$1; value=$2; gsub(/[[:space:]]/, "", key); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)}
            key == "user" && value == name {found=1}
            END {exit !found}
        ' "$file"; then printf '%s\n' "$file"; fi
    done
}

pushit_user_config_is_shared() {
    local username="$1" file="$2"
    pushit_user_config_lines "$file" | awk -v home="/home/$username" -v name="$username" '
        {sub(/[;#].*/, ""); gsub(/["\047]/, "")}
        $1 == "root" && index($2, "/home/") == 1 && $2 != home && index($2, home "/") != 1 {shared=1}
        $1 == "fastcgi_pass" && index($2, "-fpm-") > 0 && index($2, "-fpm-" name ".sock") == 0 {shared=1}
        /^[[:space:]]*user[[:space:]]*=/ {value=$0; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/[[:space:]]*$/, "", value); if (value != name) shared=1}
        END {exit !shared}
    '
}

pushit_user_restore_configs() {
    local stage="$1" file index=0 status=0
    shift
    for file in "$@"; do
        rm -f "$file" || status=1
        cp -a "$stage/$index" "$file" || status=1
        index=$((index + 1))
    done
    return "$status"
}

pushit_user_reload_services() {
    local nginx_changed="$1" supervisor_changed="$2" ssh_changed="$3" version
    shift 3
    if [ "$nginx_changed" -eq 1 ]; then
        nginx -t && systemctl reload nginx || return 1
    fi
    for version in "$@"; do
        systemctl restart "php${version}-fpm" || return 1
    done
    if [ "$supervisor_changed" -eq 1 ]; then
        supervisorctl reread && supervisorctl update || return 1
    fi
    if [ "$ssh_changed" -eq 1 ]; then
        systemctl reload ssh || systemctl reload sshd || return 1
    fi
}

delete_server_user() {
    local username confirmation file stage index=0 status=0 version enabled
    local nginx_changed=0 supervisor_changed=0 ssh_changed=0 site_snapshot service_snapshot
    local ssh_config="${PUSHIT_USERS_SSH_CONFIG:-/etc/ssh/sshd_config}"
    local php_dir="${PUSHIT_USERS_PHP_DIR:-/etc/php}"
    local supervisor_dir="${PUSHIT_USERS_SUPERVISOR_DIR:-/etc/supervisor/conf.d}"
    local -a configs=() versions=()
    read -r -p 'Enter server username to DELETE (Enter to cancel): ' username || return 1
    [ -n "$username" ] || return 0
    pushit_server_user_delete_require "$username" || return 1
    if [ -L "/home/$username" ]; then
        echo -e "${RED}Refusing to delete a user with a symlinked home directory.${NC}"
        return 1
    fi
    pushit_show_user_sites "$username"
    site_snapshot=$(pushit_user_site_files "$username") || return 1
    service_snapshot=$(pushit_user_service_configs "$username") || return 1
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        configs+=("$file")
        nginx_changed=1
        # Also remove the corresponding enabled link when the file is available.
        enabled="${PUSHIT_USERS_NGINX_ENABLED:-/etc/nginx/sites-enabled}/$(basename "$file")"
        if [ -L "$enabled" ] && [ "$file" -ef "$enabled" ] && [ "$file" != "$enabled" ]; then configs+=("$enabled"); fi
    done <<< "$site_snapshot"
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        configs+=("$file")
        if [[ "$file" == "$php_dir/"* ]]; then
            version=${file#"$php_dir/"}
            version=${version%%/*}
            [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
            if ! printf '%s\n' ${versions[@]+"${versions[@]}"} | grep -Fxq "$version"; then versions+=("$version"); fi
        elif [[ "$file" == "$supervisor_dir/"* ]]; then
            supervisor_changed=1
        fi
    done <<< "$service_snapshot"
    for file in ${configs[@]+"${configs[@]}"}; do
        if pushit_user_config_is_shared "$username" "$file"; then
            echo -e "${RED}Configuration '${file}' also uses another account. Separate it before deleting this user.${NC}"
            return 1
        fi
    done
    if [ "$nginx_changed" -eq 1 ]; then
        command -v nginx >/dev/null 2>&1 && nginx -t || return 1
    fi
    if [ "$supervisor_changed" -eq 1 ]; then
        command -v supervisorctl >/dev/null 2>&1 || return 1
    fi
    if [ -f "$ssh_config" ] && awk -v name="$username" '$1 == "Match" && $2 == "User" && $3 == name && NF == 3 {found=1} END {exit !found}' "$ssh_config"; then
        ssh_changed=1
        command -v sshd >/dev/null 2>&1 && sshd -t -f "$ssh_config" || return 1
    fi
    echo -e "${YELLOW}DELETE ALL sites above, user '${username}', every file in /home/${username}, its crontab and user processes.${NC}"
    for file in ${configs[@]+"${configs[@]}"}; do printf '  - Remove configuration: %s\n' "$file"; done
    if [ "$ssh_changed" -eq 1 ]; then printf '  - Remove dedicated SSH Match User %s block\n' "$username"; fi
    echo 'SSL certificates and database accounts are managed separately.'
    read -r -p 'Type the username again to confirm deleting the user AND ALL ITS SITES: ' confirmation || return 1
    if [ "$confirmation" != "$username" ]; then
        echo -e "${RED}Confirmation does not match. Nothing was deleted.${NC}"
        return 1
    fi
    pushit_server_user_delete_require "$username" || return 1
    if [ "$site_snapshot" != "$(pushit_user_site_files "$username")" ] || [ "$service_snapshot" != "$(pushit_user_service_configs "$username")" ]; then
        echo -e "${RED}The user's sites/services changed during confirmation. Review the new list and retry.${NC}"
        return 1
    fi
    for file in ${configs[@]+"${configs[@]}"}; do
        if pushit_user_config_is_shared "$username" "$file"; then
            echo -e "${RED}Configuration '${file}' is now shared. Deletion aborted.${NC}"
            return 1
        fi
    done
    # Keep originals for rollback if validation/reload/account deletion fails.
    stage=$(mktemp -d "${TMPDIR:-/tmp}/pushit-user-delete.XXXXXX") || return 1
    for file in ${configs[@]+"${configs[@]}"}; do
        if ! cp -a "$file" "$stage/$index"; then rm -rf "$stage"; return 1; fi
        index=$((index + 1))
    done
    if [ "$ssh_changed" -eq 1 ]; then
        cp -a "$ssh_config" "$stage/sshd_config" || { rm -rf "$stage"; return 1; }
        awk -v name="$username" '
            $1 == "Match" {skip=($2 == "User" && $3 == name && NF == 3)}
            !skip {print}
        ' "$ssh_config" > "$stage/sshd_config.new" || { rm -rf "$stage"; return 1; }
    fi
    crontab -l -u "$username" > "$stage/crontab" 2>/dev/null || true
    anchor_cwd
    for file in ${configs[@]+"${configs[@]}"}; do rm -f "$file" || status=1; done
    if [ "$ssh_changed" -eq 1 ]; then
        cat "$stage/sshd_config.new" > "$ssh_config" && sshd -t -f "$ssh_config" || status=1
    fi
    if [ "$status" -eq 0 ]; then
        pushit_user_reload_services "$nginx_changed" "$supervisor_changed" "$ssh_changed" ${versions[@]+"${versions[@]}"} || status=1
    fi
    if [ "$status" -eq 0 ]; then
        # Stop remaining processes before removing the account.
        if pgrep -u "$username" >/dev/null 2>&1; then
            pkill -TERM -u "$username" 2>/dev/null || status=1
            sleep 1
        fi
        if pgrep -u "$username" >/dev/null 2>&1; then
            echo -e "${RED}User processes are still running. Stop them before retrying.${NC}"
            status=1
        fi
    fi
    if [ "$status" -eq 0 ]; then
        # Remove cron while the account still exists; userdel does not do this reliably.
        crontab -r -u "$username" 2>/dev/null || true
        userdel -r "$username" || status=1
    fi
    if [ "$status" -ne 0 ]; then
        # userdel can report a partially completed deletion. Keep services disabled
        # when the account no longer exists, instead of referencing a missing user.
        if pushit_server_user_require "$username" >/dev/null 2>&1; then
            if [ "$ssh_changed" -eq 1 ]; then cp -a "$stage/sshd_config" "$ssh_config" || true; fi
            if pushit_user_restore_configs "$stage" ${configs[@]+"${configs[@]}"}; then
                pushit_user_reload_services "$nginx_changed" "$supervisor_changed" "$ssh_changed" ${versions[@]+"${versions[@]}"} || true
            fi
            if [ -s "$stage/crontab" ]; then crontab -u "$username" "$stage/crontab" || true; fi
        fi
        echo -e "${RED}Deletion failed or was incomplete. Config backups are in '${stage}'; verify the account/home before retrying.${NC}"
        return 1
    fi
    rm -rf "$stage"
    echo -e "${GREEN}Server user '${username}', its sites and home directory removed.${NC}"
}

manage_server_users() {
    local choice
    while true; do
        echo -e "\n--- Server User Management ---"
        echo '1) List Users & Their Sites'
        echo '2) Change User Password'
        echo '3) Delete User'
        echo '0) Back'
        read -r -p 'Select an option: ' choice || return 0
        case "$choice" in
            1) list_server_users ;;
            2) change_server_user_password ;;
            3) delete_server_user ;;
            0) return 0 ;;
            *) echo -e "${RED}Invalid choice.${NC}" ;;
        esac
    done
}

manage_sites() {
    while true; do
        echo -e "\n--- Site Management ---"
        echo "1) Create Site (Deploy via Git or ZIP)"
        echo "2) Delete Site"
        echo "3) Add Domain to Site"
        echo "4) Remove Domain from Site"
        echo "5) List Sites & Domains"
        echo "6) Manage Server Users"
        echo "0) Back"
        read -r -p "Choice: " SITE_CHOICE
        case $SITE_CHOICE in
            1) deploy_site ;;
            2) delete_site ;;
            3) add_site_domain ;;
            4) remove_site_domain ;;
            5) list_site_domains ;;
            6) manage_server_users ;;
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
    local fw_opt fw_input fw_rule fw_status fw_number fw_confirm fw_source fw_port fw_protocol ssh_ports ssh_port
    if ! command -v ufw >/dev/null 2>&1; then
        echo -e "${RED}UFW is not installed. Run Install Full Stack first.${NC}"
        return 1
    fi
    echo "1) Enable UFW with SSH, HTTP and HTTPS allowed; deny other inbound traffic"
    echo "2) Allow a port (PORT/tcp or PORT/udp; optional source IP/CIDR)"
    echo "3) Deny a port (inserts a blocking rule before existing rules)"
    echo "4) Show UFW status and numbered rules"
    echo "5) Remove a rule by number"
    echo "0) Back"
    read -r -p "Select: " fw_opt
    case "$fw_opt" in
        1) pushit_ufw_apply_baseline ;;
        2|3)
            read -r -p "Port[/tcp|/udp]: " fw_input
            fw_rule=$(pushit_ufw_validate_rule "$fw_input") || {
                echo -e "${RED}Enter a port from 1 to 65535, optionally followed by /tcp or /udp.${NC}"
                return 1
            }
            read -r -p "Limit to source IP/CIDR (Enter = any address): " fw_input
            fw_source=""
            if [ -n "$fw_input" ]; then
                fw_source=$(pushit_ufw_validate_source "$fw_input") || {
                    echo -e "${RED}Enter a valid IPv4/IPv6 address or CIDR network.${NC}"
                    return 1
                }
            fi
            fw_port="${fw_rule%/*}"
            fw_protocol="${fw_rule#*/}"
            ssh_ports=""
            if command -v sshd >/dev/null 2>&1; then ssh_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}'); fi
            if [ "$fw_opt" = 2 ]; then
                if [ -n "$fw_source" ] && [[ "$fw_rule" == */tcp && " $ssh_ports " == *" ${fw_port} "* ]]; then
                    echo -e "${RED}This will restrict SSH to ${fw_source}; a wrong address may lock you out.${NC}"
                    read -r -p "Type RESTRICT to continue: " fw_confirm
                    [ "$fw_confirm" = RESTRICT ] || return 1
                fi
                ufw --force delete deny "$fw_rule" >/dev/null 2>&1 || true
                if [ -n "$fw_source" ]; then
                    ufw --force delete allow from "$fw_source" to any port "$fw_port" proto "$fw_protocol" >/dev/null 2>&1 || true
                    ufw insert 1 deny "$fw_rule" || return 1
                    ufw insert 1 allow from "$fw_source" to any port "$fw_port" proto "$fw_protocol"
                else
                    ufw insert 1 allow "$fw_rule"
                fi
            else
                if [[ "$fw_rule" == */tcp && " $ssh_ports " == *" ${fw_rule%/*} "* ]]; then
                    echo -e "${RED}This is an active SSH port. Closing it may disconnect you.${NC}"
                    read -r -p "Type CLOSE to continue: " fw_input
                    [ "$fw_input" = CLOSE ] || return 1
                fi
                if [ -n "$fw_source" ]; then
                    ufw insert 1 deny from "$fw_source" to any port "$fw_port" proto "$fw_protocol"
                elif ! ufw status 2>/dev/null | awk -v rule="$fw_rule" '$1 == rule && $2 == "DENY" {found=1} END {exit !found}'; then
                    ufw insert 1 deny "$fw_rule"
                fi
            fi
            ;;
        4) ufw status verbose; ufw status numbered ;;
        5)
            fw_status=$(ufw status numbered)
            printf '%s\n' "$fw_status"
            read -r -p "Rule number to remove: " fw_number
            if ! [[ "$fw_number" =~ ^[0-9]+$ ]] || [ "$fw_number" -lt 1 ]; then
                echo -e "${RED}Enter a valid rule number.${NC}"
                return 1
            fi
            fw_rule=$(printf '%s\n' "$fw_status" | awk -v number="$fw_number" '($1 == "[" && $2 == number "]") || $1 == "[" number "]" { $1=""; if ($2 == number "]") $2=""; sub(/^[[:space:]]+/, ""); print; exit }')
            if [ -z "$fw_rule" ]; then
                echo -e "${RED}No rule numbered ${fw_number} was found.${NC}"
                return 1
            fi
            if command -v sshd >/dev/null 2>&1; then
                ssh_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}')
                for ssh_port in $ssh_ports; do
                    if [[ "$fw_rule" == *"${ssh_port}/tcp"* || "$fw_rule" == *OpenSSH* ]]; then
                        echo -e "${RED}This rule may allow SSH. Removing it may disconnect you.${NC}"
                        read -r -p "Type CLOSE to continue: " fw_confirm
                        [ "$fw_confirm" = CLOSE ] || return 1
                        break
                    fi
                done
            fi
            read -r -p "Type DELETE to remove rule ${fw_number}: " fw_confirm
            [ "$fw_confirm" = DELETE ] || return 1
            ufw --force delete "$fw_number"
            ;;
        0) return 0 ;;
        *) echo -e "${RED}Invalid choice.${NC}"; return 1 ;;
    esac
}

pushit_ssh_reload() {
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
}

# Collect active Include files and build candidates without touching SSH yet.
pushit_ssh_prepare_configs() {
    python3 - "$1" "$2" <<'PYSSH'
import glob, json, os, pathlib, re, shlex, shutil, sys
main, backup = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2])
policy = {
    'permitrootlogin': ('PermitRootLogin', 'no'),
    'passwordauthentication': ('PasswordAuthentication', 'no'),
    'kbdinteractiveauthentication': ('KbdInteractiveAuthentication', 'no'),
    'challengeresponseauthentication': ('ChallengeResponseAuthentication', 'no'),
    'pubkeyauthentication': ('PubkeyAuthentication', 'yes'),
    'authenticationmethods': ('AuthenticationMethods', 'publickey'),
}
seen, entries = set(), []
def visit(path):
    path = pathlib.Path(path).resolve()
    if path in seen:
        return
    seen.add(path)
    text = path.read_text()
    index = str(len(entries))
    shutil.copy2(str(path), str(backup / (index + '.original')))
    entries.append({'path': str(path), 'index': index})
    if path == main:
        text = re.sub(r'\A# BEGIN Pushit SSH hardening\n.*?# END Pushit SSH hardening\n\n?', '', text, count=1, flags=re.S)
    lines = []
    for line in text.splitlines(keepends=True):
        normalized = re.sub(r'^(\s*[A-Za-z][A-Za-z0-9]*)\s*=\s*', r'\1 ', line)
        fields = shlex.split(normalized, comments=True)
        if fields and fields[0].lower() == 'include':
            for pattern in fields[1:]:
                if '%' in pattern or '$' in pattern or '~' in pattern:
                    raise ValueError('Unsupported dynamic SSH Include: ' + pattern)
                if not os.path.isabs(pattern):
                    pattern = '/etc/ssh/' + pattern
                for child in sorted(glob.glob(pattern)):
                    visit(child)
        if fields and fields[0].lower() in policy:
            directive, value = policy[fields[0].lower()]
            indent = line[:len(line) - len(line.lstrip())]
            line = indent + directive + ' ' + value + '\n'
        lines.append(line)
    candidate = ''.join(lines)
    if path == main:
        candidate = '# BEGIN Pushit SSH hardening\n' + ''.join(k + ' ' + v + '\n' for k, v in policy.values()) + '# END Pushit SSH hardening\n\n' + candidate
    (backup / (index + '.candidate')).write_text(candidate)
try:
    visit(main)
    (backup / 'manifest.json').write_text(json.dumps(entries))
except Exception as exc:
    print('Cannot prepare SSH configuration: ' + str(exc), file=sys.stderr)
    sys.exit(1)
PYSSH
}

pushit_ssh_copy_configs() {
    python3 - "$1" "$2" <<'PYSSH'
import json, pathlib, shutil, sys
backup, kind = pathlib.Path(sys.argv[1]), sys.argv[2]
for entry in json.loads((backup / 'manifest.json').read_text()):
    # Copy bytes into the existing file to preserve its permissions/ownership.
    shutil.copyfile(str(backup / (entry['index'] + '.' + kind)), entry['path'])
PYSSH
}

pushit_ssh_write_rollback() {
    cat > "$1/rollback.sh" <<'ROLLBACK'
#!/bin/bash
set -eu
backup="$1"
sshd_bin="$2"
config="$3"
exec 9> "$backup/lock"
flock -x 9
[ -f "$backup/pending" ] || exit 0
python3 - "$backup" <<'PYSSH'
import json, pathlib, shutil, sys
backup = pathlib.Path(sys.argv[1])
for entry in json.loads((backup / 'manifest.json').read_text()):
    shutil.copyfile(str(backup / (entry['index'] + '.original')), entry['path'])
PYSSH
"$sshd_bin" -t -f "$config"
systemctl reload ssh || systemctl reload sshd
rm -f "$backup/pending"
touch "$backup/restored"
ROLLBACK
    chmod 700 "$1/rollback.sh"
}

pushit_ssh_confirm_hardening() {
    local backup="$1"
    # Serialize confirmation with the independently running rollback service.
    (
        flock -x 9 || exit 1
        [ -f "$backup/pending" ] || exit 1
        touch "$backup/confirmed" || exit 1
        rm -f "$backup/pending"
    ) 9> "$backup/lock"
}

pushit_ssh_verify_policy() {
    local sshd_bin="$1" config="$2" admin="$3" username output setting
    local address="${SSH_CONNECTION:-}"
    address="${address%% *}"
    address="${address:-127.0.0.1}"
    for username in root "$admin"; do
        output=$("$sshd_bin" -T -f "$config" -C "user=$username,addr=$address,host=$address") || return 1
        for setting in 'permitrootlogin no' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'pubkeyauthentication yes' 'authenticationmethods publickey'; do
            if ! printf '%s\n' "$output" | grep -Fxq "$setting"; then
                echo -e "${RED}Effective SSH policy for '${username}' did not match '${setting}'.${NC}"
                return 1
            fi
        done
    done
}

# The private key is exported once and removed before waiting for confirmation.
pushit_ssh_generate_client_key() (
    local public_file="$1" client_name="$2" admin="$3" key_dir saved
    umask 077
    key_dir=$(mktemp -d "${TMPDIR:-/tmp}/pushit-ssh-key.XXXXXX") || return 1
    trap 'rm -rf -- "$key_dir"' EXIT
    trap 'exit 1' HUP INT TERM
    ssh-keygen -q -t ed25519 -N '' -C "$admin@pushit" -f "$key_dir/private_key" || return 1
    echo ''
    echo 'New SSH key pair. Keep the PRIVATE key secret; only the PUBLIC key is installed on the server.'
    echo 'On your own Mac/Linux computer, copy and run this entire block to save BOTH files:'
    echo '--- BEGIN LOCAL SAVE COMMANDS ---'
    cat <<'KEYSAVE'
(
    umask 077
    mkdir -p "$HOME/.ssh" || exit 1
    chmod 700 "$HOME/.ssh" || exit 1
    set -C # Refuse to overwrite an existing key file.
KEYSAVE
    printf '    cat > "$HOME/.ssh/%s" <<\x27PUSHIT_PRIVATE_KEY\x27 || exit 1\n' "$client_name"
    cat "$key_dir/private_key" || return 1
    echo 'PUSHIT_PRIVATE_KEY'
    printf '    cat > "$HOME/.ssh/%s.pub" <<\x27PUSHIT_PUBLIC_KEY\x27 || exit 1\n' "$client_name"
    cat "$key_dir/private_key.pub" || return 1
    echo 'PUSHIT_PUBLIC_KEY'
    echo ')'
    echo '--- END LOCAL SAVE COMMANDS ---'
    # Do not retain a private key in the administrator's home or config backups.
    rm -f -- "$key_dir/private_key" || return 1
    printf 'Windows: save the PRIVATE key block as %s and the PUBLIC key line as %s.pub in your local .ssh directory (plain text, no BOM).\n' "$client_name" "$client_name"
    echo 'The generated private key has no passphrase. You can add one on your own computer:'
    printf '  ssh-keygen -p -f "$HOME/.ssh/%s"\n' "$client_name"
    read -r -p 'After saving BOTH files on your computer, type SAVED (anything else cancels): ' saved || return 1
    if [ "$saved" != SAVED ]; then
        echo 'Cancelled. SSH policy was not changed.'
        return 1
    fi
    cp "$key_dir/private_key.pub" "$public_file"
)

pushit_ssh_admin_record() {
    local username="$1" record uid home
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || [ "$username" = root ]; then return 1; fi
    record=$(getent passwd "$username") || return 1
    uid=$(printf '%s\n' "$record" | cut -d: -f3)
    home=$(printf '%s\n' "$record" | cut -d: -f6)
    if ! [[ "$uid" =~ ^[0-9]+$ ]] || [ "$uid" -eq 0 ] || [ "$home" != "${PUSHIT_SSH_HOME_ROOT:-/home}/$username" ]; then return 1; fi
    if [ ! -d "$home" ] || [ -L "$home" ] || [ -L "$home/.ssh" ] || [ -L "$home/.ssh/authorized_keys" ]; then return 1; fi
    if ! id -nG "$username" 2>/dev/null | tr ' ' '\n' | grep -Fxq sudo; then return 1; fi
    printf '%s\n' "$record"
}

pushit_harden_server_wizard() {
    local config="${PUSHIT_SSH_CONFIG:-/etc/ssh/sshd_config}"
    local backup_root="${PUSHIT_SSH_BACKUP_DIR:-/var/backups/pushit/ssh}"
    local admin record home group candidate key_choice public_key key_file
    local sshd_bin backup unit confirmation port server_ip command_name pending generated_key_name='' missing=0
    echo -e "\n--- Guided SSH Hardening ---"
    echo 'This wizard uses an existing sudo administrator and prepares public-key login before disabling root/password SSH.'
    admin=''
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && record=$(pushit_ssh_admin_record "$SUDO_USER"); then
        admin="$SUDO_USER"
    else
        while IFS=: read -r candidate _; do
            [ -n "$candidate" ] || continue
            [ "$candidate" != "${SUDO_USER:-}" ] || continue
            if record=$(pushit_ssh_admin_record "$candidate"); then
                admin="$candidate"
                break
            fi
        done < <(getent passwd)
    fi
    if [ -z "$admin" ]; then
        echo -e "${RED}No existing non-root sudo administrator with a usable /home/<user> account was found. Add one and run SSH Hardening again; no changes were made.${NC}"
        return 1
    fi
    echo -e "${GREEN}Using existing sudo administrator '${admin}'.${NC}"
    for command_name in python3 ssh-keygen sshd sudo flock systemd-run; do
        command -v "$command_name" >/dev/null 2>&1 || missing=1
    done
    if [ "$missing" -eq 1 ]; then
        echo -e "${YELLOW}Installing required SSH administration tools...${NC}"
        apt-get update && apt-get install -y openssh-server openssh-client sudo python3 util-linux || return 1
    fi
    sshd_bin=$(command -v sshd) || return 1
    "$sshd_bin" -t -f "$config" || return 1
    # Finish recovery from an interrupted earlier run before preparing new changes.
    for pending in "$backup_root"/hardening.*/pending; do
        [ -f "$pending" ] || continue
        backup=${pending%/pending}
        /bin/bash "$backup/rollback.sh" "$backup" "$sshd_bin" "$config" || return 1
    done
    home=$(printf '%s\n' "$record" | cut -d: -f6)
    group=$(id -gn "$admin") || return 1
    mkdir -p "$backup_root" || return 1
    chmod 700 "$backup_root" || return 1
    backup=$(mktemp -d "$backup_root/hardening.XXXXXX") || return 1
    key_file="$backup/selected_keys"
    while true; do
        echo 'Provide your own public key or let Pushit generate a new key pair:'
        echo "1) Paste your computer's SSH public key"
        echo '2) Generate a new key pair and show BOTH keys for saving on your computer'
        echo '0) Cancel (SSH policy remains unchanged)'
        read -r -p 'Key source [1]: ' key_choice || return 1
        case "${key_choice:-1}" in
            1)
                read -r -p 'Paste PUBLIC key (ssh-ed25519/ssh-rsa/...; never a private key): ' public_key || return 1
                printf '%s\n' "$public_key" > "$key_file"
                ;;
            2)
                generated_key_name="pushit_${admin}_${backup##*.}"
                pushit_ssh_generate_client_key "$key_file" "$generated_key_name" "$admin" || return 1
                ;;
            0) echo 'Cancelled. SSH policy was not changed.'; return 0 ;;
            *) echo 'Invalid choice.'; continue ;;
        esac
        if ssh-keygen -lf "$key_file" 2>/dev/null; then break; fi
        echo -e "${RED}Invalid public key. Paste the complete public-key line or choose another source.${NC}"
    done
    mkdir -p "$home/.ssh" || return 1
    chmod 700 "$home/.ssh" || return 1
    if [ -f "$home/.ssh/authorized_keys" ]; then
        cp -p "$home/.ssh/authorized_keys" "$backup/authorized_keys.before" || return 1
    fi
    # Keep existing keys and append validated input without replacing access.
    touch "$home/.ssh/authorized_keys" || return 1
    chmod 600 "$home/.ssh/authorized_keys" || return 1
    if ! grep -Fqx -f "$key_file" "$home/.ssh/authorized_keys"; then
        { printf '\n'; cat "$key_file"; } >> "$home/.ssh/authorized_keys" || return 1
    fi
    chown "$admin:$group" "$home/.ssh" "$home/.ssh/authorized_keys" || return 1
    chmod go-w "$home" || return 1
    if ! pushit_ssh_prepare_configs "$config" "$backup" || ! pushit_ssh_write_rollback "$backup"; then return 1; fi
    touch "$backup/pending" || return 1
    unit="pushit-ssh-rollback-${backup##*/}"
    if ! systemd-run --unit="$unit" --on-active=5m /bin/bash "$backup/rollback.sh" "$backup" "$sshd_bin" "$config"; then
        rm -f "$backup/pending"
        echo -e "${RED}Could not arm automatic rollback. SSH policy was not changed.${NC}"
        return 1
    fi
    if ! pushit_ssh_copy_configs "$backup" candidate || ! "$sshd_bin" -t -f "$config" || ! pushit_ssh_verify_policy "$sshd_bin" "$config" "$admin" || ! pushit_ssh_reload; then
        echo -e "${RED}Could not activate hardening; restoring the previous SSH configuration.${NC}"
        /bin/bash "$backup/rollback.sh" "$backup" "$sshd_bin" "$config" || echo "Automatic restore failed. Backups: $backup"
        return 1
    fi
    port=$(pushit_ssh_port)
    server_ip=$(printf '%s\n' "${SSH_CONNECTION:-}" | awk '{print $3}')
    if [ -z "$server_ip" ]; then server_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || server_ip=SERVER_IP; fi
    echo -e "${YELLOW}Hardening is temporary until you confirm. Automatic rollback in 5 minutes.${NC}"
    echo 'Keep this terminal open. In a NEW terminal on your computer, run:'
    if [ -n "$generated_key_name" ]; then
        printf '  ssh -i "$HOME/.ssh/%s" -o IdentitiesOnly=yes -p %s -o PreferredAuthentications=publickey -o PasswordAuthentication=no %s@%s\n' "$generated_key_name" "$port" "$admin" "${server_ip:-SERVER_IP}"
    else
        printf '  ssh -p %s -o PreferredAuthentications=publickey -o PasswordAuthentication=no %s@%s\n' "$port" "$admin" "${server_ip:-SERVER_IP}"
    fi
    echo 'After connecting, run: sudo -v'
    # Checking real login requires possession of the private key on the client.
    read -r -t 240 -p 'After BOTH login and sudo succeed, type KEEP to confirm (anything else restores SSH): ' confirmation || confirmation=''
    if [ "$confirmation" = KEEP ] && pushit_ssh_confirm_hardening "$backup"; then
        systemctl stop "$unit.timer" 2>/dev/null || true
        echo -e "${GREEN}SSH hardened: administrator '${admin}', public-key login, root/password SSH disabled.${NC}"
        echo "Configuration backups: $backup"
    else
        /bin/bash "$backup/rollback.sh" "$backup" "$sshd_bin" "$config" || echo "Check rollback service: $unit.service (backups: $backup)"
        echo -e "${YELLOW}Hardening was not confirmed. Previous SSH configuration restored, or restoration is pending in $unit.service. Administrator/key setup was kept.${NC}"
        return 1
    fi
}

harden_server() {
    local lock="${PUSHIT_SSH_LOCK_FILE:-/etc/pushit/ssh-hardening.lock}"
    if ! command -v flock >/dev/null 2>&1; then
        apt-get update && apt-get install -y util-linux || return 1
    fi
    mkdir -p "$(dirname "$lock")" || return 1
    (
        if ! flock -n 8; then
            echo -e "${YELLOW}Another SSH hardening wizard is already running.${NC}"
            exit 1
        fi
        pushit_harden_server_wizard
    ) 8> "$lock"
}

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
        pushit_db_publish_backup "$DUMP_FILE" "$db_name"
    else
        rm -f "$DUMP_FILE"
        echo -e "${RED}Dump failed. No backup file was kept.${NC}"
        return 1
    fi
}

pushit_db_publish_backup() {
    local DUMP_FILE="$1" db_name="$2"
    local SERVER_IP _SSH_PORT
    chmod 600 "$DUMP_FILE"
    local fsize
    fsize=$(du -h "$DUMP_FILE" 2>/dev/null | cut -f1)
    echo -e "${GREEN}Backup created: ${DUMP_FILE} (${fsize})${NC}"
    # --- 10-min download link (reusable until expiry) ---
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${YELLOW}python3 not found — installing for download server...${NC}"
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
        echo -e "${RED}Failed to prepare download link file.${NC}"
        dl_file="$DUMP_FILE"
    fi
    expires=$(( $(date +%s) + 600 ))
    expires_human=$(date -d "@${expires}" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || date -r "$expires" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "in 10 minutes")
    {
        echo "filename=$(basename "$DUMP_FILE")"
        echo "expires=${expires}"
        echo "db=${db_name}"
        echo "size=${fsize:-unknown}"
        echo "created=$(date +%s)"
    } > "$dl_meta" 2>/dev/null || true
    chmod 600 "$dl_meta" 2>/dev/null || true
    # Schedule deletion after 10 min (expiry)
    ( sleep 600; rm -f "$dl_file" "$dl_meta" "$DUMP_FILE" 2>/dev/null ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
    if command -v at >/dev/null 2>&1; then
        echo "rm -f '$dl_file' '$dl_meta' '$DUMP_FILE' 2>/dev/null" | at now + 10 minutes 2>/dev/null || true
    fi
    # Ensure download server is running
    pushit_dl_ensure_server 2>/dev/null || pushit_dl_init_python_server 2>/dev/null || true
    dl_url=$(pushit_dl_build_url "$token" 2>/dev/null)
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN} Download link (valid 10 min, reusable):${NC}"
    echo -e "  ${YELLOW}${dl_url}${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}Browser:${NC} open link above"
    echo -e "  ${YELLOW}curl -O \"${dl_url}\"${NC}"
    echo -e "  ${YELLOW}wget \"${dl_url}\"${NC}"
    echo -e "  Expires: ${expires_human}  |  Size: ${fsize}  |  File: $(basename "$DUMP_FILE")"
    echo -e "  ${RED}Link expires in 10 min — reusable until expiry.${NC}"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        echo -e "  ${YELLOW}Browser link needs ${PUSHIT_DL_PORT}/tcp open in menu 5. Close it after downloading; SCP uses SSH and needs no extra port.${NC}"
    fi
    echo ""
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    _SSH_PORT=$(pushit_ssh_port)
    echo -e "${GREEN}━━━━━━━━ Fallback: scp (if link fails) ━━━━━━━━${NC}"
    echo -e "  ${YELLOW}File on server:${NC} ${DUMP_FILE}"
    if [ "$_SSH_PORT" != "22" ]; then
        echo -e "  ${YELLOW}From your PC:${NC}"
        echo -e "    ${GREEN}scp -P ${_SSH_PORT} root@${SERVER_IP}:${DUMP_FILE} ./  ${YELLOW}← correct${NC}"
        echo -e "  ${RED}Wrong:${NC} scp root@${SERVER_IP}:${_SSH_PORT}/...  ${YELLOW}(port goes with -P, not after :)${NC}"
        echo -e "  ${YELLOW}SSH port is ${_SSH_PORT} (from sshd_config) — always use -P ${_SSH_PORT} for ssh/scp.${NC}"
        echo -e "    ssh -p ${_SSH_PORT} root@${SERVER_IP}  ${YELLOW}(test connection)${NC}"
    else
        echo -e "  ${YELLOW}From your PC:${NC} scp root@${SERVER_IP}:${DUMP_FILE} ./"
    fi
    echo -e "  ${YELLOW}Note: file will be deleted after 10 min.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

upload_database() {
    if ! pushit_db_require; then return 1; fi
    SERVER_IP=$(hostname -I | awk '{print $1}')
    _SSH_PORT=$(pushit_ssh_port)
    if [ "$_SSH_PORT" != "22" ]; then
        echo -e "${YELLOW}Step 1: Upload your backup file to this server with a command like:${NC}"
        echo -e "  ${GREEN}scp -P ${_SSH_PORT} ./backup.sql.gz root@${SERVER_IP}:/root/  ${YELLOW}← correct${NC}"
        echo -e "  ${RED}Wrong:${NC} scp ./backup.sql.gz root@${SERVER_IP}:${_SSH_PORT}/...  ${YELLOW}(port goes with -P)${NC}"
        echo -e "  ${YELLOW}SSH port is ${_SSH_PORT} — always use -P ${_SSH_PORT}${NC}"
    else
        echo -e "${YELLOW}Step 1: Upload your backup file to this server with a command like:${NC}"
        echo "scp ./backup.sql.gz root@${SERVER_IP}:/root/"
    fi
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

manage_mysql_database_menu() {
    while true; do
        echo -e "\n--- MySQL Database Management ---"
        echo "1) Create Database & User"
        echo "2) List Databases"
        echo "3) Delete Database"
        echo "4) Change Database User Password"
        echo "5) Download Database (Backup)"
        echo "6) Upload / Restore Database"
        echo "0) Back to Database Engines"
        read -r -p "Select an option: " db_choice || return 0

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
                    _esc_pass="${db_pass//\'/\'\'}"
                    mysql -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
                    # Fix: create user for both localhost (socket) and 127.0.0.1 (TCP) so Laravel DB_HOST=127.0.0.1 works
                    for _h in localhost "127.0.0.1"; do
                        mysql -e "CREATE USER IF NOT EXISTS '${db_user}'@'$_h' IDENTIFIED WITH mysql_native_password BY '${_esc_pass}';"
                        mysql -e "ALTER USER '${db_user}'@'$_h' IDENTIFIED WITH mysql_native_password BY '${_esc_pass}';"
                        mysql -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'$_h';"
                    done
                    mysql -e "FLUSH PRIVILEGES;"
                    echo -e "\e[32mSuccess: Database '${db_name}' and user '${db_user}' created (localhost + 127.0.0.1).\e[0m"
                    if [[ "$db_pass" == *"#"* || "$db_pass" == *"\$"* || "$db_pass" == *" "* ]]; then
                        echo -e "${YELLOW}Note: your password contains #/\$/space — in Laravel .env wrap it in double quotes:${NC}"
                        echo -e "${YELLOW}  DB_PASSWORD=\"${db_pass}\"${NC}"
                    fi
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
                    _esc_new_pass="${new_pass//\'/\'\'}"
                    for _h in localhost "127.0.0.1"; do
                        mysql -e "ALTER USER '${edit_user}'@'$_h' IDENTIFIED WITH mysql_native_password BY '${_esc_new_pass}';" 2>/dev/null || mysql -e "CREATE USER IF NOT EXISTS '${edit_user}'@'$_h' IDENTIFIED WITH mysql_native_password BY '${_esc_new_pass}';" 2>/dev/null || true
                    done
                    mysql -e "FLUSH PRIVILEGES;"
                    echo -e "\e[32mSuccess: Password updated for user '${edit_user}' (localhost + 127.0.0.1).\e[0m"
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

# PostgreSQL uses the Ubuntu postgres OS account for local peer authentication.
# Explicit connection settings avoid accidentally using a remote PGHOST/service.
pushit_pg_run() {
    local pg_command="$1"
    shift
    local -a runner
    if command -v runuser >/dev/null 2>&1; then
        runner=(runuser -u postgres --)
    elif command -v sudo >/dev/null 2>&1; then
        runner=(sudo -u postgres --)
    else
        echo -e "${RED}runuser or sudo is required to run PostgreSQL tools as postgres.${NC}" >&2
        return 1
    fi
    "${runner[@]}" env -u PGHOST -u PGHOSTADDR -u PGPORT -u PGDATABASE -u PGUSER \
        -u PGPASSWORD -u PGPASSFILE -u PGSERVICE -u PGSERVICEFILE -u PGOPTIONS \
        "$pg_command" --host=/var/run/postgresql --port="${PUSHIT_PG_PORT:-5432}" \
        --username=postgres --no-password "$@"
}

pushit_pg_psql() {
    pushit_pg_run psql -X --set=ON_ERROR_STOP=1 "$@"
}

pushit_pg_require() {
    if ! command -v psql >/dev/null 2>&1; then
        echo -e "${RED}PostgreSQL client 'psql' not found.${NC}"
        echo -e "${YELLOW}Install it from Manage DB -> PostgreSQL -> 7) Install PostgreSQL.${NC}"
        return 1
    fi
    # The umbrella service can be active (exited) while the cluster is down.
    if ! pushit_pg_psql --dbname=postgres -Atc 'SELECT 1' >/dev/null 2>&1; then
        echo -e "${YELLOW}PostgreSQL is not reachable - trying to start the service...${NC}"
        systemctl enable --now postgresql 2>/dev/null || service postgresql start 2>/dev/null || true
        sleep 2
    fi
    if ! pushit_pg_psql --dbname=postgres -Atc 'SELECT 1' >/dev/null 2>&1; then
        echo -e "${RED}Cannot connect to local PostgreSQL as postgres.${NC}"
        echo -e "${YELLOW}Check: pg_lsclusters ; systemctl status postgresql --no-pager${NC}"
        echo -e "${YELLOW}Try: sudo -u postgres psql -h /var/run/postgresql -p ${PUSHIT_PG_PORT:-5432} -d postgres -c 'SELECT 1'${NC}"
        return 1
    fi
}

install_postgresql() {
    local -a packages=(postgresql postgresql-client)
    if command -v php >/dev/null 2>&1; then
        packages+=("php${PHP_VERSION}-pgsql")
    fi
    echo -e "${YELLOW}Installing PostgreSQL and its client tools...${NC}"
    if ! apt-get update || ! apt-get install -y "${packages[@]}"; then
        echo -e "${RED}PostgreSQL package installation failed. Check APT mirrors and retry.${NC}"
        return 1
    fi
    systemctl enable --now postgresql 2>/dev/null || service postgresql start 2>/dev/null || true
    if ! pushit_pg_require; then return 1; fi
    if command -v php >/dev/null 2>&1; then
        if systemctl is-active --quiet "php${PHP_VERSION}-fpm" 2>/dev/null; then
            systemctl restart "php${PHP_VERSION}-fpm" || return 1
        fi
    fi
    echo -e "${GREEN}PostgreSQL is ready: $(psql --version)${NC}"
}

pushit_pg_valid_name() {
    [[ "$1" =~ ^[A-Za-z0-9_]+$ && ${#1} -le 63 ]]
}

pushit_pg_app_database() {
    pushit_pg_valid_name "$1" || return 1
    case "$1" in postgres|template0|template1) return 1 ;; esac
}

pushit_pg_app_role() {
    pushit_pg_valid_name "$1" || return 1
    case "$1" in postgres|pg_*) return 1 ;; esac
}

pushit_pg_database_exists() {
    pushit_pg_app_database "$1" || return 1
    pushit_pg_psql --dbname=postgres -Atc "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = '$1');"
}

pushit_pg_role_exists() {
    pushit_pg_valid_name "$1" || return 1
    pushit_pg_psql --dbname=postgres -Atc "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$1');"
}

list_postgresql_databases() {
    pushit_pg_psql --dbname=postgres -c "SELECT datname AS database, pg_get_userbyid(datdba) AS owner FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY datname;"
}

# Passwords go through stdin, never through process arguments or printed output.
pushit_pg_save_password() {
    local db_user="$1" db_pass="$2" exists escaped_pass
    pushit_pg_app_role "$db_user" && [ -n "$db_pass" ] || return 1
    if ! exists=$(pushit_pg_role_exists "$db_user"); then return 1; fi
    escaped_pass=$(printf '%s' "$db_pass" | sed "s/'/''/g")
    if [ "$exists" = t ]; then
        pushit_pg_psql --dbname=postgres <<SQL
SET standard_conforming_strings = on;
ALTER ROLE "$db_user" WITH LOGIN PASSWORD '$escaped_pass';
SQL
    else
        pushit_pg_psql --dbname=postgres <<SQL
SET standard_conforming_strings = on;
CREATE ROLE "$db_user" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '$escaped_pass';
SQL
    fi
}

create_postgresql_database() {
    pushit_pg_require || return 1
    local db_name db_user db_pass exists
    read -r -p "Enter Database Name: " db_name
    read -r -p "Enter Database User: " db_user
    read -r -sp "Enter Database Password: " db_pass
    echo ""
    if ! pushit_pg_app_database "$db_name" || ! pushit_pg_app_role "$db_user" || [ -z "$db_pass" ]; then
        echo -e "${RED}Use letters, digits and underscores (max 63 characters), a nonempty password, and no reserved database/user names.${NC}"
        return 1
    fi
    if ! exists=$(pushit_pg_database_exists "$db_name"); then return 1; fi
    if ! pushit_pg_save_password "$db_user" "$db_pass"; then
        echo -e "${RED}Failed to create or update PostgreSQL user.${NC}"
        return 1
    fi
    unset db_pass
    if [ "$exists" = f ]; then
        if ! pushit_pg_psql --dbname=postgres <<SQL
CREATE DATABASE "$db_name" OWNER "$db_user" ENCODING 'UTF8' TEMPLATE template0;
SQL
        then return 1; fi
    else
        if ! pushit_pg_psql --dbname=postgres <<SQL
ALTER DATABASE "$db_name" OWNER TO "$db_user";
SQL
        then return 1; fi
    fi
    # Database ownership alone does not grant access to existing tables/sequences.
    if ! pushit_pg_psql --dbname="$db_name" <<SQL
GRANT ALL PRIVILEGES ON DATABASE "$db_name" TO "$db_user";
GRANT USAGE, CREATE ON SCHEMA public TO "$db_user";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "$db_user";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "$db_user";
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO "$db_user";
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO "$db_user";
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO "$db_user";
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL PRIVILEGES ON FUNCTIONS TO "$db_user";
SQL
    then return 1; fi
    echo -e "${GREEN}Success: Database '${db_name}' and user '${db_user}' are ready.${NC}"
    printf 'Laravel .env: DB_CONNECTION=pgsql, DB_HOST=127.0.0.1, DB_PORT=%s, DB_DATABASE=%s, DB_USERNAME=%s\n' "${PUSHIT_PG_PORT:-5432}" "$db_name" "$db_user"
    echo 'Set DB_PASSWORD in your .env; quote/escape special characters as needed.'
}

delete_postgresql_database() {
    pushit_pg_require || return 1
    list_postgresql_databases || return 1
    local db_name confirmation
    read -r -p "Enter Database Name to DELETE (or press Enter to cancel): " db_name
    [ -n "$db_name" ] || return 0
    if ! pushit_pg_app_database "$db_name"; then
        echo -e "${RED}Invalid or reserved database name.${NC}"
        return 1
    fi
    read -r -p "Type the database name again to confirm: " confirmation
    if [ "$confirmation" != "$db_name" ]; then
        echo -e "${RED}Confirmation does not match. Aborted.${NC}"
        return 1
    fi
    if pushit_pg_psql --dbname=postgres <<SQL
DROP DATABASE IF EXISTS "$db_name";
SQL
    then
        echo -e "${GREEN}Success: Database '${db_name}' deleted.${NC}"
    else
        echo -e "${RED}Delete failed. Check for active connections to '${db_name}'.${NC}"
        return 1
    fi
}

change_postgresql_password() {
    pushit_pg_require || return 1
    local db_user db_pass
    read -r -p "Enter Database User to edit: " db_user
    read -r -sp "Enter New Password: " db_pass
    echo ""
    if pushit_pg_save_password "$db_user" "$db_pass"; then
        echo -e "${GREEN}Success: Password updated for user '${db_user}'.${NC}"
    else
        echo -e "${RED}Password update failed. Check the user name and use a nonempty password.${NC}"
        return 1
    fi
}

download_postgresql_database() {
    pushit_pg_require || return 1
    if ! command -v pg_dump >/dev/null 2>&1; then
        echo -e "${RED}pg_dump not found. Install postgresql-client first.${NC}"
        return 1
    fi
    list_postgresql_databases || return 1
    local db_name exists backup_dir dump_file
    read -r -p "Enter Database Name to download: " db_name
    if ! pushit_pg_app_database "$db_name"; then
        echo -e "${RED}Invalid or reserved database name.${NC}"
        return 1
    fi
    if ! exists=$(pushit_pg_database_exists "$db_name"); then return 1; fi
    if [ "$exists" != t ]; then
        echo -e "${RED}Database '${db_name}' not found.${NC}"
        return 1
    fi
    backup_dir="${PUSHIT_DB_BACKUP_DIR:-/root/db-backups}/postgresql"
    mkdir -p "$backup_dir" || return 1
    dump_file=$(mktemp "${backup_dir}/${db_name}_$(date +%Y%m%d_%H%M%S)_XXXXXX") || return 1
    if ! mv "$dump_file" "${dump_file}.sql.gz"; then rm -f "$dump_file"; return 1; fi
    dump_file="${dump_file}.sql.gz"
    echo -e "${YELLOW}Dumping PostgreSQL database '${db_name}'...${NC}"
    # Portable SQL: the destination owner supplies object ownership and grants.
    if (set -o pipefail; pushit_pg_run pg_dump --dbname="$db_name" --format=plain --no-owner --no-acl | gzip > "$dump_file"); then
        pushit_db_publish_backup "$dump_file" "$db_name"
    else
        rm -f "$dump_file"
        echo -e "${RED}Dump failed. No backup file was kept.${NC}"
        return 1
    fi
}

upload_postgresql_database() {
    pushit_pg_require || return 1
    local sql_file db_name exists db_owner role_exists table_count server_ip ssh_port
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || server_ip=""
    ssh_port=$(pushit_ssh_port)
    printf 'Upload your PostgreSQL dump: scp -P %s ./backup.sql.gz root@%s:/root/\n' "$ssh_port" "${server_ip:-SERVER_IP}"
    read -r -p "Enter path of the PostgreSQL .sql or .sql.gz file on this server: " sql_file
    if [ ! -f "$sql_file" ]; then
        echo -e "${RED}File not found: '${sql_file}'${NC}"
        return 1
    fi
    case "$sql_file" in
        *.sql.gz) gzip -t "$sql_file" || return 1 ;;
        *.sql) ;;
        *) echo -e "${RED}Use a PostgreSQL plain SQL dump (.sql or .sql.gz).${NC}"; return 1 ;;
    esac
    read -r -p "Enter target Database Name: " db_name
    if ! pushit_pg_app_database "$db_name"; then
        echo -e "${RED}Invalid or reserved database name.${NC}"
        return 1
    fi
    if ! exists=$(pushit_pg_database_exists "$db_name"); then return 1; fi
    if [ "$exists" = f ]; then
        local create_answer
        read -r -p "Database '${db_name}' does not exist. Create it now? (y/n): " create_answer
        [[ "$create_answer" =~ ^[yY] ]] || return 1
        read -r -p "Enter existing Database User to own the new database: " db_owner
        if ! pushit_pg_app_role "$db_owner"; then
            echo -e "${RED}Invalid or reserved database user. Create it with option 1 first.${NC}"
            return 1
        fi
        if ! role_exists=$(pushit_pg_role_exists "$db_owner"); then return 1; fi
        if [ "$role_exists" != t ]; then
            echo -e "${RED}User not found. Create it with option 1 first.${NC}"
            return 1
        fi
        if ! pushit_pg_psql --dbname=postgres <<SQL
CREATE DATABASE "$db_name" OWNER "$db_owner" ENCODING 'UTF8' TEMPLATE template0;
SQL
        then return 1; fi
    else
        if ! db_owner=$(pushit_pg_psql --dbname=postgres -Atc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$db_name';"); then return 1; fi
    fi
    # Restore as the target database owner so app users can run future migrations.
    # Quote even externally created role names; never interpolate unquoted SQL.
    local quoted_owner
    quoted_owner=$(printf '%s' "$db_owner" | sed 's/"/""/g')
    echo -e "${YELLOW}Restoring '${sql_file}' into '${db_name}'...${NC}"
    if (set -o pipefail
        {
            printf 'SET ROLE "%s";\n' "$quoted_owner"
            case "$sql_file" in
                *.sql.gz) gunzip -c "$sql_file" ;;
                *) cat "$sql_file" ;;
            esac
        } | pushit_pg_psql --dbname="$db_name" --single-transaction
    ); then
        if ! table_count=$(pushit_pg_psql --dbname="$db_name" -Atc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema') AND table_type = 'BASE TABLE';"); then return 1; fi
        echo -e "${GREEN}Success: '${db_name}' restored; ${table_count} table(s).${NC}"
    else
        echo -e "${RED}Restore failed. Check the dump and target database.${NC}"
        return 1
    fi
}

manage_postgresql_database_menu() {
    local db_choice
    while true; do
        echo -e "\n--- PostgreSQL Database Management ---"
        echo '1) Create Database & User'
        echo '2) List Databases'
        echo '3) Delete Database'
        echo '4) Change Database User Password'
        echo '5) Download Database (Backup)'
        echo '6) Upload / Restore Database'
        echo '7) Install PostgreSQL (including PHP driver if PHP is installed)'
        echo '0) Back to Database Engines'
        read -r -p 'Select an option: ' db_choice || return 0
        case "$db_choice" in
            1) create_postgresql_database ;;
            2) pushit_pg_require && list_postgresql_databases ;;
            3) delete_postgresql_database ;;
            4) change_postgresql_password ;;
            5) download_postgresql_database ;;
            6) upload_postgresql_database ;;
            7) install_postgresql ;;
            0) return 0 ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
    done
}

manage_database_menu() {
    local engine_choice
    while true; do
        echo -e "\n--- Database Engines ---"
        echo '1) MySQL'
        echo '2) PostgreSQL'
        echo '0) Back to Main Menu'
        read -r -p 'Select a database engine: ' engine_choice || return 0
        case "$engine_choice" in
            1) manage_mysql_database_menu ;;
            2) manage_postgresql_database_menu ;;
            0) return 0 ;;
            *) echo -e "${RED}Invalid choice.${NC}" ;;
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
                if [ -z "$C_USER" ]; then
                    echo -e "${RED}Username cannot be empty.${NC}"
                    continue
                fi
                if ! id "$C_USER" >/dev/null 2>&1; then
                    echo -e "${RED}User '$C_USER' does not exist.${NC}"
                    continue
                fi
                crontab -u "$C_USER" -l 2>/dev/null || echo "No crontab for $C_USER"
                ;;
            2)
                read -r -p "Enter username to run cron as: " C_USER
                if [ -z "$C_USER" ]; then
                    echo -e "${RED}Username cannot be empty.${NC}"; continue
                fi
                if ! id "$C_USER" >/dev/null 2>&1; then
                    echo -e "${RED}User '$C_USER' does not exist.${NC}"
                    continue
                fi
                echo -e "\e[33mExample Schedule:\e[0m * * * * * (Every minute)"
                read -r -p "Enter schedule expression: " C_SCHED
                echo -e "\e[33mExample Command:\e[0m cd /home/user && php artisan schedule:run >> /dev/null 2>&1"
                read -r -p "Enter command: " C_CMD

                # Use temp file instead of pipe — more reliable when no crontab exists
                _cron_tmp=$(mktemp)
                crontab -u "$C_USER" -l > "$_cron_tmp" 2>/dev/null || true
                printf '%s\n' "$C_SCHED $C_CMD" >> "$_cron_tmp"
                if crontab -u "$C_USER" "$_cron_tmp"; then
                    echo -e "\e[32mJob added successfully.${NC}"
                else
                    echo -e "\e[31mFailed to add cron job.${NC}"
                fi
                rm -f "$_cron_tmp"
                ;;
            3)
                read -r -p "Enter username to manage: " C_USER
                if [ -z "$C_USER" ]; then
                    echo -e "${RED}Username cannot be empty.${NC}"
                    continue
                fi
                if ! id "$C_USER" >/dev/null 2>&1; then
                    echo -e "${RED}User '$C_USER' does not exist.${NC}"
                    continue
                fi
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
    local _resolv_target; _resolv_target=$(readlink -f /etc/resolv.conf 2>/dev/null || echo "not symlink")
    echo -e "${YELLOW}/etc/resolv.conf -> ${_resolv_target}${NC}"
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
    pushit_update_check
    pushit_show_update_notice
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
    echo "2) Install Full Stack (Nginx, PHP ${PHP_VERSION}, MySQL, PostgreSQL, Redis, Node)"
    echo "3) Manage Sites (Deploy / Delete)"
    echo "4) Install SSL (Certbot)"
    echo "5) Manage Firewall (UFW)"
    echo "6) Harden Server (SSH)"
    echo "7) Manage DB (MySQL / PostgreSQL)"
    echo "8) Manage Cron"
    echo "9) Manage Supervisor"
    echo "10) Manage DNS (/etc/resolv.conf)"
    echo "11) Change Access Mode (IP:port / Domain)"
    if [ "${PUSHIT_HAS_UPDATE:-0}" = "1" ]; then
        echo -e "${YELLOW}12) ★ Update Script (v${PUSHIT_VERSION} → v${PUSHIT_REMOTE_VER}) [press 'u']${NC}"
    else
        echo "12) Update Script (from GitHub)"
    fi
    echo "13) Manage Server Users (List / Password / Delete)"
    echo -e "${RED}14) Uninstall Pushit (remove script & cache)${NC}"
    read -r -p "Option [u=update]: " OPT
    # Shortcut: 'u' / 'U' triggers update when available, or anyway
    if [[ "$OPT" =~ ^[uU]$ ]]; then OPT="12"; fi
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
        13) manage_server_users ;;
        14) pushit_uninstall ;;
        *) echo "Invalid option." ;;
    esac
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    check_root
    pushit_ensure_bootstrap
    while true; do
        show_menu
    done
fi
