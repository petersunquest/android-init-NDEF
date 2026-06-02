#!/usr/bin/env bash
# Deploy x402sdk fragment daemon (IPFS API) to ipfs.conet.network / 38.102.126.30
# See .cursor/rules/conet-ipfs-deploy.mdc

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
X402SDK_DIR="$REPO_ROOT/src/x402sdk"
NGINX_CONF="$X402SDK_DIR/service/ipfs.conf"
SYSTEMD_UNIT="$X402SDK_DIR/service/systemd/conetIPFS.service"

CONET_IPFS_HOST="${CONET_IPFS_HOST:-38.102.126.30}"
CONET_IPFS_USER="${CONET_IPFS_USER:-peter}"
CONET_IPFS_ROOT="${CONET_IPFS_ROOT:-/home/peter/x402sdk}"
CONET_IPFS_SERVICE="${CONET_IPFS_SERVICE:-conetIPFS.service}"
CONET_IPFS_PUBLIC_URL="${CONET_IPFS_PUBLIC_URL:-https://ipfs.conet.network}"
SSH_TARGET="${CONET_IPFS_USER}@${CONET_IPFS_HOST}"

LOCAL_BUILD=1
REMOTE_BUILD=0
SKIP_BUILD=0
SKIP_RESTART=0
SKIP_SMOKE=0
SYNC_NGINX=0
SYNC_SYSTEMD=0
DRY_RUN=0
REQUIRE_PUSH=0

usage() {
	cat <<'EOF'
Usage: scripts/deployConetIpfs.sh [options]

Deploy x402sdk fragmentClusterServer (port 8002) to ipfs.conet.network.

Default (local build + rsync dist):
  1) cd src/x402sdk && npm run build
  2) rsync dist/ -> peter@38.102.126.30:/home/peter/x402sdk/dist/
  3) rsync fragment source TS (traceability)
  4) sudo systemctl restart conetIPFS.service
  5) smoke test Accept-Ranges / 206 Range

Options:
  --remote-build    git fetch + reset on server, npm install/build there (needs clean remote clone)
  --skip-build      Skip compile; rsync existing local dist/ only
  --skip-restart    Do not restart conetIPFS.service
  --skip-smoke      Skip post-deploy curl checks
  --sync-nginx      Install service/ipfs.conf to /etc/nginx/sites-enabled/ and reload nginx
  --sync-systemd    Install service/systemd/conetIPFS.service and daemon-reload
  --require-push    Fail if src/x402sdk main is ahead of origin/main (deploy stale code guard)
  --dry-run         Pass --dry-run to rsync
  -h, --help        Show this help

Environment:
  CONET_IPFS_HOST          SSH host (default: 38.102.126.30)
  CONET_IPFS_USER          SSH user (default: peter)
  CONET_IPFS_ROOT          Remote x402sdk root (default: /home/peter/x402sdk)
  CONET_IPFS_SERVICE       systemd unit (default: conetIPFS.service)
  CONET_IPFS_PUBLIC_URL    Public base URL for smoke test (default: https://ipfs.conet.network)
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--remote-build) REMOTE_BUILD=1; LOCAL_BUILD=0; shift ;;
		--skip-build) SKIP_BUILD=1; shift ;;
		--skip-restart) SKIP_RESTART=1; shift ;;
		--skip-smoke) SKIP_SMOKE=1; shift ;;
		--sync-nginx) SYNC_NGINX=1; shift ;;
		--sync-systemd) SYNC_SYSTEMD=1; shift ;;
		--require-push) REQUIRE_PUSH=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

RSYNC_FLAGS=(-av)
if [[ "$DRY_RUN" -eq 1 ]]; then
	RSYNC_FLAGS+=(--dry-run)
fi

if [[ "$REQUIRE_PUSH" -eq 1 ]]; then
	echo "==> Checking src/x402sdk is pushed to origin/main"
	( cd "$X402SDK_DIR" && git fetch origin main >/dev/null 2>&1 )
	local_sha="$(cd "$X402SDK_DIR" && git rev-parse HEAD)"
	remote_sha="$(cd "$X402SDK_DIR" && git rev-parse origin/main)"
	if [[ "$local_sha" != "$remote_sha" ]]; then
		echo "src/x402sdk HEAD ($local_sha) != origin/main ($remote_sha). Push first or drop --require-push." >&2
		exit 1
	fi
fi

if [[ "$REMOTE_BUILD" -eq 1 ]]; then
	echo "==> Remote build on ${SSH_TARGET}:${CONET_IPFS_ROOT}"
	ssh "$SSH_TARGET" "set -euo pipefail
cd '${CONET_IPFS_ROOT}'
git fetch origin main
git checkout origin/main -- src/endpoint/fragmentClusterServer.ts src/endpoint/fragmentDaemon.ts
npm install --no-audit --no-fund
npm run build
test -f dist/endpoint/fragmentDaemon.js
test -f dist/endpoint/fragmentClusterServer.js
"
elif [[ "$SKIP_BUILD" -eq 0 ]]; then
	echo "==> Building x402sdk locally in $X402SDK_DIR"
	( cd "$X402SDK_DIR" && npm run build )
