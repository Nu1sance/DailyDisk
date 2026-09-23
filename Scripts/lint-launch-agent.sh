#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$ROOT/App/DailyDisk/LaunchAgents/io.github.xiuyuwu.DailyDisk.agent.plist"
plutil -lint "$PLIST"
/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST" | grep -Fx 'io.github.xiuyuwu.DailyDisk.agent'
/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$PLIST" | grep -Fx 'Contents/Helpers/DailyDiskAgent'
/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST" | grep -Fx 'DailyDiskAgent'
