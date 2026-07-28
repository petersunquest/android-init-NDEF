#!/usr/bin/env bash
# Smoke-test beamio.app/app OTA artifacts for CashTrees iOS embedded PWA update daemon.
set -euo pipefail

BASE="${BEAMIO_PWA_OTA_BASE:-https://beamio.app/app}"
MANIFEST_URL="${BASE%/}/update.json"
BUNDLE_ZIP="${1:-}"

echo "==> OTA manifest: $MANIFEST_URL"
MANIFEST="$(curl -fsS "$MANIFEST_URL")"
echo "$MANIFEST"

VER="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['ver'])" "$MANIFEST")"
FILE="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['filename'])" "$MANIFEST")"
ZIP_URL="${BASE%/}/${FILE}"

echo "==> Remote version: $VER"
echo "==> Remote zip: $ZIP_URL"

HTTP_CODE="$(curl -fsSI "$ZIP_URL" | awk 'NR==1{print $2}')"
test "$HTTP_CODE" = "200"

TMP_ZIP="$(mktemp /tmp/silentpass-ota-smoke.XXXXXX.zip)"
curl -fsSL "$ZIP_URL" -o "$TMP_ZIP"
ls -lh "$TMP_ZIP"

echo "==> Zip update.json"
unzip -p "$TMP_ZIP" update.json

echo "==> Zip index.html asset paths (expect /static/, not /app/static/)"
unzip -p "$TMP_ZIP" index.html | grep -Eo 'src="[^"]+"' | head -3

if [[ -n "$BUNDLE_ZIP" && -f "$BUNDLE_ZIP" ]]; then
  echo "==> Bundled bootstrap update.json"
  unzip -p "$BUNDLE_ZIP" update.json || true
  BUNDLE_VER="$(unzip -p "$BUNDLE_ZIP" update.json | python3 -c "import json,sys; print(json.load(sys.stdin)['ver'])")"
  echo "==> Bundled version: $BUNDLE_VER"
  python3 - <<PY
import sys
def parse(v):
    return [int(x) for x in v.split('.')]
b, r = parse("$BUNDLE_VER"), parse("$VER")
newer = r > b
print(f"Remote newer than bundled: {newer}")
sys.exit(0 if newer else 2)
PY
fi

rm -f "$TMP_ZIP"
echo "✅ OTA smoke test passed"
