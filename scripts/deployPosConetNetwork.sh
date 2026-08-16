#!/usr/bin/env bash
# Deploy src/posPwa to https://pos.beamio.app (root base path, dedicated vhost).
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

Build posPwa (base /) and publish to https://pos.beamio.app:
  1) POS_PWA_BASE=/ npm run build
  2) rsync dist -> posTemp/ (staging; keep BeamioPOS-*.zip)
  3) rsync posTemp/ -> web root (live; keep BeamioPOS-*.zip)
  4) pack BeamioPOS-{ver}.zip + smoke https://pos.beamio.app/update.json
  5) install nginx vhost (if missing) + expand TLS cert for pos.beamio.app

Options:
  --skip-build      Use existing src/posPwa/dist without npm run build
  --skip-promote    Only update posTemp/, do not copy to live root
  --skip-nginx      Do not install or reload nginx config
  --skip-cert       Do not reissue shared cert for pos.beamio.app
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

POS_VERSION="$(node -e "console.log(require('$POS_PWA_DIR/package.json').version)")"
OTA_ZIP_NAME="BeamioPOS-${POS_VERSION}.zip"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
	echo "==> Building posPwa for pos.beamio.app (POS_PWA_BASE=/)"
	( cd "$POS_PWA_DIR" && npm ci && npm run build:root )
fi

BUILD_DIR="$POS_PWA_DIR/dist"
if [[ ! -f "$BUILD_DIR/index.html" ]]; then
	echo "Missing $BUILD_DIR/index.html — run build first." >&2
	exit 1
fi

# Guard: pos.beamio.app is served at / — assets must not use /pos/ prefix.
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

echo "==> Rsync POS PWA build -> posTemp/ (keep live OTA zips)"
rsync -av "${RSYNC_DELETE[@]}" --exclude 'BeamioPOS-*.zip' ${RSYNC_EXTRA[@]+"${RSYNC_EXTRA[@]}"} "$BUILD_DIR/" "$REMOTE_TEMP"

if [[ "$SKIP_PROMOTE" -eq 1 ]]; then
	echo "==> Skipped promote to live root (--skip-promote)"
else
	echo "==> Promote posTemp/ -> ${POS_WEB_ROOT}/"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		rsync -av --dry-run "${RSYNC_DELETE[@]}" --exclude 'posTemp/' --exclude 'BeamioPOS-*.zip' \
			"${SSH_TARGET}:${POS_WEB_ROOT}/posTemp/" "$REMOTE_LIVE"
	else
		ssh "$SSH_TARGET" "rsync -a --delete --exclude 'posTemp/' --exclude 'BeamioPOS-*.zip' '${POS_WEB_ROOT}/posTemp/' '${POS_WEB_ROOT}/'"
	fi

	if [[ "$DRY_RUN" -eq 0 ]]; then
		echo "==> Ensure update.json matches package.json ${POS_VERSION}"
		printf '{\n\t"ver": "%s",\n\t"filename": "%s"\n}\n' "$POS_VERSION" "$OTA_ZIP_NAME" > "$POS_PWA_DIR/public/update.json"
		printf '{\n\t"ver": "%s",\n\t"filename": "%s"\n}\n' "$POS_VERSION" "$OTA_ZIP_NAME" > "$BUILD_DIR/update.json"

		echo "==> Pack Embedded OTA zip ${OTA_ZIP_NAME} (POS_PWA_BASE=/)"
		OTA_ZIP_PATH="/tmp/BeamioPOS-${POS_VERSION}-$$.zip"
		rm -f "$OTA_ZIP_PATH"
		(
			cd "$BUILD_DIR"
			zip -qr "$OTA_ZIP_PATH" .
		)
		if [[ ! -s "$OTA_ZIP_PATH" ]]; then
			echo "ERROR: OTA zip empty or missing at $OTA_ZIP_PATH" >&2
			exit 1
		fi
		zip_has_file() {
			local needle="$1"
			local listing
			listing="$(unzip -Z1 "$OTA_ZIP_PATH" 2>/dev/null || true)"
			if [[ -z "$listing" ]]; then
				listing="$(unzip -l "$OTA_ZIP_PATH" 2>/dev/null | awk '{print $NF}' || true)"
			fi
			printf '%s\n' "$listing" | grep -qx "$needle"
		}
		if ! zip_has_file 'index.html'; then
			echo "ERROR: OTA zip missing index.html ($(ls -lh "$OTA_ZIP_PATH" 2>/dev/null || true))" >&2
			unzip -l "$OTA_ZIP_PATH" 2>&1 | head -n 30 >&2 || true
			exit 1
		fi
		if ! zip_has_file 'update.json'; then
			echo "ERROR: OTA zip missing update.json" >&2
			exit 1
		fi

		echo "==> Install nginx vhost (OTA locations) before live smoke"
		scp "$NGINX_CONF" "${SSH_TARGET}:/tmp/nginx-pos-conet.network.conf"
		ssh "$SSH_TARGET" "sudo cp /tmp/nginx-pos-conet.network.conf /etc/nginx/sites-available/pos.beamio.app.conf && sudo ln -sf /etc/nginx/sites-available/pos.beamio.app.conf /etc/nginx/sites-enabled/pos.beamio.app.conf && sudo nginx -t && sudo systemctl reload nginx"
		# Avoid double nginx install later in this run
		SKIP_NGINX=1

		scp "$OTA_ZIP_PATH" "${SSH_TARGET}:${POS_WEB_ROOT}/${OTA_ZIP_NAME}"
		scp "$BUILD_DIR/update.json" "${SSH_TARGET}:${POS_WEB_ROOT}/update.json"
		ssh "$SSH_TARGET" "chmod 644 '${POS_WEB_ROOT}/${OTA_ZIP_NAME}' '${POS_WEB_ROOT}/update.json' && test -f '${POS_WEB_ROOT}/update.json' && test -f '${POS_WEB_ROOT}/${OTA_ZIP_NAME}'"
		rm -f "$OTA_ZIP_PATH"
		echo "==> Smoke live OTA"
		sleep 1
		LIVE_JSON="$(curl -fsS https://pos.beamio.app/update.json)"
		if [[ "$LIVE_JSON" == *"<!doctype html>"* || "$LIVE_JSON" == *"<html"* ]]; then
			echo "OTA smoke FAILED: update.json returned HTML (SPA fallback). Check nginx." >&2
			echo "Body head: ${LIVE_JSON:0:120}" >&2
			exit 1
		fi
		LIVE_VER="$(node -e "const j=JSON.parse(process.argv[1]); process.stdout.write(String(j.ver||''))" "$LIVE_JSON")"
		LIVE_FILE="$(node -e "const j=JSON.parse(process.argv[1]); process.stdout.write(String(j.filename||''))" "$LIVE_JSON")"
		if [[ "$LIVE_VER" != "$POS_VERSION" || "$LIVE_FILE" != "$OTA_ZIP_NAME" ]]; then
			echo "OTA smoke FAILED: update.json ver=${LIVE_VER} filename=${LIVE_FILE} expected ${POS_VERSION} / ${OTA_ZIP_NAME}" >&2
			exit 1
		fi
		ZIP_CT="$(curl -fsSI "https://pos.beamio.app/${OTA_ZIP_NAME}" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print $2; exit}')"
		ZIP_CODE="$(curl -fsSI -o /dev/null -w '%{http_code}' "https://pos.beamio.app/${OTA_ZIP_NAME}")"
		if [[ "$ZIP_CODE" != "200" ]]; then
			echo "OTA smoke FAILED: ${OTA_ZIP_NAME} HTTP ${ZIP_CODE}" >&2
			exit 1
		fi
		if [[ "$ZIP_CT" == *"text/html"* ]]; then
			echo "OTA smoke FAILED: ${OTA_ZIP_NAME} Content-Type=${ZIP_CT} (SPA fallback)" >&2
			exit 1
		fi
		echo "    update.json ver=${LIVE_VER} filename=${LIVE_FILE}"
		echo "    ${OTA_ZIP_NAME} HTTP ${ZIP_CODE} Content-Type=${ZIP_CT}"

		# Service Worker paths must 404 (not SPA HTML) — POS has no SW update path.
		for sw_path in /sw.js /service-worker.js /registerSW.js; do
			SW_CODE="$(curl -sS -o /dev/null -w '%{http_code}' "https://pos.beamio.app${sw_path}" || true)"
			if [[ "$SW_CODE" != "404" ]]; then
				echo "OTA smoke FAILED: ${sw_path} HTTP ${SW_CODE} (expected 404; check nginx SW block)" >&2
				exit 1
			fi
		done
		echo "    /sw.js /service-worker.js /registerSW.js → 404 OK"
	fi
