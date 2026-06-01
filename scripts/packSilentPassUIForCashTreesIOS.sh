#!/usr/bin/env bash
# Build SilentPassUI for root-path local serving in CashTrees_iOS WKWebView (cashtrees-local://localhost/).
# App bundle SilentPassUI.zip MUST match the OTA artifact SilentPassUI-{version}.zip (PUBLIC_URL=/).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPUI="$ROOT/src/SilentPassUI"
IOS_DIR="$ROOT/src/CashTrees_iOS/CashTrees_iOS/CashTrees_iOS"
OUT_ZIP="$IOS_DIR/SilentPassUI.zip"

echo "==> Building SilentPassUI with PUBLIC_URL=/ (root asset paths for embedded scheme handler)"
cd "$SPUI"
npm install
PUBLIC_URL=/ npm run build

VERSION="$(node -p "require('./package.json').version")"
ZIP_NAME="SilentPassUI-${VERSION}.zip"
OTA_ZIP="$IOS_DIR/${ZIP_NAME}"

echo "==> Writing build/update.json (ver=${VERSION}, filename=${ZIP_NAME})"
printf '{"ver":"%s","filename":"%s"}\n' "$VERSION" "$ZIP_NAME" > build/update.json

echo "==> Packing ${ZIP_NAME} (OTA + app bootstrap; identical artifacts)"
rm -f "$OUT_ZIP" "$OTA_ZIP"
(
  cd build
  zip -r "$OTA_ZIP" . \
    -x "*.DS_Store" \
    -x "__MACOSX/*" \
    -x "**/__MACOSX/*"
)
cp "$OTA_ZIP" "$OUT_ZIP"

echo "✅ Wrote $OUT_ZIP (copy of ${ZIP_NAME})"
ls -lh "$OUT_ZIP" "$OTA_ZIP"
