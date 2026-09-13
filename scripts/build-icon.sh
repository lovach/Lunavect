#!/bin/bash
# Builds Sources/Weekleft/Resources/LunavectTide.icns from the selected design SVG.
# selection.json is the source of truth. Tide already contains macOS icon margins.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-}"
OUT="$ROOT/Sources/Weekleft/Resources/LunavectTide.icns"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Export tooling only; the app and CI consume the committed PNG/ICNS resources.
if [ ! -d "$ROOT/scripts/artwork/node_modules/@resvg/resvg-js" ]; then
  npm ci --prefix "$ROOT/scripts/artwork" --ignore-scripts --no-audit --no-fund
fi
node "$ROOT/scripts/artwork/export.cjs" "$SRC" "$TMP"
mkdir -p "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d "$TMP/icon_1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$OUT"
cp "$TMP/icon_1024.png" "$ROOT/design/selected/lunavect-appicon-1024.png"
cp "$TMP/LunavectMark.png" "$ROOT/Sources/Weekleft/Resources/LunavectMark.png"
cp "$TMP/LunavectMarkLeft.png" "$ROOT/Sources/Weekleft/Resources/LunavectMarkLeft.png"
cp "$TMP/LunavectMarkRight.png" "$ROOT/Sources/Weekleft/Resources/LunavectMarkRight.png"
echo "written $OUT"
