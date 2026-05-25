#!/usr/bin/env bash
# Deploy src/bizSite build to https://biz.beamio.app/biz/
# Syncs to bizTemp/ then biz/ (same pattern as PWA app/appTemp staging).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIZ_DIR="$REPO_ROOT/src/bizSite"

BEAMIO_DEPLOY_HOST="${BEAMIO_DEPLOY_HOST:-conet.network}"
BEAMIO_BIZ_ROOT="${BEAMIO_BIZ_ROOT:-/var/www/biz.beamio.app}"
REMOTE="${BEAMIO_DEPLOY_USER:+${BEAMIO_DEPLOY_USER}@}${BEAMIO_DEPLOY_HOST}:${BEAMIO_BIZ_ROOT}"

SKIP_BUILD=0
DRY_RUN=0

usage() {
	cat <<'EOF'
Usage: scripts/deployBeamioBizSite.sh [options]

Deploy bizSite (Merchant OS) to biz.beamio.app/biz/ and bizTemp/.

Options:
  --skip-build   Use existing src/bizSite/build without npm run build
  --dry-run      Pass --dry-run to rsync
  -h, --help     Show this help

Environment:
  BEAMIO_DEPLOY_HOST   SSH host (default: conet.network)
  BEAMIO_DEPLOY_USER   SSH user (optional)
  BEAMIO_BIZ_ROOT      Remote root (default: /var/www/biz.beamio.app)
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

if [[ "$SKIP_BUILD" -eq 0 ]]; then
	echo "==> Building bizSite in $BIZ_DIR"
	( cd "$BIZ_DIR" && npm run build )
fi

BUILD_DIR="$BIZ_DIR/build"
if [[ ! -f "$BUILD_DIR/index.html" ]]; then
	echo "Missing $BUILD_DIR/index.html — run npm run build in src/bizSite first." >&2
	exit 1
fi

RSYNC_FLAGS=(-av --delete)
if [[ "$DRY_RUN" -eq 1 ]]; then
	RSYNC_FLAGS+=("--dry-run")
fi

for target in bizTemp biz; do
	echo "==> Rsync bizSite -> ${REMOTE}/${target}/"
	rsync "${RSYNC_FLAGS[@]}" "$BUILD_DIR/" "${REMOTE}/${target}/"
done

echo "==> Done. Spot-check:"
echo "    https://biz.beamio.app/biz/"
echo "    Hard-refresh Merchant OS, then open Redeem Code Distribution — URL should start with https://beamio.app/app-download?target="
