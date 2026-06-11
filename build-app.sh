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

ARCHS="$(lipo -archs "$APP/Contents/MacOS/StorageBar")"
if [[ " $ARCHS " != *" arm64 "* || " $ARCHS " != *" x86_64 "* ]]; then
  echo "Expected universal binary, got: $ARCHS" >&2
  exit 1
fi

# Ad-hoc sign so macOS treats the bundle as a stable identity
codesign --force --sign - "$APP"

echo "Built $APP — run with: open $APP"
