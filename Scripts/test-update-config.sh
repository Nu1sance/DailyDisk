#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
reset_plist() { cp "$ROOT/Config/DailyDisk-Info.plist" "$WORK/Info.plist"; }
reset_plist
"$ROOT/Scripts/configure-updates.sh" "$WORK/Info.plist"
[[ "$(plutil -extract DailyDiskUpdatesEnabled raw "$WORK/Info.plist")" == false ]]
if plutil -extract SUFeedURL raw "$WORK/Info.plist" >/dev/null 2>&1; then exit 1; fi
KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
reset_plist
DAILYDISK_UPDATES_ENABLED=1 SPARKLE_FEED_URL=https://updates.example/appcast.xml SPARKLE_PUBLIC_ED_KEY="$KEY" \
    "$ROOT/Scripts/configure-updates.sh" "$WORK/Info.plist"
[[ "$(plutil -extract DailyDiskUpdatesEnabled raw "$WORK/Info.plist")" == true ]]
[[ "$(plutil -extract SUAutomaticallyUpdate raw "$WORK/Info.plist")" == false ]]
for feed in '' http://updates.example/feed https://user:pass@updates.example/feed; do
    reset_plist
    if DAILYDISK_UPDATES_ENABLED=1 SPARKLE_FEED_URL="$feed" SPARKLE_PUBLIC_ED_KEY="$KEY" \
        "$ROOT/Scripts/configure-updates.sh" "$WORK/Info.plist"; then exit 1; fi
done
reset_plist
if DAILYDISK_UPDATES_ENABLED=1 SPARKLE_FEED_URL=https://updates.example/feed SPARKLE_PUBLIC_ED_KEY=unset \
    "$ROOT/Scripts/configure-updates.sh" "$WORK/Info.plist"; then exit 1; fi
echo 'Update configuration tests passed'
