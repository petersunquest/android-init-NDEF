#!/usr/bin/env bash
# Deploy bizSite (Merchant OS) to https://biz.beamio.app/biz/
# Default: remote git pull + build on server, then promote bizTemp/ -> biz/.
# See .cursor/rules/beamio-bizsite-deploy.mdc

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIZ_DIR="$REPO_ROOT/src/bizSite"

BEAMIO_DEPLOY_HOST="${BEAMIO_DEPLOY_HOST:-conet.network}"
BEAMIO_BIZ_ROOT="${BEAMIO_BIZ_ROOT:-/var/www/biz.beamio.app}"
BEAMIO_BIZ_SRC="${BEAMIO_BIZ_SRC:-${BEAMIO_BIZ_ROOT}/SilentPassUI}"
SSH_TARGET="${BEAMIO_DEPLOY_USER:+${BEAMIO_DEPLOY_USER}@}${BEAMIO_DEPLOY_HOST}"

LOCAL_BUILD=0
SKIP_BUILD=0
SKIP_PROMOTE=0
DRY_RUN=0

usage() {
	cat <<'EOF'
Usage: scripts/deployBeamioBizSite.sh [options]

Deploy bizSite (Merchant OS) to biz.beamio.app/biz/.

Default (remote build):
  1) ssh: cd /var/www/biz.beamio.app/SilentPassUI && git pull && npm run build
  2) rsync build/ -> bizTemp/
  3) rsync bizTemp/ -> biz/

Options:
  --local-build   Build in src/bizSite locally, then rsync to remote
  --skip-build    Skip build step (remote: use existing build/ on server)
  --skip-promote  Only update bizTemp/, do not copy to biz/
  --dry-run       Pass --dry-run to rsync (local-build mode only)
  -h, --help      Show this help

Environment:
  BEAMIO_DEPLOY_HOST   SSH host (default: conet.network)
  BEAMIO_DEPLOY_USER   SSH user (optional)
  BEAMIO_BIZ_ROOT      Remote site root (default: /var/www/biz.beamio.app)
  BEAMIO_BIZ_SRC       Remote source clone (default: $BEAMIO_BIZ_ROOT/SilentPassUI)
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--local-build) LOCAL_BUILD=1; shift ;;
		--skip-build) SKIP_BUILD=1; shift ;;
		--skip-promote) SKIP_PROMOTE=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

remote_promote() {
	local remote_cmd="
set -euo pipefail
cd '${BEAMIO_BIZ_SRC}'
if [[ ! -f build/index.html ]]; then
  echo 'Missing build/index.html on server.' >&2
  exit 1
fi
rsync -a --delete build/ '${BEAMIO_BIZ_ROOT}/bizTemp/'
"
	if [[ "$SKIP_PROMOTE" -eq 1 ]]; then
		remote_cmd+="
echo 'Skipped promote to biz/ (--skip-promote)'
"
	else
		remote_cmd+="
rsync -a --delete '${BEAMIO_BIZ_ROOT}/bizTemp/' '${BEAMIO_BIZ_ROOT}/biz/'
"
	fi

	echo "==> Remote promote build/ -> bizTemp/ -> biz/"
	ssh "$SSH_TARGET" "$remote_cmd"
}

if [[ "$LOCAL_BUILD" -eq 1 ]]; then
	if [[ "$SKIP_BUILD" -eq 0 ]]; then
		echo "==> Building bizSite locally in $BIZ_DIR"
		( cd "$BIZ_DIR" && npm run build )
	fi

	BUILD_DIR="$BIZ_DIR/build"
	if [[ ! -f "$BUILD_DIR/index.html" ]]; then
		echo "Missing $BUILD_DIR/index.html — run npm run build in src/bizSite first." >&2
		exit 1
	fi

	RSYNC_FLAGS=(-av --delete)
	if [[ "$DRY_RUN" -eq 1 ]]; then
		RSYNC_FLAGS+=(--dry-run)
	fi

	echo "==> Rsync local build -> ${SSH_TARGET}:${BEAMIO_BIZ_ROOT}/bizTemp/"
	rsync "${RSYNC_FLAGS[@]}" "$BUILD_DIR/" "${SSH_TARGET}:${BEAMIO_BIZ_ROOT}/bizTemp/"

	if [[ "$SKIP_PROMOTE" -eq 1 ]]; then
		echo "==> Skipped promote to biz/ (--skip-promote)"
	else
		echo "==> Promote bizTemp/ -> biz/"
		if [[ "$DRY_RUN" -eq 1 ]]; then
			rsync -av --dry-run --delete \
				"${SSH_TARGET}:${BEAMIO_BIZ_ROOT}/bizTemp/" "${SSH_TARGET}:${BEAMIO_BIZ_ROOT}/biz/"
		else
			ssh "$SSH_TARGET" "rsync -a --delete '${BEAMIO_BIZ_ROOT}/bizTemp/' '${BEAMIO_BIZ_ROOT}/biz/'"
		fi
	fi
else
	if [[ "$SKIP_BUILD" -eq 0 ]]; then
		echo "==> Remote build on ${SSH_TARGET}:${BEAMIO_BIZ_SRC}"
		ssh "$SSH_TARGET" "set -euo pipefail; cd '${BEAMIO_BIZ_SRC}' && git pull && npm run build"
	fi
	remote_promote
fi

echo "==> Done. Spot-check:"
echo "    https://biz.beamio.app/biz/"
