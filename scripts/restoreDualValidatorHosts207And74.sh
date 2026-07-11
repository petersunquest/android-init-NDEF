#!/usr/bin/env bash
# Restore independent 136+136 validators: pool batch on 207, legacy batch on 74.
# Reverts mistaken migration of 207 keystores/deposits onto 74.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST74="${VALIDATOR_HOST_74:-74.208.224.45}"
HOST207="${VALIDATOR_HOST_207:-207.90.192.71}"
USER="${VALIDATOR_SSH_USER:-peter}"
NEWCONET="${VALIDATOR_NEWCONET_DIR:-/home/peter/ethereum-pos-mainnet}"
SSH74="${USER}@${HOST74}"
SSH207="${USER}@${HOST207}"

POOL="0x32bE583C8e778FFfC5107BF34820c2B225336201"
LEGACY_FEE="0x0981275553A41E00ec1006fe074971285E00c2A3"
LEGACY_BAK="validator_deposits.json.bak-legacy-20260710053547"

echo "==> [1/4] Restore 74 legacy deposits + fee_recipient (stop pool VA config)"
ssh "$SSH74" bash -s -- "$NEWCONET" "$LEGACY_FEE" "$LEGACY_BAK" <<'REMOTE'
set -euo pipefail
NEWCONET="$1"
LEGACY_FEE="$2"
LEGACY_BAK="$3"
cd "$NEWCONET"
[[ -f "$LEGACY_BAK" ]] || { echo "ERROR: missing $LEGACY_BAK" >&2; exit 1; }
cp -a "$LEGACY_BAK" validator_deposits.json
# Remove pool proposer-settings (pubkeys were 207 batch)
rm -f network/node-0/consensus/validatordata/proposer-settings.json
# Stop current validator (pool-tuned)
PIDFILE=network/node-0/validator.pid
if [[ -f "$PIDFILE" ]]; then
  PID="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    sleep 3
    kill -9 "$PID" 2>/dev/null || true
  fi
fi
pkill -f './dependencies/prysm-.*/validator.*127.0.0.1:4000' 2>/dev/null || true
sleep 2
export PRYSM_VALIDATOR_BINARY="./dependencies/prysm-v7.1.4/validator"
NODE_DIR=./network/node-0
VALIDATOR_DATA_DIR="$NODE_DIR/consensus/validatordata"
VALIDATOR_WALLET_DIR="$NODE_DIR/consensus/validator-wallet"
CHAIN_CONFIG_FILE="$NODE_DIR/consensus/config.yml"
WALLET_PASSWORD_FILE=./secrets/prysm_wallet_password.txt
nohup "$PRYSM_VALIDATOR_BINARY" \
  --beacon-rpc-provider=127.0.0.1:4000 \
  --datadir="$VALIDATOR_DATA_DIR" \
  --accept-terms-of-use \
  --wallet-dir="$VALIDATOR_WALLET_DIR" \
  --wallet-password-file="$WALLET_PASSWORD_FILE" \
  --rpc-port=7000 --grpc-gateway-port=7100 --monitoring-port=7200 \
  --graffiti=conet-append-validator \
  --chain-config-file="$CHAIN_CONFIG_FILE" \
  --suggested-fee-recipient="$LEGACY_FEE" \
  >>"$NODE_DIR/validator.log" 2>&1 &
echo $! >"$PIDFILE"
sleep 3
kill -0 "$(cat "$PIDFILE")" && echo "OK 74 validator pid=$(cat "$PIDFILE") fee=$LEGACY_FEE"
python3 -c "import json;d=json.load(open('validator_deposits.json'));print('74 pk0',d[0]['pubkey'][:24])"
REMOTE

echo "==> [2/4] Rsync fee script to 207 if needed"
rsync -av "$REPO_ROOT/scripts/validator-node/setConetLabMiningPoolFeeRecipient207.sh" "${SSH207}:${NEWCONET}/"
ssh "$SSH207" "chmod +x '${NEWCONET}/setConetLabMiningPoolFeeRecipient207.sh'"

echo "==> [3/4] Restart 207 pool VA (beacon -> 74:4000)"
ssh "$SSH207" bash -s -- "$NEWCONET" "$POOL" <<'REMOTE'
set -euo pipefail
NEWCONET="$1"
POOL="$2"
cd "$NEWCONET"
export PRYSM_VALIDATOR_BINARY="./dependencies/prysm-v7.1.5/validator"
[[ -x "$PRYSM_VALIDATOR_BINARY" ]] || export PRYSM_VALIDATOR_BINARY="./dependencies/prysm-v7.1.4/validator"
export VALIDATOR_DEPOSITS_FILE="$NEWCONET/validator_deposits.json"
export PROPOSER_SETTINGS_FILE="$NEWCONET/network/node-0/consensus/validatordata/proposer-settings.json"
FEE_RECIPIENT="$POOL" BEACON_RPC_PROVIDER=74.208.224.45:4000 \
  ./setConetLabMiningPoolFeeRecipient207.sh
python3 -c "import json;d=json.load(open('validator_deposits.json'));print('207 pk0',d[0]['pubkey'][:24],'wc',d[0]['withdrawal_credentials'][:34])"
REMOTE

echo "==> [4/4] Spot-check both hosts"
ssh "$SSH74" 'pgrep -af "prysm.*validator" | head -1'
ssh "$SSH207" 'pgrep -af "prysm.*validator" | head -1'
echo "==> Done. 207=pool 136, 74=legacy 136 (independent)."
