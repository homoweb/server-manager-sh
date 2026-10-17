#!/usr/bin/env bash
# SSH parsing is real; account lookup, service actions and timers are fixtures.
set -euo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REAL_SSHD=$(command -v sshd || true)
[ -n "$REAL_SSHD" ] || REAL_SSHD=/usr/sbin/sshd
[ -x "$REAL_SSHD" ] || { echo 'Install OpenSSH server to run this test.' >&2; exit 1; }
export REAL_SSHD
REAL_SSH_KEYGEN=$(command -v ssh-keygen)
export REAL_SSH_KEYGEN
mkdir -p "$REPO_DIR/tmp"
TEST_DIR=$(mktemp -d "$REPO_DIR/tmp/ssh-test-XXXXXX")
export TEST_DIR
cleanup() {
    local status=$?
    [ "${BASH_SUBSHELL:-0}" -eq 0 ] || return 0
    if [ "$status" -eq 0 ]; then rm -rf "$TEST_DIR"; else echo "Test logs: $TEST_DIR" >&2; fi
}
trap cleanup EXIT
# shellcheck source=../server_manager.sh
source "$REPO_DIR/server_manager.sh"
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/flock" <<'PY'
#!/usr/bin/env python3
import fcntl, sys
flags = fcntl.LOCK_EX | (fcntl.LOCK_NB if '-n' in sys.argv else 0)
try:
    fcntl.flock(int(sys.argv[-1]), flags)
except OSError:
    sys.exit(1)
PY
cat > "$TEST_DIR/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$TEST_DIR/actions"
if [[ "$1" == reload && "${TEST_RELOAD_FAIL:-0}" == 1 && ! -f "$TEST_DIR/reload-failed-once" ]]; then
    printf '1' > "$TEST_DIR/reload-failed-once"
    exit 1
fi
if [[ "$1" == reload && "${TEST_RELOAD_FAIL:-0}" == 1 && $(cat "$TEST_DIR/reload-failed-once") == 1 ]]; then
    printf '2' > "$TEST_DIR/reload-failed-once"
    exit 1
fi
STUB
cat > "$TEST_DIR/bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
printf 'systemd-run %s\n' "$*" >> "$TEST_DIR/actions"
exit "${TEST_TIMER_FAIL:-0}"
STUB
cat > "$TEST_DIR/bin/getent" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == passwd && $# == 1 ]]; then
    cat "$TEST_DIR/passwd"
    exit 0
fi
awk -F: -v name="$2" '$1 == name {print; found=1} END {exit !found}' "$TEST_DIR/passwd"
STUB
cat > "$TEST_DIR/bin/id" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    -gn) echo staff ;;
    -nG)
        if [[ "${TEST_NO_SUDO:-0}" == 1 || "$2" == site-user ]]; then echo staff; else echo 'staff sudo'; fi
        ;;
    *) exit 1 ;;
esac
STUB
cat > "$TEST_DIR/bin/useradd" <<'STUB'
#!/usr/bin/env bash
printf 'useradd %s\n' "$*" >> "$TEST_DIR/actions"
username="${!#}"
mkdir -p "$TEST_DIR/home/$username"
printf '%s:x:1005:1005:Admin:%s/home/%s:/bin/bash\n' "$username" "$TEST_DIR" "$username" >> "$TEST_DIR/passwd"
STUB
cat > "$TEST_DIR/bin/chpasswd" <<'STUB'
#!/usr/bin/env bash
[[ $# == 0 ]] || exit 1
cat > "$TEST_DIR/password-input"
exit "${TEST_PASSWORD_FAIL:-0}"
STUB
cat > "$TEST_DIR/bin/chown" <<'STUB'
#!/usr/bin/env bash
printf 'chown %s\n' "$*" >> "$TEST_DIR/actions"
STUB
cat > "$TEST_DIR/bin/sudo" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$TEST_DIR/bin/sshd" <<'STUB'
#!/usr/bin/env bash
if [[ "${TEST_VALIDATE_FAIL:-0}" == 1 ]] && grep -q 'Pushit SSH hardening' "$PUSHIT_SSH_CONFIG"; then exit 1; fi
if [[ "${TEST_EFFECTIVE_FAIL:-0}" == 1 && "$1" == -T ]]; then
    echo 'passwordauthentication yes'
    exit 0
fi
if [[ "${TEST_LEGACY_ROOT_VALUE:-0}" == 1 && "$1" == -T ]]; then
    output=$("$REAL_SSHD" "$@") || exit $?
    output=$(printf '%s\n' "$output" | sed 's/^permitrootlogin prohibit-password$/permitrootlogin without-password/')
    printf '%s\n' "$output"
    exit 0
fi
exec "$REAL_SSHD" "$@"
STUB
cat > "$TEST_DIR/bin/ssh-keygen" <<'STUB'
#!/usr/bin/env bash
if [[ "${TEST_GENERATE_FAIL:-0}" == 1 && " $* " == *' root@pushit '* ]]; then
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -f ]]; then
            printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'partial key' > "$2"
            exit 1
        fi
        shift
    done
    exit 1
