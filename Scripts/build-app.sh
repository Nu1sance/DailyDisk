#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/build}"
APP_NAME="DailyDisk.app"
FINAL_APP="$OUTPUT_DIR/$APP_NAME"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-io.github.xiuyuwu.DailyDisk}"
PRODUCT_METADATA="$ROOT/Sources/DailyDiskCore/Resources/Product.json"
SOURCE_BUILD_NUMBER="$(/usr/bin/plutil -extract buildNumber raw "$PRODUCT_METADATA")"
EXPLICIT_BUILD_NUMBER="${BUILD_NUMBER:-}"
BUILD_NUMBER="${BUILD_NUMBER:-$SOURCE_BUILD_NUMBER}"
RELEASE_BUILD="${RELEASE_BUILD:-0}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
CODE_SIGN_TIMESTAMP="${CODE_SIGN_TIMESTAMP:-secure}"
ALLOW_ADHOC_SIGNING="${ALLOW_ADHOC_SIGNING:-0}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
INSTALL_APP=0
if [[ "${1:-}" == "--install" ]]; then
    INSTALL_APP=1
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--install]" >&2
    exit 64
fi

case "$CONFIGURATION" in
    debug|release) ;;
    *)
        echo "error: CONFIGURATION must be 'debug' or 'release'" >&2
        exit 64
        ;;
esac

if [[ ! "$BUNDLE_IDENTIFIER" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] \
    || [[ "$BUNDLE_IDENTIFIER" != *.* ]] \
    || [[ "$BUNDLE_IDENTIFIER" == *..* ]]; then
    echo "error: invalid BUNDLE_IDENTIFIER: $BUNDLE_IDENTIFIER" >&2
    exit 64
fi

if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,8}$ ]]; then
    echo "error: BUILD_NUMBER must be a positive integer of at most nine digits" >&2
    exit 64
fi

if [[ "$RELEASE_BUILD" == "1" ]]; then
    if [[ -z "$EXPLICIT_BUILD_NUMBER" || ! "${PREVIOUS_BUILD_NUMBER:-}" =~ ^(0|[1-9][0-9]{0,8})$ ]]; then
        echo 'error: release builds require explicit BUILD_NUMBER and PREVIOUS_BUILD_NUMBER (0 for first release)' >&2
        exit 64
    fi
    if (( BUILD_NUMBER <= PREVIOUS_BUILD_NUMBER )); then
        echo 'error: release BUILD_NUMBER must exceed PREVIOUS_BUILD_NUMBER' >&2
        exit 64
    fi
    if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
        echo 'error: release builds require a persistent signing identity' >&2
        exit 64
    fi
fi

if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
    if [[ "$ALLOW_ADHOC_SIGNING" != "1" ]]; then
        cat >&2 <<'ERROR'
error: a persistent CODE_SIGN_IDENTITY is required for an installable build.
       Ad-hoc signatures change identity after rebuild and can invalidate Full
       Disk Access and notification grants. For development-only builds, set
       ALLOW_ADHOC_SIGNING=1 explicitly.
ERROR
        exit 64
    fi
    cat >&2 <<'WARNING'
warning: using development-only ad-hoc signing because ALLOW_ADHOC_SIGNING=1.
         Do not rely on privacy grants surviving rebuilds.
WARNING
fi

# Never assemble directly over an installed bundle, bypassing install safeguards.
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
FINAL_APP="$OUTPUT_DIR/$APP_NAME"
case "$OUTPUT_DIR" in
    /Applications|"$HOME/Applications")
        echo 'error: OUTPUT_DIR must be separate from installed Applications directories' >&2
        exit 64 ;;
esac
if [[ "$INSTALL_APP" == 1 ]]; then
    mkdir -p "$INSTALL_DIR"
    INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
    [[ "$OUTPUT_DIR" != "$INSTALL_DIR" ]] || {
        echo 'error: OUTPUT_DIR and INSTALL_DIR must differ' >&2
        exit 64
    }
fi

swift build \
    --package-path "$ROOT" \
    --configuration "$CONFIGURATION" \
    --product DailyDiskApp
swift build \
    --package-path "$ROOT" \
    --configuration "$CONFIGURATION" \
    --product DailyDiskAgent
swift build \
    --package-path "$ROOT" \
    --configuration "$CONFIGURATION" \
    --product dailydiskctl

BIN_DIR="$(swift build --package-path "$ROOT" --configuration "$CONFIGURATION" --show-bin-path)"
PRODUCT_VERSION="$("$BIN_DIR/dailydiskctl" version)"
MINIMUM_SYSTEM_VERSION="$("$BIN_DIR/dailydiskctl" minimum-system-version)"

