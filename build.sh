#!/usr/bin/env bash
# build.sh — bundle lib/*.sh -> server_manager.sh (single-file distribution)
# Usage: ./build.sh           # rebuild server_manager.sh
#        ./build.sh --check   # verify that bundle is up-to-date (CI)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$ROOT/lib"
OUT="$ROOT/server_manager.sh"
TMP="$(mktemp /tmp/pushit_build.XXXXXX)"

# Order is critical — mirrors the original monolithic file
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

bundle() {
  : > "$TMP"
  for f in "${ORDER[@]}"; do
    if [ ! -f "$LIB/$f" ]; then
      echo "Missing module: $LIB/$f" >&2; exit 1
    fi
    cat "$LIB/$f" >> "$TMP"
  done
  # Single source of truth: file must end with newline
  tail -c1 "$TMP" | od -An -tx1 | grep -q "0a" || echo "" >> "$TMP"
}

if [ "${1:-}" = "--check" ]; then
  bundle
  if ! cmp -s "$TMP" "$OUT" 2>/dev/null; then
    echo "✗ server_manager.sh is out of date — run ./build.sh" >&2
    diff -u "$OUT" "$TMP" | head -n 80 || true
    rm -f "$TMP"
    exit 1
  fi
  echo "✓ server_manager.sh is up to date ($(wc -l < "$OUT") lines)"
  rm -f "$TMP"
  exit 0
fi

bundle
# Syntax check before overwriting
if ! bash -n "$TMP" 2>&1; then
  echo "✗ bash -n failed on bundle" >&2
  rm -f "$TMP"; exit 1
fi

# Also syntax-check each module individually (catch missing 'done' easily)
for f in "${ORDER[@]}"; do
  # Fragments are not standalone scripts — skip bare bash -n on fragments with unbalanced constructs.
  # Instead rely on the full bundle check above. Keep this loop for future standalone libs only.
  :
done

mv -f "$TMP" "$OUT"
chmod +x "$OUT"
echo "✓ Built $OUT ($(wc -l < "$OUT") lines, $(wc -c < "$OUT") bytes)"
echo "  bash -n OK"
echo "  version: $(grep -m1 '^PUSHIT_VERSION=' "$OUT" | cut -d= -f2 | tr -d '\"' | xargs)"
echo "  tip: edit lib/*.sh then re-run ./build.sh — do NOT edit server_manager.sh directly"
