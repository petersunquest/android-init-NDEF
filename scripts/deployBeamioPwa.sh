#!/usr/bin/env bash
# Deploy the SilentPassUI PWA to https://beamio.app/app/.
# Bumps src/SilentPassUI/package.json patch version locally before each deploy.
# Builds on conet.network from /var/www/beamio.app/SilentPassUI,
# then publishes to /var/www/beamio.app/app/ on the same host.
# See .cursor/rules/beamio-pwa-deploy-app-dirs.mdc

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PWA_DIR="$REPO_ROOT/src/SilentPassUI"

REMOTE_BUILD_HOST="${REMOTE_BUILD_HOST:-conet.network}"
REMOTE_BUILD_DIR="${REMOTE_BUILD_DIR:-/var/www/beamio.app/SilentPassUI}"
REMOTE_APP_DIR="${REMOTE_APP_DIR:-/var/www/beamio.app/app/}"

SKIP_VERSION_BUMP=0
DRY_RUN=0

usage() {
	cat <<'EOF'
Usage: scripts/deployBeamioPwa.sh [options]

Deploy SilentPassUI PWA:
  1) bump patch version in src/SilentPassUI/package.json (commit + push)
  2) ssh conet.network
  3) cd /var/www/beamio.app/SilentPassUI
  4) git fetch origin cashtree && git reset --hard origin/cashtree && npm install && npm run build
  5) rsync build/ -> /var/www/beamio.app/app/
  6) PUBLIC_URL=/ rebuild, pack SilentPassUI-{version}.zip + update.json -> /var/www/beamio.app/app/
     (iOS CashTrees embedded PWA OTA; see CashTreesPWAUpdateDaemon)

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

	git add package.json package-lock.json
	git commit -m "chore(pwa): bump version to ${new_version}"
	git push
}

if [[ "$DRY_RUN" -eq 1 ]]; then
	echo "==> Dry run: would deploy SilentPassUI"
	if [[ "$SKIP_VERSION_BUMP" -eq 0 ]]; then
		echo "    1) npm version patch in $PWA_DIR (commit + push)"
	fi
	echo "    2) ssh $REMOTE_BUILD_HOST 'cd $REMOTE_BUILD_DIR && git fetch origin cashtree && git reset --hard origin/cashtree && npm install && npm run build'"
	echo "    3) rsync -av --delete build/ $REMOTE_APP_DIR"
	echo "    4) PUBLIC_URL=/ npm run build; zip SilentPassUI-{ver}.zip; publish update.json to $REMOTE_APP_DIR"
	exit 0
fi

if [[ "$SKIP_VERSION_BUMP" -eq 0 ]]; then
	bump_pwa_version
else
	echo "==> Skipping version bump (--skip-version-bump)"
fi

echo "==> Remote build and deploy SilentPassUI"
ssh "$REMOTE_BUILD_HOST" "set -euo pipefail
cd '$REMOTE_BUILD_DIR'
git fetch origin cashtree
git reset --hard origin/cashtree
npm install
npm run build
test -f build/index.html
rsync -av --delete build/ '$REMOTE_APP_DIR'
VERSION=\$(node -p \"require('./package.json').version\")
ZIP_NAME=\"SilentPassUI-\${VERSION}.zip\"
echo \"==> iOS embedded OTA pack (PUBLIC_URL=/): \${ZIP_NAME}\"
PUBLIC_URL=/ npm run build
test -f build/index.html
printf '{\"ver\":\"%s\",\"filename\":\"%s\"}\\n' \"\$VERSION\" \"\$ZIP_NAME\" > build/update.json
TMP_ZIP=\"\$(mktemp /tmp/silentpass-ota.XXXXXX.zip)\"
(
  cd build
  zip -qr \"\$TMP_ZIP\" . -x '*.DS_Store' -x '__MACOSX/*' -x '**/__MACOSX/*'
)
cp \"\$TMP_ZIP\" '${REMOTE_APP_DIR}'\"\${ZIP_NAME}\"
cp build/update.json '${REMOTE_APP_DIR}update.json'
rm -f \"\$TMP_ZIP\"
ls -lh '${REMOTE_APP_DIR}update.json' '${REMOTE_APP_DIR}'\"\${ZIP_NAME}\"
"

echo "==> Done. Spot-check:"
echo "    https://beamio.app/app/"
echo "    https://beamio.app/app/update.json"
