#!/usr/bin/env bash
# Deploy CoNET Blockscout homepage metrics API to scan host (.30).
# Run: bash scripts/deployConetHomepageMetrics.sh
set -euo pipefail
HOST="${CONET_SCAN_HOST:-38.102.126.30}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/scripts/conet-homepage-metrics.py"
REMOTE="/opt/conet-scan/conet-homepage-metrics.py"

if [[ ! -f "$SRC" ]]; then
  echo "Missing $SRC"
  exit 1
fi

echo "==> scp -> root@${HOST}:${REMOTE}"
scp -o BatchMode=yes "$SRC" "root@${HOST}:${REMOTE}"

echo "==> restart conet-homepage-metrics.service"
ssh -o BatchMode=yes "root@${HOST}" "systemctl restart conet-homepage-metrics.service && systemctl is-active conet-homepage-metrics.service"

echo "==> smoke test"
sleep 2
curl -fsS "https://mainnet.conet.network/api/conet/homepage-metrics" | python3 -c "
import json,sys
j=json.load(sys.stdin)
print('estimated_total_supply_cnet', j.get('estimated_total_supply_cnet'))
print('net_consensus_issuance_cnet', j.get('net_consensus_issuance_cnet'))
print('consensus_issuance_cnet', j.get('consensus_issuance_cnet'))
print('el_execution_issuance_cnet', j.get('el_execution_issuance_cnet'))
print('el_circulating_cnet', j.get('el_circulating_cnet'))
"
echo "Done."
