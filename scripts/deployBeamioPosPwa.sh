#!/usr/bin/env bash
# Deploy src/posPwa build to https://beamio.app/pos/ via posTemp staging.
# Does not touch /app/ (SilentPassUI) or homepage root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POS_PWA_DIR="$REPO_ROOT/src/posPwa"

BEAMIO_DEPLOY_HOST="${BEAMIO_DEPLOY_HOST:-conet.network}"
BEAMIO_WEB_ROOT="${BEAMIO_WEB_ROOT:-/var/www/beamio.app}"
SSH_TARGET="${BEAMIO_DEPLOY_USER:+${BEAMIO_DEPLOY_USER}@}${BEAMIO_DEPLOY_HOST}"

SKIP_BUILD=0
DRY_RUN=0
SKIP_PROMOTE=0
RSYNC_EXTRA=()

usage() {
	cat <<'EOF'
Usage: scripts/deployBeamioPosPwa.sh [options]

Build posPwa and publish to /var/www/beamio.app/pos/:
  1) rsync dist -> posTemp/ (staging)
  2) rsync posTemp/ -> pos/ (live POS PWA)

Options:
  --skip-build      Use existing src/posPwa/dist without npm run build
  --skip-promote    Only update posTemp/, do not copy to pos/
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
	echo "==> Building posPwa in $POS_PWA_DIR"
	( cd "$POS_PWA_DIR" && npm ci && npm run build )
fi

BUILD_DIR="$POS_PWA_DIR/dist"
if [[ ! -f "$BUILD_DIR/index.html" ]]; then
	echo "Missing $BUILD_DIR/index.html — run npm run build in src/posPwa first." >&2
	exit 1
fi

REMOTE_POS_TEMP="${SSH_TARGET}:${BEAMIO_WEB_ROOT}/posTemp/"
REMOTE_POS="${SSH_TARGET}:${BEAMIO_WEB_ROOT}/pos/"

echo "==> Rsync POS PWA build -> posTemp/"
if [[ ${#RSYNC_EXTRA[@]} -gt 0 ]]; then
	rsync -av "${RSYNC_DELETE[@]}" "${RSYNC_EXTRA[@]}" "$BUILD_DIR/" "$REMOTE_POS_TEMP"
else
	rsync -av "${RSYNC_DELETE[@]}" "$BUILD_DIR/" "$REMOTE_POS_TEMP"
fi

if [[ "$SKIP_PROMOTE" -eq 1 ]]; then
	echo "==> Skipped promote to pos/ (--skip-promote)"
	exit 0
fi

echo "==> Promote posTemp/ -> pos/"
if [[ "$DRY_RUN" -eq 1 ]]; then
	rsync -av --dry-run "${RSYNC_DELETE[@]}" \
		"${SSH_TARGET}:${BEAMIO_WEB_ROOT}/posTemp/" "$REMOTE_POS"
else
	ssh "$SSH_TARGET" "rsync -a --delete '${BEAMIO_WEB_ROOT}/posTemp/' '${BEAMIO_WEB_ROOT}/pos/'"
fi

echo "==> Done. Spot-check:"
echo "    https://beamio.app/pos/"
