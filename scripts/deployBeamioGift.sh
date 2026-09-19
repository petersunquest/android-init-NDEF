#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIFT_DIR="$ROOT/src/gift"
REMOTE_HOST="${BEAMIO_DEPLOY_HOST:-conet.network}"
WEB_ROOT="${BEAMIO_WEB_ROOT:-/var/www/beamio.app}"
REMOTE="${BEAMIO_DEPLOY_USER:+${BEAMIO_DEPLOY_USER}@}${REMOTE_HOST}:${WEB_ROOT}/gift/"

if [[ "${1:-}" != "--skip-build" ]]; then
  (cd "$GIFT_DIR" && npm run build)
fi

[[ -f "$GIFT_DIR/build/index.html" ]] || {
  echo "Missing $GIFT_DIR/build/index.html" >&2
  exit 1
}

echo "==> Deploying Gift page to ${REMOTE}"
rsync -av --delete "$GIFT_DIR/build/" "$REMOTE"
echo "==> Published https://beamio.app/gift/<cardAddress>"
