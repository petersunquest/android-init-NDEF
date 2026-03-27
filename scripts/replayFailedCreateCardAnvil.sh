#!/usr/bin/env bash
# Replay a failed createCardCollectionWithInitCodeAndTiers on a local Anvil fork.
# Uses impersonation — no private key. Funds the paymaster with anvil_setBalance for gas.
#
# Usage:
#   ./scripts/replayFailedCreateCardAnvil.sh
# Env overrides:
#   FORK_URL   (default https://base-rpc.conet.network)
#   ANVIL_PORT (default 8549)
#   FAILED_TX  (default 0xf3257d9dc9cf0df398fac87ba50bb993d589fa14d5783b0b73f905acb2bd35c8)
#   PAYMASTER  (default 0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1)
#   FACTORY    (default 0x2EB245646de404b2Dce87E01C6282C131778bb05)

set -euo pipefail
FORK_URL="${FORK_URL:-https://base-rpc.conet.network}"
ANVIL_PORT="${ANVIL_PORT:-8549}"
FAILED_TX="${FAILED_TX:-0xf3257d9dc9cf0df398fac87ba50bb993d589fa14d5783b0b73f905acb2bd35c8}"
PAYMASTER="${PAYMASTER:-0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1}"
FACTORY="${FACTORY:-0x2EB245646de404b2Dce87E01C6282C131778bb05}"
RPC="http://127.0.0.1:${ANVIL_PORT}"

echo "Starting anvil fork on ${RPC} ..."
anvil --fork-url "${FORK_URL}" --port "${ANVIL_PORT}" --silent &
ANVIL_PID=$!
trap 'kill ${ANVIL_PID} 2>/dev/null || true' EXIT
sleep 2

cast rpc anvil_impersonateAccount "${PAYMASTER}" --rpc-url "${RPC}" >/dev/null
cast rpc anvil_setBalance "${PAYMASTER}" 0x3635C9ADC5DEA00000 --rpc-url "${RPC}" >/dev/null

INPUT="$(cast tx "${FAILED_TX}" --rpc-url "${FORK_URL}" -j | jq -r .input)"
echo "Replaying calldata from ${FAILED_TX} as ${PAYMASTER} -> ${FACTORY} ..."
set +e
OUT="$(cast send "${FACTORY}" "${INPUT}" --from "${PAYMASTER}" --unlocked --gas-limit 8000000 --rpc-url "${RPC}" 2>&1)"
EC=$?
set -e
echo "${OUT}"
if [[ ${EC} -ne 0 ]]; then exit ${EC}; fi
HASH="$(echo "${OUT}" | awk '/transactionHash/ {print $2}')"
if [[ -n "${HASH}" ]]; then
  echo "--- cast run (trace) ---"
  cast run "${HASH}" --rpc-url "${RPC}" 2>&1 | tail -30
fi
