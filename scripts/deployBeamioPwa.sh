#!/usr/bin/env bash
# Deploy the SilentPassUI PWA to https://beamio.app/app/ ONLY (never rsync --delete to /var/www/beamio.app/ root).
# Builds on conet.network from /var/www/beamio.app/SilentPassUI (server git clone; do not delete via homepage rsync).
#
# Embedded native OTA (CashTrees iOS / CaehTrees Android WebView shell) REQUIRES:
#   https://beamio.app/app/update.json  →  {"ver":"<semver>","filename":"SilentPassUI-<semver>.zip"}
#   https://beamio.app/app/SilentPassUI-<semver>.zip
# Native shells poll update.json; "New version available" banner is NOT Service Worker.
# See .cursor/rules/beamio-pwa-deploy-app-dirs.mdc

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PWA_DIR="$REPO_ROOT/src/SilentPassUI"

REMOTE_BUILD_HOST="${REMOTE_BUILD_HOST:-conet.network}"
REMOTE_BUILD_DIR="${REMOTE_BUILD_DIR:-/var/www/beamio.app/SilentPassUI}"
REMOTE_APP_DIR="${REMOTE_APP_DIR:-/var/www/beamio.app/app/}"
PUBLIC_UPDATE_JSON_URL="${PUBLIC_UPDATE_JSON_URL:-https://beamio.app/app/update.json}"
PUBLIC_APP_BASE_URL="${PUBLIC_APP_BASE_URL:-https://beamio.app/app}"

SKIP_VERSION_BUMP=0
DRY_RUN=0

usage() {
	cat <<'EOF'
Usage: scripts/deployBeamioPwa.sh [options]

Deploy SilentPassUI PWA:
  1) bump patch version in src/SilentPassUI/package.json + sync public/update.json (commit + push)
  2) ssh conet.network
  3) cd /var/www/beamio.app/SilentPassUI
  4) git fetch origin cashtree && git reset --hard origin/cashtree && npm install --legacy-peer-deps && npm run build
  5) rsync build/ -> /var/www/beamio.app/app/  (EXCLUDE SilentPassUI-*.zip so OTA zips survive --delete)
  6) PUBLIC_URL=/ rebuild, pack SilentPassUI-{version}.zip + update.json -> /var/www/beamio.app/app/
     (native embedded PWA OTA; CashTreesIOS/Android applyEmbeddedPwaUpdate)
  7) smoke: live update.json.ver == package.json version AND zip HTTP 200

Options:
  --skip-version-bump  Skip local package.json patch bump (not recommended)
  --dry-run            Print planned steps without changing files or publishing
  -h, --help           Show this help

Environment:
  REMOTE_BUILD_HOST  SSH host used for build (default: conet.network)
  REMOTE_BUILD_DIR   Remote SilentPassUI repo (default: /var/www/beamio.app/SilentPassUI)
  REMOTE_APP_DIR     Final rsync target on build host (default: /var/www/beamio.app/app/)
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-version-bump) SKIP_VERSION_BUMP=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

if [[ ! -f "$PWA_DIR/package.json" ]]; then
	echo "Missing SilentPassUI package.json: $PWA_DIR/package.json" >&2
	exit 1
fi

# Keep CRA public/update.json aligned with package.json so a bare rsync cannot
# resurrect a stale OTA manifest (historical bug: public/update.json stuck at 0.39.7).
sync_public_update_json() {
	local version="$1"
	local zip_name="SilentPassUI-${version}.zip"
	mkdir -p "$PWA_DIR/public"
	printf '{\n\t"ver": "%s",\n\t"filename": "%s"\n}\n' "$version" "$zip_name" > "$PWA_DIR/public/update.json"
	echo "==> Synced public/update.json -> ver=${version} filename=${zip_name}"
}

