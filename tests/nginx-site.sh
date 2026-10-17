#!/usr/bin/env bash
# Test generated Nginx directives and activation rollback using local fixtures.
set -euo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$REPO_DIR/tmp"
TEST_DIR=$(mktemp -d "$REPO_DIR/tmp/nginx-test-XXXXXX")
cleanup() {
    local status=$?
    if [ "$status" -eq 0 ]; then rm -rf "$TEST_DIR"; else echo "Test logs: $TEST_DIR" >&2; fi
}
trap cleanup EXIT
# shellcheck source=../server_manager.sh
source "$REPO_DIR/server_manager.sh"
export PUSHIT_NGINX_AVAILABLE_DIR="$TEST_DIR/available"
export PUSHIT_NGINX_ENABLED_DIR="$TEST_DIR/enabled"
fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() {
    if "$@" > "$TEST_DIR/failure.log" 2>&1; then fail "Unexpected success: $*"; fi
}
nginx() {
    printf 'nginx %s\n' "$*" >> "$TEST_DIR/actions"
    if [ "${TEST_NGINX_INVALID:-0}" -eq 1 ]; then echo 'invalid number of arguments in proxy_set_header' >&2; return 1; fi
}
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$TEST_DIR/actions"
    case "$1" in
        is-active) return "${TEST_INACTIVE:-0}" ;;
        reload|start) return "${TEST_SERVICE_FAIL:-0}" ;;
        *) return 0 ;;
    esac
}
journalctl() { printf 'journalctl %s\n' "$*" >> "$TEST_DIR/actions"; }
reset_fixture() {
    rm -rf "$TEST_DIR/available" "$TEST_DIR/enabled"
    mkdir -p "$TEST_DIR/available" "$TEST_DIR/enabled"
    : > "$TEST_DIR/actions"
    TEST_NGINX_INVALID=0 TEST_SERVICE_FAIL=0 TEST_INACTIVE=0
}

# Shell variables with the same names must never enter the Nginx config.
realpath_root=WRONG fastcgi_script_name=WRONG uri=WRONG query_string=WRONG \
    pushit_render_site_vhost radayar.ir site_user > "$TEST_DIR/rendered.conf"
[[ $(grep -Fc 'fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;' "$TEST_DIR/rendered.conf") == 1 ]] || fail 'SCRIPT_FILENAME incorrectly escaped'
grep -Fq 'try_files $uri $uri/ /index.php?$query_string;' "$TEST_DIR/rendered.conf"
grep -Fq 'server_name radayar.ir www.radayar.ir;' "$TEST_DIR/rendered.conf"
grep -Fq 'root /home/site_user/radayar.ir/public;' "$TEST_DIR/rendered.conf"
if grep -Fq WRONG "$TEST_DIR/rendered.conf"; then fail 'Shell variable expanded in template'; fi
pushit_render_site_vhost app.radayar.ir site_user > "$TEST_DIR/subdomain.conf"
if grep -q www.app.radayar.ir "$TEST_DIR/subdomain.conf"; then fail 'Unwanted www alias on subdomain'; fi
echo 'PASS: literal Nginx variables, PHP directives, domain aliases and site paths'

reset_fixture
pushit_activate_site_vhost radayar.ir site_user > /dev/null
[[ -f "$TEST_DIR/available/radayar.ir" && -L "$TEST_DIR/enabled/radayar.ir" ]] || fail 'Site not activated'
grep -q '^nginx -t$' "$TEST_DIR/actions"
grep -q '^systemctl reload nginx$' "$TEST_DIR/actions"
[[ $(head -n 1 "$TEST_DIR/actions") == 'nginx -t' ]] || fail 'Service action happened before validation'
[[ $(stat -f %Lp "$TEST_DIR/available/radayar.ir" 2>/dev/null || stat -c %a "$TEST_DIR/available/radayar.ir") == 644 ]] || fail 'Wrong config permissions'
reset_fixture
TEST_INACTIVE=1 pushit_activate_site_vhost radayar.ir site_user > /dev/null
grep -q '^systemctl start nginx$' "$TEST_DIR/actions"
echo 'PASS: validation before reload and startup of an inactive service'

reset_fixture
TEST_NGINX_INVALID=1 expect_failure pushit_activate_site_vhost radayar.ir site_user
[[ ! -e "$TEST_DIR/available/radayar.ir" && ! -L "$TEST_DIR/enabled/radayar.ir" ]] || fail 'Invalid new site remained enabled'
if grep -q '^systemctl' "$TEST_DIR/actions"; then fail 'Invalid configuration reached service activation'; fi
reset_fixture
printf 'original SSL configuration\n' > "$TEST_DIR/available/radayar.ir"
ln -s "$TEST_DIR/available/radayar.ir" "$TEST_DIR/enabled/radayar.ir"
TEST_NGINX_INVALID=1 expect_failure pushit_activate_site_vhost radayar.ir site_user
[[ $(cat "$TEST_DIR/available/radayar.ir") == 'original SSL configuration' && -L "$TEST_DIR/enabled/radayar.ir" ]] || fail 'Original site lost on validation failure'
reset_fixture
printf 'disabled original configuration\n' > "$TEST_DIR/available/radayar.ir"
TEST_SERVICE_FAIL=1 expect_failure pushit_activate_site_vhost radayar.ir site_user
[[ $(cat "$TEST_DIR/available/radayar.ir") == 'disabled original configuration' && ! -L "$TEST_DIR/enabled/radayar.ir" ]] || fail 'Disabled site state not restored'
grep -q '^journalctl -u nginx -n 40 --no-pager$' "$TEST_DIR/actions"
grep -q '^systemctl status nginx --no-pager -l$' "$TEST_DIR/actions"
echo 'PASS: invalid-config and service-failure rollback, existing SSL files and disabled state'

reset_fixture
printf 'original target\n' > "$TEST_DIR/original-target"
ln -s "$TEST_DIR/original-target" "$TEST_DIR/available/radayar.ir"
ln -s "$TEST_DIR/available/radayar.ir" "$TEST_DIR/enabled/radayar.ir"
TEST_SERVICE_FAIL=1 expect_failure pushit_activate_site_vhost radayar.ir site_user
[[ -L "$TEST_DIR/available/radayar.ir" && $(cat "$TEST_DIR/original-target") == 'original target' ]] || fail 'Symlink target overwritten'
expect_failure pushit_activate_site_vhost '../bad.ir' site_user
expect_failure pushit_activate_site_vhost radayar.ir '../bad'
echo 'PASS: symlink preservation and invalid path rejection'
echo 'All Nginx site checks passed (service commands are simulated).'
