#!/bin/sh
# Notarizes and staples build/Rivulet.app, then writes build/Rivulet.zip ready to distribute.
# One time setup, using an app specific password from appleid.apple.com:
#   xcrun notarytool store-credentials rivulet-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID
# Then: SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./Scripts/build_app.sh && ./Scripts/notarize.sh
set -eu
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-rivulet-notary}"
APP="build/Rivulet.app"

ditto -c -k --keepParent "$APP" build/Rivulet-notarize.zip
xcrun notarytool submit build/Rivulet-notarize.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f build/Rivulet-notarize.zip build/Rivulet.zip
ditto -c -k --keepParent "$APP" build/Rivulet.zip
spctl --assess --type execute --verbose "$APP"
echo "Ready: build/Rivulet.zip"
