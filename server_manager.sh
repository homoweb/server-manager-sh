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
PUSHIT_VERSION="0.1.17"
PUSHIT_REPO="homoweb/server-manager-sh"
PUSHIT_REMOTE_URL="https://raw.githubusercontent.com/${PUSHIT_REPO}/main/server_manager.sh"
PUSHIT_UPDATE_TTL=21600
PUSHIT_UPDATE_CACHE_DIR="/var/cache/pushit"
PUSHIT_UPDATE_CACHE_FILE="${PUSHIT_UPDATE_CACHE_DIR}/update.json"
PUSHIT_DL_DIR="/var/lib/pushit/downloads"
PUSHIT_DL_PORT="8787"
PUSHIT_DL_SERVER="/usr/local/bin/pushit-dl-server.py"
PUSHIT_DL_LOG="/var/log/pushit-dl.log"

# --- AI Agent paths ---
PUSHIT_AI_DIR="/etc/pushit/ai"
PUSHIT_AI_SERVER_CONF="${PUSHIT_AI_DIR}/server.json"
PUSHIT_AI_BIN="/usr/local/bin/pushit-ai-agent"
PUSHIT_AI_LOG_DIR="/var/log/pushit-ai"
PUSHIT_AI_DEFAULT_PROVIDER="9router"
PUSHIT_AI_DEFAULT_MODEL="gpt-5-codex"

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
    if command -v ufw >/dev/null 2>&1; then ufw delete allow "${PUSHIT_DL_PORT}/tcp" 2>/dev/null || true; fi
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
    # Always ensure firewall is open
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${PUSHIT_DL_PORT}/tcp" >/dev/null 2>&1 || true
    fi
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

install_stack() {
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
    copy_ai_source_files
    echo -e "${GREEN}Stack installed successfully.${NC}"
}

