#!/usr/bin/env bash
# 上传 CONET USDC 静态资源到 Blockscout 主机 (.30) 镜像 + API 主机 (.50) 权威 endpoint。
# 运行: bash scripts/deployConetUsdcAssets.sh
set -euo pipefail
HOST_30="${USDC_ASSETS_HOST:-38.102.126.30}"
HOST_50="${USDC_ASSETS_HOST_50:-38.102.126.50}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET_DIR="$ROOT/deployments/assets/usdc/erc20"
SRC_DIR="$ROOT/deployments/assets/usdc"
REMOTE_DIR="/opt/conet-scan/assets/usdc/erc20"
REMOTE_DIR_50="/var/www/assets/usdc/erc20"

mkdir -p "$ASSET_DIR"
for f in USDC.png USDC-256.png metadata.json; do
  [[ -f "$ASSET_DIR/$f" ]] || { echo "缺少 $ASSET_DIR/$f"; exit 1; }
done

echo "==> scp -> root@${HOST_30}:${REMOTE_DIR} (Blockscout 镜像)"
ssh -o BatchMode=yes "root@${HOST_30}" "mkdir -p ${REMOTE_DIR}"
scp -o BatchMode=yes \
  "$ASSET_DIR/USDC.png" \
  "$ASSET_DIR/USDC-256.png" \
  "$ASSET_DIR/metadata.json" \
  "root@${HOST_30}:${REMOTE_DIR}/"

echo "==> nginx: mainnet.conet.network /usdc/erc20/"
ssh -o BatchMode=yes "root@${HOST_30}" bash -s <<'REMOTE'
set -euo pipefail
CONF=/etc/nginx/sites-enabled/mainnet.conet.network.conf
MARKER="# CONET USDC static assets"
if ! grep -q "$MARKER" "$CONF"; then
  sed -i "/location = \/api\/conet\/homepage-metrics/i\\
    ${MARKER}\\
    location ^~ /usdc/erc20/ {\\
        alias /opt/conet-scan/assets/usdc/erc20/;\\
        default_type application/octet-stream;\\
        types { image/png png; application/json json; }\\
        add_header Access-Control-Allow-Origin * always;\\
        add_header Cache-Control \"public, max-age=86400\" always;\\
    }\\
" "$CONF"
  nginx -t && systemctl reload nginx
  echo "nginx mainnet updated (/usdc/erc20/)"
else
  echo "nginx mainnet already has USDC assets block"
fi
REMOTE

echo "==> scp -> root@${HOST_50}:${REMOTE_DIR_50} (assets.conet.network)"
ssh -o BatchMode=yes "root@${HOST_50}" "mkdir -p ${REMOTE_DIR_50}"
scp -o BatchMode=yes \
  "$ASSET_DIR/USDC.png" \
  "$ASSET_DIR/USDC-256.png" \
  "$ASSET_DIR/metadata.json" \
  "root@${HOST_50}:${REMOTE_DIR_50}/"

echo "✅ USDC assets deployed"
echo "   mirror: https://mainnet.conet.network/usdc/erc20/USDC-256.png"
echo "   canonical: https://assets.conet.network/usdc/erc20/metadata.json"
