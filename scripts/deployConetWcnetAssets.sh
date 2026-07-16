#!/usr/bin/env bash
# 上传 wCNET 静态资源到 Blockscout 主机 (.30)；.50 仅保留兼容镜像。
# 运行: bash scripts/deployConetWcnetAssets.sh
set -euo pipefail
HOST_30="${WCNET_ASSETS_HOST:-38.102.126.30}"
HOST_50="${WCNET_ASSETS_HOST_50:-38.102.126.50}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET_DIR="$ROOT/deployments/assets/wcnet/erc20"
REMOTE_DIR="/opt/conet-scan/assets/wcnet/erc20"
REMOTE_DIR_50="/var/www/assets/wcnet/erc20"
SOURCE_IMAGE="${WCNET_SOURCE_IMAGE:-}"

mkdir -p "$ASSET_DIR"
if [[ -n "$SOURCE_IMAGE" ]]; then
  [[ -f "$SOURCE_IMAGE" ]] || { echo "找不到 WCNET_SOURCE_IMAGE: $SOURCE_IMAGE"; exit 1; }
  cp -f "$SOURCE_IMAGE" "$ASSET_DIR/wCNET.png"
  cp -f "$SOURCE_IMAGE" "$ASSET_DIR/wCNET-256.png"
fi
for f in wCNET.png wCNET-256.png metadata.json; do
  [[ -f "$ASSET_DIR/$f" ]] || { echo "缺少 $ASSET_DIR/$f"; exit 1; }
done

echo "==> scp -> root@${HOST_30}:${REMOTE_DIR} (Blockscout 镜像)"
ssh -o BatchMode=yes "root@${HOST_30}" "mkdir -p ${REMOTE_DIR}"
scp -o BatchMode=yes \
  "$ASSET_DIR/wCNET.png" \
  "$ASSET_DIR/wCNET-256.png" \
  "$ASSET_DIR/metadata.json" \
  "root@${HOST_30}:${REMOTE_DIR}/"

echo "==> nginx: mainnet.conet.network /wcnet/erc20/"
ssh -o BatchMode=yes "root@${HOST_30}" bash -s <<'REMOTE'
set -euo pipefail
CONF=/etc/nginx/sites-enabled/mainnet.conet.network.conf
MARKER="# CONET wCNET static assets"
if grep -q "$MARKER" "$CONF"; then
  echo "nginx mainnet already has wCNET assets block"
else
  python3 <<'PY'
from pathlib import Path
conf = Path("/etc/nginx/sites-enabled/mainnet.conet.network.conf")
text = conf.read_text()
needle = """    # CONET USDC static assets
    location ^~ /usdc/erc20/ {
        alias /opt/conet-scan/assets/usdc/erc20/;
        default_type application/octet-stream;
        types { image/png png; application/json json; }
        add_header Access-Control-Allow-Origin * always;
        add_header Cache-Control \"public, max-age=86400\" always;
    }
"""
block = needle + """
    # CONET wCNET static assets
    location ^~ /wcnet/erc20/ {
        alias /opt/conet-scan/assets/wcnet/erc20/;
        default_type application/octet-stream;
        types { image/png png; application/json json; }
        add_header Access-Control-Allow-Origin * always;
        add_header Cache-Control \"public, max-age=86400\" always;
    }
"""
if needle not in text:
    raise SystemExit("USDC nginx block not found; insert /wcnet/erc20/ manually")
conf.write_text(text.replace(needle, block, 1))
print("inserted wCNET nginx block")
PY
  nginx -t && systemctl reload nginx
  echo "nginx mainnet updated (/wcnet/erc20/)"
fi
REMOTE

echo "==> scp -> root@${HOST_50}:${REMOTE_DIR_50} (assets.conet.network)"
ssh -o BatchMode=yes "root@${HOST_50}" "mkdir -p ${REMOTE_DIR_50}"
scp -o BatchMode=yes \
  "$ASSET_DIR/wCNET.png" \
  "$ASSET_DIR/wCNET-256.png" \
  "$ASSET_DIR/metadata.json" \
  "root@${HOST_50}:${REMOTE_DIR_50}/"

echo "✅ wCNET assets deployed"
echo "   mirror: https://mainnet.conet.network/wcnet/erc20/wCNET-256.png"
echo "   metadata: https://mainnet.conet.network/wcnet/erc20/metadata.json"
