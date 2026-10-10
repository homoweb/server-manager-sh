#!/usr/bin/env bash
# Real PostgreSQL integration checks; never connect to an existing server.
set -euo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for binary in initdb pg_ctl psql pg_dump python3 rg; do
    command -v "$binary" >/dev/null || { echo "Missing test dependency: $binary" >&2; exit 1; }
done
mkdir -p "$REPO_DIR/tmp"
TEST_DIR=$(mktemp -d "$REPO_DIR/tmp/pg-test-XXXXXX")
TEST_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
cleanup() {
    local status=$?
    pg_ctl -D "$TEST_DIR/data" -m immediate -w stop >/dev/null 2>&1 || true
    if [ "$status" -eq 0 ]; then
        rm -rf "$TEST_DIR"
    else
        echo "Test logs kept at $TEST_DIR" >&2
    fi
}
trap cleanup EXIT
trap 'printf "Test failed at line %s\n" "$LINENO" >&2' ERR
initdb -D "$TEST_DIR/data" -U postgres --auth-local=trust --auth-host=scram-sha-256 > "$TEST_DIR/init.log"
pg_ctl -D "$TEST_DIR/data" -l "$TEST_DIR/server.log" \
    -o "-k '$REPO_DIR/tmp' -p $TEST_PORT -h 127.0.0.1" -w start >/dev/null
# shellcheck source=../server_manager.sh
source "$REPO_DIR/server_manager.sh"
# Retain the production wrapper for an isolated runner/argument check below.
eval "$(declare -f pushit_pg_run | sed '1s/pushit_pg_run/pushit_pg_run_ubuntu/')"
# Only replace the Ubuntu OS-account/connection wrapper. All DB operations and
# SQL, including preflight, run unchanged against this isolated cluster.
pushit_pg_run() {
    local pg_command="$1"
    shift
    "$pg_command" --host="$REPO_DIR/tmp" --port="$TEST_PORT" --username=postgres --no-password "$@"
}
pushit_ssh_port() { echo 2222; }
# Used by the sourced production functions.
export PUSHIT_DB_BACKUP_DIR="$TEST_DIR/backups"
pushit_db_publish_backup() { TEST_DUMP="$1"; chmod 600 "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_sql() {
    local actual
    actual=$(pushit_pg_psql --dbname="$1" -Atc "$2")
    [[ "$actual" == "$3" ]] || fail "$2: expected '$3', got '$actual'"
}
expect_failure() {
    if "$@" > "$TEST_DIR/expected-error.log" 2>&1; then fail "Unexpected success: $*"; fi
}
login_sql() {
    PGPASSWORD="$TEST_PASSWORD" psql -X -v ON_ERROR_STOP=1 -w -h 127.0.0.1 -p "$TEST_PORT" -U "$1" -d "$2" -Atc "$3"
}

# Quoted names and SQL metacharacters in passwords must survive creation/login.
TEST_PASSWORD="quote' slash\\ dollar\$ hash# space; --"
create_postgresql_database <<< "$(printf 'App_DB\nApp_User\n%s\n' "$TEST_PASSWORD")" > "$TEST_DIR/create.log"
assert_sql postgres "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='App_DB'" App_User
assert_sql postgres "SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls FROM pg_roles WHERE rolname='App_User'" f
login_sql App_User App_DB "CREATE TABLE items (id bigserial PRIMARY KEY, name text); INSERT INTO items(name) VALUES ('سلام'), ('backup'); CREATE FUNCTION item_count() RETURNS bigint LANGUAGE sql AS 'SELECT count(*) FROM items';" > /dev/null
[[ $(login_sql App_User App_DB 'SELECT count(*) FROM items') == 2 ]] || fail 'Application login/data failed'
echo 'PASS: creation, password escaping, TCP login, application DDL'

