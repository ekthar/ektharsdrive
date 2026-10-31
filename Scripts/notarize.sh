#!/bin/bash
# Notarizes and staples the DMG. Requires a Developer ID signed build and a notarytool keychain profile:
#   xcrun notarytool store-credentials ekthar-notary --apple-id you@example.com --team-id TEAMID
#   SIGN_IDENTITY="Developer ID Application: ..." Scripts/build-app.sh && Scripts/make-dmg.sh
#   NOTARY_PROFILE=ekthar-notary Scripts/notarize.sh dist/EktharDrive-1.0.0.dmg
set -euo pipefail
DMG="${1:?usage: notarize.sh <dmg>}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
