#!/bin/bash
# Packages build/Ekthar Drive.app into dist/EktharDrive-<version>.dmg.
# An existing DMG with the same name is kept (renamed), never overwritten.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Ekthar Drive.app"
[ -d "$APP" ] || { echo "Build the app first: Scripts/build-app.sh"; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DIST="$ROOT/dist"
DMG="$DIST/EktharDrive-$VERSION.dmg"
mkdir -p "$DIST"
if [ -f "$DMG" ]; then
  mv "$DMG" "$DIST/EktharDrive-$VERSION.previous-$(date +%Y%m%d-%H%M%S).dmg"
fi

STAGE="$(mktemp -d)"
trap 'rm -r "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/Documentation/INSTALL.md" "$STAGE/Read Me First.md" 2>/dev/null || true

hdiutil create -volname "Ekthar Drive $VERSION" -srcfolder "$STAGE" -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
if [ "${SIGN_IDENTITY:--}" != "-" ]; then codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"; fi
hdiutil verify "$DMG" >/dev/null
shasum -a 256 "$DMG"
echo "==> $DMG"
