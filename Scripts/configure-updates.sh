#!/usr/bin/env bash
# Public configuration only. No signing secret belongs in the bundle.
set -euo pipefail
[[ $# == 1 ]] || exit 64
PLIST="$1"
ENABLED="${DAILYDISK_UPDATES_ENABLED:-0}"
[[ "$ENABLED" == 0 || "$ENABLED" == 1 ]] || exit 64
if [[ "$ENABLED" == 1 ]]; then
    FEED="${SPARKLE_FEED_URL:-}"
    KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
    if [[ ! "$FEED" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]]*)?$ ]] \
        || [[ ! "$KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
        || [[ "$(printf '%s' "$KEY" | /usr/bin/base64 -D | wc -c | tr -d ' ')" != 32 ]]; then
        echo 'error: updates require an HTTPS SPARKLE_FEED_URL and a 32-byte base64 SPARKLE_PUBLIC_ED_KEY' >&2
        exit 64
    fi
    plutil -insert SUFeedURL -string "$FEED" "$PLIST"
    plutil -insert SUPublicEDKey -string "$KEY" "$PLIST"
fi
plutil -insert DailyDiskUpdatesEnabled -bool "$([[ "$ENABLED" == 1 ]] && echo YES || echo NO)" "$PLIST"
plutil -insert SUEnableAutomaticChecks -bool NO "$PLIST"
plutil -insert SUAutomaticallyUpdate -bool NO "$PLIST"
plutil -insert SUAllowsAutomaticUpdates -bool NO "$PLIST"
plutil -insert SUEnableSystemProfiling -bool NO "$PLIST"
plutil -insert SUVerifyUpdateBeforeExtraction -bool YES "$PLIST"
