#!/usr/bin/env bash
# Sourced by build-app.sh; no build/sign/install side effects.
CONFIGURATION="${CONFIGURATION:-release}"
RELEASE_BUILD="${RELEASE_BUILD:-0}"
EXPLICIT_INSTALL_DIR="${INSTALL_DIR:-}"
INSTALL_APP=0
DEBUG_BUILD=0
USER_INSTALL=0
for option in "$@"; do
    case "$option" in
        --install) INSTALL_APP=1 ;;
        --debug) DEBUG_BUILD=1 ;;
        --user) USER_INSTALL=1 ;;
        *) echo "usage: $0 [--install] [--debug] [--user]" >&2; exit 64 ;;
    esac
done
if [[ "$DEBUG_BUILD" == 1 ]]; then
    [[ "${CONFIGURATION:-release}" == release || "$CONFIGURATION" == debug ]] || exit 64
    CONFIGURATION=debug
fi
if [[ "$RELEASE_BUILD" == 1 && "$CONFIGURATION" != release ]]; then
    echo 'error: RELEASE_BUILD requires release configuration' >&2; exit 64
fi
if [[ "$USER_INSTALL" == 1 || "$DEBUG_BUILD" == 1 ]]; then
    INSTALL_DIR="$HOME/Applications"
    if [[ -n "$EXPLICIT_INSTALL_DIR" && "$EXPLICIT_INSTALL_DIR" != "$INSTALL_DIR" ]]; then
        echo 'error: --debug/--user conflicts with INSTALL_DIR' >&2; exit 64
    fi
else
    INSTALL_DIR="${EXPLICIT_INSTALL_DIR:-/Applications}"
fi

case "$CONFIGURATION" in
    debug|release) ;;
    *)
        echo "error: CONFIGURATION must be 'debug' or 'release'" >&2
        exit 64
        ;;
esac