# Re-running creation must grant access to objects created by the admin too.
pushit_pg_psql --dbname=App_DB -c 'CREATE TABLE admin_items (id serial PRIMARY KEY);' > /dev/null
create_postgresql_database <<< "$(printf 'App_DB\nApp_User\n%s\n' "$TEST_PASSWORD")" > /dev/null
login_sql App_User App_DB 'INSERT INTO admin_items DEFAULT VALUES; SELECT * FROM admin_items;' > /dev/null
echo 'PASS: existing database/table/sequence privileges'

# Exercise pg_dump compression and both restore inputs, including object owners.
download_postgresql_database <<< App_DB > /dev/null
gzip -t "$TEST_DUMP"
[[ $(stat -f %Lp "$TEST_DUMP" 2>/dev/null || stat -c %a "$TEST_DUMP") == 600 ]] || fail 'Backup is not private'
create_postgresql_database <<< "$(printf 'Restored\nRestore_User\n%s\n' "$TEST_PASSWORD")" > /dev/null
upload_postgresql_database <<< "$(printf '%s\nRestored\n' "$TEST_DUMP")" > /dev/null
assert_sql Restored 'SELECT count(*) FROM items' 2
assert_sql Restored "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE relname='items'" Restore_User
login_sql Restore_User Restored 'ALTER TABLE items ADD COLUMN migration_check text; INSERT INTO items(name) VALUES (item_count()::text);' > /dev/null
[[ $(login_sql Restore_User Restored 'SELECT count(*) FROM items') == 3 ]] || fail 'Restored app migrations/data failed'
gunzip -c "$TEST_DUMP" > "$TEST_DIR/backup.sql"
upload_postgresql_database <<< "$(printf '%s\nNewTarget\ny\nRestore_User\n' "$TEST_DIR/backup.sql")" > /dev/null
assert_sql NewTarget 'SELECT count(*) FROM items' 2
assert_sql NewTarget "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE relname='items'" Restore_User
echo 'PASS: gzip/plain backups, missing-target creation, data/functions, restore ownership and migrations'

printf 'CREATE TABLE rollback_marker (id int);\nSELECT missing_column;\n' > "$TEST_DIR/broken.sql"
expect_failure upload_postgresql_database <<< "$(printf '%s\nRestored\n' "$TEST_DIR/broken.sql")"
assert_sql Restored "SELECT to_regclass('public.rollback_marker') IS NULL" t
assert_sql Restored 'SELECT count(*) FROM items' 3
printf 'not gzip' > "$TEST_DIR/corrupt.sql.gz"
expect_failure upload_postgresql_database <<< "$(printf '%s\nUnused\n' "$TEST_DIR/corrupt.sql.gz")"
expect_failure create_postgresql_database <<< $'bad;DROP\nunused\nsecret'
expect_failure create_postgresql_database <<< $'postgres\nunused\nsecret'
expect_failure create_postgresql_database <<< $'unused\npostgres\nsecret'
expect_failure create_postgresql_database <<< $'unused\npg_reserved\nsecret'
expect_failure pushit_pg_valid_name "$(printf '%064d' 0)"
echo 'PASS: restore SQL rollback, corrupt gzip, reserved names, injection and length validation'

