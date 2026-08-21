#!/usr/bin/env bash
# One-shot mock-L1 auction E2E: hardhat node → deploy → CoNET-DLE on-chain settle.
# Local only — refuses CoNET 224422. Never use these keys on mainnet.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DLE="$ROOT/src/conet-layer2"
PORT="${MOCK_L1_PORT:-8545}"
RPC="http://127.0.0.1:${PORT}"
LOG="${TMPDIR:-/tmp}/hardhat-node-mock-auction.$$.log"
NODE_PID=""

cleanup() {
  if [[ -n "${NODE_PID}" ]] && kill -0 "${NODE_PID}" 2>/dev/null; then
    kill "${NODE_PID}" 2>/dev/null || true
    wait "${NODE_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

cd "$ROOT"

if [[ ! -d "$DLE" ]]; then
  echo "missing CoNET-DLE at $DLE" >&2
  exit 1
fi

# Prefer free port if 8545 is busy.
if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT in use — set MOCK_L1_PORT or free the port" >&2
  exit 1
fi

echo "starting hardhat node on $RPC …"
npx hardhat node --hostname 127.0.0.1 --port "$PORT" >"$LOG" 2>&1 &
NODE_PID=$!

ready=0
for _ in $(seq 1 90); do
  if curl -sf -X POST "$RPC" \
    -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
    | grep -q '"result"'; then
    ready=1
    break
  fi
  if ! kill -0 "${NODE_PID}" 2>/dev/null; then
    echo "hardhat node exited early; log:" >&2
    cat "$LOG" >&2 || true
    exit 1
  fi
  sleep 0.5
done
if [[ "$ready" -ne 1 ]]; then
  echo "hardhat node did not become ready; log:" >&2
  cat "$LOG" >&2 || true
  exit 1
fi

echo "deploying mock auction stack …"
# hardhat/dotenv may print non-JSON noise on stdout — extract the JSON object.
DEPLOY_RAW="$(npx hardhat run scripts/dle/deployMockL1AuctionLocal.ts --network localhost)"
DEPLOY_JSON="$(
  printf '%s\n' "$DEPLOY_RAW" | node --input-type=module -e "
let s = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (d) => { s += d; });
process.stdin.on('end', () => {
  const i = s.indexOf('{');
  const j = s.lastIndexOf('}');
  if (i < 0 || j <= i) {
    console.error('deploy output missing JSON object');
    console.error(s);
    process.exit(1);
  }
  process.stdout.write(s.slice(i, j + 1));
});
"
)"
echo "$DEPLOY_JSON"

# Export env from deploy JSON for the DLE e2e.
eval "$(
  node --input-type=module -e "
const j = JSON.parse(process.argv[1]);
const e = j.env || {};
for (const [k, v] of Object.entries(e)) {
  if (typeof v === 'string') {
    console.log('export ' + k + '=' + JSON.stringify(v));
  }
}
" "$DEPLOY_JSON"
)"

export MOCK_L1_RPC_URL="${MOCK_L1_RPC_URL:-$RPC}"
export MOCK_L1_SETTLE_ONCHAIN=1

cd "$DLE"

# Round 10: recovery first (list → fail → unlist, NFT back to seller), then happy settle.
echo "running CoNET-DLE mock-auction-e2e (recovery) …"
MOCK_L1_E2E_MODE=recovery npm run mock-auction-e2e

echo "running CoNET-DLE mock-auction-e2e (settle) …"
MOCK_L1_E2E_MODE=settle npm run mock-auction-e2e
