#!/bin/sh
# Builds the app and writes build/Rivulet-<version>.zip plus its SHA-256, ready to attach to a GitHub release.
set -eu
cd "$(dirname "$0")/.."
./Scripts/build_app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Rivulet.app/Contents/Info.plist)
ZIP="build/Rivulet-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Rivulet.app "$ZIP"
SUM=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "$SUM  Rivulet-$VERSION.zip" > "$ZIP.sha256"
echo "Wrote $ZIP"
echo "sha256 $SUM"
