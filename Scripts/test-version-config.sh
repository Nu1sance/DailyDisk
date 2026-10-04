#!/usr/bin/env bash
# Reject malformed/repeated release build numbers before compiling or signing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
for pair in '1 1' '1 2' '0 0' '01 0' '1000000000 1' '2 invalid'; do
    read -r next previous <<< "$pair"
    if RELEASE_BUILD=1 BUILD_NUMBER="$next" PREVIOUS_BUILD_NUMBER="$previous" CODE_SIGN_IDENTITY=fixture \
        "$ROOT/Scripts/build-app.sh" >"$LOG" 2>&1; then
        echo "Accepted invalid release build pair: $pair" >&2
        exit 1
    fi
    grep -q 'error:.*[Bb][Uu][Ii][Ll][Dd]' "$LOG"
done
if env -u BUILD_NUMBER RELEASE_BUILD=1 PREVIOUS_BUILD_NUMBER=1 CODE_SIGN_IDENTITY=fixture \
    "$ROOT/Scripts/build-app.sh" >"$LOG" 2>&1; then
    echo 'Accepted implicit release build number' >&2
    exit 1
fi
grep -q 'explicit BUILD_NUMBER' "$LOG"
echo 'Release version input checks passed.'
