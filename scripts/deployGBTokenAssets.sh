#!/usr/bin/env bash
# 上传 GBToken 静态资源到 Blockscout 主机 (.30) 并配置 nginx 镜像路径。
# 注：合约 contractURI 权威 endpoint 为 assets.conet.network（.50），见 deployGBTokenAssetsTo50.sh。
# 运行: bash scripts/deployGBTokenAssets.sh
set -euo pipefail
HOST="${GB_ASSETS_HOST:-38.102.126.30}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET_DIR="$ROOT/deployments/assets/gb/erc20"
SRC_DIR="$ROOT/deployments/assets/gb"
REMOTE_DIR="/opt/conet-scan/assets/gb/erc20"

mkdir -p "$ASSET_DIR"
if [[ ! -f "$SRC_DIR/GB.png" ]]; then
  echo "缺少 $SRC_DIR/GB.png"
  exit 1
fi
cp -f "$SRC_DIR/GB.png" "$SRC_DIR/GB-256.png" "$SRC_DIR/metadata.json" "$ASSET_DIR/"

echo "==> scp -> root@${HOST}:${REMOTE_DIR}"
ssh -o BatchMode=yes "root@${HOST}" "mkdir -p ${REMOTE_DIR}"
scp -o BatchMode=yes \
  "$ASSET_DIR/GB.png" \
  "$ASSET_DIR/GB-256.png" \
  "$ASSET_DIR/metadata.json" \
  "root@${HOST}:${REMOTE_DIR}/"

echo "==> nginx: mainnet.conet.network /gb/erc20/"
ssh -o BatchMode=yes "root@${HOST}" bash -s <<'REMOTE'
set -euo pipefail
CONF=/etc/nginx/sites-enabled/mainnet.conet.network.conf
MARKER="# GBToken static assets"
if ! grep -q "$MARKER" "$CONF"; then
  sed -i "/location = \/api\/conet\/homepage-metrics/i\\
    ${MARKER}\\
    location ^~ /gb/erc20/ {\\
        alias /opt/conet-scan/assets/gb/erc20/;\\
        default_type application/octet-stream;\\
        types { image/png png; application/json json; }\\
        add_header Access-Control-Allow-Origin * always;\\
        add_header Cache-Control \"public, max-age=86400\" always;\\
    }\\
" "$CONF"
  nginx -t && systemctl reload nginx
  echo "nginx mainnet updated"
else
  echo "nginx mainnet already has GBToken assets block"
fi

# assets.conet.network（若 DNS 已指向本机，可 certbot 扩证）
ASSETS_CONF=/etc/nginx/sites-enabled/assets.conet.network.conf
if [[ ! -f "$ASSETS_CONF" ]]; then
  cat > "$ASSETS_CONF" <<'NGINX'
# assets.conet.network — GBToken contractURI 静态托管
server {
    listen 80;
    listen [::]:80;
    server_name assets.conet.network;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
        try_files $uri =404;
    }
    location / {
        return 301 https://$host$request_uri;
    }
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name assets.conet.network;
    ssl_certificate     /etc/letsencrypt/live/mainnet.conet.network/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/mainnet.conet.network/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    root /opt/conet-scan/assets;
    location /gb/erc20/ {
        add_header Access-Control-Allow-Origin * always;
        add_header Cache-Control "public, max-age=86400" always;
        try_files $uri =404;
    }
}
NGINX
  nginx -t && systemctl reload nginx
  echo "created $ASSETS_CONF (uses mainnet cert; add DNS A assets.conet.network -> 38.102.126.30)"
fi
REMOTE

echo "==> 探活"
curl -fsSI "https://mainnet.conet.network/gb/erc20/metadata.json" | head -5 || true
curl -fsSI "https://mainnet.conet.network/gb/erc20/GB.png" | head -5 || true
echo "Done. contractURI 目标域 assets.conet.network 需 DNS 指向 ${HOST} 后可用。"
