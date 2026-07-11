#!/bin/bash
# Set execution-layer fee_recipient → ConetLabMiningPool for all validators on 207.90.192.71.
# VA connects to remote beacon (default 74.208.224.45:4000); only restarts Prysm validator — not geth/beacon EL/CL.
#
# Run ON 207.90.192.71:
#   FEE_RECIPIENT=0x32bE583C8e778FFfC5107BF34820c2B225336201 \
#   BEACON_RPC_PROVIDER=74.208.224.45:4000 \
#     bash setConetLabMiningPoolFeeRecipient207.sh
#
# Or from dev machine:
#   scp scripts/validator-node/setConetLabMiningPoolFeeRecipient207.sh peter@207.90.192.71:~/ethereum-pos-mainnet/
#   ssh peter@207.90.192.71 'FEE_RECIPIENT=0x32bE583C8e778FFfC5107BF34820c2B225336201 bash ~/ethereum-pos-mainnet/setConetLabMiningPoolFeeRecipient207.sh'

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$HOME/ethereum-pos-mainnet}"
# shellcheck disable=SC1091
[[ -f "$PROJECT_DIR/conet_fee_recipient_defaults.sh" ]] && source "$PROJECT_DIR/conet_fee_recipient_defaults.sh"

NETWORK_DIR="${NETWORK_DIR:-$PROJECT_DIR/network}"
NODE_DIR="${NODE_DIR:-$NETWORK_DIR/node-0}"
VALIDATOR_DATA_DIR="${VALIDATOR_DATA_DIR:-$NODE_DIR/consensus/validatordata}"
VALIDATOR_WALLET_DIR="${VALIDATOR_WALLET_DIR:-$NODE_DIR/consensus/validator-wallet}"
CHAIN_CONFIG_FILE="${CHAIN_CONFIG_FILE:-$NODE_DIR/consensus/config.yml}"
VALIDATOR_DEPOSITS_FILE="${VALIDATOR_DEPOSITS_FILE:-$PROJECT_DIR/validator_deposits.json}"
PROPOSER_FILE="${PROPOSER_SETTINGS_FILE:-$VALIDATOR_DATA_DIR/proposer-settings.json}"
WALLET_PASSWORD_FILE="${WALLET_PASSWORD_FILE:-$PROJECT_DIR/secrets/prysm_wallet_password.txt}"

FEE_RECIPIENT="${FEE_RECIPIENT:-${CONET_DEFAULT_FEE_RECIPIENT:-0x32bE583C8e778FFfC5107BF34820c2B225336201}}"
BEACON_RPC_PROVIDER="${BEACON_RPC_PROVIDER:-74.208.224.45:4000}"
PRYSM_VALIDATOR_BINARY="${PRYSM_VALIDATOR_BINARY:-$PROJECT_DIR/dependencies/prysm-v7.1.5/validator}"
PRYSM_VALIDATOR_RPC_PORT="${PRYSM_VALIDATOR_RPC_PORT:-7000}"
PRYSM_VALIDATOR_GRPC_GATEWAY_PORT="${PRYSM_VALIDATOR_GRPC_GATEWAY_PORT:-7100}"
PRYSM_VALIDATOR_MONITORING_PORT="${PRYSM_VALIDATOR_MONITORING_PORT:-7200}"

[[ -f "$VALIDATOR_DEPOSITS_FILE" ]] || { echo "ERROR: missing $VALIDATOR_DEPOSITS_FILE" >&2; exit 1; }
[[ -f "$WALLET_PASSWORD_FILE" ]] || { echo "ERROR: missing $WALLET_PASSWORD_FILE" >&2; exit 1; }
[[ -x "$PRYSM_VALIDATOR_BINARY" ]] || { echo "ERROR: validator binary not executable: $PRYSM_VALIDATOR_BINARY" >&2; exit 1; }

echo "==> fee_recipient (ConetLabMiningPool): $FEE_RECIPIENT"
echo "==> beacon-rpc-provider: $BEACON_RPC_PROVIDER"
echo "==> building proposer-settings from $VALIDATOR_DEPOSITS_FILE"

export PROPOSER_FILE FEE_RECIPIENT VALIDATOR_DEPOSITS_FILE
node <<'NODE'
const fs = require("fs");
const fee = process.env.FEE_RECIPIENT;
const depositsPath = process.env.VALIDATOR_DEPOSITS_FILE;
const out = process.env.PROPOSER_FILE;
const raw = JSON.parse(fs.readFileSync(depositsPath, "utf8"));
const list = Array.isArray(raw) ? raw : raw.deposits || [];
if (!list.length) throw new Error("no deposits in " + depositsPath);
const proposer_config = {};
for (const row of list) {
  let pk = row.pubkey || row.pub_key || row.validator_pubkey;
  if (!pk) continue;
  pk = String(pk).replace(/^0x/i, "");
  if (pk.length !== 96) throw new Error("bad pubkey length: " + pk.slice(0, 16));
  proposer_config["0x" + pk] = { fee_recipient: fee };
}
const doc = {
  proposer_config,
  default_config: { fee_recipient: fee },
};
fs.mkdirSync(require("path").dirname(out), { recursive: true });
fs.writeFileSync(out, JSON.stringify(doc, null, 2) + "\n");
console.log("Wrote", out, "validators=", Object.keys(proposer_config).length);
NODE

echo "==> stopping Prysm validator only (beacon on $BEACON_RPC_PROVIDER unchanged)"
VALIDATOR_PID_FILE="$NODE_DIR/validator.pid"
if [[ -f "$VALIDATOR_PID_FILE" ]]; then
  OLD_PID="$(cat "$VALIDATOR_PID_FILE" 2>/dev/null || true)"
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill "$OLD_PID" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 "$OLD_PID" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$OLD_PID" 2>/dev/null || true
  fi
fi
# Fallback: any validator using this remote beacon
pkill -f "${PRYSM_VALIDATOR_BINARY}.*--beacon-rpc-provider=${BEACON_RPC_PROVIDER}" 2>/dev/null || true
sleep 2

echo "==> starting Prysm validator with ConetLabMiningPool fee_recipient"
nohup "$PRYSM_VALIDATOR_BINARY" \
  --beacon-rpc-provider="$BEACON_RPC_PROVIDER" \
  --datadir="$VALIDATOR_DATA_DIR" \
  --accept-terms-of-use \
  --wallet-dir="$VALIDATOR_WALLET_DIR" \
  --wallet-password-file="$WALLET_PASSWORD_FILE" \
  --rpc-port="$PRYSM_VALIDATOR_RPC_PORT" \
  --grpc-gateway-port="$PRYSM_VALIDATOR_GRPC_GATEWAY_PORT" \
  --monitoring-port="$PRYSM_VALIDATOR_MONITORING_PORT" \
  --graffiti="conet-append-validator" \
  --chain-config-file="$CHAIN_CONFIG_FILE" \
  --suggested-fee-recipient="$FEE_RECIPIENT" \
  --proposer-settings-file="$PROPOSER_FILE" \
  >>"$NODE_DIR/validator.log" 2>&1 &
echo $! >"$VALIDATOR_PID_FILE"
sleep 3
NEW_PID="$(cat "$VALIDATOR_PID_FILE")"
if kill -0 "$NEW_PID" 2>/dev/null; then
  echo "OK: validator pid=$NEW_PID fee_recipient=$FEE_RECIPIENT proposer-settings=$PROPOSER_FILE"
else
  echo "ERROR: validator failed to start; tail $NODE_DIR/validator.log" >&2
  tail -40 "$NODE_DIR/validator.log" >&2 || true
  exit 1
fi
