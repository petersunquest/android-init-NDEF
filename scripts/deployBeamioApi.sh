#!/usr/bin/env bash
# Deploy x402sdk BeamioCluster API (port 2222) to conet.network — beamio.app /api/*
# Source workflow: local src/x402sdk commit + push, then remote git pull + build.
# Does NOT enable CONET_VALIDATOR_REDEEM_LISTENER (validator node listeners deploy separately).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
X402SDK_DIR="$REPO_ROOT/src/x402sdk"
SYSTEMD_UNIT="$X402SDK_DIR/service/beamio.service"

BEAMIO_API_HOST="${BEAMIO_API_HOST:-conet.network}"
BEAMIO_API_USER="${BEAMIO_API_USER:-peter}"
BEAMIO_API_ROOT="${BEAMIO_API_ROOT:-/home/peter/x402sdk}"
BEAMIO_API_SERVICE="${BEAMIO_API_SERVICE:-conet-beamio-api.service}"
BEAMIO_API_PUBLIC_URL="${BEAMIO_API_PUBLIC_URL:-https://beamio.app}"
SSH_TARGET="${BEAMIO_API_USER}@${BEAMIO_API_HOST}"

SKIP_BUILD=0
SKIP_RESTART=0
SKIP_SMOKE=0
DRY_RUN=0

usage() {
	cat <<'EOF'
Usage: scripts/deployBeamioApi.sh [options]

Deploy x402sdk BeamioCluster (port 2222) to conet.network for beamio.app API proxy.

Default:
  1) cd src/x402sdk && npm run build
  2) require a clean local git worktree and push the active branch
  3) remote /home/peter/x402sdk git pull --ff-only && npm install && npm run build
  4) sudo systemctl restart conet-beamio-api.service
  5) smoke test GET /api/validatorDepositRedeemConfig

Options:
  --skip-build      Skip compile; rsync existing local dist/ only
  --skip-restart    Do not restart conet-si.service
  --skip-smoke      Skip post-deploy curl checks
  --dry-run         Print the plan without pushing, pulling, restarting, or testing
  -h, --help        Show this help

Environment:
  BEAMIO_API_HOST          SSH host (default: conet.network)
  BEAMIO_API_USER          SSH user (default: peter)
  BEAMIO_API_ROOT          Remote x402sdk root (default: /home/peter/x402sdk)
  BEAMIO_API_SERVICE       systemd unit (default: conet-si.service)
  BEAMIO_API_PUBLIC_URL    Public base URL for smoke test (default: https://beamio.app)
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-build) SKIP_BUILD=1; shift ;;
		--skip-restart) SKIP_RESTART=1; shift ;;
		--skip-smoke) SKIP_SMOKE=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

if [[ "$SKIP_BUILD" -eq 0 ]]; then
	echo "==> Building x402sdk locally in $X402SDK_DIR"
	( cd "$X402SDK_DIR" && npm run build )
fi

API_GIT_BRANCH="$(git -C "$X402SDK_DIR" branch --show-current)"
if [[ -z "$API_GIT_BRANCH" ]]; then
	echo "x402sdk is detached or has no active branch; deploy from a named branch." >&2
	exit 1
fi
if [[ -n "$(git -C "$X402SDK_DIR" status --porcelain)" ]]; then
	echo "x402sdk has uncommitted changes. Commit and push from the local source first." >&2
	exit 1
fi
git -C "$X402SDK_DIR" fetch origin "$API_GIT_BRANCH"
if ! git -C "$X402SDK_DIR" merge-base --is-ancestor "origin/$API_GIT_BRANCH" HEAD; then
	echo "Local x402sdk is behind or diverged from origin/$API_GIT_BRANCH. Merge locally before deploy." >&2
	exit 1
fi

for required in dist/endpoint/BeamioCluster.js dist/endpoint/beamioServer.js dist/endpoint/validatorDepositRedeem.js; do
	if [[ ! -f "$X402SDK_DIR/$required" ]]; then
		echo "Missing $X402SDK_DIR/$required — run npm run build in src/x402sdk first." >&2
		exit 1
	fi
done

echo "==> Git push local ${API_GIT_BRANCH} and pull on ${SSH_TARGET}"
if [[ "$DRY_RUN" -eq 1 ]]; then
	echo "(dry-run) would: git -C ${X402SDK_DIR} push origin ${API_GIT_BRANCH}"
	echo "(dry-run) would: ssh ${SSH_TARGET} 'cd ${BEAMIO_API_ROOT} && git pull --ff-only origin ${API_GIT_BRANCH} && npm install --no-audit --no-fund && npm run build'"
else
	git -C "$X402SDK_DIR" push origin "$API_GIT_BRANCH"
	ssh "$SSH_TARGET" "set -euo pipefail
cd '${BEAMIO_API_ROOT}'
git pull --ff-only origin '${API_GIT_BRANCH}'
npm install --no-audit --no-fund
npm run build"
fi

if [[ "$SKIP_RESTART" -eq 0 ]]; then
	echo "==> Restart ${BEAMIO_API_SERVICE}"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		echo "(dry-run) would: ssh ${SSH_TARGET} sudo systemctl restart ${BEAMIO_API_SERVICE}"
	else
		ssh "$SSH_TARGET" "sudo systemctl restart ${BEAMIO_API_SERVICE}"
		sleep 3
	fi
fi

if [[ "$SKIP_SMOKE" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
	echo "==> Smoke test ${BEAMIO_API_PUBLIC_URL}/api/validatorDepositRedeemConfig"
	body="$(curl -fsS "${BEAMIO_API_PUBLIC_URL}/api/validatorDepositRedeemConfig" || true)"
	if [[ -z "$body" ]]; then
		echo "Smoke test failed: empty response" >&2
		exit 1
	fi
	echo "$body" | head -c 400
	echo ""
	if ! echo "$body" | grep -q '"success":true'; then
		echo "Smoke test failed: success!=true" >&2
		exit 1
	fi
	if ! echo "$body" | grep -q '0x1488ED35054f2Eb5301E1dC14Be3D9283d10B3B5'; then
		echo "Warning: ValidatorDepositRedeem address not in config response (may need env on server)" >&2
	fi
fi

echo "==> Done. API deployed through local git push + remote git pull (listener NOT enabled unless CONET_VALIDATOR_REDEEM_LISTENER=1 on server)."
