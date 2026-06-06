#!/usr/bin/env bash
set -euo pipefail

# Generates an .icns from assets/icon.png (1024x1024) at all macOS sizes.
# Usage: ./assets/make-icns.sh <output.icns>

cd "$(dirname "$0")/.."

SRC="assets/icon.png"
OUT="${1:-build/AppIcon.icns}"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

gen() { sips -z "$2" "$2" "$SRC" --out "$SET/$1" >/dev/null; }
gen icon_16x16.png        16
gen icon_16x16@2x.png     32
gen icon_32x32.png        32
gen icon_32x32@2x.png     64
gen icon_128x128.png     128
gen icon_128x128@2x.png  256
gen icon_256x256.png     256
gen icon_256x256@2x.png  512
gen icon_512x512.png     512
gen icon_512x512@2x.png 1024

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$SET" -o "$OUT"
rm -rf "$(dirname "$SET")"
echo "Wrote $OUT"
