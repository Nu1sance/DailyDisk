#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
options() {
    env -u CONFIGURATION -u RELEASE_BUILD -u INSTALL_DIR bash -c '
        option_script="$1"; shift
        source "$option_script" "$@"
        printf "%s|%s|%s" "$CONFIGURATION" "$INSTALL_DIR" "$INSTALL_APP"
    ' bash "$ROOT/Scripts/build-options.sh" "$@"
}
[[ "$(options --install)" == 'release|/Applications|1' ]]
[[ "$(options --debug --install)" == "debug|$HOME/Applications|1" ]]
[[ "$(options --install --debug)" == "debug|$HOME/Applications|1" ]]
[[ "$(options --user --install)" == "release|$HOME/Applications|1" ]]
[[ "$(options)" == 'release|/Applications|0' ]]
if options --unknown >/dev/null 2>&1; then exit 1; fi
if RELEASE_BUILD=1 bash -c 'source "$1" --debug' bash "$ROOT/Scripts/build-options.sh" >/dev/null 2>&1; then exit 1; fi
if INSTALL_DIR=/Applications bash -c 'source "$1" --user' bash "$ROOT/Scripts/build-options.sh" >/dev/null 2>&1; then exit 1; fi
echo 'Build destination and configuration tests passed.'
