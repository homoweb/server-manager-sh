#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=../server_manager.sh
source "$REPO_DIR/server_manager.sh"

cat > "$TEST_DIR/install.log" <<'LOG'
/usr/lib/python3/dist-packages/fail2ban/tests/example.py:10: SyntaxWarning: invalid escape sequence '\s'
TimeoutError: [Errno 110] Connection timed out
E: Unable to locate package php8.4-cli
W: Some package metadata is old.
LOG

PUSHIT_STACK_OK_COUNT=0
PUSHIT_STACK_WARN_COUNT=0
PUSHIT_STACK_ERROR_COUNT=0
pushit_stack_report_install_messages "$TEST_DIR/install.log" > "$TEST_DIR/report.log"

[[ "$PUSHIT_STACK_OK_COUNT" -eq 0 ]]
[[ "$PUSHIT_STACK_WARN_COUNT" -eq 2 ]]
[[ "$PUSHIT_STACK_ERROR_COUNT" -eq 2 ]]
grep -Fq 'Fail2ban warning' "$TEST_DIR/report.log"
grep -Fq 'Installer warning' "$TEST_DIR/report.log"
grep -Fq 'Installer error' "$TEST_DIR/report.log"
grep -Fq 'TimeoutError: [Errno 110]' "$TEST_DIR/report.log"
grep -Fq 'E: Unable to locate package php8.4-cli' "$TEST_DIR/report.log"
echo 'All stack health report checks passed.'
