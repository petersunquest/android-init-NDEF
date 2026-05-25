#!/usr/bin/env bash
# Deploy src/homepage build to https://beamio.app/ (site root only).
# NEVER sync with --delete over /var/www/beamio.app/ without excluding app/ and appTemp/.
# See .cursor/rules/beamio-pwa-deploy-app-dirs.mdc

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMEPAGE_DIR="$REPO_ROOT/src/homepage"

BEAMIO_DEPLOY_HOST="${BEAMIO_DEPLOY_HOST:-conet.network}"
BEAMIO_WEB_ROOT="${BEAMIO_WEB_ROOT:-/var/www/beamio.app}"
REMOTE="${BEAMIO_DEPLOY_USER:+${BEAMIO_DEPLOY_USER}@}${BEAMIO_DEPLOY_HOST}:${BEAMIO_WEB_ROOT}/"

SKIP_BUILD=0
DRY_RUN=0

usage() {
	cat <<'EOF'
Usage: scripts/deployBeamioHomepage.sh [options]

Deploy homepage (src/homepage) to the beamio.app site root.
Preserves server directories app/ and appTemp/ (Beamio PWA).

Options:
  --skip-build   Use existing src/homepage/build without npm run build
  --dry-run      Pass --dry-run to rsync
  -h, --help     Show this help

Environment:
  BEAMIO_DEPLOY_HOST   SSH host (default: conet.network)
  BEAMIO_DEPLOY_USER   SSH user (optional)
  BEAMIO_WEB_ROOT      Remote web root (default: /var/www/beamio.app)
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-build) SKIP_BUILD=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

# Mandatory excludes — do not remove.
RSYNC_EXCLUDES=(
	--exclude 'app/'
	--exclude 'appTemp/'
)

if [[ "$SKIP_BUILD" -eq 0 ]]; then
	echo "==> Building homepage in $HOMEPAGE_DIR"
	( cd "$HOMEPAGE_DIR" && npm run build )
fi

BUILD_DIR="$HOMEPAGE_DIR/build"
if [[ ! -f "$BUILD_DIR/index.html" ]]; then
	echo "Missing $BUILD_DIR/index.html — run npm run build in src/homepage first." >&2
	exit 1
fi

echo "==> Rsync homepage -> ${REMOTE} (excluding app/, appTemp/)"
if [[ "$DRY_RUN" -eq 1 ]]; then
	rsync -av --delete "${RSYNC_EXCLUDES[@]}" --dry-run "$BUILD_DIR/" "$REMOTE"
else
	rsync -av --delete "${RSYNC_EXCLUDES[@]}" "$BUILD_DIR/" "$REMOTE"
fi

echo "==> Done. Spot-check:"
echo "    https://beamio.app/"
echo "    https://beamio.app/app/  (PWA must still load — not modified by this script)"
