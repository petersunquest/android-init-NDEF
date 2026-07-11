#!/usr/bin/env bash
# Manual 288 staking validators on any CoNET VA host — same model as 74 / 216.225.202.22.
#   VALIDATOR_HOST=38.102.126.50 ./scripts/executeManual288StakingVaOnHost.sh
#   SKIP_DEPOSIT=1 — skip step 4 (run deposit separately with VALIDATOR_HOST + VALIDATOR_COUNT)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST="${VALIDATOR_HOST:?set VALIDATOR_HOST}"
USER="${VALIDATOR_SSH_USER:-peter}"
NEWCONET="${VALIDATOR_NEWCONET_DIR:-/home/peter/ethereum-pos-mainnet}"
SSH="${USER}@${HOST}"
REDEEM="0xc71e246DD78B37C2fABc905D340932F28F503433"
POOL="0x32bE583C8e778FFfC5107BF34820c2B225336201"
COUNT="${VALIDATOR_COUNT:-288}"

echo "==> [1/6] Rsync validator-node scripts to ${HOST}"
rsync -av \
	"$REPO_ROOT/scripts/validator-node/01_generate_append_validator_deposits_listener.sh" \
	"$REPO_ROOT/scripts/validator-node/08_import_append_validator_keys.sh" \
	"$REPO_ROOT/scripts/validator-node/setConetLabMiningPoolFeeRecipient74.sh" \
	"$REPO_ROOT/scripts/validator-node/conet_fee_recipient_defaults.sh" \
	"$REPO_ROOT/scripts/validator-node/batchExitValidatorsFromDeposits.sh" \
	"$REPO_ROOT/scripts/validator-node/06_exit_validator.sh" \
	"${SSH}:${NEWCONET}/"
ssh "$SSH" "chmod +x '${NEWCONET}/01_generate_append_validator_deposits_listener.sh' '${NEWCONET}/08_import_append_validator_keys.sh' '${NEWCONET}/setConetLabMiningPoolFeeRecipient74.sh' '${NEWCONET}/batchExitValidatorsFromDeposits.sh' '${NEWCONET}/06_exit_validator.sh'"

echo "==> [2/6] Voluntary-exit legacy ${COUNT} validators on ${HOST}"
ssh "$SSH" bash -s -- "$NEWCONET" <<'REMOTE'
set -euo pipefail
NEWCONET="$1"
cd "$NEWCONET"
export PRYSM_VALIDATOR_BINARY="./dependencies/prysm-v7.1.4/validator"
[[ -x "$PRYSM_VALIDATOR_BINARY" ]] || export PRYSM_VALIDATOR_BINARY="./dependencies/prysm-v7.1.5/validator"
if [[ -f validator_deposits.json ]]; then
  cp -a validator_deposits.json "validator_deposits.json.bak-legacy-$(date +%Y%m%d%H%M%S)"
fi
if pgrep -f './dependencies/prysm-.*/validator' >/dev/null 2>&1; then
  BEACON_RPC_PROVIDER=127.0.0.1:4000 PRYSM_BEACON_RPC_PORT=4000 \
    ./batchExitValidatorsFromDeposits.sh || echo "WARN: batch exit returned non-zero"
fi
REMOTE

echo "==> [3/6] Generate ${COUNT} NEW validator keys (wc=ValidatorDepositRedeem) on ${HOST}"
ssh "$SSH" bash -s -- "$NEWCONET" "$REDEEM" "$COUNT" <<'REMOTE'
set -euo pipefail
NEWCONET="$1"
REDEEM="$2"
COUNT="$3"
cd "$NEWCONET"
export PRYSM_VALIDATOR_BINARY="./dependencies/prysm-v7.1.4/validator"
[[ -x "$PRYSM_VALIDATOR_BINARY" ]] || export PRYSM_VALIDATOR_BINARY="./dependencies/prysm-v7.1.5/validator"
export KEYSTORE_PASSWORD="$(cat secrets/validator_keystore_password.txt)"
export WALLET_PASSWORD="$(cat secrets/prysm_wallet_password.txt)"
export VALIDATOR_COUNT="$COUNT"
export WITHDRAWAL_ADDRESS_RAW="$REDEEM"
export CONFIRM_OVERRIDE_WITHDRAWAL_ADDRESS=YES
export CONFIRM_REPLACE=REPLACE
export DEPOSIT_NON_INTERACTIVE=YES
export NETWORK_NAME=conet-mainnet
export DEPOSIT_CONTRACT_ADDRESS=0x4242424242424242424242424242424242424242
./01_generate_append_validator_deposits_listener.sh
python3 -c "
import json
d=json.load(open('validator_deposits.json'))
wc=d[0]['withdrawal_credentials'].lower()
assert wc.startswith('010000000000000000000000c71e246dd78b37c2fabc905d340932f28f503433'), wc
print('OK deposits', len(d), 'wc prefix', wc[:34])
"
REMOTE

if [[ "${SKIP_DEPOSIT:-}" != "1" ]]; then
  echo "==> [4/6] withdrawNative + direct beacon deposit (no guardian ledger)"
  VALIDATOR_COUNT="$COUNT" VALIDATOR_HOST="$HOST" \
    node "$REPO_ROOT/scripts/depositManual136BeaconFromRedeemBalance.mjs"
else
  echo "==> [4/6] SKIP_DEPOSIT=1"
fi

echo "==> [5/6] Import keystores on ${HOST}"
ssh "$SSH" bash -s -- "$NEWCONET" "$POOL" <<'REMOTE'
set -euo pipefail
NEWCONET="$1"
POOL="$2"
cd "$NEWCONET"
export PRYSM_VALIDATOR_BINARY="./dependencies/prysm-v7.1.4/validator"
[[ -x "$PRYSM_VALIDATOR_BINARY" ]] || export PRYSM_VALIDATOR_BINARY="./dependencies/prysm-v7.1.5/validator"
export KEYSTORE_PASSWORD="$(cat secrets/validator_keystore_password.txt)"
export WALLET_PASSWORD="$(cat secrets/prysm_wallet_password.txt)"
export FEE_RECIPIENT="$POOL"
export RELOAD_VALIDATOR_AFTER_IMPORT=NO
export VALIDATOR_KEYS_SOURCE_DIR="$NEWCONET/append_validator_keys"
./08_import_append_validator_keys.sh
REMOTE

echo "==> [6/6] proposer-settings (ConetLabMiningPool) + restart VA on ${HOST}"
ssh "$SSH" bash -s -- "$NEWCONET" "$POOL" <<'REMOTE'
set -euo pipefail
NEWCONET="$1"
POOL="$2"
cd "$NEWCONET"
export PRYSM_VALIDATOR_BINARY="./dependencies/prysm-v7.1.4/validator"
[[ -x "$PRYSM_VALIDATOR_BINARY" ]] || export PRYSM_VALIDATOR_BINARY="./dependencies/prysm-v7.1.5/validator"
export VALIDATOR_DEPOSITS_FILE="$NEWCONET/validator_deposits.json"
export PROPOSER_SETTINGS_FILE="$NEWCONET/network/node-0/consensus/validatordata/proposer-settings.json"
FEE_RECIPIENT="$POOL" BEACON_RPC_PROVIDER=127.0.0.1:4000 \
  ./setConetLabMiningPoolFeeRecipient74.sh
REMOTE

echo "==> Done. ${HOST} manual ${COUNT} VA: Redeem wc, ConetLabMiningPool fee_recipient."