TEST_PASSWORD="new'password\\with\$special# chars"
change_postgresql_password <<< "$(printf 'App_User\n%s\n' "$TEST_PASSWORD")" > /dev/null
[[ $(login_sql App_User App_DB 'SELECT count(*) FROM items') == 2 ]] || fail 'Updated password login failed'
PGPASSWORD=wrong expect_failure psql -X -w -h 127.0.0.1 -p "$TEST_PORT" -U App_User -d App_DB -c 'SELECT 1'
expect_failure delete_postgresql_database <<< $'App_DB\nwrong'
assert_sql postgres "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='App_DB')" t
delete_postgresql_database <<< $'App_DB\nApp_DB' > /dev/null
assert_sql postgres "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='App_DB')" f
expect_failure delete_postgresql_database <<< $'template0\ntemplate0'
# The new engine menu must route both engines correctly without invoking services.
manage_mysql_database_menu() { echo MYSQL_ROUTE; }
manage_postgresql_database_menu() { echo POSTGRESQL_ROUTE; }
manage_database_menu <<< $'1\n2\n0' > "$TEST_DIR/menu.log"
rg -q MYSQL_ROUTE "$TEST_DIR/menu.log"
rg -q POSTGRESQL_ROUTE "$TEST_DIR/menu.log"
echo 'PASS: password rotation, delete confirmation, reserved database protection, engine routing'
# Failed dumps must propagate through gzip and remove incomplete files.
pg_dump() { return 9; }
expect_failure download_postgresql_database <<< Restored
unset -f pg_dump
[[ $(find "$PUSHIT_DB_BACKUP_DIR/postgresql" -type f | wc -l | tr -d ' ') == 1 ]] || fail 'Failed dump left a file behind'

# MySQL must still use its original dump options through the shared publisher.
pushit_db_require() { return 0; }
mysql() { printf 'MysqlApp\n'; }
mysqldump() {
    printf '%s\n' "$@" > "$TEST_DIR/mysql-args.log"
    printf 'CREATE TABLE mysql_items (id int);\n'
}
download_database <<< MysqlApp > /dev/null
gunzip -c "$TEST_DUMP" | rg -q 'CREATE TABLE mysql_items'
rg -q -- '--single-transaction' "$TEST_DIR/mysql-args.log"
rg -q -- '--routines' "$TEST_DIR/mysql-args.log"
rg -q -- '--triggers' "$TEST_DIR/mysql-args.log"
rg -q -- '--events' "$TEST_DIR/mysql-args.log"
echo 'PASS: failed dump cleanup and MySQL backup regression'

# Check installer behavior without touching APT or system services.
php() { return 0; }
apt-get() { printf '%s\n' "$*" >> "$TEST_DIR/install.log"; return "${TEST_APT_STATUS:-0}"; }
systemctl() { printf '%s\n' "$*" >> "$TEST_DIR/services.log"; return 0; }
install_postgresql > /dev/null
rg -q 'install -y postgresql postgresql-client php8.4-pgsql' "$TEST_DIR/install.log"
rg -q 'enable --now postgresql' "$TEST_DIR/services.log"
rg -q 'restart php8.4-fpm' "$TEST_DIR/services.log"
TEST_APT_STATUS=1 expect_failure install_postgresql

# The production runner must discard inherited remote connection variables,
# select the local socket/port and execute through the postgres OS account.
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/psql" <<'STUB'
#!/usr/bin/env bash
set -eu
for variable in PGHOST PGHOSTADDR PGPORT PGDATABASE PGUSER PGPASSWORD PGPASSFILE PGSERVICE PGSERVICEFILE PGOPTIONS; do
    if env | grep -q "^${variable}="; then exit 7; fi
done
printf '%s\n' "$@"
STUB
chmod +x "$TEST_DIR/bin/psql"
runuser() {
    [[ "$1 $2 $3" == '-u postgres --' ]] || return 8
    shift 3
    "$@"
}
PATH="$TEST_DIR/bin:$PATH" PGHOST=remote PGHOSTADDR=remote PGPORT=9999 PGDATABASE=remote PGUSER=remote \
    PGPASSWORD=dummy PGPASSFILE=remote PGSERVICE=remote PGSERVICEFILE=remote PGOPTIONS=remote \
    PUSHIT_PG_PORT=5433 pushit_pg_run_ubuntu psql -X --dbname=postgres > "$TEST_DIR/runner.log"
rg -q -- '--host=/var/run/postgresql' "$TEST_DIR/runner.log"
rg -q -- '--port=5433' "$TEST_DIR/runner.log"
rg -q -- '--username=postgres' "$TEST_DIR/runner.log"
echo 'PASS: installer package/error/FPM behavior and local postgres runner'
echo 'All PostgreSQL integration checks passed.'
