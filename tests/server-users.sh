#!/usr/bin/env bash
# Fixture-based checks: never create/delete real OS accounts or touch services.
set -euo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$REPO_DIR/tmp"
TEST_DIR=$(mktemp -d "$REPO_DIR/tmp/users-test-XXXXXX")
cleanup() {
    local status=$?
    if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then return; fi
    if [ "$status" -eq 0 ]; then rm -rf "$TEST_DIR"; else echo "Test logs: $TEST_DIR" >&2; fi
}
trap cleanup EXIT
# shellcheck source=../server_manager.sh
source "$REPO_DIR/server_manager.sh"
export PUSHIT_USERS_PASSWD_FILE="$TEST_DIR/passwd"
export PUSHIT_USERS_LOGIN_DEFS="$TEST_DIR/login.defs"
export PUSHIT_USERS_NGINX_AVAILABLE="$TEST_DIR/available"
export PUSHIT_USERS_NGINX_ENABLED="$TEST_DIR/enabled"
export PUSHIT_USERS_PHP_DIR="$TEST_DIR/php"
export PUSHIT_USERS_SUPERVISOR_DIR="$TEST_DIR/supervisor"
export PUSHIT_USERS_SSH_CONFIG="$TEST_DIR/sshd_config"
export TMPDIR="$TEST_DIR/stage"
fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() {
    if "$@" > "$TEST_DIR/error.log" 2>&1; then fail "Unexpected success: $*"; fi
}
# Every consequential OS/service command is replaced before tests run.
anchor_cwd() { :; }
id() {
    [[ "$1" == -nG ]] || return 1
    case "$2" in admin) echo 'admin sudo' ;; *) echo "$2" ;; esac
}
who() { if [ -n "${TEST_LOGGED_IN:-}" ]; then echo "$TEST_LOGGED_IN pts/0"; fi; }
chpasswd() {
    [[ $# == 0 ]] || fail 'Password passed in process arguments'
    cat > "$TEST_DIR/password-input"
    return "${TEST_PASSWORD_STATUS:-0}"
}
nginx() {
    printf 'nginx %s\n' "$*" >> "$TEST_DIR/actions"
    if [ "${TEST_NGINX_FAIL:-0}" = 1 ] && [ ! -f "$PUSHIT_USERS_NGINX_AVAILABLE/a.test" ]; then return 1; fi
}
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$TEST_DIR/actions"
    if [[ "$*" == 'is-active --quiet pushit-ai@'* ]]; then [[ "${TEST_AI_ACTIVE:-0}" == 1 ]]; else return 0; fi
}
sshd() { printf 'sshd %s\n' "$*" >> "$TEST_DIR/actions"; }
supervisorctl() { printf 'supervisorctl %s\n' "$*" >> "$TEST_DIR/actions"; }
pgrep() { [[ "${TEST_PROCESSES:-0}" == 1 ]]; }
pkill() { printf 'pkill %s\n' "$*" >> "$TEST_DIR/actions"; }
sleep() { :; }
crontab() {
    printf 'crontab %s\n' "$*" >> "$TEST_DIR/actions"
    if [[ "$1" == -l ]]; then printf '* * * * * echo fixture\n'; fi
}
userdel() {
    printf 'userdel %s\n' "$*" >> "$TEST_DIR/actions"
    [[ "$1" == -r && "$2" == alice ]] || fail 'Unexpected account deletion'
    if [ "${TEST_USERDEL_FAIL:-0}" = 1 ]; then return 1; fi
    awk -F: '$1 != "alice"' "$PUSHIT_USERS_PASSWD_FILE" > "$TEST_DIR/passwd-new"
    mv "$TEST_DIR/passwd-new" "$PUSHIT_USERS_PASSWD_FILE"
    rm -rf "$TEST_DIR/home/alice"
}
reset_fixture() {
    rm -rf "$TEST_DIR/available" "$TEST_DIR/enabled" "$TEST_DIR/php" "$TEST_DIR/supervisor" "$TEST_DIR/stage" "${TEST_DIR:?}/home"
    mkdir -p "$TEST_DIR/available" "$TEST_DIR/enabled" "$TEST_DIR/php/8.4/fpm/pool.d" "$TEST_DIR/supervisor" "$TEST_DIR/stage" "$TEST_DIR/home/alice"
    printf 'UID_MIN 1000\n' > "$PUSHIT_USERS_LOGIN_DEFS"
    cat > "$PUSHIT_USERS_PASSWD_FILE" <<'PASSWD'
root:x:0:0:root:/root:/bin/bash
service:x:998:998:service:/home/service:/usr/sbin/nologin
alice:x:1001:1001:Alice:/home/alice:/bin/bash
alice2:x:1002:1002:Other:/home/alice2:/bin/bash
admin:x:1003:1003:Admin:/home/admin:/bin/bash
nobody:x:65534:65534:Nobody:/nonexistent:/usr/sbin/nologin
external:x:1004:1004:Other:/srv/external:/bin/bash
PASSWD
    cat > "$TEST_DIR/available/a.test" <<'VHOST'
server {
    server_name a.test www.a.test alias.test;
    root /home/alice/a.test/public;
    fastcgi_pass unix:/run/php/php8.4-fpm-alice.sock;
}
VHOST
    cat > "$TEST_DIR/available/b.test" <<'VHOST'
server {
    server_name b.test;
    root "/home/alice/b.test/public";
}
VHOST
    cat > "$TEST_DIR/available/other.test" <<'VHOST'
server { }
server_name other.test;
root /home/alice2/other.test/public;
# root /home/alice/a.test/public;
VHOST
    cp "$TEST_DIR/available/a.test" "$TEST_DIR/available/a.test.bak.123"
    ln -s "$TEST_DIR/available/a.test" "$TEST_DIR/enabled/a.test"
    cat > "$TEST_DIR/php/8.4/fpm/pool.d/alice.conf" <<'POOL'
[alice]
user = alice
group = alice
POOL
    printf '[other]\nuser = alice2\n' > "$TEST_DIR/php/8.4/fpm/pool.d/other.conf"
    printf '[program:alice-worker]\nuser=alice\n' > "$TEST_DIR/supervisor/alice.conf"
    printf '[program:other-worker]\nuser=alice2\n' > "$TEST_DIR/supervisor/other.conf"
    printf 'PasswordAuthentication no\nMatch User alice\n    PasswordAuthentication yes\nMatch User alice2\n    PasswordAuthentication yes\n' > "$PUSHIT_USERS_SSH_CONFIG"
    printf 'site content\n'  > "$TEST_DIR/home/alice/site-file"
    : > "$TEST_DIR/actions"
    rm -f "$TEST_DIR/password-input"
    TEST_USERDEL_FAIL=0 TEST_NGINX_FAIL=0 TEST_PROCESSES=0 TEST_AI_ACTIVE=0 TEST_PASSWORD_STATUS=0 TEST_LOGGED_IN=''
}
reset_fixture
list_server_users > "$TEST_DIR/list.log"
grep -q 'User: alice |' "$TEST_DIR/list.log"
grep -q 'a.test www.a.test alias.test | enabled' "$TEST_DIR/list.log"
grep -q 'b.test | domains: b.test | disabled' "$TEST_DIR/list.log"
[[ $(pushit_user_site_files alice | wc -l | tr -d ' ') == 2 ]] || fail 'Site matching mixed users/backups/links'
[[ $(pushit_user_site_files alice2 | wc -l | tr -d ' ') == 1 ]] || fail 'Username prefix matched another user'
for excluded in root service nobody external; do
    if grep -q "User: $excluded |" "$TEST_DIR/list.log"; then fail "Unexpected user: $excluded"; fi
done
printf 'server { server_name compact.test; root /home/alice/compact/public; }\n' > "$TEST_DIR/available/compact.test"
[[ $(pushit_user_site_files alice | wc -l | tr -d ' ') == 3 ]] || fail 'One-line Nginx block not detected'
pushit_show_user_sites alice > "$TEST_DIR/compact.log"
grep -q 'domains: compact.test' "$TEST_DIR/compact.log"
rm "$TEST_DIR/available/compact.test"
echo 'PASS: local user filtering, domains, enabled/disabled sites, aliases and username boundaries' 

TEST_PASSWORD="quote' \\ dollar\$ hash# colon: space"
change_server_user_password <<< "$(printf 'alice\n%s\n%s\n' "$TEST_PASSWORD" "$TEST_PASSWORD")" > "$TEST_DIR/password.log"
[[ $(cat "$TEST_DIR/password-input") == "alice:$TEST_PASSWORD" ]] || fail 'Password corrupted'
if grep -Fq "$TEST_PASSWORD" "$TEST_DIR/password.log"; then fail 'Password leaked to output'; fi
rm "$TEST_DIR/password-input"
expect_failure change_server_user_password <<< $'alice\none\ntwo'
[[ ! -f "$TEST_DIR/password-input" ]] || fail 'Mismatch changed password'
expect_failure change_server_user_password <<< $'root\nsecret\nsecret'
expect_failure change_server_user_password <<< $'../bad\nsecret\nsecret'
expect_failure change_server_user_password <<< $'alice\n\n'
TEST_PASSWORD_STATUS=1 expect_failure change_server_user_password <<< $'alice\nsecret\nsecret'
echo 'PASS: password confirmation, special characters, hidden output, protected accounts and command failure'

expect_failure delete_server_user <<< $'alice\nwrong'
[[ -f "$TEST_DIR/available/a.test" && -f "$TEST_DIR/home/alice/site-file" ]] || fail 'Cancelled deletion removed files'
if grep -q '^userdel\|^pkill\|^supervisorctl\|^crontab' "$TEST_DIR/actions"; then fail 'Mutation before deletion confirmation'; fi
expect_failure delete_server_user <<< $'admin\nadmin'
SUDO_USER=alice expect_failure delete_server_user <<< $'alice\nalice'
TEST_LOGGED_IN=alice expect_failure delete_server_user <<< $'alice\nalice'
printf 'duplicate:x:1001:1001:Shared:/home/duplicate:/bin/bash\n' >> "$PUSHIT_USERS_PASSWD_FILE"
expect_failure delete_server_user <<< $'alice\nalice'
echo 'PASS: delete confirmation, administrator/session/logged-in protection and shared UID guard'

reset_fixture
printf '\nroot /home/alice2/shared/public;\n' >> "$TEST_DIR/available/a.test"
expect_failure delete_server_user <<< $'alice\nalice'
[[ -f "$TEST_DIR/available/a.test" ]] || fail 'Shared config deleted'
reset_fixture
printf '\n[other]\nuser=alice2\n' >> "$TEST_DIR/php/8.4/fpm/pool.d/alice.conf"
expect_failure delete_server_user <<< $'alice\nalice'
[[ -f "$TEST_DIR/php/8.4/fpm/pool.d/alice.conf" ]] || fail 'Shared FPM config deleted'
echo 'PASS: shared Nginx/PHP configuration guard'

reset_fixture
TEST_NGINX_FAIL=1 expect_failure delete_server_user <<< $'alice\nalice'
[[ -f "$TEST_DIR/available/a.test" && -L "$TEST_DIR/enabled/a.test" && -f "$TEST_DIR/php/8.4/fpm/pool.d/alice.conf" ]] || fail 'Validation failure did not restore configs'
if grep -q '^userdel' "$TEST_DIR/actions"; then fail 'Account removed after validation failure'; fi
reset_fixture
TEST_AI_ACTIVE=1 TEST_USERDEL_FAIL=1 expect_failure delete_server_user <<< $'alice\nalice'
[[ -f "$TEST_DIR/available/a.test" && -L "$TEST_DIR/enabled/a.test" && -f "$TEST_DIR/supervisor/alice.conf" && -f "$TEST_DIR/home/alice/site-file" ]] || fail 'Account failure lost original configs/home'
grep -q '^Match User alice$' "$PUSHIT_USERS_SSH_CONFIG"
grep -q 'systemctl start pushit-ai@alice' "$TEST_DIR/actions"
grep -q 'crontab -u alice .*crontab' "$TEST_DIR/actions"
echo 'PASS: validation/account failure rollback, symlink restoration, cron and AI recovery'

reset_fixture
TEST_PROCESSES=1 expect_failure delete_server_user <<< $'alice\nalice'
if grep -q '^userdel' "$TEST_DIR/actions"; then fail 'Deleted account with running processes'; fi
reset_fixture
delete_server_user <<< $'alice\nalice' > "$TEST_DIR/deletion.log"
[[ ! -e "$TEST_DIR/available/a.test" && ! -e "$TEST_DIR/available/b.test" && ! -L "$TEST_DIR/enabled/a.test" ]] || fail 'Site configurations survived'
[[ ! -e "$TEST_DIR/php/8.4/fpm/pool.d/alice.conf" && ! -e "$TEST_DIR/supervisor/alice.conf" && ! -e "$TEST_DIR/home/alice" ]] || fail 'User resources survived'
[[ -e "$TEST_DIR/available/other.test" && -e "$TEST_DIR/php/8.4/fpm/pool.d/other.conf" && -e "$TEST_DIR/supervisor/other.conf" ]] || fail 'Other user resources were removed'
grep -q 'systemctl reload nginx' "$TEST_DIR/actions"
grep -q 'systemctl restart php8.4-fpm' "$TEST_DIR/actions"
grep -q 'supervisorctl update' "$TEST_DIR/actions"
if grep -q '^Match User alice$' "$PUSHIT_USERS_SSH_CONFIG"; then fail 'Dedicated SSH block survived'; fi
grep -q '^Match User alice2$' "$PUSHIT_USERS_SSH_CONFIG"
expect_failure pushit_server_user_require alice
echo 'PASS: cascading deletion, site links, FPM/Supervisor cleanup and preservation of other users'
# Accounts with no sites/pools/workers must also be removable.
reset_fixture
rm -f "$TEST_DIR/available/a.test" "$TEST_DIR/available/b.test" "$TEST_DIR/enabled/a.test" "$TEST_DIR/php/8.4/fpm/pool.d/alice.conf" "$TEST_DIR/supervisor/alice.conf"
delete_server_user <<< $'alice\nalice' > /dev/null
expect_failure pushit_server_user_require alice
# Empty account lists and both menu entry points work without side effects.
printf 'root:x:0:0:root:/root:/bin/bash\n' > "$PUSHIT_USERS_PASSWD_FILE"
list_server_users > "$TEST_DIR/empty-list.log"
grep -q 'No local server users found.' "$TEST_DIR/empty-list.log"
manage_server_users <<< $'1\n0' > /dev/null
manage_sites <<< $'7\n0\n0' > "$TEST_DIR/site-menu.log"
grep -q -- '--- Server User Management ---' "$TEST_DIR/site-menu.log"
pushit_show_banner() { :; }
pushit_update_check() { :; }
pushit_show_update_notice() { :; }
PUSHIT_CONFIG="$TEST_DIR/no-config" show_menu <<< $'15\n0' > "$TEST_DIR/main-menu.log"
grep -q -- '--- Server User Management ---' "$TEST_DIR/main-menu.log"
echo 'PASS: users without sites, empty list and main/site menu routing' 
echo 'All server user checks passed.'
