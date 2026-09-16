pushit_dl_init_python_server() {
    mkdir -p "$PUSHIT_DL_DIR" 2>/dev/null || true
    chmod 700 "$PUSHIT_DL_DIR" 2>/dev/null || true
    find "$PUSHIT_DL_DIR" -maxdepth 1 -name "*.meta" -mmin +30 -exec rm -f {} \; 2>/dev/null || true
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
import os, sys, time, http.server, socketserver, urllib.parse
DL_DIR = "/var/lib/pushit/downloads"
PORT = 8787
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        token = parsed.path.lstrip("/")
        if not token or "/" in token or ".." in token or not token.replace("_","").replace("-","").isalnum():
            self.send_response(400); self.end_headers(); self.wfile.write(b"Invalid token\n"); return
        fpath = os.path.join(DL_DIR, token)
        mpath = os.path.join(DL_DIR, token + ".meta")
        if not os.path.isfile(fpath) or not os.path.isfile(mpath):
            self.send_response(404); self.end_headers(); self.wfile.write(b"Not found or expired\n"); return
        meta = {}
        try:
            with open(mpath) as mf:
                for line in mf:
                    if "=" in line: k,v=line.strip().split("=",1); meta[k]=v
        except: pass
        exp = int(meta.get("expires","0") or 0)
        if exp and time.time() >= exp:
            try: os.remove(fpath)
            except: pass
            try: os.remove(mpath)
            except: pass
            self.send_response(410); self.end_headers(); self.wfile.write(b"Link expired (30 min)\n"); return
        fname = meta.get("filename", token)
        fsize = os.path.getsize(fpath)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(fsize))
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % fname.replace('"',''))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        with open(fpath, "rb") as fh:
            while True:
                chunk = fh.read(1024*1024)
                if not chunk: break
                self.wfile.write(chunk)
        try: os.remove(fpath)
        except: pass
        try: os.remove(mpath)
        except: pass
    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" % (self.client_address[0], self.log_date_time_string(), fmt%args))
if __name__ == "__main__":
    os.makedirs(DL_DIR, exist_ok=True)
    with socketserver.TCPServer(("", PORT), Handler) as httpd:
        httpd.allow_reuse_address = True
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
    if command -v ss >/dev/null 2>&1; then
        if ss -tlnH 2>/dev/null | grep -q ":${PUSHIT_DL_PORT} "; then return 0; fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tln 2>/dev/null | grep -q ":${PUSHIT_DL_PORT} "; then return 0; fi
    fi
    nohup python3 "$PUSHIT_DL_SERVER" >> "$PUSHIT_DL_LOG" 2>&1 &
    disown 2>/dev/null || true
    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        cat > /etc/systemd/system/pushit-dl.service <<EOF2
[Unit]
Description=Pushit one-time download server
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
ExecStart=/bin/bash -c 'find $PUSHIT_DL_DIR -maxdepth 1 -name "*.meta" -mmin +30 -delete; for m in $PUSHIT_DL_DIR/*.meta; do [ -f "\$m" ] || continue; exp=\$(grep -m1 "^expires=" "\$m" | cut -d= -f2); tok=\$(basename "\$m" .meta); if [ -n "\$exp" ] && [ "\$(date +%s)" -ge "\$exp" ]; then rm -f "$PUSHIT_DL_DIR/\$tok" "\$m"; fi; done'
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
        systemctl enable --now pushit-dl-prune.timer 2>/dev/null || true
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${PUSHIT_DL_PORT}/tcp" >/dev/null 2>&1 || true
    fi
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

