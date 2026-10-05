#!/usr/bin/env bash
# Synthetic bundles only; no signing, GUI, launchd or production data changes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
export DAILYDISK_INSTALL_CONTROL_ROOT="$FIXTURE/Control"
mkdir -p "$FIXTURE/bin" "$FIXTURE/source.app" "$FIXTURE/target"
printf new > "$FIXTURE/source.app/marker"
cat > "$FIXTURE/bin/codesign" <<'MOCK'
#!/bin/bash
if [[ "$1" == -dr ]]; then
    if [[ "${SIGNATURE_CHANGE:-0}" == 1 && "$3" == *new.app* ]]; then
        echo 'designated => different'
    else
        echo 'designated => stable'
    fi
fi
exit "${VERIFY_FAIL:-0}"
MOCK
cat > "$FIXTURE/bin/pgrep" <<'MOCK'
#!/bin/bash
exit "${PROCESS_RESULT:-1}"
MOCK
cat > "$FIXTURE/bin/launchctl" <<'MOCK'
#!/bin/bash
if [[ "$*" == "print system" ]]; then
    printf 'system = {\n user/0\n user/99\n user/306\n user/%s\n' "$(id -u)"
    if [[ "${OTHER_SESSION:-0}" == 1 ]]; then printf 'user/99999\n'; fi
    printf '}\n'
    exit 0
fi
exit "${JOB_RESULT:-113}"
MOCK
cat > "$FIXTURE/bin/ditto" <<'MOCK'
#!/bin/bash
/bin/cp -R "$1" "$2"
MOCK
cat > "$FIXTURE/bin/mv" <<'MOCK'
#!/bin/bash
if [[ "${MOVE_FAIL:-0}" == 1 && "$1" == *new.app ]]; then exit 1; fi
if [[ "${ROLLBACK_FAIL:-0}" == 1 && "$1" == *previous.app ]]; then exit 1; fi
exec /bin/mv "$@"
MOCK
chmod +x "$FIXTURE/bin/"*
export PATH="$FIXTURE/bin:$PATH"
install_fixture() { bash "$ROOT/Scripts/install-app.sh" "$FIXTURE/source.app" "$FIXTURE/target"; }
# Native flock is transferred across exec to the shell installer, not held
# by a disposable wrapper that could exit while replacement continues.
cat > "$FIXTURE/hold.sh" <<'MOCK'
#!/bin/bash
echo "$$" > "$2"
kill -STOP "$$"
MOCK
swift "$ROOT/Scripts/with-installation-lock.swift" "$DAILYDISK_INSTALL_CONTROL_ROOT" "$FIXTURE/hold.sh" "$FIXTURE/ready" unused &
LOCK_PID=$!
trap 'kill -CONT "$LOCK_PID" 2>/dev/null || true; kill -TERM "$LOCK_PID" 2>/dev/null || true; rm -rf "$FIXTURE"' EXIT
for _ in {1..100}; do
    [[ -e "$FIXTURE/ready" ]] && break
    sleep 0.05
done
[[ "$(cat "$FIXTURE/ready")" == "$LOCK_PID" ]]
if install_fixture; then echo 'Accepted concurrent installer' >&2; exit 1; fi
kill -CONT "$LOCK_PID"
wait "$LOCK_PID"
trap 'rm -rf "$FIXTURE"' EXIT
install_fixture
[[ "$(cat "$FIXTURE/target/DailyDisk.app/marker")" == new ]]
printf old > "$FIXTURE/target/DailyDisk.app/marker"
for failure in 'PROCESS_RESULT=0' 'PROCESS_RESULT=2' 'OTHER_SESSION=1' 'JOB_RESULT=0' 'JOB_RESULT=1' 'SIGNATURE_CHANGE=1' 'VERIFY_FAIL=1' 'MOVE_FAIL=1'; do
    if env "$failure" bash "$ROOT/Scripts/install-app.sh" "$FIXTURE/source.app" "$FIXTURE/target"; then
        echo "Unexpected success: $failure" >&2; exit 1
    fi
    [[ "$(cat "$FIXTURE/target/DailyDisk.app/marker")" == old ]]
    [[ ! -e "$FIXTURE/target/.DailyDisk-install.lock" ]]
done
mkdir "$FIXTURE/target/.DailyDisk-install.lock"
if install_fixture; then exit 1; fi
rmdir "$FIXTURE/target/.DailyDisk-install.lock"
install_fixture
[[ "$(cat "$FIXTURE/target/DailyDisk.app/marker")" == new ]]
# A failed rollback must preserve the only surviving old app.
printf old > "$FIXTURE/target/DailyDisk.app/marker"
if MOVE_FAIL=1 ROLLBACK_FAIL=1 install_fixture; then exit 1; fi
[[ ! -e "$FIXTURE/target/DailyDisk.app" ]]
backups=("$FIXTURE/target"/.DailyDisk-install.*/previous.app)
[[ "${#backups[@]}" == 1 && "$(cat "${backups[0]}/marker")" == old ]]
/bin/mv "${backups[0]}" "$FIXTURE/target/DailyDisk.app"
/bin/mv "$FIXTURE/target/DailyDisk.app" "$FIXTURE/old.app"
ln -s "$FIXTURE/old.app" "$FIXTURE/target/DailyDisk.app"
if install_fixture; then exit 1; fi
[[ "$(cat "$FIXTURE/old.app/marker")" == old ]]
# Unsafe lock substitution must fail before touching the installed app.
rm "$FIXTURE/target/DailyDisk.app"
rm "$FIXTURE/Control/.installation.lock"
ln -s "$FIXTURE/old.app/marker" "$FIXTURE/Control/.installation.lock"
if install_fixture; then exit 1; fi
[[ "$(cat "$FIXTURE/old.app/marker")" == old ]]
echo 'Installer synthetic safety and rollback checks passed.' 
