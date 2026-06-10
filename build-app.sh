#!/bin/bash
# Builds StorageBar.app from the Swift package.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="StorageBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/StorageBar" "$APP/Contents/MacOS/StorageBar"
cp "Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc sign so macOS treats the bundle as a stable identity
codesign --force --sign - "$APP"

echo "Built $APP — run with: open $APP"
