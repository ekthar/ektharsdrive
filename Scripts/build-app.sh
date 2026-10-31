#!/bin/bash
# Builds "Ekthar Drive.app" from the Swift package.
#   CONFIG=release|debug   (default release)
#   ARCHS="arm64"          (use "arm64 x86_64" for a universal binary)
#   VERSION=1.1.0
#   SIGN_IDENTITY="-"      (ad-hoc). Use "Developer ID Application: Name (TEAMID)" for distribution.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
ARCHS="${ARCHS:-arm64}"
VERSION="${VERSION:-1.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
if [ -z "${SIGN_IDENTITY:-}" ] && security find-certificate -c "Ekthar Drive Local" >/dev/null 2>&1; then
  SIGN_IDENTITY="Ekthar Drive Local"   # stable local identity: Keychain "Always Allow" survives rebuilds
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP_NAME="Ekthar Drive"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

ARCH_ARGS=()
for a in $ARCHS; do ARCH_ARGS+=(--arch "$a"); done

cd "$ROOT"
echo "==> swift build ($CONFIG, $ARCHS)"
swift build --disable-sandbox -c "$CONFIG" "${ARCH_ARGS[@]}" --product EktharDrive
BIN_DIR="$(swift build --disable-sandbox -c "$CONFIG" "${ARCH_ARGS[@]}" --show-bin-path)"

mkdir -p "$BUILD_DIR"
if [ -d "$APP" ]; then
  mkdir -p "$BUILD_DIR/previous"
  mv "$APP" "$BUILD_DIR/previous/$APP_NAME $(date +%Y%m%d-%H%M%S).app"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/EktharDrive" "$APP/Contents/MacOS/EktharDrive"

echo "==> icon"
ICONSET="$BUILD_DIR/AppIcon.iconset"
swift "$ROOT/Scripts/make-icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.ekthar.drive</string>
  <key>CFBundleExecutable</key><string>EktharDrive</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Ekthar Drive. Uses rclone (MIT).</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

echo "==> codesign ($SIGN_IDENTITY)"
TIMESTAMP_FLAG="--timestamp=none"
[[ "$SIGN_IDENTITY" == Developer\ ID* ]] && TIMESTAMP_FLAG="--timestamp"
codesign --force --options runtime $TIMESTAMP_FLAG --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "==> built $APP"
