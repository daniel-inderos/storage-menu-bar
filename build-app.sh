#!/bin/bash
# Builds StorageBar.app from the Swift package.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64 --arch x86_64
PRODUCT_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

APP="StorageBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCT_DIR/StorageBar" "$APP/Contents/MacOS/StorageBar"
cp "Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${APP_VERSION:-}" ]]; then
  VERSION="${APP_VERSION#v}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
  echo "Stamped version $VERSION"
fi

ARCHS="$(lipo -archs "$APP/Contents/MacOS/StorageBar")"
if [[ " $ARCHS " != *" arm64 "* || " $ARCHS " != *" x86_64 "* ]]; then
  echo "Expected universal binary, got: $ARCHS" >&2
  exit 1
fi

# Sign the bundle. Default is ad-hoc (stable local identity, no Apple account).
# Set CODESIGN_IDENTITY to a "Developer ID Application: ..." identity to produce
# a distributable build; hardened runtime + timestamp are notarization requirements.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
fi

echo "Built $APP — run with: open $APP"