fi

for required in dist/endpoint/fragmentDaemon.js dist/endpoint/fragmentClusterServer.js; do
	if [[ ! -f "$X402SDK_DIR/$required" ]]; then
		echo "Missing $X402SDK_DIR/$required — run npm run build in src/x402sdk first." >&2
		exit 1
	fi
done

echo "==> Rsync dist/ -> ${SSH_TARGET}:${CONET_IPFS_ROOT}/dist/"
rsync "${RSYNC_FLAGS[@]}" "$X402SDK_DIR/dist/" "${SSH_TARGET}:${CONET_IPFS_ROOT}/dist/"

echo "==> Rsync package.json + npm install (runtime deps e.g. multer)"
rsync "${RSYNC_FLAGS[@]}" \
	"$X402SDK_DIR/package.json" \
	"$X402SDK_DIR/package-lock.json" \
	"${SSH_TARGET}:${CONET_IPFS_ROOT}/"
if [[ "$DRY_RUN" -eq 0 ]]; then
	ssh "$SSH_TARGET" "cd '${CONET_IPFS_ROOT}' && npm install --no-audit --no-fund"
fi

echo "==> Rsync fragment endpoint sources (traceability)"
rsync "${RSYNC_FLAGS[@]}" \
	"$X402SDK_DIR/src/endpoint/fragmentClusterServer.ts" \
	"$X402SDK_DIR/src/endpoint/fragmentDaemon.ts" \
	"${SSH_TARGET}:${CONET_IPFS_ROOT}/src/endpoint/"

if [[ "$SYNC_SYSTEMD" -eq 1 ]]; then
	echo "==> Install systemd unit ${CONET_IPFS_SERVICE}"
	scp "$SYSTEMD_UNIT" "${SSH_TARGET}:/tmp/conetIPFS.service"
	ssh "$SSH_TARGET" "sudo cp /tmp/conetIPFS.service /etc/systemd/system/${CONET_IPFS_SERVICE} && sudo systemctl daemon-reload"
fi

if [[ "$SYNC_NGINX" -eq 1 ]]; then
	echo "==> Install nginx ipfs.conet.network vhost"
	scp "$NGINX_CONF" "${SSH_TARGET}:/tmp/ipfs.conet.network.conf"
	ssh "$SSH_TARGET" "sudo cp /tmp/ipfs.conet.network.conf /etc/nginx/sites-enabled/ipfs.conet.network.conf && sudo nginx -t && sudo systemctl reload nginx"
fi

if [[ "$SKIP_RESTART" -eq 0 ]]; then
	echo "==> Restart ${CONET_IPFS_SERVICE}"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		echo "(dry-run) would: ssh ${SSH_TARGET} sudo systemctl restart ${CONET_IPFS_SERVICE}"
	else
		ssh "$SSH_TARGET" "sudo systemctl restart ${CONET_IPFS_SERVICE}"
		sleep 2
		ssh "$SSH_TARGET" "systemctl is-active ${CONET_IPFS_SERVICE}"
	fi
fi

if [[ "$SKIP_SMOKE" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
	echo "==> Smoke test (Accept-Ranges + 206 Range)"
	ssh "$SSH_TARGET" 'set -euo pipefail
storage="$(node -pe "require(\"/home/peter/.master.json\").storagePATH")"
sample="$(ls "$storage" 2>/dev/null | head -1 || true)"
if [[ -z "$sample" ]]; then
  echo "No fragment files in storage; skipping local sample hash test." >&2
  exit 0
fi
curl -sfI "http://127.0.0.1:8002/api/getFragment?hash=${sample}" | grep -qi "Accept-Ranges: bytes"
curl -sfI -H "Range: bytes=0-99" "http://127.0.0.1:8002/api/getFragment?hash=${sample}" | grep -qi "206"
echo "Local smoke OK (hash=${sample})"
'
	if [[ -n "${CONET_IPFS_PUBLIC_URL:-}" ]]; then
		ssh "$SSH_TARGET" "set -euo pipefail
storage=\"\$(node -pe \"require('/home/peter/.master.json').storagePATH\")\"
sample=\"\$(ls \"\$storage\" 2>/dev/null | head -1 || true)\"
if [[ -z \"\$sample\" ]]; then exit 0; fi
curl -sfI -H 'Range: bytes=0-99' '${CONET_IPFS_PUBLIC_URL}/api/getFragment?hash='\${sample} | grep -qi '206'
echo 'Public smoke OK (${CONET_IPFS_PUBLIC_URL})'
"
	fi
fi

echo "==> Done. Fragment API:"
echo "    ${CONET_IPFS_PUBLIC_URL}/api/getFragment?hash=<keccak256>"
