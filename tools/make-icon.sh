#!/bin/bash
# Regenerates docs/icon.png and Resources/AppIcon.icns from tools/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

swift tools/make-icon.swift docs/icon.png

ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET" Resources
for size in 16 32 128 256 512; do
    sips -z $size $size docs/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double docs/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