# ── Copy AI Agent source to /etc/pushit/ai/ (bundled) ─────────────────────
copy_ai_source_files() {
    if [ ! -d "$PUSHIT_AI_DIR" ]; then
        mkdir -p "$PUSHIT_AI_DIR/templates" || {
            echo -e "${RED}Cannot create $PUSHIT_AI_DIR. Run with sudo.${NC}"
            return 1
        }
    fi
    if [ ! -f "$PUSHIT_AI_DIR/pushit-ai-agent.py" ]; then
        python3 << 'PYEOF'
import base64, os
d = 'IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJwdXNoaXQtYWktYWdlbnQg4oCUIENMSSAmIEhUVFAgYWdlbnQgZm9yIFB1c2hpdCBBSSAoT3BlbkFJLWNvbXBhdGlibGUgQVBJKSIiIgppbXBvcnQgb3MsIHN5cywganNvbiwgdXJsbGliLnJlcXVlc3QsIHVybGxpYi5lcnJvciwgYXJncGFyc2UsIHRleHR3cmFwCmZyb20gZGF0ZXRpbWUgaW1wb3J0IGRhdGV0aW1lCmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAoKQUlfRElSICAgICAgPSAiL2V0Yy9wdXNoaXQvYWkiClNFUlZFUl9DT05GID0gZiJ7QUlfRElSfS9zZXJ2ZXIuanNvbiIKCmRlZiBsb2FkX2NvbmYocGF0aCk6CiAgICB0cnk6CiAgICAgICAgd2l0aCBvcGVuKHBhdGgpIGFzIGY6IHJldHVybiBqc29uLmxvYWQoZikKICAgIGV4Y2VwdCBFeGNlcHRpb246IHJldHVybiB7fQoKZGVmIGxvYWRfcHJvamVjdF9jb25mKHByb2plY3RfcGF0aCk6CiAgICBpZiBwcm9qZWN0X3BhdGggYW5kIG9zLnBhdGguaXNmaWxlKGYie3Byb2plY3RfcGF0aH0vLnB1c2hpdC9haS9jb25maWcuanNvbiIpOgogICAgICAgIHJldHVybiBsb2FkX2NvbmYoZiJ7cHJvamVjdF9wYXRofS8ucHVzaGl0L2FpL2NvbmZpZy5qc29uIiksIGYie3Byb2plY3RfcGF0aH0vLnB1c2hpdC9haS9jb25maWcuanNvbiIKICAgIGlmIG9zLnBhdGguaXNmaWxlKFNFUlZFUl9DT05GKTogcmV0dXJuIGxvYWRfY29uZihTRVJWRVJfQ09ORiksIFNFUlZFUl9DT05GCiAgICByZXR1cm4gTm9uZSwgTm9uZQoKZGVmIGdhdGhlcl9jb250ZXh0KHByb2plY3RfcGF0aCwgbWF4X2ZpbGVzPTgpOgogICAgY3R4ID0geyJmaWxlcyI6IFtdLCAic3RydWN0dXJlIjogW119CiAgICByb290ID0gUGF0aChwcm9qZWN0X3BhdGgpCiAgICBpZiBub3Qgcm9vdC5pc19kaXIoKTogcmV0dXJuIGN0eAogICAgZm9yIHAgaW4gc29ydGVkKHJvb3QuaXRlcmRpcigpKToKICAgICAgICBpZiBwLm5hbWUuc3RhcnRzd2l0aCgiLiIpIG9yIHAubmFtZSBpbiAoInZlbmRvciIsICJub2RlX21vZHVsZXMiKTogY29udGludWUKICAgICAgICBjdHhbInN0cnVjdHVyZSJdLmFwcGVuZChzdHIocC5yZWxhdGl2ZV90byhyb290KSkgKyAoIi8iIGlmIHAuaXNfZGlyKCkgZWxzZSAiIikpCiAgICBmb3IgcGF0IGluIFsiUkVBRE1FLm1kIiwicGFja2FnZS5qc29uIiwiY29tcG9zZXIuanNvbiIsIi5lbnYuZXhhbXBsZSIsCiAgICAgICAgICAgICAgICAicm91dGVzL3dlYi5waHAiLCJyb3V0ZXMvYXBpLnBocCIsImJvb3RzdHJhcC9hcHAucGhwIiwKICAgICAgICAgICAgICAgICJ2aXRlLmNvbmZpZy5qcyIsIkRvY2tlcmZpbGUiXToKICAgICAgICBmdWxsID0gcm9vdCAvIHBhdAogICAgICAgIGlmIGZ1bGwuZXhpc3RzKCk6CiAgICAgICAgICAgIHRyeTogY3R4WyJmaWxlcyJdLmFwcGVuZCh7InBhdGgiOiBwYXQsICJjb250ZW50IjogZnVsbC5yZWFkX3RleHQoZXJyb3JzPSJpZ25vcmUiKVs6MjUwMF19KQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uOiBwYXNzCiAgICAgICAgaWYgbGVuKGN0eFsiZmlsZXMiXSkgPj0gbWF4X2ZpbGVzOiBicmVhawogICAgcmV0dXJuIGN0eAoKZGVmIGJ1aWxkX3N5c3RlbV9wcm9tcHQocHJvamVjdF9wYXRoLCB1c2VybmFtZSk6CiAgICBsaW5lcyA9IFsiWW91IGFyZSBhIGhlbHBmdWwgQUkgYXNzaXN0YW50IGludGVncmF0ZWQgaW50byB0aGUgUHVzaGl0IHNlcnZlciBtYW5hZ2VyLiIsCiAgICAgICAgICAgICAiWW91IGhlbHAgZGV2ZWxvcGVycyBidWlsZCwgZGVidWcsIGFuZCBtYWludGFpbiB0aGVpciBwcm9qZWN0cy4iLCAiIl0KICAgIGlmIHByb2plY3RfcGF0aDoKICAgICAgICBjdHggPSBnYXRoZXJfY29udGV4dChwcm9qZWN0X3BhdGgpCiAgICAgICAgaWYgY3R4WyJmaWxlcyJdOgogICAgICAgICAgICBsaW5lcy5hcHBlbmQoIiMjIFByb2plY3QgQ29udGV4dCIpCiAgICAgICAgICAgIGZvciBmIGluIGN0eFsiZmlsZXMiXToKICAgICAgICAgICAgICAgIGxpbmVzLmFwcGVuZChmIlxuIyMjIHtmWydwYXRoJ119XG5gYGBcbntmWydjb250ZW50J119XG5gYGAiKQogICAgICAgIGlmIGN0eFsic3RydWN0dXJlIl06CiAgICAgICAgICAgIGxpbmVzLmFwcGVuZCgiXG4jIyBQcm9qZWN0IFN0cnVjdHVyZSAodG9wLWxldmVsKSIpCiAgICAgICAgICAgIGZvciBzIGluIGN0eFsic3RydWN0dXJlIl1bOjI1XTogbGluZXMuYXBwZW5kKGYiICB7c30iKQogICAgbGluZXMuYXBwZW5kKCJcbkJlIGNvbmNpc2UsIGhlbHBmdWwsIGFuZCB3cml0ZSBjb2RlIGluIFBlcnNpYW4gb3IgRW5nbGlzaC4iKQogICAgcmV0dXJuICJcbiIuam9pbihsaW5lcykKCmRlZiBjYWxsX2FwaShtZXNzYWdlcywgY29uZik6CiAgICBiYXNlID0gKGNvbmYuZ2V0KCJhcGlfYmFzZV91cmwiKSBvciAiIikucnN0cmlwKCIvIikKICAgIGtleSAgPSBjb25mLmdldCgiYXBpX2tleSIpIG9yICIiCiAgICBtb2RlbD0gY29uZi5nZXQoIm1vZGVsIikgb3IgImdwdC01LWNvZGV4IgogICAgaWYgbm90IGJhc2Ugb3Igbm90IGtleTogcmV0dXJuIE5vbmUsICJDb25maWcgbWlzc2luZyBhcGlfYmFzZV91cmwgb3IgYXBpX2tleSIKICAgIHVybCA9IGYie2Jhc2V9L3YxL2NoYXQvY29tcGxldGlvbnMiCiAgICBib2R5ID0ganNvbi5kdW1wcyh7Im1vZGVsIjptb2RlbCwibWVzc2FnZXMiOm1lc3NhZ2VzLCJ0ZW1wZXJhdHVyZSI6MC43LCJtYXhfdG9rZW5zIjoyMDQ4fSkuZW5jb2RlKCkKICAgIHJlcSA9IHVybGxpYi5yZXF1ZXN0LlJlcXVlc3QodXJsLCBkYXRhPWJvZHksIG1ldGhvZD0iUE9TVCIpCiAgICByZXEuYWRkX2hlYWRlcigiQ29udGVudC1UeXBlIiwiYXBwbGljYXRpb24vanNvbiIpCiAgICByZXEuYWRkX2hlYWRlcigiQXV0aG9yaXphdGlvbiIsIGYiQmVhcmVyIHtrZXl9IikKICAgIHRyeToKICAgICAgICB3aXRoIHVybGxpYi5yZXF1ZXN0LnVybG9wZW4ocmVxLCB0aW1lb3V0PTYwKSBhcyByOgogICAgICAgICAgICBkID0ganNvbi5sb2FkcyhyLnJlYWQoKSkKICAgICAgICAgICAgcmV0dXJuIGRbImNob2ljZXMiXVswXVsibWVzc2FnZSJdWyJjb250ZW50Il0sIE5vbmUKICAgIGV4Y2VwdCB1cmxsaWIuZXJyb3IuSFRUUEVycm9yIGFzIGU6CiAgICAgICAgYiA9IGUucmVhZCgpLmRlY29kZShlcnJvcnM9Imlnbm9yZSIpCiAgICAgICAgcmV0dXJuIE5vbmUsIGYiSFRUUCB7ZS5jb2RlfToge2JbOjIwMF19IgogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOiByZXR1cm4gTm9uZSwgc3RyKGUpCgpkZWYgbG9hZF9oaXN0KGNwKToKICAgIHRyeToKICAgICAgICB3aXRoIG9wZW4oZiJ7Y3B9Lmhpc3RvcnkuanNvbiIpIGFzIGY6IHJldHVybiBqc29uLmxvYWQoZikKICAgIGV4Y2VwdCBFeGNlcHRpb246IHJldHVybiBbXQoKZGVmIHNhdmVfaGlzdChjcCwgaCk6CiAgICB3aXRoIG9wZW4oZiJ7Y3B9Lmhpc3RvcnkuanNvbiIsInciKSBhcyBmOiBqc29uLmR1bXAoaCwgZiwgZW5zdXJlX2FzY2lpPUZhbHNlLCBpbmRlbnQ9MikKZGVmIGNtZF9jaGF0KGFyZ3MpOgogICAgcHJvaiA9IGFyZ3MucHJvamVjdCBvciBvcy5nZXRjd2QoKQogICAgY29uZiwgY3BhdGggPSBsb2FkX3Byb2plY3RfY29uZihwcm9qKQogICAgaWYgbm90IGNvbmY6IHByaW50KCJbcmVkXU5vIEFJIGNvbmZpZy4gUnVuICdwdXNoaXQtYWktYWdlbnQgc2V0dXAnIGZpcnN0LlsvcmVkXSIpOyBzeXMuZXhpdCgxKQogICAgc3lzdCA9IGJ1aWxkX3N5c3RlbV9wcm9tcHQocHJvaiwgYXJncy51c2VyIG9yIG9zLmVudmlyb24uZ2V0KCJVU0VSIiwiIikpCiAgICBoaXN0ID0gbG9hZF9oaXN0KGNwYXRoKQogICAgaWYgbm90IGhpc3Qgb3IgaGlzdFswXS5nZXQoInJvbGUiKSAhPSAic3lzdGVtIjoKICAgICAgICBoaXN0Lmluc2VydCgwLCB7InJvbGUiOiJzeXN0ZW0iLCJjb250ZW50IjpzeXN0fSkKICAgIHByaW50KGYiXG57Jz0nKjUwfVxuICBQdXNoaXQgQUkgQWdlbnQgIMK3ICBQcm92aWRlcjp7Y29uZi5nZXQoJ3Byb3ZpZGVyJywnLScpfSAgTW9kZWw6e2NvbmYuZ2V0KCdtb2RlbCcsJy0nKX1cbiAgUHJvamVjdDp7cHJvan1cbnsnPScqNTB9IikKICAgIHByaW50KCJUeXBlIGV4aXQvQ3RybCtEIHRvIGxlYXZlLiAvY29udGV4dCByZWxvYWQgL2NsZWFyIGVyYXNlIC9zdGF0dXMgc2hvdyIpCiAgICB3aGlsZSBUcnVlOgogICAgICAgIHRyeTogaW5wID0gaW5wdXQoIj4gIikuc3RyaXAoKQogICAgICAgIGV4Y2VwdCAoRU9GRXJyb3IsIEtleWJvYXJkSW50ZXJydXB0KTogcHJpbnQoIlxuQnllISIpOyBicmVhawogICAgICAgIGlmIG5vdCBpbnA6IGNvbnRpbnVlCiAgICAgICAgaWYgaW5wLmxvd2VyKCkgaW4gKCJleGl0IiwicXVpdCIpOiBwcmludCgiQnllISIpOyBicmVhawogICAgICAgIGlmIGlucCA9PSAiL2NsZWFyIjoKICAgICAgICAgICAgaGlzdCA9IFtoaXN0WzBdXSBpZiBoaXN0IGFuZCBoaXN0WzBdLmdldCgicm9sZSIpPT0ic3lzdGVtIiBlbHNlIFtdCiAgICAgICAgICAgIHNhdmVfaGlzdChjcGF0aCwgaGlzdCk7IHByaW50KCJbb2tdIGNsZWFyZWRcbiIpOyBjb250aW51ZQogICAgICAgIGlmIGlucCA9PSAiL2NvbnRleHQiOgogICAgICAgICAgICBzeXN0ID0gYnVpbGRfc3lzdGVtX3Byb21wdChwcm9qLCBhcmdzLnVzZXIgb3Igb3MuZW52aXJvbi5nZXQoIlVTRVIiLCIiKSkKICAgICAgICAgICAgaWYgaGlzdDogaGlzdFswXVsiY29udGVudCJdID0gc3lzdAogICAgICAgICAgICBzYXZlX2hpc3QoY3BhdGgsIGhpc3QpOyBwcmludCgiW29rXSBjb250ZXh0IHJlbG9hZGVkXG4iKTsgY29udGludWUKICAgICAgICBpZiBpbnAgPT0gIi9zdGF0dXMiOgogICAgICAgICAgICBwcmludChmIiAgUHJvdmlkZXI6e2NvbmYuZ2V0KCdwcm92aWRlcicsJy0nKX0gIE1vZGVsOntjb25mLmdldCgnbW9kZWwnLCctJyl9ICBNc2dzOntsZW4oW2ggZm9yIGggaW4gaGlzdCBpZiBoLmdldCgncm9sZScpPT0ndXNlciddKX1cbiIpOyBjb250aW51ZQogICAgICAgIGhpc3QuYXBwZW5kKHsicm9sZSI6InVzZXIiLCJjb250ZW50IjppbnB9KQogICAgICAgIHByaW50KCLij7MgIiwgZW5kPSIiLCBmbHVzaD1UcnVlKQogICAgICAgIHJlc3AsIGVyciA9IGNhbGxfYXBpKGhpc3QsIGNvbmYpCiAgICAgICAgcHJpbnQoIlxyICAgIiwgZW5kPSJcciIpCiAgICAgICAgaWYgZXJyOiBwcmludChmIltlcnJvcl0ge2Vycn0iKTsgaGlzdC5wb3AoKTsgcHJpbnQoKTsgY29udGludWUKICAgICAgICBoaXN0LmFwcGVuZCh7InJvbGUiOiJhc3Npc3RhbnQiLCJjb250ZW50IjpyZXNwfSkKICAgICAgICBpZiBsZW4oaGlzdCkgPiA0MjogaGlzdCA9IFtoaXN0WzBdXSArIGhpc3RbLTQwOl0KICAgICAgICBzYXZlX2hpc3QoY3BhdGgsIGhpc3QpCiAgICAgICAgcHJpbnQodGV4dHdyYXAuZmlsbChyZXNwLCB3aWR0aD04MCkpOyBwcmludCgpCmRlZiBjbWRfcXVlcnkoYXJncyk6CiAgICBwcm9qID0gYXJncy5wcm9qZWN0IG9yIG9zLmdldGN3ZCgpCiAgICBjb25mLCBfID0gbG9hZF9wcm9qZWN0X2NvbmYocHJvaikKICAgIGlmIG5vdCBjb25mOiBwcmludCgiTm8gQUkgY29uZmlnLiIsIGZpbGU9c3lzLnN0ZGVycik7IHN5cy5leGl0KDEpCiAgICBtc2dzID0gW3sicm9sZSI6InN5c3RlbSIsImNvbnRlbnQiOmJ1aWxkX3N5c3RlbV9wcm9tcHQocHJvaiwgIiIpfSwgeyJyb2xlIjoidXNlciIsImNvbnRlbnQiOmFyZ3MucHJvbXB0fV0KICAgIHJlc3AsIGVyciA9IGNhbGxfYXBpKG1zZ3MsIGNvbmYpCiAgICBpZiBlcnI6IHByaW50KGYiRXJyb3I6IHtlcnJ9IiwgZmlsZT1zeXMuc3RkZXJyKTsgc3lzLmV4aXQoMSkKICAgIHByaW50KHJlc3ApCgpkZWYgY21kX3NlcnZlKGFyZ3MpOgogICAgaW1wb3J0IGh0dHAuc2VydmVyLCBzb2NrZXRzZXJ2ZXIKICAgIFBPUlQgPSBhcmdzLnBvcnQgb3IgODc2NQogICAgY2xhc3MgSChodHRwLnNlcnZlci5CYXNlSFRUUFJlcXVlc3RIYW5kbGVyKToKICAgICAgICBkZWYgZG9fUE9TVChzZWxmKToKICAgICAgICAgICAgbG4gPSBpbnQoc2VsZi5oZWFkZXJzLmdldCgiQ29udGVudC1MZW5ndGgiLCAwKSkKICAgICAgICAgICAgYm9keSA9IGpzb24ubG9hZHMoc2VsZi5yZmlsZS5yZWFkKGxuKSkgaWYgbG4gZWxzZSB7fQogICAgICAgICAgICBtc2dzICA9IGJvZHkuZ2V0KCJtZXNzYWdlcyIsIFtdKQogICAgICAgICAgICBwcm9qICA9IGJvZHkuZ2V0KCJwcm9qZWN0X3BhdGgiLCAiIikKICAgICAgICAgICAgY29uZiwgY3AgPSBsb2FkX3Byb2plY3RfY29uZihwcm9qKSBpZiBwcm9qIGVsc2UgKE5vbmUsIE5vbmUpCiAgICAgICAgICAgIGlmIG5vdCBjb25mOiBjb25mLCBjcCA9IGxvYWRfcHJvamVjdF9jb25mKCIiKQogICAgICAgICAgICBpZiBub3QgY29uZjogc2VsZi5faih7ImVycm9yIjoiTm8gY29uZmlnIn0sIDUwMyk7IHJldHVybgogICAgICAgICAgICBzeXN0ID0gYnVpbGRfc3lzdGVtX3Byb21wdChwcm9qLCAiIikgaWYgcHJvaiBlbHNlICIiCiAgICAgICAgICAgIGhpc3QgPSBsb2FkX2hpc3QoY3ApCiAgICAgICAgICAgIGlmIHN5c3QgYW5kIChub3QgaGlzdCBvciBoaXN0WzBdLmdldCgicm9sZSIpIT0ic3lzdGVtIik6CiAgICAgICAgICAgICAgICBoaXN0Lmluc2VydCgwLCB7InJvbGUiOiJzeXN0ZW0iLCJjb250ZW50IjpzeXN0fSkKICAgICAgICAgICAgZWxpZiBub3Qgc3lzdCBhbmQgaGlzdCBhbmQgaGlzdFswXS5nZXQoInJvbGUiKT09InN5c3RlbSI6IGhpc3QgPSBoaXN0WzE6XQogICAgICAgICAgICBmb3IgbSBpbiBtc2dzOiBoaXN0LmFwcGVuZChtKQogICAgICAgICAgICByZXNwLCBlcnIgPSBjYWxsX2FwaShoaXN0LCBjb25mKQogICAgICAgICAgICBpZiBlcnI6IHNlbGYuX2ooeyJlcnJvciI6ZXJyfSwgNTAwKTsgcmV0dXJuCiAgICAgICAgICAgIGhpc3QuYXBwZW5kKHsicm9sZSI6ImFzc2lzdGFudCIsImNvbnRlbnQiOnJlc3B9KQogICAgICAgICAgICBpZiBsZW4oaGlzdCkgPiA0MjogaGlzdCA9IFtoaXN0WzBdXSArIGhpc3RbLTQwOl0gaWYgaGlzdFswXS5nZXQoInJvbGUiKT09InN5c3RlbSIgZWxzZSBoaXN0Wy00MDpdCiAgICAgICAgICAgIHNhdmVfaGlzdChjcCwgaGlzdCkKICAgICAgICAgICAgc2VsZi5faih7InJlc3BvbnNlIjpyZXNwLCJoaXN0b3J5IjpoaXN0fSkKICAgICAgICBkZWYgX2ooc2VsZiwgZCwgc3Q9MjAwKToKICAgICAgICAgICAgYiA9IGpzb24uZHVtcHMoZCwgZW5zdXJlX2FzY2lpPUZhbHNlKS5lbmNvZGUoKQogICAgICAgICAgICBzZWxmLnNlbmRfcmVzcG9uc2Uoc3QpOyBzZWxmLnNlbmRfaGVhZGVyKCJDb250ZW50LVR5cGUiLCJhcHBsaWNhdGlvbi9qc29uIikKICAgICAgICAgICAgc2VsZi5zZW5kX2hlYWRlcigiQ29udGVudC1MZW5ndGgiLCBsZW4oYikpOyBzZWxmLmVuZF9oZWFkZXJzKCk7IHNlbGYud2ZpbGUud3JpdGUoYikKICAgICAgICBkZWYgZG9fR0VUKHNlbGYpOiBzZWxmLl9qKHsic2VydmljZSI6InB1c2hpdC1haSIsInN0YXR1cyI6InJ1bm5pbmcifSkKICAgICAgICBkZWYgbG9nX21lc3NhZ2Uoc2VsZiwgKmEpOiBwYXNzCiAgICB3aXRoIHNvY2tldHNlcnZlci5UQ1BTZXJ2ZXIoKCIxMjcuMC4wLjEiLCBQT1JUKSwgSCkgYXMgc3J2OgogICAgICAgIHByaW50KGYiUHVzaGl0IEFJIFNlcnZlciBvbiBodHRwOi8vMTI3LjAuMC4xOntQT1JUfSAgKEN0cmwrQyB0byBzdG9wKSIpCiAgICAgICAgdHJ5OiBzcnYuc2VydmVfZm9yZXZlcigpCiAgICAgICAgZXhjZXB0IEtleWJvYXJkSW50ZXJydXB0OiBwcmludCgiXG5TdG9wcGVkLiIpOyBzeXMuZXhpdCgwKQpkZWYgY21kX3N0YXR1cyhhcmdzKToKICAgIGNvbmYsIGNwID0gbG9hZF9wcm9qZWN0X2NvbmYoYXJncy5wcm9qZWN0IG9yICIiKQogICAgaWYgbm90IGNvbmY6IHByaW50KCJObyBBSSBjb25maWcuIik7IHN5cy5leGl0KDEpCiAgICBrID0gY29uZi5nZXQoImFwaV9rZXkiLCIiKQogICAgcHJpbnQoZiJDb25maWcgOiB7Y3B9IikKICAgIHByaW50KGYiUHJvdmlkZXI6e2NvbmYuZ2V0KCdwcm92aWRlcicsJy0nKX0gIE1vZGVsOntjb25mLmdldCgnbW9kZWwnLCctJyl9IikKICAgIHByaW50KGYiQmFzZSBVUkw6e2NvbmYuZ2V0KCdhcGlfYmFzZV91cmwnLCctJyl9IikKICAgIHByaW50KGYiQVBJIEtleSA6IHtrWzo0XX0qKioqe2tbLTI6XSBpZiBsZW4oayk+NiBlbHNlICcnfSIpCiAgICBwcmludChmIkVuYWJsZWQ6e2NvbmYuZ2V0KCdlbmFibGVkJyxGYWxzZSl9ICBJbnN0YWxsZWQ6e2NvbmYuZ2V0KCdpbnN0YWxsZWQnLEZhbHNlKX0iKQoKZGVmIGNtZF9zZXR1cChhcmdzKToKICAgIHByaW50KCItLS0gUHVzaGl0IEFJIFNldHVwIC0tLVxuIikKICAgIHByb3YgPSBpbnB1dCgiUHJvdmlkZXIgWzlyb3V0ZXJdOiAiKSBvciAiOXJvdXRlciIKICAgIGJhc2UgPSBpbnB1dCgiQVBJIEJhc2UgVVJMIDogIikKICAgIGtleSAgPSBpbnB1dCgiQVBJIEtleSAgICAgIDogIikKICAgIG1vZGVsPSBpbnB1dCgiTW9kZWwgW2dwdC01LWNvZGV4XTogIikgb3IgImdwdC01LWNvZGV4IgogICAgb3MubWFrZWRpcnMoQUlfRElSLCBleGlzdF9vaz1UcnVlKQogICAgY29uZiA9IHsiZW5hYmxlZCI6VHJ1ZSwicHJvdmlkZXIiOnByb3YsImFwaV9iYXNlX3VybCI6YmFzZSwKICAgICAgICAgICAgImFwaV9rZXkiOmtleSwibW9kZWwiOm1vZGVsLCJzY29wZSI6InNlcnZlciIsInBlcm1pc3Npb25zIjp7fSwKICAgICAgICAgICAgImluc3RhbGxlZCI6VHJ1ZSwicnVubmluZyI6RmFsc2UsInVwZGF0ZWRfYXQiOmRhdGV0aW1lLnV0Y25vdygpLmlzb2Zvcm1hdCgpKyJaIn0KICAgIHdpdGggb3BlbihTRVJWRVJfQ09ORiwgInciKSBhcyBmOiBqc29uLmR1bXAoY29uZiwgZiwgaW5kZW50PTQpCiAgICBvcy5jaG1vZChTRVJWRVJfQ09ORiwgMG82MDApCiAgICBwcmludChmIlxuW29rXSBDb25maWcgc2F2ZWQgdG8ge1NFUlZFUl9DT05GfSIpCgpkZWYgbWFpbigpOgogICAgcCA9IGFyZ3BhcnNlLkFyZ3VtZW50UGFyc2VyKGRlc2NyaXB0aW9uPSJQdXNoaXQgQUkgQWdlbnQiKQogICAgcyA9IHAuYWRkX3N1YnBhcnNlcnMoZGVzdD0iY21kIikKICAgIHBjPXMuYWRkX3BhcnNlcigiY2hhdCIpOyAgcGMuYWRkX2FyZ3VtZW50KCItLXByb2plY3QiLCItcCIpOyBwYy5hZGRfYXJndW1lbnQoIi0tdXNlciIsIi11IikKICAgIHBxPXMuYWRkX3BhcnNlcigicXVlcnkiKTsgcHEuYWRkX2FyZ3VtZW50KCJwcm9tcHQiKTsgcHEuYWRkX2FyZ3VtZW50KCItLXByb2plY3QiLCItcCIpOyBwcS5hZGRfYXJndW1lbnQoIi0tdXNlciIsIi11IikKICAgIHBzPXMuYWRkX3BhcnNlcigic2VydmUiKTsgcHMuYWRkX2FyZ3VtZW50KCItLXBvcnQiLHR5cGU9aW50LGRlZmF1bHQ9ODc2NSkKICAgIHBzdD1zLmFkZF9wYXJzZXIoInN0YXR1cyIpO3BzdC5hZGRfYXJndW1lbnQoIi0tcHJvamVjdCIsIi1wIikKICAgIHN1PXMuYWRkX3BhcnNlcigic2V0dXAiKQogICAgYT1wLnBhcnNlX2FyZ3MoKQogICAgaWYgbm90IGEuY21kOiBwLnByaW50X2hlbHAoKTsgc3lzLmV4aXQoMCkKICAgIHsiY2hhdCI6Y21kX2NoYXQsInF1ZXJ5IjpjbWRfcXVlcnksInNlcnZlIjpjbWRfc2VydmUsInN0YXR1cyI6Y21kX3N0YXR1cywic2V0dXAiOmNtZF9zZXR1cH1bYS5jbWRdKGEpCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOiBtYWluKCkK'
os.makedirs('$PUSHIT_AI_DIR', exist_ok=True)
open('$PUSHIT_AI_DIR/pushit-ai-agent.py', 'wb').write(base64.b64decode(d))
os.chmod('$PUSHIT_AI_DIR/pushit-ai-agent.py', 0o755)
print('Agent written')
PYEOF
        echo -e "${GREEN}Agent binary bundled${NC}"
    fi
    if [ ! -f "$PUSHIT_AI_DIR/templates/ai.php" ]; then
        python3 << 'PYEOF'
import base64, os
d = 'PD9waHAKLyoqCiAqIFB1c2hpdCBBSSBBUEkgRW5kcG9pbnQKICogUGxhY2UgYXQ6IC9ob21lLzx1c2VyPi88ZG9tYWluPi9wdWJsaWMvYXBpL2FpLnBocAogKi8KaGVhZGVyKCdDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24nKTsKaGVhZGVyKCdBY2Nlc3MtQ29udHJvbC1BbGxvdy1PcmlnaW46IConKTsKaGVhZGVyKCdBY2Nlc3MtQ29udHJvbC1BbGxvdy1NZXRob2RzOiBQT1NULCBPUFRJT05TJyk7CmhlYWRlcignQWNjZXNzLUNvbnRyb2wtQWxsb3ctSGVhZGVyczogQ29udGVudC1UeXBlJyk7CmlmICgkX1NFUlZFUlsnUkVRVUVTVF9NRVRIT0QnXSA9PT0gJ09QVElPTlMnKSB7IGh0dHBfcmVzcG9uc2VfY29kZSgyMDQpOyBleGl0OyB9CgpkZWZpbmUoJ1BVU0hJVF9BSV9ESVInLCAgICAgJy9ldGMvcHVzaGl0L2FpJyk7CmRlZmluZSgnUFVTSElUX1NFUlZFUl9DT05GJywgUFVTSElUX0FJX0RJUiAuICcvc2VydmVyLmpzb24nKTsKCmZ1bmN0aW9uIGFpX2xvYWRfanNvbihzdHJpbmcgJHApOiBhcnJheSB7CiAgICByZXR1cm4gZmlsZV9leGlzdHMoJHApID8gKGpzb25fZGVjb2RlKGZpbGVfZ2V0X2NvbnRlbnRzKCRwKSwgdHJ1ZSkgPzogW10pIDogW107Cn0KZnVuY3Rpb24gYWlfc2F2ZV9qc29uKHN0cmluZyAkcCwgYXJyYXkgJGQpOiB2b2lkIHsKICAgIGlmICghaXNfZGlyKGRpcm5hbWUoJHApKSkgbWtkaXIoZGlybmFtZSgkcCksIDA3NTUsIHRydWUpOwogICAgZmlsZV9wdXRfY29udGVudHMoJHAsIGpzb25fZW5jb2RlKCRkLCBKU09OX1VORVNDQVBFRF9VTklDT0RFIHwgSlNPTl9QUkVUVFlfUFJJTlQpKTsKfQpmdW5jdGlvbiBhaV9nZXRfY29uZig/c3RyaW5nICRwcm9qZWN0X3BhdGggPSBudWxsKTogP2FycmF5IHsKICAgIGlmICgkcHJvamVjdF9wYXRoICYmIGZpbGVfZXhpc3RzKCJ7JHByb2plY3RfcGF0aH0vLnB1c2hpdC9haS9jb25maWcuanNvbiIpKSB7CiAgICAgICAgJGQgPSBhaV9sb2FkX2pzb24oInskcHJvamVjdF9wYXRofS8ucHVzaGl0L2FpL2NvbmZpZy5qc29uIik7CiAgICAgICAgaWYgKCFlbXB0eSgkZCkpIHJldHVybiAkZDsKICAgIH0KICAgIHJldHVybiBhaV9sb2FkX2pzb24oUFVTSElUX1NFUlZFUl9DT05GKTsKfQpmdW5jdGlvbiBhaV9nZXRfaGlzdG9yeShzdHJpbmcgJGNvbmZfcGF0aCk6IGFycmF5IHsKICAgIHJldHVybiBhaV9sb2FkX2pzb24oInskY29uZl9wYXRofS5oaXN0b3J5Lmpzb24iKTsKfQpmdW5jdGlvbiBhaV9zYXZlX2hpc3Rvcnkoc3RyaW5nICRjb25mX3BhdGgsIGFycmF5ICRoKTogdm9pZCB7CiAgICBhaV9zYXZlX2pzb24oInskY29uZl9wYXRofS5oaXN0b3J5Lmpzb24iLCAkaCk7Cn0KZnVuY3Rpb24gYWlfYnVpbGRfY29udGV4dChzdHJpbmcgJHByb2plY3RfcGF0aCk6IHN0cmluZyB7CiAgICAkcGFydHMgPSBbXTsKICAgICRrZXlzID0gWydSRUFETUUubWQnLCdwYWNrYWdlLmpzb24nLCdjb21wb3Nlci5qc29uJywnLmVudi5leGFtcGxlJywKICAgICAgICAgICAgICdyb3V0ZXMvd2ViLnBocCcsJ3JvdXRlcy9hcGkucGhwJywnYm9vdHN0cmFwL2FwcC5waHAnLAogICAgICAgICAgICAgJ3ZpdGUuY29uZmlnLmpzJywnRG9ja2VyZmlsZScsJ2RvY2tlci1jb21wb3NlLnltbCddOwogICAgZm9yZWFjaCAoJGtleXMgYXMgJGtmKSB7CiAgICAgICAgJGZ1bGwgPSAkcHJvamVjdF9wYXRoLicvJy4ka2Y7CiAgICAgICAgaWYgKGZpbGVfZXhpc3RzKCRmdWxsKSkgewogICAgICAgICAgICAkYyA9IHN1YnN0cihmaWxlX2dldF9jb250ZW50cygkZnVsbCksIDAsIDIwMDApOwogICAgICAgICAgICAkcGFydHNbXSA9ICIjIyMgeyRrZn1cbmBgYFxueyRjfVxuYGBgIjsKICAgICAgICB9CiAgICB9CiAgICAkc3RydWN0ID0gW107CiAgICAkcm9vdCA9IG5ldyBEaXJlY3RvcnlJdGVyYXRvcigkcHJvamVjdF9wYXRoKTsKICAgIGZvcmVhY2ggKCRyb290IGFzICRlKSB7CiAgICAgICAgaWYgKCRlLT5pc0RvdCgpKSBjb250aW51ZTsKICAgICAgICAkbiA9ICRlLT5nZXRGaWxlbmFtZSgpOwogICAgICAgIGlmIChpbl9hcnJheSgkbiwgWycuZ2l0JywndmVuZG9yJywnbm9kZV9tb2R1bGVzJ10pKSBjb250aW51ZTsKICAgICAgICAkc3RydWN0W10gPSAoJGUtPmlzRGlyKCk/J1tkaXJdICc6J1tmaWxlXScpLiRuOwogICAgfQogICAgJHBhcnRzW10gPSAiIyMgU3RydWN0dXJlXG4iLmltcGxvZGUoIlxuIiwgYXJyYXlfc2xpY2UoJHN0cnVjdCwgMCwgMzApKTsKICAgIHJldHVybiBpbXBsb2RlKCJcblxuIiwgJHBhcnRzKTsKfQpmdW5jdGlvbiBhaV9jYWxsX2FwaShhcnJheSAkbXNncywgYXJyYXkgJGNvbmYpOiBhcnJheSB7CiAgICAkYmFzZSA9IHJ0cmltKCRjb25mWydhcGlfYmFzZV91cmwnXT8/JycsICcvJyk7CiAgICAka2V5ICA9ICRjb25mWydhcGlfa2V5J10/PycnOwogICAgJG1vZGVsPSAkY29uZlsnbW9kZWwnXT8/J2dwdC01LWNvZGV4JzsKICAgIGlmIChlbXB0eSgkYmFzZSkgfHwgZW1wdHkoJGtleSkpIHJldHVybiBbJ2Vycm9yJz0+J01pc3NpbmcgY29uZmlnJ107CiAgICAkYm9keSA9IGpzb25fZW5jb2RlKFsnbW9kZWwnPT4kbW9kZWwsJ21lc3NhZ2VzJz0+JG1zZ3MsJ3RlbXBlcmF0dXJlJz0+MC43LCdtYXhfdG9rZW5zJz0+MjA0OF0pOwogICAgJGN0eCA9IHN0cmVhbV9jb250ZXh0X2NyZWF0ZShbJ2h0dHAnPT5bJ21ldGhvZCc9PidQT1NUJywnaGVhZGVyJz0+WyJDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24iLCJBdXRob3JpemF0aW9uOiBCZWFyZXIgeyRrZXl9Il0sJ2NvbnRlbnQnPT4kYm9keSwndGltZW91dCc9PjYwXV0pOwogICAgdHJ5IHsKICAgICAgICAkciA9IGZpbGVfZ2V0X2NvbnRlbnRzKCJ7JGJhc2V9L3YxL2NoYXQvY29tcGxldGlvbnMiLCBmYWxzZSwgJGN0eCk7CiAgICAgICAgJGQgPSBqc29uX2RlY29kZSgkciwgdHJ1ZSk7CiAgICAgICAgaWYgKCFpc3NldCgkZFsnY2hvaWNlcyddWzBdWydtZXNzYWdlJ11bJ2NvbnRlbnQnXSkpIHRocm93IG5ldyBFeGNlcHRpb24oJGRbJ2Vycm9yJ11bJ21lc3NhZ2UnXT8/J2JhZCByZXNwb25zZScpOwogICAgICAgIHJldHVybiBbJ3Jlc3BvbnNlJz0+JGRbJ2Nob2ljZXMnXVswXVsnbWVzc2FnZSddWydjb250ZW50J10sJ2Vycm9yJz0+bnVsbF07CiAgICB9IGNhdGNoIChFeGNlcHRpb24gJGUpIHsgcmV0dXJuIFsncmVzcG9uc2UnPT5udWxsLCdlcnJvcic9PiRlLT5nZXRNZXNzYWdlKCldOyB9Cn0KCiRpbnB1dCA9IGpzb25fZGVjb2RlKGZpbGVfZ2V0X2NvbnRlbnRzKCdwaHA6Ly9pbnB1dCcpLCB0cnVlKSA/PyBbXTsKJG1lc3NhZ2VzICAgPSAkaW5wdXRbJ21lc3NhZ2VzJ10gPz8gW107CiRwcm9qZWN0UGF0aD0gJGlucHV0Wydwcm9qZWN0X3BhdGgnXSA/PyAnJzsKCmlmIChlbXB0eSgkbWVzc2FnZXMpKSB7IGh0dHBfcmVzcG9uc2VfY29kZSg0MDApOyBlY2hvIGpzb25fZW5jb2RlKFsnZXJyb3InPT4nTm8gbWVzc2FnZXMnXSk7IGV4aXQ7IH0KJGNvbmYgICA9IGFpX2dldF9jb25mKCRwcm9qZWN0UGF0aCk7CiRjb25mUGF0aCA9ICRwcm9qZWN0UGF0aCA/ICJ7JHByb2plY3RQYXRofS8ucHVzaGl0L2FpL2NvbmZpZy5qc29uIiA6IFBVU0hJVF9TRVJWRVJfQ09ORjsKaWYgKGVtcHR5KCRjb25mKSkgeyBodHRwX3Jlc3BvbnNlX2NvZGUoNTAzKTsgZWNobyBqc29uX2VuY29kZShbJ2Vycm9yJz0+J0FJIGNvbmZpZyBub3QgZm91bmQnXSk7IGV4aXQ7IH0KCiRzeXN0ICA9ICJZb3UgYXJlIGEgaGVscGZ1bCBBSSBhc3Npc3RhbnQgaW50ZWdyYXRlZCBpbnRvIHRoZSBQdXNoaXQgc2VydmVyIG1hbmFnZXIuXG5cbiI7CmlmICgkcHJvamVjdFBhdGggJiYgaXNfZGlyKCRwcm9qZWN0UGF0aCkpICRzeXN0IC49ICIjIyBQcm9qZWN0IENvbnRleHRcbiIuYWlfYnVpbGRfY29udGV4dCgkcHJvamVjdFBhdGgpLiJcblxuIjsKJHN5c3QgLj0gIkJlIGNvbmNpc2UsIGhlbHBmdWwsIGFuZCB3cml0ZSBjb2RlIGluIFBlcnNpYW4gb3IgRW5nbGlzaC4iOwoKJGhpc3QgPSBhaV9nZXRfaGlzdG9yeSgkY29uZlBhdGgpOwppZiAoZW1wdHkoJGhpc3QpIHx8ICgkaGlzdFswXVsncm9sZSddPz8nJykgIT09ICdzeXN0ZW0nKQogICAgYXJyYXlfdW5zaGlmdCgkaGlzdCwgWydyb2xlJz0+J3N5c3RlbScsJ2NvbnRlbnQnPT4kc3lzdF0pOwplbHNlCiAgICAkaGlzdFswXVsnY29udGVudCddID0gJHN5c3Q7CmZvcmVhY2ggKCRtZXNzYWdlcyBhcyAkbSkgJGhpc3RbXSA9ICRtOwoKJHJlc3VsdCA9IGFpX2NhbGxfYXBpKCRoaXN0LCAkY29uZik7CmlmICgkcmVzdWx0WydyZXNwb25zZSddKSB7CiAgICAkaGlzdFtdID0gWydyb2xlJz0+J2Fzc2lzdGFudCcsJ2NvbnRlbnQnPT4kcmVzdWx0WydyZXNwb25zZSddXTsKICAgIGlmIChjb3VudCgkaGlzdCkgPiA0MikgJGhpc3QgPSBbJGhpc3RbMF1dICsgYXJyYXlfc2xpY2UoJGhpc3QsIC00MCk7CiAgICBhaV9zYXZlX2hpc3RvcnkoJGNvbmZQYXRoLCAkaGlzdCk7Cn0KaHR0cF9yZXNwb25zZV9jb2RlKCRyZXN1bHRbJ2Vycm9yJ10gPyA1MDAgOiAyMDApOwplY2hvIGpzb25fZW5jb2RlKFsncmVzcG9uc2UnPT4kcmVzdWx0WydyZXNwb25zZSddLCdoaXN0b3J5Jz0+JGhpc3QsJ2Vycm9yJz0+JHJlc3VsdFsnZXJyb3InXV0sIEpTT05fVU5FU0NBUEVEX1VOSUNPREUpOwo='
os.makedirs('$PUSHIT_AI_DIR/templates', exist_ok=True)
open('$PUSHIT_AI_DIR/templates/ai.php', 'wb').write(base64.b64decode(d))
print('PHP endpoint bundled')
PYEOF
        echo -e "${GREEN}PHP endpoint bundled${NC}"
    fi
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
    systemctl restart "php${PHP_VERSION}-fpm"
    
    # Nginx Vhost
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    VHOST_CONF="/etc/nginx/sites-available/$DOMAIN"
    _DOTCOUNT=$(echo "$DOMAIN" | tr -cd '.' | wc -c)
    if [ "$_DOTCOUNT" -ge 2 ]; then
        # Already a subdomain — no need to add www.
        SN_LINE="server_name ${DOMAIN};"
    else
        SN_LINE="server_name ${DOMAIN} www.${DOMAIN};"
    fi
    cat <<EOF > "$VHOST_CONF"
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

    # -- Pushit AI endpoints --
    location ^~ /api/ai.php {
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm-$USERNAME.sock;
        fastcgi_param SCRIPT_FILENAME \\${realpath_root}\\${fastcgi_script_name};
        include fastcgi_params;
    }
    location = /api/ai-proxy {
        proxy_pass http://127.0.0.1:8765;
        proxy_set_header Host \\${host};
        proxy_set_header X-Real-IP \\${remote_addr};
        proxy_set_header X-Project-Path /home/$USERNAME/$DOMAIN;
        proxy_read_timeout 90s;
    }
}
EOF
    ln -sf "$VHOST_CONF" "/etc/nginx/sites-enabled/$DOMAIN"
    systemctl reload nginx
    
    echo -e "\e[32mSite $DOMAIN deployed. Root: /home/$USERNAME/$DOMAIN\e[0m"

    # --- AI Agent (optional) ---
    read -r -p "Install AI Agent for this site? (y/N): " INSTALL_AI
    if [[ "$INSTALL_AI" =~ ^[Yy]$ ]]; then
        ai_install_for_project "/home/$USERNAME/$DOMAIN" "$DOMAIN" "$USERNAME"
    fi
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


