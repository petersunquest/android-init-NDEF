#!/usr/bin/env bash
# Sync live Embedded OTA zip into Consumer native shells (bootstrap bundle).
# Source of truth: https://beamio.app/app/update.json + matching SilentPassUI-{ver}.zip
#
# Usage: ./scripts/syncEmbeddedPwaZipToNativeShells.sh
# Optional: VERSION=0.52.222 (skip live update.json)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PUBLIC_BASE="${PUBLIC_APP_BASE_URL:-https://beamio.app/app}"
UPDATE_URL="${PUBLIC_UPDATE_JSON_URL:-${PUBLIC_BASE}/update.json}"

IOS_DIR="$REPO_ROOT/src/CashTrees_iOS/CashTrees_iOS/CashTrees_iOS"
ANDROID_ASSETS="$REPO_ROOT/src/CaehTrees/app/src/main/assets"

if [[ -n "${VERSION:-}" ]]; then
	VER="$VERSION"
	ZIP_NAME="SilentPassUI-${VER}.zip"
else
	echo "==> Fetch $UPDATE_URL"
	LIVE_JSON="$(curl -fsS "$UPDATE_URL")"
	VER="$(node -e "const j=JSON.parse(process.argv[1]); if(!j.ver) process.exit(2); process.stdout.write(String(j.ver))" "$LIVE_JSON")"
	ZIP_NAME="$(node -e "const j=JSON.parse(process.argv[1]); if(!j.filename) process.exit(2); process.stdout.write(String(j.filename))" "$LIVE_JSON")"
fi

ZIP_URL="${PUBLIC_BASE}/${ZIP_NAME}"
TMP_ZIP="$(mktemp -t SilentPassUI-XXXXXX.zip)"
cleanup() { rm -f "$TMP_ZIP"; }
trap cleanup EXIT

echo "==> Download $ZIP_URL"
curl -fsSL -o "$TMP_ZIP" "$ZIP_URL"
# Sanity: must contain index.html + update.json (match Name column, not path noise)
if ! unzip -Z1 "$TMP_ZIP" 2>/dev/null | grep -qx 'index.html'; then
	if ! unzip -l "$TMP_ZIP" | awk '{print $NF}' | grep -qx 'index.html'; then
		echo "Zip missing index.html" >&2
		exit 1
	fi
fi
if ! unzip -Z1 "$TMP_ZIP" 2>/dev/null | grep -qx 'update.json'; then
	if ! unzip -l "$TMP_ZIP" | awk '{print $NF}' | grep -qx 'update.json'; then
		echo "Zip missing update.json" >&2
		exit 1
	fi
fi

INNER_VER="$(unzip -p "$TMP_ZIP" update.json | node -e "let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{const j=JSON.parse(s);process.stdout.write(j.ver||'')})")"
if [[ -n "$INNER_VER" && "$INNER_VER" != "$VER" ]]; then
	echo "WARN: update.json inside zip ver=${INNER_VER} != manifest ver=${VER}" >&2
fi

mkdir -p "$IOS_DIR" "$ANDROID_ASSETS"
cp "$TMP_ZIP" "$IOS_DIR/SilentPassUI.zip"
cp "$TMP_ZIP" "$IOS_DIR/SilentPassUI-${VER}.zip"
cp "$TMP_ZIP" "$ANDROID_ASSETS/SilentPassUI.zip"

echo "==> Synced Embedded bootstrap SilentPassUI.zip ver=${VER}"
echo "    iOS:      $IOS_DIR/SilentPassUI.zip"
echo "    Android:  $ANDROID_ASSETS/SilentPassUI.zip"
echo "==> Next: bump native app version + archive/upload (App Store / Play)."