fi

if [[ "$SKIP_NGINX" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
	echo "==> Install nginx vhost for pos.beamio.app (if needed)"
	scp "$NGINX_CONF" "${SSH_TARGET}:/tmp/nginx-pos-conet.network.conf"
	ssh "$SSH_TARGET" "sudo cp /tmp/nginx-pos-conet.network.conf /etc/nginx/sites-available/pos.beamio.app.conf && sudo ln -sf /etc/nginx/sites-available/pos.beamio.app.conf /etc/nginx/sites-enabled/pos.beamio.app.conf"
fi

if [[ "$SKIP_CERT" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
	echo "==> Ensure TLS cert covers pos.beamio.app"
	ssh "$SSH_TARGET" 'bash -s' <<'REMOTE_CERT'
set -euo pipefail
if sudo openssl x509 -in /etc/letsencrypt/live/api.settleonbase.xyz/fullchain.pem -noout -text 2>/dev/null | grep -q "DNS:pos.beamio.app" \
	&& sudo openssl x509 -in /etc/letsencrypt/live/api.settleonbase.xyz/fullchain.pem -noout -text 2>/dev/null | grep -q "DNS:pos.conet.network"; then
	echo "Cert already includes pos.beamio.app and pos.conet.network"
	exit 0
fi
# Reissue shared multi-SAN cert (same cert name used by dashboard.conet.network / verra.network).
sudo certbot certonly --cert-name api.settleonbase.xyz --force-renewal \
	-d alliance.beamio.app -d api.settleonbase.xyz -d apiv4.conet.network -d apps.conet.network \
	-d beamio.app -d beta.conet.network -d beta1.conet.network -d biz.beamio.app \
	-d cashtrees.beamio.app -d conet.network -d conetlabs.org -d dashboard.conet.network \
	-d download.silentpass.io -d frameworkminigame.conet.network -d fx168.silentpass.io \
	-d hooks.conet.network -d ios-test.silentpass.io -d ios-vpn.silentpass.io \
	-d platform.conet.network -d pos.beamio.app -d pos.conet.network -d silentpass.io \
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
echo "    https://pos.beamio.app/"
echo "    https://pos.beamio.app/home"
echo "    https://pos.beamio.app/update.json  (must be ver=${POS_VERSION})"
echo "    https://pos.beamio.app/${OTA_ZIP_NAME}"
echo "    https://pos.conet.network/ (proxy → pos.beamio.app)"
