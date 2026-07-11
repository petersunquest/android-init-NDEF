#!/usr/bin/env bash
# Build x402sdk and start Lab CL skim → ConetLabMiningPool daemon (single instance).
#
# Prerequisites:
#   node scripts/aggregateLabMiningPoolPubkeys.mjs
#   → deployments/conet-lab-mining-pool-pubkeys.json
#
# Required env (export or /etc/default/conet-lab-mining-pool-cl-payout):
#   CONET_LAB_MINING_POOL_CL_PAYOUT=1
#   CONET_LAB_MINING_POOL_CL_PAYOUT_ADMIN_PRIVATE_KEY_FILE=/path/to/redeem_contract_admin.txt
#   CONET_VALIDATOR_DEPOSIT_RPC_URL=https://publicrpc.conet.network
#   CONET_VALIDATOR_BEACON_REST_URL=http://127.0.0.1:4100
#
# Optional:
#   CONET_LAB_MINING_POOL_PUBKEYS_FILE=$REPO/deployments/conet-lab-mining-pool-pubkeys.json
#   CONET_LAB_MINING_POOL_CL_PAYOUT_DRY_RUN=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
X402SDK_DIR="$REPO_ROOT/src/x402sdk"

SKIP_BUILD=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-build) SKIP_BUILD=1; shift ;;
		-h | --help)
			head -n 20 "$0" | tail -n +2
			exit 0
			;;
		*) echo "Unknown option: $1" >&2; exit 1 ;;
	esac
done

export CONET_LAB_MINING_POOL_CL_PAYOUT="${CONET_LAB_MINING_POOL_CL_PAYOUT:-1}"
export CONET_LAB_MINING_POOL_PUBKEYS_FILE="${CONET_LAB_MINING_POOL_PUBKEYS_FILE:-$REPO_ROOT/deployments/conet-lab-mining-pool-pubkeys.json}"

if [[ ! -f "$CONET_LAB_MINING_POOL_PUBKEYS_FILE" ]]; then
	echo "Missing pubkey manifest: $CONET_LAB_MINING_POOL_PUBKEYS_FILE" >&2
	echo "Run: node scripts/aggregateLabMiningPoolPubkeys.mjs" >&2
	exit 1
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
	echo "==> Building x402sdk"
	( cd "$X402SDK_DIR" && npm run build )
fi

DAEMON_JS="$X402SDK_DIR/dist/endpoint/labMiningPoolClPayoutDaemon.js"
if [[ ! -f "$DAEMON_JS" ]]; then
	echo "Missing $DAEMON_JS — build failed?" >&2
	exit 1
fi

echo "==> Starting labMiningPoolClPayoutDaemon (manifest=$CONET_LAB_MINING_POOL_PUBKEYS_FILE)"
exec node "$DAEMON_JS"
