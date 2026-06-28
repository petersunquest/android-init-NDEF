#!/bin/bash
set -euo pipefail

# Hot-update execution-layer fee_recipient for one validator pubkey on this node.
# Env: EXIT_VALIDATOR_PUBKEY or VALIDATOR_PUBKEY, FEE_RECIPIENT or FEE_RECIPIENT_ADDRESS.

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

PUBKEY="${EXIT_VALIDATOR_PUBKEY:-${VALIDATOR_PUBKEY:-}}"
FEE="${FEE_RECIPIENT_ADDRESS:-${FEE_RECIPIENT:-}}"
[[ -n "$PUBKEY" ]] || { echo "ERROR: EXIT_VALIDATOR_PUBKEY or VALIDATOR_PUBKEY required" >&2; exit 1; }
[[ -n "$FEE" ]] || { echo "ERROR: FEE_RECIPIENT or FEE_RECIPIENT_ADDRESS required" >&2; exit 1; }
PUBKEY="${PUBKEY#0x}"
PUBKEY="0x${PUBKEY}"

NETWORK_DIR="${NETWORK_DIR:-./network}"
NODE_DIR="${NODE_DIR:-$NETWORK_DIR/node-0}"
VALIDATOR_DATA_DIR="${VALIDATOR_DATA_DIR:-$NODE_DIR/consensus/validatordata}"
PROPOSER_FILE="${PROPOSER_SETTINGS_FILE:-$VALIDATOR_DATA_DIR/proposer-settings.json}"
PRYSM_VALIDATOR_GRPC_GATEWAY_PORT="${PRYSM_VALIDATOR_GRPC_GATEWAY_PORT:-7100}"
KEYMANAGER_TOKEN_FILE="${KEYMANAGER_TOKEN_FILE:-$HOME/.eth2validators/prysm-wallet-v2/auth-token}"

mkdir -p "$(dirname "$PROPOSER_FILE")"
export PROPOSER_FILE PUBKEY FEE
node <<'NODE'
const fs = require('fs');
const file = process.env.PROPOSER_FILE;
const pubkey = process.env.PUBKEY;
const fee = process.env.FEE;
let doc = { proposer_config: {}, default_config: { fee_recipient: fee } };
if (fs.existsSync(file)) {
  try { doc = JSON.parse(fs.readFileSync(file, 'utf8')); } catch {}
  doc.proposer_config = doc.proposer_config || {};
  doc.default_config = doc.default_config || {};
}
doc.proposer_config[pubkey] = { ...(doc.proposer_config[pubkey] || {}), fee_recipient: fee };
fs.writeFileSync(file, JSON.stringify(doc, null, 2) + '\n');
console.log('Wrote proposer settings:', file, 'pubkey=', pubkey, 'fee_recipient=', fee);
NODE

if [[ -f "$KEYMANAGER_TOKEN_FILE" ]]; then
	TOKEN="$(tr -d '\\n' < "$KEYMANAGER_TOKEN_FILE")"
	if curl -sfS -X POST "http://127.0.0.1:${PRYSM_VALIDATOR_GRPC_GATEWAY_PORT}/eth/v1/validator/${PUBKEY}/feerecipient" \
		-H "Authorization: Bearer ${TOKEN}" \
		-H "Content-Type: application/json" \
		-d "{\"fee_recipient\":\"${FEE}\"}"; then
		echo "Keymanager API fee_recipient updated for ${PUBKEY}"
		exit 0
	fi
	echo "Keymanager API unavailable; proposer-settings file updated (restart validator with --proposer-settings-file if needed)"
else
	echo "No keymanager token; proposer-settings file updated (restart validator with --proposer-settings-file if needed)"
fi
