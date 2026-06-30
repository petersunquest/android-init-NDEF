#!/usr/bin/env bash
# 部署 GBToken contractURI 权威 endpoint 到 API 主机 .50（assets.conet.network）。
# 前提：DNS assets.conet.network -> 38.102.126.50（用户已设；经 Cloudflare 橙云代理）。
# 合约链上 contractURI = https://assets.conet.network/gb/erc20/metadata.json（不可改，常量）。
#
# 运行: bash scripts/deployGBTokenAssetsTo50.sh
set -euo pipefail
HOST="${GB_ASSETS_HOST_50:-38.102.126.50}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$ROOT/deployments/assets/gb"
REMOTE_DIR="/var/www/assets/gb/erc20"

for f in GB.png GB-256.png metadata.json; do
  [[ -f "$SRC_DIR/$f" ]] || { echo "缺少 $SRC_DIR/$f"; exit 1; }
done

echo "==> scp -> root@${HOST}:${REMOTE_DIR}"
ssh -o BatchMode=yes "root@${HOST}" "mkdir -p ${REMOTE_DIR}"
scp -o BatchMode=yes "$SRC_DIR/GB.png" "$SRC_DIR/GB-256.png" "$SRC_DIR/metadata.json" \
  "root@${HOST}:${REMOTE_DIR}/"

echo "==> nginx vhost assets.conet.network（80/443 均直接返回内容，兼容 Cloudflare Flexible/Full）"
ssh -o BatchMode=yes "root@${HOST}" bash -s <<'REMOTE'
set -euo pipefail
CONF=/etc/nginx/sites-available/assets.conet.network.conf
NEED_CERT=0
[[ -f /etc/letsencrypt/live/assets.conet.network/fullchain.pem ]] || NEED_CERT=1

if [[ "$NEED_CERT" == "1" ]]; then
  # 先建临时 HTTP vhost 以便 webroot 签证书
  cat > "$CONF" <<'HTTP'
server {
    listen 80; listen [::]:80;
    server_name assets.conet.network;
    location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; try_files $uri =404; }
    location / { root /var/www/assets; try_files $uri =404; }
}
HTTP
  ln -sf "$CONF" /etc/nginx/sites-enabled/assets.conet.network.conf
  nginx -t && systemctl reload nginx
  certbot certonly --webroot -w /var/www/certbot -d assets.conet.network \
    --non-interactive --agree-tos --keep-until-expiring --no-eff-email
fi

cat > "$CONF" <<'NGINX'
# assets.conet.network — GBToken contractURI / 静态资源（API 主机 .50，仅加路径）
# assets.conet.network 经 Cloudflare 橙云代理；80 与 443 均直接返回内容，
# 兼容 Cloudflare SSL 模式 Flexible(回源:80) 与 Full(回源:443)，避免回源 301 重定向环。
server {
    listen 80; listen [::]:80;
    server_name assets.conet.network;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot; default_type "text/plain"; try_files $uri =404;
    }
    location / {
        root /var/www/assets;
        add_header Access-Control-Allow-Origin * always;
        add_header Cache-Control "public, max-age=86400" always;
        types { image/png png; application/json json; }
        try_files $uri =404;
    }
}
server {
    listen 443 ssl; listen [::]:443 ssl;
    server_name assets.conet.network;
    ssl_certificate     /etc/letsencrypt/live/assets.conet.network/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/assets.conet.network/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    root /var/www/assets;
    location / {
        add_header Access-Control-Allow-Origin * always;
        add_header Cache-Control "public, max-age=86400" always;
        types { image/png png; application/json json; }
        try_files $uri =404;
    }
}
NGINX
ln -sf "$CONF" /etc/nginx/sites-enabled/assets.conet.network.conf
nginx -t && systemctl reload nginx
REMOTE

echo "==> 终验（公网经 Cloudflare）"
for u in metadata.json GB.png GB-256.png; do
  curl -fsS -o /dev/null -w "$u -> %{http_code} %{content_type}\n" "https://assets.conet.network/gb/erc20/$u" || true
done
echo "提示：若公网仍返回旧的 301（cf-cache-status HIT），在 Cloudflare 清除缓存(Purge)或将 SSL/TLS 模式设为 Full。"
