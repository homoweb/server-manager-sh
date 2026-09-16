#!/usr/bin/env bash
# dev.sh — dev entry point: sources lib/*.sh directly (no build needed)
# Usage: ./dev.sh            # interactive menu
#        bash dev.sh         # same
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$ROOT/lib"
ORDER=(
  "00-header.sh"
  "01-core.sh"
  "02-update.sh"
  "03-download.sh"
  "04-apt.sh"
  "05-stack.sh"
  "06-sites.sh"
  "07-ssl.sh"
  "08-firewall.sh"
  "09-harden.sh"
  "10-database.sh"
  "11-cron.sh"
  "12-supervisor.sh"
  "13-dns.sh"
  "14-menu.sh"
)
TMP="$(mktemp /tmp/pushit_dev.XXXXXX)"
trap 'rm -f "$TMP"' EXIT
: > "$TMP"
for f in "${ORDER[@]}"; do cat "$LIB/$f" >> "$TMP"; done
tail -c1 "$TMP" | od -An -tx1 | grep -q "0a" || echo "" >> "$TMP"
if ! bash -n "$TMP" 2>&1; then echo "✗ syntax error" >&2; exit 1; fi
exec bash "$TMP" "$@"
