#!/usr/bin/env bash
# Deploy src/SilentPassUI build to https://beamio.app/app/ via appTemp staging.
# Does not touch homepage files at the site root.
# See .cursor/rules/beamio-pwa-deploy-app-dirs.mdc

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PWA_DIR="$REPO_ROOT/src/SilentPassUI"

BEAMIO_DEPLOY_HOST="${BEAMIO_DEPLOY_HOST:-conet.network}"
BEAMIO_WEB_ROOT="${BEAMIO_WEB_ROOT:-/var/www/beamio.app}"
SSH_TARGET="${BEAMIO_DEPLOY_USER:+${BEAMIO_DEPLOY_USER}@}${BEAMIO_DEPLOY_HOST}"

SKIP_BUILD=0
DRY_RUN=0
SKIP_PROMOTE=0

usage() {
	cat <<'EOF'
Usage: scripts/deployBeamioPwa.sh [options]

Build SilentPassUI and publish to /var/www/beamio.app/app/:
  1) rsync build -> appTemp/ (staging)
  2) rsync appTemp/ -> app/ (live PWA)

Options:
  --skip-build      Use existing src/SilentPassUI/build without npm run build
  --skip-promote    Only update appTemp/, do not copy to app/
  --dry-run         Pass --dry-run to rsync
  -h, --help        Show this help

Environment:
  BEAMIO_DEPLOY_HOST   SSH host (default: conet.network)
  BEAMIO_DEPLOY_USER   SSH user (optional)
  BEAMIO_WEB_ROOT      Remote web root (default: /var/www/beamio.app)
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-build) SKIP_BUILD=1; shift ;;
		--skip-promote) SKIP_PROMOTE=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

RSYNC_DELETE=(--delete)
RSYNC_EXTRA=()
if [[ "$DRY_RUN" -eq 1 ]]; then
	RSYNC_EXTRA+=(--dry-run)
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
	echo "==> Building SilentPassUI in $PWA_DIR"
	( cd "$PWA_DIR" && npm run build )
fi

BUILD_DIR="$PWA_DIR/build"
if [[ ! -f "$BUILD_DIR/index.html" ]]; then
	echo "Missing $BUILD_DIR/index.html — run npm run build in src/SilentPassUI first." >&2
	exit 1
fi

REMOTE_APP_TEMP="${SSH_TARGET}:${BEAMIO_WEB_ROOT}/appTemp/"
REMOTE_APP="${SSH_TARGET}:${BEAMIO_WEB_ROOT}/app/"

echo "==> Rsync PWA build -> appTemp/"
rsync -av "${RSYNC_DELETE[@]}" "${RSYNC_EXTRA[@]}" "$BUILD_DIR/" "$REMOTE_APP_TEMP"

if [[ "$SKIP_PROMOTE" -eq 1 ]]; then
	echo "==> Skipped promote to app/ (--skip-promote)"
	exit 0
fi

echo "==> Promote appTemp/ -> app/"
if [[ "$DRY_RUN" -eq 1 ]]; then
	rsync -av --dry-run "${RSYNC_DELETE[@]}" \
		"${SSH_TARGET}:${BEAMIO_WEB_ROOT}/appTemp/" "$REMOTE_APP"
else
	ssh "$SSH_TARGET" "rsync -a --delete '${BEAMIO_WEB_ROOT}/appTemp/' '${BEAMIO_WEB_ROOT}/app/'"
fi

echo "==> Done. Spot-check:"
echo "    https://beamio.app/app/"