fi
exec "$REAL_SSH_KEYGEN" "$@"
STUB
chmod +x "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:$PATH"
export PUSHIT_SSH_CONFIG="$TEST_DIR/sshd_config"
export PUSHIT_SSH_BACKUP_DIR="$TEST_DIR/backups"
export PUSHIT_SSH_HOME_ROOT="$TEST_DIR/home"
export PUSHIT_SSH_LOCK_FILE="$TEST_DIR/wizard.lock"
export SSH_CONNECTION='127.0.0.1 40000 192.0.2.10 2222'
export SUDO_USER=admin
ssh-keygen -q -t ed25519 -N '' -f "$TEST_DIR/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_DIR/client_key"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_DIR/root_client_key"
PUBLIC_KEY=$(cat "$TEST_DIR/client_key.pub")
pushit_ssh_port() { echo 2222; }
fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() { if "$@" > "$TEST_DIR/error.log" 2>&1; then fail "Unexpected success: $*"; fi; }
root_key_input() { printf '1\n%s\nKEEP\n' "$PUBLIC_KEY"; }
reset_fixture() {
    rm -rf "$TEST_DIR/backups" "${TEST_DIR:?}/home"
    mkdir -p "$TEST_DIR/includes" "$TEST_DIR/home/root/.ssh" "$TEST_DIR/home/admin/.ssh"
    rm -f "$TEST_DIR/reload-failed-once" "$TEST_DIR/password-input"
    cat > "$PUSHIT_SSH_CONFIG" <<EOF
HostKey $TEST_DIR/host_key
PidFile $TEST_DIR/sshd.pid
Include $TEST_DIR/includes/*.conf
PermitRootLogin yes
PasswordAuthentication yes
Match User site-user
    PasswordAuthentication=yes
    AuthenticationMethods any
EOF
    printf 'KbdInteractiveAuthentication yes\nPubkeyAuthentication no\n' > "$TEST_DIR/includes/auth.conf"
    printf 'root:x:0:0:root:%s/home/root:/bin/bash\n' "$TEST_DIR" > "$TEST_DIR/passwd"
    printf 'other-admin:x:1003:1003:Other admin:%s/home/other-admin:/bin/bash\n' "$TEST_DIR" >> "$TEST_DIR/passwd"
    printf 'admin:x:1001:1001:Admin:%s/home/admin:/bin/bash\n' "$TEST_DIR" >> "$TEST_DIR/passwd"
    printf 'site-user:x:1002:1002:Site:%s/home/site-user:/bin/bash\n' "$TEST_DIR" >> "$TEST_DIR/passwd"
    mkdir -p "$TEST_DIR/home/other-admin"
    cp "$TEST_DIR/root_client_key.pub" "$TEST_DIR/home/root/.ssh/authorized_keys"
    cp "$TEST_DIR/client_key.pub" "$TEST_DIR/home/admin/.ssh/authorized_keys"
    cp "$PUSHIT_SSH_CONFIG" "$TEST_DIR/original"
    cp "$TEST_DIR/includes/auth.conf" "$TEST_DIR/include-original"
    : > "$TEST_DIR/actions"
    export TEST_TIMER_FAIL=0 TEST_RELOAD_FAIL=0 TEST_PASSWORD_FAIL=0 TEST_VALIDATE_FAIL=0 TEST_EFFECTIVE_FAIL=0 TEST_LEGACY_ROOT_VALUE=0 TEST_NO_SUDO=0 TEST_GENERATE_FAIL=0
}
assert_generated_key_cleanup() {
    python3 - "$PUSHIT_SSH_BACKUP_DIR" "$PUSHIT_SSH_HOME_ROOT" "$TEST_DIR/key-tmp" <<'PY'
import pathlib, sys
for root in map(pathlib.Path, sys.argv[1:]):
    for path in root.rglob('*'):
        if path.is_file():
            assert b'-----BEGIN OPENSSH PRIVATE KEY-----' not in path.read_bytes(), 'Private key retained: ' + str(path)
temporary = pathlib.Path(sys.argv[3])
assert not list(temporary.glob('pushit-ssh-key.*')), 'Generated key temporary directory was not cleaned'
PY
}
assert_policy() {
    local username output
    for username in root admin site-user; do
        output=$("$REAL_SSHD" -T -f "$PUSHIT_SSH_CONFIG" -C "user=$username,addr=127.0.0.1,host=localhost")
        for setting in 'permitrootlogin prohibit-password' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'pubkeyauthentication yes' 'authenticationmethods publickey'; do
            printf '%s\n' "$output" | grep -Fxq "$setting" || fail "Wrong effective policy for $username: $setting"
        done
    done
}
reset_fixture
# A real sshd validates Include and Match candidates, including keyword=value.
mkdir -p "$TEST_DIR/manual-backup"
pushit_ssh_prepare_configs "$PUSHIT_SSH_CONFIG" "$TEST_DIR/manual-backup"
cmp "$PUSHIT_SSH_CONFIG" "$TEST_DIR/original"
pushit_ssh_copy_configs "$TEST_DIR/manual-backup" candidate
"$REAL_SSHD" -t -f "$PUSHIT_SSH_CONFIG"
assert_policy
mkdir -p "$TEST_DIR/idempotent-backup"
pushit_ssh_prepare_configs "$PUSHIT_SSH_CONFIG" "$TEST_DIR/idempotent-backup"
python3 - "$TEST_DIR/idempotent-backup" <<'PY'
import json, pathlib, sys
backup = pathlib.Path(sys.argv[1])
for entry in json.loads((backup / 'manifest.json').read_text()):
    assert (backup / (entry['index'] + '.candidate')).read_bytes() == pathlib.Path(entry['path']).read_bytes()
PY
pushit_ssh_copy_configs "$TEST_DIR/manual-backup" original
cmp "$PUSHIT_SSH_CONFIG" "$TEST_DIR/original"
cmp "$TEST_DIR/includes/auth.conf" "$TEST_DIR/include-original"
echo 'PASS: real OpenSSH syntax/effective policy, recursive Includes, Match overrides and exact restore'

reset_fixture
harden_server <<< "$(root_key_input)" > "$TEST_DIR/success.log"
assert_policy
grep -q 'Using the root SSH account' "$TEST_DIR/success.log"
[[ ! -e "$TEST_DIR/password-input" ]] || fail 'SSH hardening changed a password'
[[ $(grep -Fxc "$PUBLIC_KEY" "$TEST_DIR/home/root/.ssh/authorized_keys") -eq 1 ]] || fail 'Selected key was not installed exactly once for root'
grep -Fq "$(cat "$TEST_DIR/root_client_key.pub")" "$TEST_DIR/home/root/.ssh/authorized_keys" || fail 'Existing root key was not preserved'
grep -q 'systemd-run .*--on-active=5m' "$TEST_DIR/actions"
grep -q 'systemctl stop .*\.timer' "$TEST_DIR/actions"
grep -q 'ssh -p 2222 .*root@192.0.2.10' "$TEST_DIR/success.log"
[[ $(stat -f %Lp "$TEST_DIR/home/root/.ssh" 2>/dev/null || stat -c %a "$TEST_DIR/home/root/.ssh") == 700 ]] || fail 'SSH directory permissions'
[[ $(stat -f %Lp "$TEST_DIR/home/root/.ssh/authorized_keys" 2>/dev/null || stat -c %a "$TEST_DIR/home/root/.ssh/authorized_keys") == 600 ]] || fail 'Key file permissions'
echo 'PASS: root key-only login, preserved keys, permissions, temporary hardening and confirmed completion'

reset_fixture
TEST_LEGACY_ROOT_VALUE=1 harden_server <<< "$(root_key_input)" > "$TEST_DIR/legacy-root-value.log"
grep -Fq 'SSH hardened: root public-key login enabled' "$TEST_DIR/legacy-root-value.log"
echo 'PASS: legacy OpenSSH without-password spelling is accepted as key-only root policy'

reset_fixture
TEST_NO_SUDO=1 harden_server <<< "$(root_key_input)" > "$TEST_DIR/no-sudo-admin.log"
assert_policy
grep -Fq 'Using the root SSH account' "$TEST_DIR/no-sudo-admin.log"
grep -Fq "$PUBLIC_KEY" "$TEST_DIR/home/root/.ssh/authorized_keys"
[[ ! -e "$TEST_DIR/password-input" ]] || fail 'Root SSH hardening asked for or changed a password'
reset_fixture
harden_server <<< "$(root_key_input)" > "$TEST_DIR/key-options.log"
grep -Fq "$PUBLIC_KEY" "$TEST_DIR/home/root/.ssh/authorized_keys"
if grep -Eq 'Use this administrator|Copy existing root' "$TEST_DIR/key-options.log"; then fail 'Legacy key-source options are still shown'; fi
echo 'PASS: root hardening without a sudo administrator and two key-source choices'

reset_fixture
mkdir -p "$TEST_DIR/key-tmp" "$TEST_DIR/local-computer"
TMPDIR="$TEST_DIR/key-tmp" harden_server <<< $'2\nSAVED\nKEEP' > "$TEST_DIR/generated.log"
assert_policy
# Execute the exact emitted save instructions in an isolated client environment.
python3 - "$TEST_DIR" <<'PY'
import os, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
output = (root / 'generated.log').read_text()
save = output.split('--- BEGIN LOCAL SAVE COMMANDS ---\n', 1)[1].split('--- END LOCAL SAVE COMMANDS ---', 1)[0]
client = root / 'local-computer'
environment = dict(os.environ, HOME=str(client))
result = subprocess.run(['/bin/bash'], input=save, text=True, capture_output=True, env=environment)
assert result.returncode == 0, result.stderr
private_files = [p for p in (client / '.ssh').iterdir() if p.suffix != '.pub']
assert len(private_files) == 1, 'Save instructions did not write exactly one private key'
private = private_files[0]
public = private.with_name(private.name + '.pub')
assert private.stat().st_mode & 0o777 == 0o600, 'Local private key permissions are not 600'
assert public.stat().st_mode & 0o777 == 0o600, 'Local public key permissions are not 600'
assert (client / '.ssh').stat().st_mode & 0o777 == 0o700, 'Local SSH directory permissions are not 700'
derived = subprocess.check_output([os.environ['REAL_SSH_KEYGEN'], '-y', '-f', str(private)], text=True).split()[:2]
public_text = public.read_text().strip()
assert public_text.split()[:2] == derived, 'Exported private/public keys do not match'
assert public_text in output, 'Generated public key was not displayed'
authorized = (root / 'home/root/.ssh/authorized_keys').read_text().splitlines()
assert public_text in authorized, 'Generated public key was not installed'
assert (root / 'root_client_key.pub').read_text().strip() in authorized, 'Existing root authorized key was replaced'
login = [line for line in output.splitlines() if line.startswith('  ssh -i ')]
assert len(login) == 1, 'Generated-key login command is missing'
assert '"$HOME/.ssh/' + private.name + '"' in login[0], 'Login command uses a different key file'
assert '-o IdentitiesOnly=yes -p 2222' in login[0] and 'root@192.0.2.10' in login[0], 'Generated-key login command is incomplete'
before = {p.name: p.read_bytes() for p in (private, public)}
repeat = subprocess.run(['/bin/bash'], input=save, text=True, capture_output=True, env=environment)
assert repeat.returncode != 0, 'Save instructions overwrote an existing private key'
assert before == {p.name: p.read_bytes() for p in (private, public)}, 'Existing client key material changed'
# Also protect an existing .pub file when the matching private file is absent.
private.unlink()
public.write_text('existing public key\n')
repeat = subprocess.run(['/bin/bash'], input=save, text=True, capture_output=True, env=environment)
assert repeat.returncode != 0, 'Save instructions overwrote an existing public key'
assert public.read_text() == 'existing public key\n', 'Existing client public key changed'
PY
assert_generated_key_cleanup
echo 'PASS: generated key export saves matching local keys, preserves existing identities and prints exact SSH identity'

for generated_input in $'2\nCANCEL' $'2'; do
    reset_fixture
    cp "$TEST_DIR/home/root/.ssh/authorized_keys" "$TEST_DIR/authorized-before"
    TMPDIR="$TEST_DIR/key-tmp" expect_failure harden_server <<< "$generated_input"
    cmp "$PUSHIT_SSH_CONFIG" "$TEST_DIR/original"
    cmp "$TEST_DIR/includes/auth.conf" "$TEST_DIR/include-original"
    cmp "$TEST_DIR/home/root/.ssh/authorized_keys" "$TEST_DIR/authorized-before"
    if grep -Eq '^systemd-run |^systemctl reload' "$TEST_DIR/actions"; then fail 'SSH activated before key save confirmation'; fi
    assert_generated_key_cleanup
done
reset_fixture
cp "$TEST_DIR/home/root/.ssh/authorized_keys" "$TEST_DIR/authorized-before"
TMPDIR="$TEST_DIR/key-tmp" TEST_GENERATE_FAIL=1 expect_failure harden_server <<< $'2\nSAVED\nKEEP'
cmp "$PUSHIT_SSH_CONFIG" "$TEST_DIR/original"
cmp "$TEST_DIR/home/root/.ssh/authorized_keys" "$TEST_DIR/authorized-before"
if grep -Eq '^systemd-run |^systemctl reload' "$TEST_DIR/actions"; then fail 'SSH activated after key generation failure'; fi
assert_generated_key_cleanup
echo 'PASS: generated-key cancellation, EOF and partial generation failures clean secrets and leave SSH unchanged'

reset_fixture
expect_failure harden_server <<< $'1\nCANCEL'
cmp "$PUSHIT_SSH_CONFIG" "$TEST_DIR/original"
cmp "$TEST_DIR/includes/auth.conf" "$TEST_DIR/include-original"
reset_fixture
expect_failure harden_server <<< $'1'
cmp "$PUSHIT_SSH_CONFIG" "$TEST_DIR/original"
reset_fixture
TEST_TIMER_FAIL=1 expect_failure harden_server <<< "$(root_key_input)"
cmp "$PUSHIT_SSH_CONFIG" "$TEST_DIR/original"
if grep -q '^systemctl reload' "$TEST_DIR/actions"; then fail 'Policy activated without rollback timer'; fi
reset_fixture
TEST_VALIDATE_FAIL=1 expect_failure harden_server <<< "$(root_key_input)"
cmp "$PUSHIT_SSH_CONFIG" "$TEST_DIR/original"
reset_fixture
TEST_EFFECTIVE_FAIL=1 expect_failure harden_server <<< "$(root_key_input)"
cmp "$PUSHIT_SSH_CONFIG" "$TEST_DIR/original"
reset_fixture
TEST_RELOAD_FAIL=1 expect_failure harden_server <<< "$(root_key_input)"
cmp "$PUSHIT_SSH_CONFIG" "$TEST_DIR/original"
echo 'PASS: cancellation, timer-arm failure, invalid policy and reload failure restore all configs'

reset_fixture
# Execute the detached rollback script as an independent process, as the timer does.
mkdir -p "$TEST_DIR/timer-backup"
pushit_ssh_prepare_configs "$PUSHIT_SSH_CONFIG" "$TEST_DIR/timer-backup"
pushit_ssh_write_rollback "$TEST_DIR/timer-backup"
touch "$TEST_DIR/timer-backup/pending"
pushit_ssh_copy_configs "$TEST_DIR/timer-backup" candidate
/bin/bash "$TEST_DIR/timer-backup/rollback.sh" "$TEST_DIR/timer-backup" "$REAL_SSHD" "$PUSHIT_SSH_CONFIG"
cmp "$PUSHIT_SSH_CONFIG" "$TEST_DIR/original"
[[ -f "$TEST_DIR/timer-backup/restored" ]] || fail 'Detached rollback missing'
expect_failure pushit_ssh_confirm_hardening "$TEST_DIR/timer-backup"
reset_fixture
SUDO_USER=site-user harden_server <<< "$(printf '1\ninvalid-key\n1\n%s\nKEEP\n' "$PUBLIC_KEY")" > "$TEST_DIR/retry.log"
grep -q 'Using the root SSH account' "$TEST_DIR/retry.log"
grep -q 'Invalid public key' "$TEST_DIR/retry.log"
echo 'PASS: detached recovery, confirmation race guard and invalid key retry for root login'
reset_fixture
exec 7> "$PUSHIT_SSH_LOCK_FILE"
flock -x 7
expect_failure harden_server <<< $'1
KEEP'
exec 7>&-
cmp "$PUSHIT_SSH_CONFIG" "$TEST_DIR/original"
[[ ! -s "$TEST_DIR/actions" ]] || fail 'Concurrent wizard performed actions'
echo 'PASS: concurrent wizard lock, idempotent policy and unconfirmed/incorrect effective policy recovery'
echo 'All SSH hardening checks passed. No real accounts, SSH service or timers were changed.'
