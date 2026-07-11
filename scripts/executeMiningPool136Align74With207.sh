#!/usr/bin/env bash
# DEPRECATED: syncs 207 pool guardian-bound keys to 74. Use executeManual136StakingVaOn74.sh instead
# (74 manual 136 VA — no Guardian / mining-pool slot binding).
# Exit legacy 136 validators on 74.208.224.45, then align with 207 pool staking
# (same Redeem withdrawal + ConetLabMiningPool fee_recipient / on-chain pubkeys).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST74="${VALIDATOR_HOST_74:-74.208.224.45}"
HOST207="${VALIDATOR_HOST_207:-207.90.192.71}"
USER="${VALIDATOR_SSH_USER:-peter}"
NEWCONET="${VALIDATOR_NEWCONET_DIR:-/home/peter/ethereum-pos-mainnet}"
SSH74="${USER}@${HOST74}"
SSH207="${USER}@${HOST207}"
REDEEM="0xc71e246DD78B37C2fABc905D340932F28F503433"
POOL="0x32bE583C8e778FFfC5107BF34820c2B225336201"
COUNT=136

echo "==> [1/7] Rsync validator-node scripts to ${HOST74}"
rsync -av \
	"$REPO_ROOT/scripts/validator-node/06_exit_validator.sh" \
	"$REPO_ROOT/scripts/validator-node/01_generate_append_validator_deposits_listener.sh" \
	"$REPO_ROOT/scripts/validator-node/08_import_append_validator_keys.sh" \
	"$REPO_ROOT/scripts/validator-node/setConetLabMiningPoolFeeRecipient207.sh" \
	"$REPO_ROOT/scripts/validator-node/conet_fee_recipient_defaults.sh" \
	"$REPO_ROOT/scripts/validator-node/batchExitValidatorsFromDeposits.sh" \
	"${SSH74}:${NEWCONET}/"
ssh "$SSH74" "chmod +x '${NEWCONET}/06_exit_validator.sh' '${NEWCONET}/01_generate_append_validator_deposits_listener.sh' '${NEWCONET}/08_import_append_validator_keys.sh' '${NEWCONET}/setConetLabMiningPoolFeeRecipient207.sh' '${NEWCONET}/batchExitValidatorsFromDeposits.sh'"

echo "==> [2/7] Backup + voluntary-exit legacy ${COUNT} validators on ${HOST74}"
ssh "$SSH74" bash -s -- "$NEWCONET" <<'REMOTE'
set -euo pipefail
NEWCONET="$1"
cd "$NEWCONET"
export PRYSM_VALIDATOR_BINARY="./dependencies/prysm-v7.1.4/validator"
[[ -x "$PRYSM_VALIDATOR_BINARY" ]] || export PRYSM_VALIDATOR_BINARY="./dependencies/prysm-v7.1.5/validator"
cp -a validator_deposits.json "validator_deposits.json.bak-legacy-$(date +%Y%m%d%H%M%S)"
BEACON_RPC_PROVIDER=127.0.0.1:4000 PRYSM_BEACON_RPC_PORT=4000 \
	./batchExitValidatorsFromDeposits.sh
REMOTE

echo "==> [3/7] Sync pool-aligned deposits + keystores from ${HOST207} -> ${HOST74}"
ssh "$SSH207" "tar czf - -C '${NEWCONET}' validator_deposits.json append_validator_keys_archive" \
	| ssh "$SSH74" "tar xzf - -C '${NEWCONET}'"

echo "==> [4/7] Import pool keystores on ${HOST74} (no restart yet)"
ssh "$SSH74" bash -s -- "$NEWCONET" "$POOL" <<'REMOTE'
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
export VALIDATOR_KEYS_SOURCE_DIR="$NEWCONET/append_validator_keys_archive"
./08_import_append_validator_keys.sh
REMOTE

echo "==> [5/7] proposer-settings + restart validator on ${HOST74}"
ssh "$SSH74" bash -s -- "$NEWCONET" "$POOL" <<'REMOTE'
set -euo pipefail
NEWCONET="$1"
POOL="$2"
cd "$NEWCONET"
export PRYSM_VALIDATOR_BINARY="./dependencies/prysm-v7.1.4/validator"
[[ -x "$PRYSM_VALIDATOR_BINARY" ]] || export PRYSM_VALIDATOR_BINARY="./dependencies/prysm-v7.1.5/validator"
export VALIDATOR_DEPOSITS_FILE="$NEWCONET/validator_deposits.json"
export PROPOSER_SETTINGS_FILE="$NEWCONET/network/node-0/consensus/validatordata/proposer-settings.json"
FEE_RECIPIENT="$POOL" BEACON_RPC_PROVIDER=127.0.0.1:4000 \
	./setConetLabMiningPoolFeeRecipient207.sh
REMOTE

echo "==> [6/7] Stop validator on ${HOST207} (prevent double-sign with same pubkeys)"
ssh "$SSH207" bash -s -- "$NEWCONET" <<'REMOTE'
set -euo pipefail
NEWCONET="$1"
cd "$NEWCONET"
PIDFILE=network/node-0/validator.pid
if [[ -f "$PIDFILE" ]]; then
  PID="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    echo "Stopping 207 validator pid=$PID"
    kill "$PID" || true
    sleep 3
    kill -9 "$PID" 2>/dev/null || true
  fi
fi
pkill -f './dependencies/prysm-.*/validator.*74.208.224.45:4000' 2>/dev/null || true
echo "207 validator stopped"
REMOTE

echo "==> [7/7] Verify pubkey alignment + on-chain pool"
ssh "$SSH74" "python3 -c \"import json;d=json.load(open('${NEWCONET}/validator_deposits.json'));print('74 pk0',d[0]['pubkey'][:24]);print('wc',d[0]['withdrawal_credentials'][:34])\""
node -e "
const { ethers } = require('ethers');
const REDEEM='${REDEEM}';
const POOL='${POOL}';
const abi=['function stakedValidatorCountOf(address) view returns (uint256)','function getBeneficiaryNodeBundle(address) view returns (tuple(address beneficiary,uint256[] guardianNodeIds,string[] depinNodeIps,address[] nodeWallets,bytes[] validatorPubkeys,bool[] validatorActive,uint256 validatorNodeCount,uint256 gbMiningNodeCount,uint256 claimCount,uint256 nativeBalance,uint256 gbBalance,uint256 usdcBalance))'];
(async()=>{
 const p=new ethers.JsonRpcProvider('https://publicrpc.conet.network');
 const c=new ethers.Contract(REDEEM,abi,p);
 const staked=await c.stakedValidatorCountOf(POOL);
 const b=await c.getBeneficiaryNodeBundle(POOL);
 const active=b.validatorActive.filter(Boolean).length;
 const pk0=ethers.hexlify(b.validatorPubkeys[0]).slice(2).toLowerCase();
 console.log(JSON.stringify({stakedValidatorCountOf:staked.toString(),validatorActive_onChain:active,chainPk0Prefix:pk0.slice(0,24)},null,2));
})();
"

echo "==> Done. 74 should run pool-aligned validators; 207 VA stopped."
