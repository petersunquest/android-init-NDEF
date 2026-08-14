#!/usr/bin/env bash
# Deploy CoNET-DLE explorer to https://dle.conet.network on 70.35.205.77.
# Static SPA only. nginx proxies /health /rpc /api/v2/dle to lab archives on TCP 27101.
# Does not restart geth / beacon-chain / validator. Does not copy ~/.master.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXPLORER_DIR="$REPO_ROOT/src/conet-layer2/explorer"

DLE_DEPLOY_HOST="${DLE_DEPLOY_HOST:-70.35.205.77}"
DLE_DEPLOY_USER="${DLE_DEPLOY_USER:-peter}"
DLE_WEB_ROOT="${DLE_WEB_ROOT:-/var/www/dle.conet.network}"
DLE_DOMAIN="${DLE_DOMAIN:-dle.conet.network}"
REMOTE="${DLE_DEPLOY_USER}@${DLE_DEPLOY_HOST}"

SKIP_BUILD=0
SKIP_TLS=0

usage() {
	cat <<'EOF'
Usage: scripts/deployDleExplorer.sh [options]

Build src/conet-layer2/explorer and publish it to dle.conet.network.

Options:
  --skip-build   Use existing explorer/dist
  --skip-tls     Do not run certbot (HTTP bootstrap only)
  -h, --help     Show this help

Environment:
  DLE_DEPLOY_HOST   SSH host (default: 70.35.205.77)
  DLE_DEPLOY_USER   SSH user (default: peter)
  DLE_WEB_ROOT      Remote web root (default: /var/www/dle.conet.network)
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-build) SKIP_BUILD=1; shift ;;
		--skip-tls) SKIP_TLS=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

ssh_remote() {
	ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$REMOTE" "$@"
}

if [[ "$SKIP_BUILD" -eq 0 ]]; then
	echo "==> Building DLE explorer in $EXPLORER_DIR"
	if [[ ! -d "$EXPLORER_DIR/node_modules" ]]; then
		( cd "$EXPLORER_DIR" && npm install )
	fi
	( cd "$REPO_ROOT/src/conet-layer2" && npm run explorer:build )
fi

BUILD_DIR="$EXPLORER_DIR/dist"
if [[ ! -f "$BUILD_DIR/index.html" ]]; then
	echo "Missing $BUILD_DIR/index.html — run npm run explorer:build first." >&2
	exit 1
fi

echo "==> Preparing $REMOTE ($DLE_WEB_ROOT)"
ssh_remote "sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx certbot python3-certbot-nginx >/dev/null"
ssh_remote "sudo mkdir -p '$DLE_WEB_ROOT/.well-known/acme-challenge' && sudo chown -R ${DLE_DEPLOY_USER}:www-data '$DLE_WEB_ROOT'"

echo "==> Rsync explorer -> ${REMOTE}:${DLE_WEB_ROOT}/"
rsync -av --delete \
	--exclude '.well-known/' \
	"$BUILD_DIR/" \
	"${REMOTE}:${DLE_WEB_ROOT}/"

scp -q "$SCRIPT_DIR/nginx-dle.conet.network.http-bootstrap.conf" "$SCRIPT_DIR/nginx-dle.conet.network.conf" "${REMOTE}:/tmp/"

echo "==> Installing nginx bootstrap vhost"
ssh_remote "sudo cp /tmp/nginx-dle.conet.network.http-bootstrap.conf /etc/nginx/sites-available/${DLE_DOMAIN}.conf && sudo ln -sfn /etc/nginx/sites-available/${DLE_DOMAIN}.conf /etc/nginx/sites-enabled/${DLE_DOMAIN}.conf && sudo rm -f /etc/nginx/sites-enabled/default && sudo nginx -t && sudo systemctl enable --now nginx && sudo systemctl reload nginx"

if [[ "$SKIP_TLS" -eq 0 ]]; then
	echo "==> Issuing or reusing Let's Encrypt certificate"
	ssh_remote "if [[ ! -f /etc/letsencrypt/live/${DLE_DOMAIN}/fullchain.pem ]]; then sudo certbot certonly --webroot -w '$DLE_WEB_ROOT' -d '$DLE_DOMAIN' --non-interactive --agree-tos --register-unsafely-without-email; fi"
	ssh_remote "sudo cp /tmp/nginx-dle.conet.network.conf /etc/nginx/sites-available/${DLE_DOMAIN}.conf && sudo nginx -t && sudo systemctl reload nginx"
fi

echo "==> Done. Spot-check:"
echo "    https://${DLE_DOMAIN}/"
echo "    https://${DLE_DOMAIN}/health"
echo "    POST https://${DLE_DOMAIN}/rpc  {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]}"
