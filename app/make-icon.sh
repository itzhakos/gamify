#!/bin/sh
# Builds build/AppIcon.icns from icon/AppIcon.png (1024x1024). Used by build.sh.
set -eu
cd "$(dirname "$0")"
SRC="${1:-icon/AppIcon.png}"
OUT="${2:-build/AppIcon.icns}"
[ -f "$SRC" ] || { echo "make-icon: no $SRC" >&2; exit 1; }
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET" "$(dirname "$OUT")"
for size in 16 32 128 256 512; do
  sips -z $size $size "$SRC" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$SRC" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$OUT"
rm -rf "$(dirname "$SET")"
echo "made $OUT"
