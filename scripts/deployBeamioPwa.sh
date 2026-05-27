#!/usr/bin/env bash
# Deploy the SilentPassUI PWA to https://beamio.app/app/.
# This PWA is built on conet.network from /var/www/beamio.app/SilentPassUI,
# then published to peter@old-conet:/var/www/beamio.app/app/.
# See .cursor/rules/beamio-pwa-deploy-app-dirs.mdc

set -euo pipefail

REMOTE_BUILD_HOST="${REMOTE_BUILD_HOST:-conet.network}"
REMOTE_BUILD_DIR="${REMOTE_BUILD_DIR:-/var/www/beamio.app/SilentPassUI}"
REMOTE_DEPLOY_TARGET="${REMOTE_DEPLOY_TARGET:-peter@old-conet:/var/www/beamio.app/app/}"

DRY_RUN=0

usage() {
	cat <<'EOF'
Usage: scripts/deployBeamioPwa.sh [options]

Deploy SilentPassUI PWA:
  1) ssh conet.network
  2) cd /var/www/beamio.app/SilentPassUI
  3) git pull --ff-only
  4) npm run build
  5) rsync build/ -> peter@old-conet:/var/www/beamio.app/app/

Options:
  --dry-run         Print commands without publishing files
  -h, --help        Show this help

Environment:
  REMOTE_BUILD_HOST     SSH host used for build (default: conet.network)
  REMOTE_BUILD_DIR      Remote SilentPassUI repo (default: /var/www/beamio.app/SilentPassUI)
  REMOTE_DEPLOY_TARGET  Final rsync target (default: peter@old-conet:/var/www/beamio.app/app/)
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--dry-run) DRY_RUN=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

if [[ "$DRY_RUN" -eq 1 ]]; then
	echo "==> Dry run: would deploy SilentPassUI"
	echo "ssh $REMOTE_BUILD_HOST 'cd $REMOTE_BUILD_DIR && git pull --ff-only && npm run build && test -f build/index.html && rsync -av --delete build/ $REMOTE_DEPLOY_TARGET'"
	exit 0
fi

echo "==> Remote build and deploy SilentPassUI"
ssh "$REMOTE_BUILD_HOST" "set -euo pipefail; cd '$REMOTE_BUILD_DIR'; git pull --ff-only; npm run build; test -f build/index.html; rsync -av --delete build/ '$REMOTE_DEPLOY_TARGET'"

echo "==> Done. Spot-check:"
echo "    https://beamio.app/app/"
