#!/usr/bin/env bash
# 上传 B-Unit 静态资源到 Blockscout 主机 (.30) 并配置 nginx 镜像路径。
# 运行: bash scripts/deployBUintAssets.sh
set -euo pipefail
HOST="${BUINT_ASSETS_HOST:-38.102.126.30}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET_DIR="$ROOT/deployments/assets/bunit/erc20"
REMOTE_DIR="/opt/conet-scan/assets/bunit/erc20"

if [[ ! -f "$ASSET_DIR/BUNIT.png" ]]; then
  echo "缺少 $ASSET_DIR/BUNIT.png"
  exit 1
fi

echo "==> scp -> root@${HOST}:${REMOTE_DIR}"
ssh -o BatchMode=yes "root@${HOST}" "mkdir -p ${REMOTE_DIR}"
scp -o BatchMode=yes \
  "$ASSET_DIR/BUNIT.png" \
  "$ASSET_DIR/BUNIT-256.png" \
  "$ASSET_DIR/metadata.json" \
  "root@${HOST}:${REMOTE_DIR}/"

echo "==> nginx: mainnet.conet.network /bunit/erc20/"
ssh -o BatchMode=yes "root@${HOST}" bash -s <<'REMOTE'
set -euo pipefail
CONF=/etc/nginx/sites-enabled/mainnet.conet.network.conf
MARKER="# B-Unit static assets"
if ! grep -q "$MARKER" "$CONF"; then
  sed -i "/location = \/api\/conet\/homepage-metrics/i\\
    ${MARKER}\\
    location ^~ /bunit/erc20/ {\\
        alias /opt/conet-scan/assets/bunit/erc20/;\\
        default_type application/octet-stream;\\
        types { image/png png; application/json json; }\\
        add_header Access-Control-Allow-Origin * always;\\
        add_header Cache-Control \"public, max-age=86400\" always;\\
    }\\
" "$CONF"
  nginx -t && systemctl reload nginx
  echo "nginx mainnet updated"
else
  echo "nginx mainnet already has B-Unit assets block"
fi
REMOTE

echo "==> 探活"
curl -fsSI "https://mainnet.conet.network/bunit/erc20/metadata.json" | head -5 || true
curl -fsSI "https://mainnet.conet.network/bunit/erc20/BUNIT-256.png" | head -5 || true
echo "Done."
