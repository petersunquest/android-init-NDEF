#!/usr/bin/env bash
# Deploy src/posPwa to https://pos.conet.network (root base path, dedicated vhost).
# Staging: /var/www/pos.conet.network/posTemp/ → live: /var/www/pos.conet.network/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POS_PWA_DIR="$REPO_ROOT/src/posPwa"
NGINX_CONF="$REPO_ROOT/scripts/nginx-pos-conet.network.conf"

BEAMIO_DEPLOY_HOST="${BEAMIO_DEPLOY_HOST:-conet.network}"
POS_WEB_ROOT="${POS_WEB_ROOT:-/var/www/pos.conet.network}"
SSH_TARGET="${BEAMIO_DEPLOY_USER:+${BEAMIO_DEPLOY_USER}@}${BEAMIO_DEPLOY_HOST}"

SKIP_BUILD=0
DRY_RUN=0
SKIP_PROMOTE=0
SKIP_NGINX=0
SKIP_CERT=0

usage() {
	cat <<'EOF'
Usage: scripts/deployPosConetNetwork.sh [options]

Build posPwa (base /) and publish to https://pos.conet.network:
  1) POS_PWA_BASE=/ npm run build
  2) rsync dist -> posTemp/ (staging)
  3) rsync posTemp/ -> web root (live)
  4) install nginx vhost (if missing) + expand TLS cert for pos.conet.network

Options:
  --skip-build      Use existing src/posPwa/dist without npm run build
  --skip-promote    Only update posTemp/, do not copy to live root
  --skip-nginx      Do not install or reload nginx config
  --skip-cert       Do not run certbot expand for pos.conet.network
  --dry-run         Pass --dry-run to rsync
  -h, --help        Show this help

Environment:
  BEAMIO_DEPLOY_HOST   SSH host (default: conet.network)
  BEAMIO_DEPLOY_USER   SSH user (optional)
  POS_WEB_ROOT         Remote web root (default: /var/www/pos.conet.network)
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-build) SKIP_BUILD=1; shift ;;
		--skip-promote) SKIP_PROMOTE=1; shift ;;
		--skip-nginx) SKIP_NGINX=1; shift ;;
		--skip-cert) SKIP_CERT=1; shift ;;
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
	echo "==> Building posPwa for pos.conet.network (POS_PWA_BASE=/)"
	( cd "$POS_PWA_DIR" && npm ci && POS_PWA_BASE=/ npm run build )
fi

BUILD_DIR="$POS_PWA_DIR/dist"
if [[ ! -f "$BUILD_DIR/index.html" ]]; then
	echo "Missing $BUILD_DIR/index.html — run build first." >&2
	exit 1
fi

# Guard: pos.conet.network is served at / — assets must not use /pos/ prefix.
if grep -qE 'src="/pos/|href="/pos/' "$BUILD_DIR/index.html"; then
	echo "ERROR: dist/index.html still references /pos/ assets." >&2
	echo "Rebuild with: cd src/posPwa && POS_PWA_BASE=/ npm run build" >&2
	echo "Or run this script without --skip-build." >&2
	exit 1
fi

REMOTE_TEMP="${SSH_TARGET}:${POS_WEB_ROOT}/posTemp/"
REMOTE_LIVE="${SSH_TARGET}:${POS_WEB_ROOT}/"

echo "==> Ensure remote web root exists"
ssh "$SSH_TARGET" "mkdir -p '${POS_WEB_ROOT}/posTemp'"

echo "==> Rsync POS PWA build -> posTemp/"
rsync -av "${RSYNC_DELETE[@]}" ${RSYNC_EXTRA[@]+"${RSYNC_EXTRA[@]}"} "$BUILD_DIR/" "$REMOTE_TEMP"

if [[ "$SKIP_PROMOTE" -eq 1 ]]; then
	echo "==> Skipped promote to live root (--skip-promote)"
else
	echo "==> Promote posTemp/ -> ${POS_WEB_ROOT}/"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		rsync -av --dry-run "${RSYNC_DELETE[@]}" \
			"${SSH_TARGET}:${POS_WEB_ROOT}/posTemp/" "$REMOTE_LIVE"
	else
		ssh "$SSH_TARGET" "rsync -a --delete --exclude 'posTemp/' '${POS_WEB_ROOT}/posTemp/' '${POS_WEB_ROOT}/'"
	fi
fi

if [[ "$SKIP_NGINX" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
	echo "==> Install nginx vhost for pos.conet.network (if needed)"
	scp "$NGINX_CONF" "${SSH_TARGET}:/tmp/nginx-pos-conet.network.conf"
	ssh "$SSH_TARGET" "sudo cp /tmp/nginx-pos-conet.network.conf /etc/nginx/sites-available/pos.conet.network.conf && sudo ln -sf /etc/nginx/sites-available/pos.conet.network.conf /etc/nginx/sites-enabled/pos.conet.network.conf"
fi

if [[ "$SKIP_CERT" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
	echo "==> Ensure TLS cert covers pos.conet.network"
	ssh "$SSH_TARGET" 'bash -s' <<'REMOTE_CERT'
set -euo pipefail
if sudo openssl x509 -in /etc/letsencrypt/live/api.settleonbase.xyz/fullchain.pem -noout -text 2>/dev/null | grep -q "DNS:pos.conet.network"; then
	echo "Cert already includes pos.conet.network"
	exit 0
fi
# Expand shared multi-SAN cert (same cert name used by dashboard.conet.network / verra.network).
sudo certbot certonly --cert-name api.settleonbase.xyz --expand \
	-d alliance.beamio.app -d api.settleonbase.xyz -d apiv4.conet.network -d apps.conet.network \
	-d beamio.app -d beta.conet.network -d beta1.conet.network -d biz.beamio.app \
	-d cashtrees.beamio.app -d conet.network -d conetlabs.org -d dashboard.conet.network \
	-d download.silentpass.io -d frameworkminigame.conet.network -d fx168.silentpass.io \
	-d hooks.conet.network -d ios-test.silentpass.io -d ios-vpn.silentpass.io \
	-d platform.conet.network -d pos.conet.network -d silentpass.io \
	-d test.conet.network -d test.frameworkminigame.conet.network -d verra.network \
	-d vpn-beta.conet.network -d vpn-beta.silentpass.io -d vpn9.conet.network \
	-d www.conet.network -d www.conetlabs.org -d www.silentpass.io \
	--nginx --non-interactive --agree-tos || true
REMOTE_CERT
fi

if [[ "$SKIP_NGINX" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
	echo "==> Reload nginx"
	ssh "$SSH_TARGET" "sudo nginx -t && sudo systemctl reload nginx"
fi

echo "==> Done. Spot-check:"
echo "    https://pos.conet.network/"
echo "    https://pos.conet.network/home"
