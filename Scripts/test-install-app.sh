#!/usr/bin/env bash
# Synthetic bundles only; no signing, GUI, launchd or production data changes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
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
install_fixture
[[ "$(cat "$FIXTURE/target/DailyDisk.app/marker")" == new ]]
printf old > "$FIXTURE/target/DailyDisk.app/marker"
for failure in 'PROCESS_RESULT=0' 'PROCESS_RESULT=2' 'JOB_RESULT=0' 'JOB_RESULT=1' 'SIGNATURE_CHANGE=1' 'VERIFY_FAIL=1' 'MOVE_FAIL=1'; do
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
echo 'Installer synthetic safety and rollback checks passed.' 