bump_pwa_version() {
	local old_version new_version

	cd "$PWA_DIR"

	if ! git diff --quiet || ! git diff --cached --quiet; then
		echo "SilentPassUI has uncommitted changes. Commit or stash before deploy." >&2
		exit 1
	fi

	old_version="$(node -p "require('./package.json').version")"
	npm version patch --no-git-tag-version >/dev/null
	new_version="$(node -p "require('./package.json').version")"

	echo "==> Bumped SilentPassUI version: ${old_version} -> ${new_version}"
	sync_public_update_json "$new_version"

	git add package.json package-lock.json public/update.json
	git commit -m "chore(pwa): bump version to ${new_version}"
	git push
}

smoke_embedded_ota() {
	local expected_version="$1"
	local zip_name="SilentPassUI-${expected_version}.zip"
	local live_json live_ver live_filename http_code

	echo "==> Smoke: ${PUBLIC_UPDATE_JSON_URL}"
	live_json="$(curl -fsS "$PUBLIC_UPDATE_JSON_URL" || true)"
	if [[ -z "$live_json" ]]; then
		echo "OTA smoke FAILED: empty/unreachable update.json" >&2
		return 1
	fi
	live_ver="$(node -e "const j=JSON.parse(process.argv[1]); if(!j.ver) process.exit(2); process.stdout.write(String(j.ver))" "$live_json" 2>/dev/null || true)"
	live_filename="$(node -e "const j=JSON.parse(process.argv[1]); if(!j.filename) process.exit(2); process.stdout.write(String(j.filename))" "$live_json" 2>/dev/null || true)"
	if [[ -z "$live_ver" || -z "$live_filename" ]]; then
		echo "OTA smoke FAILED: cannot parse update.json: $live_json" >&2
		return 1
	fi

	if [[ "$live_ver" != "$expected_version" ]]; then
		echo "OTA smoke FAILED: update.json ver=${live_ver} != package.json ${expected_version}" >&2
		echo "Body: $live_json" >&2
		return 1
	fi
	if [[ "$live_filename" != "$zip_name" ]]; then
		echo "OTA smoke FAILED: update.json filename=${live_filename} != ${zip_name}" >&2
		echo "Body: $live_json" >&2
		return 1
	fi

	http_code="$(curl -fsSI -o /dev/null -w '%{http_code}' "${PUBLIC_APP_BASE_URL}/${zip_name}" || true)"
	if [[ "$http_code" != "200" ]]; then
		echo "OTA smoke FAILED: ${PUBLIC_APP_BASE_URL}/${zip_name} HTTP ${http_code} (expected 200)" >&2
		return 1
	fi

	echo "==> OTA smoke OK: ver=${live_ver} zip=${live_filename} HTTP ${http_code}"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
	echo "==> Dry run: would deploy SilentPassUI"
	if [[ "$SKIP_VERSION_BUMP" -eq 0 ]]; then
		echo "    1) npm version patch + sync public/update.json in $PWA_DIR (commit + push)"
	fi
	echo "    2) ssh $REMOTE_BUILD_HOST 'cd $REMOTE_BUILD_DIR && git fetch origin cashtree && git reset --hard origin/cashtree && npm install --legacy-peer-deps && npm run build'"
	echo "    3) rsync -av --delete --exclude 'SilentPassUI-*.zip' build/ $REMOTE_APP_DIR"
	echo "    4) PUBLIC_URL=/ npm run build; zip SilentPassUI-{ver}.zip; publish update.json"
	echo "    5) smoke curl $PUBLIC_UPDATE_JSON_URL + zip"
	exit 0
fi

if [[ "$SKIP_VERSION_BUMP" -eq 0 ]]; then
	bump_pwa_version
else
	echo "==> Skipping version bump (--skip-version-bump)"
	# Still align public/update.json with current package.json before push is caller's job;
	# remote build uses whatever is on cashtree.
fi

EXPECTED_VERSION="$(node -p "require('${PWA_DIR}/package.json').version")"

echo "==> Remote build and deploy SilentPassUI (expected OTA ver=${EXPECTED_VERSION})"
ssh "$REMOTE_BUILD_HOST" "set -euo pipefail
pack_embedded_ota_zip() {
  local src_dir=\"\$1\"
  local out_zip=\"\$2\"
  if command -v zip >/dev/null 2>&1; then
    (
      cd \"\$src_dir\"
      zip -qr \"\$out_zip\" . -x '*.DS_Store' -x '__MACOSX/*' -x '**/__MACOSX/*'
    )
    return 0
  fi
  python3 - \"\$src_dir\" \"\$out_zip\" <<'PY'
import sys, zipfile
from pathlib import Path
src = Path(sys.argv[1])
out = Path(sys.argv[2])
with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
    for path in src.rglob('*'):
        if not path.is_file():
            continue
        rel = path.relative_to(src).as_posix()
        if rel.startswith('__MACOSX/') or path.name == '.DS_Store':
            continue
        zf.write(path, rel)
PY
}
cd '$REMOTE_BUILD_DIR'
git fetch origin cashtree
git reset --hard origin/cashtree
npm install --legacy-peer-deps
npm run build
test -f build/index.html
# Preserve prior SilentPassUI-*.zip during --delete; OTA step replaces/adds current zip.
# Bare rsync without this exclude historically wiped all OTA zips and left stale update.json.
rsync -av --delete --exclude 'SilentPassUI-*.zip' build/ '$REMOTE_APP_DIR'
VERSION=\$(node -p \"require('./package.json').version\")
ZIP_NAME=\"SilentPassUI-\${VERSION}.zip\"
echo \"==> Native embedded OTA pack (PUBLIC_URL=/): \${ZIP_NAME}\"
PUBLIC_URL=/ npm run build
test -f build/index.html
printf '{\"ver\":\"%s\",\"filename\":\"%s\"}\\n' \"\$VERSION\" \"\$ZIP_NAME\" > build/update.json
# Also write into REMOTE_BUILD_DIR/public so next accidental bare rsync is less wrong
printf '{\"ver\":\"%s\",\"filename\":\"%s\"}\\n' \"\$VERSION\" \"\$ZIP_NAME\" > public/update.json
TMP_ZIP=\"\$(mktemp /tmp/silentpass-ota.XXXXXX.zip)\"
pack_embedded_ota_zip build \"\$TMP_ZIP\"
test -s \"\$TMP_ZIP\"
cp \"\$TMP_ZIP\" '${REMOTE_APP_DIR}'\"\${ZIP_NAME}\"
cp build/update.json '${REMOTE_APP_DIR}update.json'
chmod 644 '${REMOTE_APP_DIR}update.json' '${REMOTE_APP_DIR}'\"\${ZIP_NAME}\"
rm -f \"\$TMP_ZIP\"
# Assert on-disk before returning
test -f '${REMOTE_APP_DIR}update.json'
test -s '${REMOTE_APP_DIR}'\"\${ZIP_NAME}\"
ON_DISK_VER=\$(node -e \"const fs=require('fs'); const j=JSON.parse(fs.readFileSync('${REMOTE_APP_DIR}update.json','utf8')); if(j.ver!==process.argv[1]||j.filename!==process.argv[2]){console.error(j); process.exit(1)}\" \"\$VERSION\" \"\$ZIP_NAME\")
ls -lh '${REMOTE_APP_DIR}update.json' '${REMOTE_APP_DIR}'\"\${ZIP_NAME}\"
echo \"==> On-disk OTA OK ver=\${VERSION} zip=\${ZIP_NAME}\"
"

# CDN / nginx may need a moment; retry smoke briefly
smoke_ok=0
for i in 1 2 3 4 5; do
	if smoke_embedded_ota "$EXPECTED_VERSION"; then
		smoke_ok=1
		break
	fi
	echo "==> Smoke retry ${i}/5 in 3s..."
	sleep 3
done
if [[ "$smoke_ok" -ne 1 ]]; then
	echo "Deploy finished remote steps but live OTA smoke failed." >&2
	exit 1
fi

echo "==> Done. Spot-check:"
echo "    https://beamio.app/app/"
echo "    https://beamio.app/app/update.json  (must be ver=${EXPECTED_VERSION})"
echo "    https://beamio.app/app/SilentPassUI-${EXPECTED_VERSION}.zip"
