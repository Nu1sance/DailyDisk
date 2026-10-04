#!/usr/bin/env bash
# Install only while the GUI and its registered worker are disabled.
set -euo pipefail
[[ $# == 2 ]] || { echo 'usage: install-app.sh SOURCE_APP INSTALL_DIR' >&2; exit 64; }
SOURCE_APP="$1"
INSTALL_DIR="$2"
mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
case "$INSTALL_DIR" in
    /Applications|"$HOME/Applications") ;;
    *) echo 'warning: daily-task registration requires /Applications or ~/Applications' >&2 ;;
esac
TARGET="$INSTALL_DIR/DailyDisk.app"
[[ ! -L "$TARGET" ]] || { echo 'error: installed app must not be a symlink' >&2; exit 1; }
LOCK="$INSTALL_DIR/.DailyDisk-install.lock"
mkdir "$LOCK" || { echo 'error: another installation or an interrupted install holds the install lock' >&2; exit 1; }
WORK=""
OLD_MOVED=0
SUCCESS=0
cleanup() {
    local result=$?
    trap - EXIT HUP INT TERM
    if [[ "$OLD_MOVED" == 1 && "$SUCCESS" == 0 ]]; then
        if [[ ! -e "$TARGET" ]] && mv "$WORK/previous.app" "$TARGET"; then
            OLD_MOVED=0
        else
            echo "error: rollback app retained at $WORK/previous.app; restore it before retrying" >&2
            result=1
        fi
    fi
    if [[ -n "$WORK" && ( "$OLD_MOVED" == 0 || "$SUCCESS" == 1 ) ]]; then
        rm -rf "$WORK"
    fi
    rmdir "$LOCK"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
require_idle() {
    local code
    for name in DailyDisk DailyDiskAgent dailydiskctl; do
        if pgrep -x "$name" >/dev/null; then
            echo 'error: quit DailyDisk and wait for helper/CLI work to finish before installing' >&2
            exit 1
        else
            code=$?
            [[ "$code" == 1 ]] || { echo 'error: unable to inspect running processes' >&2; exit 1; }
        fi
    done
    # Do not race an idle launchd job that can wake during replacement.
    # Exit 113 is launchctl's missing-service result; other failures are not proof of absence.
    if launchctl print "gui/$(id -u)/io.github.xiuyuwu.DailyDisk.agent" >/dev/null 2>&1; then
        echo 'error: remove the daily task in Settings before installing; enable it again after updating' >&2
        exit 1
    else
        code=$?
        [[ "$code" == 113 ]] || { echo 'error: unable to confirm that the daily task is unregistered' >&2; exit 1; }
    fi
}
require_idle
WORK="$(mktemp -d "$INSTALL_DIR/.DailyDisk-install.XXXXXX")"
ditto "$SOURCE_APP" "$WORK/new.app"
codesign --verify --deep --strict "$WORK/new.app"
if [[ -e "$TARGET" ]]; then
    codesign --verify --deep --strict "$TARGET"
    for part in Contents/MacOS/DailyDisk Contents/Helpers/DailyDiskAgent Contents/Helpers/dailydiskctl; do
        old_requirement="$(codesign -dr - "$TARGET/$part" 2>&1 | sed -n 's/^designated => //p')"
        new_requirement="$(codesign -dr - "$WORK/new.app/$part" 2>&1 | sed -n 's/^designated => //p')"
        [[ -n "$old_requirement" && "$old_requirement" == "$new_requirement" ]] || {
            echo 'error: signing requirements changed; existing installation was preserved' >&2
            exit 1
        }
    done
fi
require_idle
if [[ -e "$TARGET" ]]; then
    mv "$TARGET" "$WORK/previous.app"
    OLD_MOVED=1
fi
mv "$WORK/new.app" "$TARGET"
SUCCESS=1
echo "Installed $TARGET"
