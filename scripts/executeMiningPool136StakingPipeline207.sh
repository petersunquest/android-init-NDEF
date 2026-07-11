#!/usr/bin/env bash
# Manual full staking pipeline on 207.90.192.71 for ConetLabMiningPool 136 validators.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST="${VALIDATOR_LISTENER_HOST:-207.90.192.71}"
USER="${VALIDATOR_LISTENER_USER:-peter}"
NEWCONET="${VALIDATOR_NEWCONET_DIR:-/home/peter/ethereum-pos-mainnet}"
SSH="${USER}@${HOST}"
REDEEM="0xc71e246DD78B37C2fABc905D340932F28F503433"
POOL="0x32bE583C8e778FFfC5107BF34820c2B225336201"
COUNT=136

echo "==> [1/5] Install redeem admin key on ${HOST}"
VALIDATOR_LISTENER_HOST="$HOST" VALIDATOR_LISTENER_USER="$USER" VALIDATOR_NEWCONET_DIR="$NEWCONET" \
	"$SCRIPT_DIR/installValidatorNodeRedeemAdminKey.sh"

echo "==> [2/5] Rsync listener wrapper + 08_import to ${NEWCONET}"
rsync -av \
	"$REPO_ROOT/scripts/validator-node/01_generate_append_validator_deposits_listener.sh" \
	"$REPO_ROOT/scripts/validator-node/08_import_append_validator_keys.sh" \
	"${SSH}:${NEWCONET}/"
ssh "$SSH" "chmod +x '${NEWCONET}/01_generate_append_validator_deposits_listener.sh' '${NEWCONET}/08_import_append_validator_keys.sh'"

echo "==> [3/5] Generate ${COUNT} validator keystores + deposit data (correct Redeem withdrawal)"
ssh "$SSH" bash -s -- "$NEWCONET" "$REDEEM" "$COUNT" <<'REMOTE'
set -euo pipefail
NEWCONET="$1"
REDEEM="$2"
COUNT="$3"
cd "$NEWCONET"
KEYSTORE_PASSWORD="$(cat secrets/validator_keystore_password.txt)"
WALLET_PASSWORD="$(cat secrets/prysm_wallet_password.txt)"
export KEYSTORE_PASSWORD WALLET_PASSWORD
export VALIDATOR_COUNT="$COUNT"
export WITHDRAWAL_ADDRESS_RAW="$REDEEM"
export CONFIRM_OVERRIDE_WITHDRAWAL_ADDRESS=YES
export CONFIRM_REPLACE=REPLACE
export DEPOSIT_NON_INTERACTIVE=YES
export NETWORK_NAME=conet-mainnet
export DEPOSIT_CONTRACT_ADDRESS=0x4242424242424242424242424242424242424242
./01_generate_append_validator_deposits_listener.sh
python3 - <<'PY'
import json
with open("validator_deposits.json") as f:
    d=json.load(f)
print("validator_deposits.json entries:", len(d))
wc=d[-1].get("withdrawal_credentials","")
print("last withdrawal_credentials prefix:", wc[:34])
PY
REMOTE

echo "==> [4/5] fundAndDepositValidators from local (redeem admin signs; stake from contract)"
node "$SCRIPT_DIR/fundMiningPool136Validators207.mjs"

echo "==> [5/5] Import new keystores + reload Prysm validator on ${HOST}"
ssh "$SSH" bash -s -- "$NEWCONET" "$POOL" <<'REMOTE'
set -euo pipefail
NEWCONET="$1"
POOL="$2"
cd "$NEWCONET"
export KEYSTORE_PASSWORD="$(cat secrets/validator_keystore_password.txt)"
export WALLET_PASSWORD="$(cat secrets/prysm_wallet_password.txt)"
export FEE_RECIPIENT="$POOL"
export RELOAD_VALIDATOR_AFTER_IMPORT=YES
export PRYSM_BEACON_RPC_PORT=4000
./08_import_append_validator_keys.sh
REMOTE

echo "==> Chain verification"
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
 const nonempty=b.validatorPubkeys.filter(pk=>ethers.hexlify(pk)!=='0x' && ethers.hexlify(pk).length>10).length;
 console.log(JSON.stringify({stakedValidatorCountOf:staked.toString(),validatorActive_onChain:active,nonemptyPubkeys:nonempty},null,2));
})();
"

echo "==> Done. Spot-check VA logs on ${HOST}: journalctl -u conet-prysm-validator -n 30 (or validator pid logs)"
