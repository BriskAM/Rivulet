#!/bin/sh
# Builds Rivulet.app into ./build using only the Command Line Tools (no Xcode needed).
# The macOS 26.x SDK is used because the newest SDK needs Xcode's SwiftUI macro plugin.
set -eu
cd "$(dirname "$0")/.."

SDK="${RIVULET_SDK:-}"
if [ -z "$SDK" ]; then
    for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
        [ -d "$candidate" ] && SDK="$candidate" && break
    done
fi
SDK_FLAG=""
[ -n "$SDK" ] && SDK_FLAG="--sdk $SDK"

CONFIG="${1:-release}"
# shellcheck disable=SC2086
swift build -c "$CONFIG" $SDK_FLAG
# shellcheck disable=SC2086
BIN="$(swift build -c "$CONFIG" $SDK_FLAG --show-bin-path)/Rivulet"

APP="build/Rivulet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Rivulet"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Site plugins for the Link Grabber.
if [ -d Resources/Plugins ]; then
    mkdir -p "$APP/Contents/Resources/Plugins"
    cp Resources/Plugins/*.js "$APP/Contents/Resources/Plugins/" 2>/dev/null || true
fi

# Bundle aria2c and its libraries so the app works without Homebrew. Set BUNDLE_ARIA2=0 to skip.
if [ "${BUNDLE_ARIA2:-1}" = "1" ] && [ -x /opt/homebrew/bin/aria2c ] && [ -x Scripts/bundle_aria2.sh ]; then
    ./Scripts/bundle_aria2.sh "$APP"
fi

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift Scripts/make-app-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Signing. Set SIGN_IDENTITY to a "Developer ID Application: Name (TEAMID)" certificate for a distributable build.
# Without it the app gets an ad-hoc signature, which is fine for running on this Mac only.
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp \
        --entitlements Resources/Rivulet.entitlements \
        --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    echo "Signed with: $SIGN_IDENTITY"
else
    codesign --force --sign - "$APP" >/dev/null
    echo "Ad-hoc signed (set SIGN_IDENTITY for a distributable build)"
fi
echo "Built $APP"