manage_sites() {
    while true; do
        echo -e "\n--- Site Management ---"
        echo "1) Create Site (Deploy via Git or ZIP)"
        echo "2) Delete Site"
        echo "3) Add Domain to Site"
        echo "4) Remove Domain from Site"
        echo "5) List Sites & Domains"
        echo "6) Manage Site AI Agents"
        echo "0) Back"
        read -r -p "Choice: " SITE_CHOICE
        case $SITE_CHOICE in
            1) deploy_site ;;
            2) delete_site ;;
            3) add_site_domain ;;
            4) remove_site_domain ;;
            5) list_site_domains ;;
            6) manage_project_ai ;;
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
    else
        rm -f "$DUMP_FILE"
        echo -e "${RED}Dump failed. No backup file was kept.${NC}"
        return 1
    fi
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
# =========================================================================
# AI Agent — Server & Project management
# =========================================================================

# JSON helpers (no jq dependency)
_ai_json_get() {
    local _f="$1" _k="$2"
    grep -o "\"${_k}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$_f" 2>/dev/null \
        | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' | head -n1
}
_ai_json_get_bool() {
    local _f="$1" _k="$2"
    grep -o "\"${_k}\"[[:space:]]*:[[:space:]]*[a-z]*" "$_f" 2>/dev/null \
        | sed -E 's/.*:[[:space:]]*//' | head -n1
}
_ai_json_set() {
    local _f="$1" _k="$2" _v="$3"
    mkdir -p "$(dirname "$_f")" 2>/dev/null || true
    if [ -f "$_f" ] && grep -q "\"${_k}\"" "$_f" 2>/dev/null; then
        local tmpf
        tmpf=$(mktemp)
        while IFS= read -r line; do
            if echo "$line" | grep -q "\"${_k}\"[[:space:]]*:"; then
                printf '    "%s": "%s",\n' "$_k" "$_v"
            else
                echo "$line"
            fi
        done < "$_f" > "$tmpf"
        mv "$tmpf" "$_f"
    else
        local tmpf
        tmpf=$(mktemp)
        local total
        total=$(wc -l < "$_f")
        while IFS= read -r line; do
            total=$((total - 1))
            if [ $total -eq 0 ] && echo "$line" | grep -q '^}'; then
                printf '    "%s": "%s",\n' "$_k" "$_v"
                echo "$line"
            else
                echo "$line"
            fi
        done < "$_f" > "$tmpf"
        mv "$tmpf" "$_f"
    fi
}
_ai_mask_key() {
    local k="$1"
    if [ ${#k} -le 6 ]; then
        echo "${k:0:2}****"
    else
        local masked
        masked=$(printf '%*s' $((${#k}-6)) '' | tr ' ' '*')
        echo "${k:0:4}${masked}${k: -2}"
    fi
}

_ai_write_conf() {
    local _conf="$1" _provider="$2" _baseurl="$3" _apikey="$4" _model="$5"
    mkdir -p "$(dirname "$_conf")" 2>/dev/null || true
    cat > "$_conf" <<JSONEOF
{
    "enabled": true,
    "provider": "${_provider}",
    "api_base_url": "${_baseurl}",
    "api_key": "${_apikey}",
    "model": "${_model}",
    "scope": "${SCOPE:-project}",
    "version": "${PUSHIT_VERSION}",
    "permissions": {
        "read_files": false,
        "write_files": false,
        "execute_commands": false,
        "git": false,
        "database_read": false,
        "database_write": false,
        "manage_services": false,
        "manage_nginx": false,
        "manage_ssl": false
    },
    "installed": false,
    "running": false,
    "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSONEOF
    chmod 600 "$_conf"
}
_ai_conf_get() {
    local _conf="$1" _key="$2" _default="${3:-}"
    if [ -f "$_conf" ]; then
        local val
        val=$(_ai_json_get "$_conf" "$_key")
        echo "${val:-$_default}"
    else
        echo "$_default"
    fi
}
_ai_bin_exists() {
    [ -x "$PUSHIT_AI_BIN" ]
}

# ── Install AI Agent binary & systemd units ─────────────────────────────
install_ai_agent() {
    local SRC_AGENT="$PUSHIT_AI_DIR/pushit-ai-agent.py"
    local SRC_PHP="$PUSHIT_AI_DIR/templates/ai.php"
    # Copy agent script
    if [ ! -f "$SRC_AGENT" ]; then
        echo -e "${RED}Agent source not found at $SRC_AGENT.${NC}"
        return 1
    fi
    install -m 0755 "$SRC_AGENT" "$PUSHIT_AI_BIN" 2>/dev/null || {
        cp "$SRC_AGENT" "$PUSHIT_AI_BIN" && chmod +x "$PUSHIT_AI_BIN"
    }
    if [ -x "$PUSHIT_AI_BIN" ]; then
        _ai_json_set "$PUSHIT_AI_SERVER_CONF" "installed" "true"
        _ai_json_set "$PUSHIT_AI_SERVER_CONF" "updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo -e "${GREEN}Agent binary installed at $PUSHIT_AI_BIN${NC}"
    else
        echo -e "${RED}Failed to install agent binary.${NC}"
        return 1
    fi
    # Create systemd server service
    if [ ! -f /etc/systemd/system/pushit-ai-server.service ]; then
        cat > /etc/systemd/system/pushit-ai-server.service <<SVEOF
[Unit]
Description=Pushit AI Server Agent
After=network.target
[Service]
Type=simple
ExecStart=$PUSHIT_AI_BIN serve --port 8765
WorkingDirectory=/root
Restart=on-failure
RestartSec=5
StandardOutput=append:$PUSHIT_AI_LOG_DIR/server.log
StandardError=append:$PUSHIT_AI_LOG_DIR/server.err.log
[Install]
WantedBy=multi-user.target
SVEOF
        systemctl daemon-reload
        echo -e "${GREEN}systemd unit pushit-ai-server.service created.${NC}"
    fi
    # Create per-user systemd service template
    if [ ! -f /etc/systemd/system/pushit-ai@.service ]; then
        cat > /etc/systemd/system/pushit-ai@.service <<SVUEOF
[Unit]
Description=Pushit AI Agent for %i
After=network.target
[Service]
Type=simple
ExecStart=$PUSHIT_AI_BIN serve --port 876%i
WorkingDirectory=/home/%i
User=%i
Group=%i
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/pushit-ai/%i.log
StandardError=append:/var/log/pushit-ai/%i.err.log
[Install]
WantedBy=multi-user.target
SVUEOF
        systemctl daemon-reload
        echo -e "${GREEN}systemd unit pushit-ai@.service template created.${NC}"
    fi
}

# ── Deploy AI PHP endpoint to a project ─────────────────────────────────
deploy_ai_php_endpoint() {
    local project_path="$1" username="$2"
    local SRC_PHP="$PUSHIT_AI_DIR/templates/ai.php"
    local DEST_PHP="${project_path}/public/api/ai.php"
    if [ ! -f "$SRC_PHP" ]; then
        echo -e "${YELLOW}AI PHP endpoint template not found at $SRC_PHP. Skipping.${NC}"
        return 0
    fi
    mkdir -p "$(dirname "$DEST_PHP")" 2>/dev/null || true
    cp "$SRC_PHP" "$DEST_PHP"
    chown -R "$username:$username" "$(dirname "$DEST_PHP")" 2>/dev/null || true
    chmod 644 "$DEST_PHP"
    echo -e "${GREEN}AI PHP endpoint deployed to $DEST_PHP${NC}"
}

ai_install_for_project() {
    local project_path="$1" domain="$2" username="$3"
    echo -e "
--- Installing AI Agent for $domain ---"
    local proj_conf="${project_path}/.pushit/ai/config.json"
    mkdir -p "$(dirname "$proj_conf")" 2>/dev/null || true
    local srv_provider srv_model srv_baseurl srv_apikey
    srv_provider=$(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "provider" "$PUSHIT_AI_DEFAULT_PROVIDER")
    srv_model=$(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "model" "$PUSHIT_AI_DEFAULT_MODEL")
    srv_baseurl=$(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "api_base_url" "")
    srv_apikey=$(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "api_key" "")
    read -r -p "Provider [$srv_provider]: " AI_PROVIDER
    AI_PROVIDER=${AI_PROVIDER:-$srv_provider}
    read -r -p "API Base URL [$srv_baseurl]: " AI_BASEURL
    AI_BASEURL=${AI_BASEURL:-$srv_baseurl}
    read -r -s -p "API Key [$(_ai_mask_key "$srv_apikey")]: " AI_APIKEY
    echo
    AI_APIKEY=${AI_APIKEY:-$srv_apikey}
    if [ -z "$AI_APIKEY" ]; then
        echo -e "${RED}API Key is required.${NC}"
        return 1
    fi
    read -r -p "Model [$srv_model]: " AI_MODEL
    AI_MODEL=${AI_MODEL:-$srv_model}
    SCOPE="project"
    _ai_write_conf "$proj_conf" "$AI_PROVIDER" "$AI_BASEURL" "$AI_APIKEY" "$AI_MODEL"
    chown -R "$username:$username" "$(dirname "$proj_conf")" 2>/dev/null || true
    if [ ! -f "$PUSHIT_AI_SERVER_CONF" ]; then
        mkdir -p "$PUSHIT_AI_DIR" 2>/dev/null || true
        SCOPE="server"
        _ai_write_conf "$PUSHIT_AI_SERVER_CONF" "$AI_PROVIDER" "$AI_BASEURL" "$AI_APIKEY" "$AI_MODEL"
        chmod 600 "$PUSHIT_AI_SERVER_CONF"
    fi
    mkdir -p "$PUSHIT_AI_LOG_DIR" 2>/dev/null || true
    # Try to install agent binary if source is present
    install_ai_agent 2>/dev/null || true
    # Deploy PHP endpoint
    deploy_ai_php_endpoint "$project_path" "$username"
    echo -e "${GREEN}AI Agent setup complete for $domain.${NC}"
    echo -e "${GREEN}  Config : $proj_conf${NC}"
    echo -e "${GREEN}  Endpoint: ${project_path}/public/api/ai.php${NC}"
}

_ai_list_projects() {
    local _found=0
    for d in /home/*/; do
        local _user="$(basename "$d")"
        for sd in "$d"*/; do
            local _domain="$(basename "$sd")"
            local _conf="${sd}.pushit/ai/config.json"
            [ -f "$_conf" ] || continue
            _found=1
            local _provider _model _inst _run
            _provider=$(_ai_conf_get "$_conf" "provider" "-")
            _model=$(_ai_conf_get "$_conf" "model" "-")
            _inst=$(_ai_conf_get "$_conf" "installed" "false")
            _run=$(_ai_conf_get "$_conf" "running" "false")
            local _status=""
            [ "$_inst" = "true" ] && _status+="installed "
            [ "$_run" = "true" ] && _status+="running"
            [ -z "$_status" ] && _status="configured only"
            echo -e "  ${GREEN}$_domain${NC}  user=$_user  provider=$_provider  model=$_model  [$_status]"
        done
    done
    [ $_found -eq 0 ] && echo "  (no project AI configs found)"
}

# ── Manage Project AI Agents (sub-menu from Sites menu) ─────────────────
manage_project_ai() {
    while true; do
        echo -e "\n--- Project AI Agents ---"
        echo "1) List all Project AI configs"
        echo "2) Manage a Project AI"
        echo "0) Back"
        read -r -p "Choice: " PAI_CHOICE
        case $PAI_CHOICE in
            1)
                echo -e "\n=== Project AI Status ==="
                _ai_list_projects
                ;;
            2)
                echo -e "\nAvailable sites with AI config:"
                local _idx=0 _sites=()
                for d in /home/*/; do
                    local _user="$(basename "$d")"
                    for sd in "$d"*/; do
                        local _domain="$(basename "$sd")"
                        local _conf="${sd}.pushit/ai/config.json"
                        [ -f "$_conf" ] || continue
                        _idx=$((_idx + 1))
                        _sites+=("$_domain|$_user|$_conf")
                        local _p _m
                        _p=$(_ai_conf_get "$_conf" "provider" "-")
                        _m=$(_ai_conf_get "$_conf" "model" "-")
                        echo "  $_idx) $_domain  ($_user)  $_p / $_m"
                    done
                done
                if [ $_idx -eq 0 ]; then
                    echo -e "${YELLOW}No project AI configs found.${NC} Deploy a site first or install AI during creation."
                    continue
                fi
                read -r -p "Select site number: " PAI_SEL
                if ! [[ "$PAI_SEL" =~ ^[0-9]+$ ]] || [ "$PAI_SEL" -lt 1 ] || [ "$PAI_SEL" -gt "$_idx" ]; then
                    echo -e "${RED}Invalid selection.${NC}"
                    continue
                fi
                local _sel="${_sites[$((PAI_SEL - 1))]}"
                local _p_domain="${_sel%%|*}"; _sel="${_sel#*|}"
                local _p_user="${_sel%%|*}"; _sel="${_sel#*|}"
                local _p_conf="$_sel"
                _manage_single_project_ai "$_p_domain" "$_p_user" "$_p_conf"
                ;;
            0) break ;;
            *) echo -e "\e[31mInvalid choice.\e[0m" ;;
        esac
    done
}
# ── Permission manager ───────────────────────────────────────────────────
_manage_permissions() {
    local CONF="$1" LABEL="$2" USERNAME="$3"
    local PERMS=("read_files" "write_files" "execute_commands" "git"
                 "database_read" "database_write"
                 "manage_services" "manage_nginx" "manage_ssl")
    while true; do
        echo -e "\n--- Permissions for $LABEL ---"
        local i=1
        for p in "${PERMS[@]}"; do
            local v mark
            v=$(_ai_json_get_bool "$CONF" "$p")
            mark="[ ]"
            [ "$v" = "true" ] && mark="[x]"
            echo -e "  $i) $mark  $p"
            i=$((i + 1))
        done
        echo "0) Save and Back"
        read -r -p "Toggle permission number: " PNUM
        case $PNUM in
            0) break ;;
            [0-9]*)
                local idx=$((PNUM - 1))
                if [ $idx -ge 0 ] && [ $idx -lt ${#PERMS[@]} ]; then
                    local pm="${PERMS[$idx]}"
                    local cur
                    cur=$(_ai_json_get_bool "$CONF" "$pm")
                    [ "$cur" = "true" ] && _ai_json_set "$CONF" "$pm" "false" || _ai_json_set "$CONF" "$pm" "true"
                    _ai_json_set "$CONF" "updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    echo -e "${GREEN}Updated: $pm${NC}"
                fi
                ;;
            *) echo -e "${RED}Invalid.${NC}" ;;
        esac
    done
}

# ── Manage Server AI Agent ──────────────────────────────────────────────
manage_server_ai() {
    mkdir -p "$PUSHIT_AI_DIR" "$PUSHIT_AI_LOG_DIR" 2>/dev/null || true
    while true; do
        echo -e "\n--- Server AI Agent ---"
        local _inst _run _prov _model _url _key
        _inst=$(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "installed" "false")
        _run=$(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "running" "false")
        _prov=$(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "provider" "-")
        _model=$(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "model" "-")
        _url=$(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "api_base_url" "-")
        _key=$(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "api_key" "")
        echo -e "  Config    : $PUSHIT_AI_SERVER_CONF"
        if _ai_bin_exists; then
            echo -e "  Binary    : ${GREEN}$PUSHIT_AI_BIN${NC}"
        else
            echo -e "  Binary    : ${YELLOW}not installed yet${NC}"
        fi
        echo -e "  Installed : $_inst"
        echo -e "  Running   : $_run"
        echo -e "  Provider  : $_prov"
        echo -e "  Model     : $_model"
        echo -e "  API Base  : $_url"
        echo -e "  API Key   : $(_ai_mask_key "$_key")"
        echo ""
        echo "1) Status (refresh)"
        echo "2) Install Agent"
        echo "3) Uninstall Agent"
        echo "4) Start"
        echo "5) Stop"
        echo "6) Restart"
        echo "7) Update"
        echo "8) Change Provider"
        echo "9) Change API Key"
        echo "10) Change API Base URL"
        echo "11) Change Model"
        echo "12) Manage Permissions"
        echo "13) Run CLI Chat ($PUSHIT_AI_BIN chat)"
        echo "0) Back"
        read -r -p "Choice: " SAI_CHOICE
        case $SAI_CHOICE in
            1)
                if _ai_bin_exists; then
                    echo -e "  Binary: ${GREEN}OK${NC}"
                    if systemctl is-active --quiet "pushit-ai-server" 2>/dev/null; then
                        echo -e "  Service: ${GREEN}running${NC}"
                        _ai_json_set "$PUSHIT_AI_SERVER_CONF" "running" "true"
                    else
                        echo -e "  Service: ${YELLOW}stopped${NC}"
                        _ai_json_set "$PUSHIT_AI_SERVER_CONF" "running" "false"
                    fi
                else
                    echo -e "  Binary: ${YELLOW}not installed${NC}"
                fi
                echo "  Installed : $(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "installed" "false")"
                echo "  Updated   : $(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "updated_at" "-")"
                ;;
            2)
                echo -e "${YELLOW}Installing AI agent binary and systemd units...${NC}"
                if copy_ai_source_files && install_ai_agent; then
                    _ai_json_set "$PUSHIT_AI_SERVER_CONF" "installed" "true"
                    _ai_json_set "$PUSHIT_AI_SERVER_CONF" "updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    echo -e "${GREEN}Server AI agent installed.${NC}"
                else
                    echo -e "${RED}Agent installation failed.${NC}"
                fi
                ;;
            3)
                read -r -p "Uninstall Server AI? (y/N): " SU
                if [[ "$SU" =~ ^[Yy]$ ]]; then
                    _ai_json_set "$PUSHIT_AI_SERVER_CONF" "installed" "false"
                    _ai_json_set "$PUSHIT_AI_SERVER_CONF" "running" "false"
                    systemctl stop "pushit-ai-server" 2>/dev/null || true
                    echo -e "${GREEN}Server AI uninstalled.${NC}"
                fi
                ;;
            4)
                if _ai_bin_exists; then
                    systemctl start "pushit-ai-server" 2>/dev/null || true
                    _ai_json_set "$PUSHIT_AI_SERVER_CONF" "running" "true"
                    echo -e "${GREEN}Started.${NC}"
                else
                    echo -e "${RED}Not installed yet.${NC}"
                fi
                ;;
            5)
                systemctl stop "pushit-ai-server" 2>/dev/null || true
                _ai_json_set "$PUSHIT_AI_SERVER_CONF" "running" "false"
                echo -e "${GREEN}Stopped.${NC}"
                ;;
            6)
                if _ai_bin_exists; then
                    systemctl restart "pushit-ai-server" 2>/dev/null || true
                    echo -e "${GREEN}Restarted.${NC}"
                else
                    echo -e "${RED}Not installed.${NC}"
                fi
                ;;
            7)
                if _ai_bin_exists; then
                    systemctl restart "pushit-ai-server" 2>/dev/null || true
                    _ai_json_set "$PUSHIT_AI_SERVER_CONF" "updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    echo -e "${GREEN}Update applied.${NC}"
                fi
                ;;
            8)
                read -r -p "New provider [$(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "provider" "$PUSHIT_AI_DEFAULT_PROVIDER")]: " NPROV
                NPROV=${NPROV:-$(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "provider" "$PUSHIT_AI_DEFAULT_PROVIDER")}
                _ai_json_set "$PUSHIT_AI_SERVER_CONF" "provider" "$NPROV"
                _ai_json_set "$PUSHIT_AI_SERVER_CONF" "updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                echo -e "${GREEN}Provider updated.${NC}"
                ;;
            9)
                local ckey
                ckey=$(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "api_key" "")
                echo -e "  Current: $(_ai_mask_key "$ckey")"
                read -r -s -p "New API Key: " NEWKEY
                echo
                if [ -n "$NEWKEY" ]; then
                    _ai_json_set "$PUSHIT_AI_SERVER_CONF" "api_key" "$NEWKEY"
                    _ai_json_set "$PUSHIT_AI_SERVER_CONF" "updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    echo -e "${GREEN}API Key updated.${NC}"
                fi
                ;;
            10)
                local curl_v
                curl_v=$(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "api_base_url" "")
                echo -e "  Current: $curl_v"
                read -r -p "New API Base URL: " NEWURL
                if [ -n "$NEWURL" ]; then
                    _ai_json_set "$PUSHIT_AI_SERVER_CONF" "api_base_url" "$NEWURL"
                    _ai_json_set "$PUSHIT_AI_SERVER_CONF" "updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    echo -e "${GREEN}Base URL updated.${NC}"
                fi
                ;;
            11)
                local cmodel
                cmodel=$(_ai_conf_get "$PUSHIT_AI_SERVER_CONF" "model" "")
                echo -e "  Current: $cmodel"
                read -r -p "New model: " NEWMODEL
                if [ -n "$NEWMODEL" ]; then
                    _ai_json_set "$PUSHIT_AI_SERVER_CONF" "model" "$NEWMODEL"
                    _ai_json_set "$PUSHIT_AI_SERVER_CONF" "updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    echo -e "${GREEN}Model updated.${NC}"
                fi
                ;;
            12)
                _manage_permissions "$PUSHIT_AI_SERVER_CONF" "(server-wide)" "root"
                ;;
            13)
                if _ai_bin_exists; then
                    $PUSHIT_AI_BIN chat
                else
                    echo -e "${RED}Agent not installed. Choose option 2 first.${NC}"
                fi
                ;;
            0) break ;;
            *) echo -e "\e[31mInvalid choice.\e[0m" ;;
        esac
    done
}
_manage_single_project_ai() {
    local DOMAIN="$1" USERNAME="$2" CONF="$3"
    local PROJ_PATH="/home/$USERNAME/$DOMAIN"
    while true; do
        echo -e "\n--- AI Agent: $DOMAIN ---"
        echo "Path       : $PROJ_PATH"
        echo "Config     : $CONF"
        local _prov _model _url _inst _run
        _prov=$(_ai_conf_get "$CONF" "provider" "-")
        _model=$(_ai_conf_get "$CONF" "model" "-")
        _url=$(_ai_conf_get "$CONF" "api_base_url" "-")
        _inst=$(_ai_conf_get "$CONF" "installed" "false")
        _run=$(_ai_conf_get "$CONF" "running" "false")
        echo -e "  Status      : ${GREEN}$_inst${NC}  Run   : ${GREEN}$_run${NC}"
        echo -e "  Provider    : $_prov    Model : $_model"
        echo -e "  API Base URL: $_url"
        echo ""
        echo "1) Status (refresh)"
        echo "2) Install Agent"
        echo "3) Uninstall Agent"
        echo "4) Start"
        echo "5) Stop"
        echo "6) Restart"
        echo "7) Update"
        echo "8) Change Provider"
        echo "9) Change API Key"
        echo "10) Change API Base URL"
        echo "11) Change Model"
        echo "12) Manage Permissions"
        echo "0) Back"
        read -r -p "Choice: " PAI_SUB
        case $PAI_SUB in
            1)
                echo "  Installed : $_inst"
                echo "  Running   : $_run"
                if _ai_bin_exists; then
                    echo -e "  Binary    : ${GREEN}$PUSHIT_AI_BIN${NC}"
                    if systemctl is-active --quiet "pushit-ai@$USERNAME" 2>/dev/null; then
                        echo -e "  Service   : ${GREEN}running${NC}"
                        _ai_json_set "$CONF" "running" "true"
                    else
                        echo -e "  Service   : ${YELLOW}stopped${NC}"
                        _ai_json_set "$CONF" "running" "false"
                    fi
                else
                    echo -e "  Binary    : ${YELLOW}not installed yet${NC}"
                fi
                ;;
            2)
                _ai_json_set "$CONF" "installed" "true"
                _ai_json_set "$CONF" "updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                echo -e "${GREEN}Marked as installed.${NC}"
                ;;
            3)
                read -r -p "Uninstall for $DOMAIN? (y/N): " UC
                if [[ "$UC" =~ ^[Yy]$ ]]; then
                    _ai_json_set "$CONF" "installed" "false"
                    _ai_json_set "$CONF" "running" "false"
                    rm -f "/run/pushit-ai-${USERNAME}.pid" 2>/dev/null || true
                    systemctl stop "pushit-ai@$USERNAME" 2>/dev/null || true
                    echo -e "${GREEN}Uninstalled.${NC}"
                fi
                ;;
            4)
                if _ai_bin_exists; then
                    systemctl start "pushit-ai@$USERNAME" 2>/dev/null || true
                    _ai_json_set "$CONF" "running" "true"
                    echo -e "${GREEN}Started.${NC}"
                else
                    echo -e "${RED}Not installed yet.${NC}"
                fi
                ;;
            5)
                systemctl stop "pushit-ai@$USERNAME" 2>/dev/null || true
                _ai_json_set "$CONF" "running" "false"
                echo -e "${GREEN}Stopped.${NC}"
                ;;
            6)
                if _ai_bin_exists; then
                    systemctl restart "pushit-ai@$USERNAME" 2>/dev/null || true
                    echo -e "${GREEN}Restarted.${NC}"
                else
                    echo -e "${RED}Not installed.${NC}"
                fi
                ;;
            7)
                if _ai_bin_exists; then
                    systemctl restart "pushit-ai@$USERNAME" 2>/dev/null || true
                    _ai_json_set "$CONF" "updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    echo -e "${GREEN}Update applied.${NC}"
                fi
                ;;
            8)
                read -r -p "New provider [$(_ai_conf_get "$CONF" "provider" "$PUSHIT_AI_DEFAULT_PROVIDER")]: " NP
                NP=${NP:-$(_ai_conf_get "$CONF" "provider" "$PUSHIT_AI_DEFAULT_PROVIDER")}
                _ai_json_set "$CONF" "provider" "$NP"
                _ai_json_set "$CONF" "updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                echo -e "${GREEN}Provider updated.${NC}"
                ;;
            9)
                local cur_key
                cur_key=$(_ai_conf_get "$CONF" "api_key" "")
                echo -e "  Current key : $(_ai_mask_key "$cur_key")"
                read -r -s -p "New API Key: " NK
                echo
                if [ -n "$NK" ]; then
                    _ai_json_set "$CONF" "api_key" "$NK"
                    _ai_json_set "$CONF" "updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    echo -e "${GREEN}API Key updated.${NC}"
                fi
                ;;
            10)
                local cur_url
                cur_url=$(_ai_conf_get "$CONF" "api_base_url" "")
                echo -e "  Current URL : $cur_url"
                read -r -p "New API Base URL: " NU
                if [ -n "$NU" ]; then
                    _ai_json_set "$CONF" "api_base_url" "$NU"
                    _ai_json_set "$CONF" "updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    echo -e "${GREEN}Base URL updated.${NC}"
                fi
                ;;
            11)
                local cur_model
                cur_model=$(_ai_conf_get "$CONF" "model" "")
                echo -e "  Current model : $cur_model"
                read -r -p "New model: " NM
                if [ -n "$NM" ]; then
                    _ai_json_set "$CONF" "model" "$NM"
                    _ai_json_set "$CONF" "updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    echo -e "${GREEN}Model updated.${NC}"
                fi
                ;;
            12)
                _manage_permissions "$CONF" "$DOMAIN" "$USERNAME"
                ;;
            0) break ;;
            *) echo -e "\e[31mInvalid choice.\e[0m" ;;
        esac
    done
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
    if [ "${PUSHIT_HAS_UPDATE:-0}" = "1" ]; then
        echo -e "${YELLOW}12) ★ Update Script (v${PUSHIT_VERSION} → v${PUSHIT_REMOTE_VER}) [press 'u']${NC}"
    else
        echo "12) Update Script (from GitHub)"
    fi
    echo -e "${RED}13) Uninstall Pushit (remove script & cache)${NC}"
    echo "14) Manage Server AI Agent"
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
        13) pushit_uninstall ;;
        14) manage_server_ai ;;
        *) echo "Invalid option." ;;
    esac
}


check_root
pushit_ensure_bootstrap
while true; do
    show_menu
done