mkdir -p "$OUTPUT_DIR"
STAGING_ROOT="$(mktemp -d "$OUTPUT_DIR/.dailydisk-build.XXXXXX")"
STAGING_APP="$STAGING_ROOT/$APP_NAME"
BACKUP_APP="$OUTPUT_DIR/.DailyDisk.app.previous.$$"
cleanup() {
    rm -rf "$STAGING_ROOT"
    if [[ -e "$BACKUP_APP" ]]; then
        echo "Previous build preserved at $BACKUP_APP" >&2
    fi
}
trap cleanup EXIT

mkdir -p \
    "$STAGING_APP/Contents/MacOS" \
    "$STAGING_APP/Contents/Helpers" \
    "$STAGING_APP/Contents/Resources" \
    "$STAGING_APP/Contents/Library/LaunchAgents"

cp "$BIN_DIR/DailyDiskApp" "$STAGING_APP/Contents/MacOS/DailyDisk"
cp "$BIN_DIR/DailyDiskAgent" "$STAGING_APP/Contents/Helpers/DailyDiskAgent"
cp "$BIN_DIR/dailydiskctl" "$STAGING_APP/Contents/Helpers/dailydiskctl"
cp "$ROOT/Config/DailyDisk-Info.plist" "$STAGING_APP/Contents/Info.plist"
cp "$ROOT/Config/PrivacyInfo.xcprivacy" "$STAGING_APP/Contents/Resources/PrivacyInfo.xcprivacy"

ICON_SOURCE="$ROOT/Config/AppIcon.png"
ICONSET="$STAGING_ROOT/DailyDisk.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$ICON_SOURCE" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns --output "$STAGING_APP/Contents/Resources/DailyDisk.icns" "$ICONSET"

for resourceBundle in "$BIN_DIR"/DailyDisk_*.bundle; do
    if [[ -d "$resourceBundle" ]]; then
        cp -R "$resourceBundle" "$STAGING_APP/Contents/Resources/"
    fi
done

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PRODUCT_VERSION" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MINIMUM_SYSTEM_VERSION" "$STAGING_APP/Contents/Info.plist"

while IFS= read -r -d '' launchAgent; do
    cp "$launchAgent" "$STAGING_APP/Contents/Library/LaunchAgents/"
done < <(find "$ROOT/App/DailyDisk/LaunchAgents" -maxdepth 1 -type f -name '*.plist' -print0)

chmod 0755 \
    "$STAGING_APP/Contents/MacOS/DailyDisk" \
    "$STAGING_APP/Contents/Helpers/DailyDiskAgent" \
    "$STAGING_APP/Contents/Helpers/dailydiskctl"

TIMESTAMP_ARGUMENT=("--timestamp=none")
if [[ "$CODE_SIGN_IDENTITY" != "-" && "$CODE_SIGN_TIMESTAMP" != "none" ]]; then
    TIMESTAMP_ARGUMENT=("--timestamp")
fi

codesign \
    --force \
    --sign "$CODE_SIGN_IDENTITY" \
    "${TIMESTAMP_ARGUMENT[@]}" \
    --options runtime \
    "$STAGING_APP/Contents/Helpers/DailyDiskAgent"

codesign \
    --force \
    --sign "$CODE_SIGN_IDENTITY" \
    "${TIMESTAMP_ARGUMENT[@]}" \
    --options runtime \
    "$STAGING_APP/Contents/Helpers/dailydiskctl"

codesign \
    --force \
    --sign "$CODE_SIGN_IDENTITY" \
    "${TIMESTAMP_ARGUMENT[@]}" \
    --options runtime \
    --entitlements "$ROOT/Config/DailyDisk.entitlements" \
    "$STAGING_APP"

plutil -lint \
    "$STAGING_APP/Contents/Info.plist" \
    "$STAGING_APP/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null
codesign --verify --deep --strict "$STAGING_APP"

if [[ -e "$FINAL_APP" ]]; then
    mv "$FINAL_APP" "$BACKUP_APP"
fi
if ! mv "$STAGING_APP" "$FINAL_APP"; then
    if [[ -e "$BACKUP_APP" ]]; then
        mv "$BACKUP_APP" "$FINAL_APP"
    fi
    exit 1
fi
rm -rf "$BACKUP_APP"

echo "Built $FINAL_APP"
if [[ "$INSTALL_APP" == "1" ]]; then
    "$ROOT/Scripts/install-app.sh" "$FINAL_APP" "$INSTALL_DIR"
fi
echo "Bundle identifier: $BUNDLE_IDENTIFIER"
echo "Product version: $PRODUCT_VERSION ($BUILD_NUMBER)"
echo "Minimum macOS: $MINIMUM_SYSTEM_VERSION"
echo "Signing identity: $CODE_SIGN_IDENTITY"
