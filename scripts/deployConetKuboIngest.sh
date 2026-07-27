#!/usr/bin/env bash
# Deploy conet-kubo-ingest to a Kubo pin peer host.
# Usage:
#   CONET_KUBO_INGEST_TOKEN='...' ./scripts/deployConetKuboIngest.sh 38.102.85.33
#   CONET_KUBO_INGEST_TOKEN='...' ./scripts/deployConetKuboIngest.sh 207.90.192.71
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_PY="$REPO_ROOT/src/x402sdk/scripts/kubo-ingest/conet_kubo_ingest.py"
UNIT_SRC="$REPO_ROOT/src/x402sdk/service/systemd/conet-kubo-ingest.service"

HOST="${1:-}"
USER_NAME="${CONET_KUBO_INGEST_SSH_USER:-peter}"
TOKEN="${CONET_KUBO_INGEST_TOKEN:-}"

if [[ -z "$HOST" ]]; then
	echo "Usage: CONET_KUBO_INGEST_TOKEN=... $0 <host>" >&2
	exit 2
fi
if [[ -z "$TOKEN" ]]; then
	echo "CONET_KUBO_INGEST_TOKEN required" >&2
	exit 2
fi
if [[ ! -f "$SRC_PY" || ! -f "$UNIT_SRC" ]]; then
	echo "missing source files" >&2
	exit 2
fi

TARGET="${USER_NAME}@${HOST}"
echo "==> Deploy conet-kubo-ingest to ${TARGET}"

ssh "$TARGET" 'sudo mkdir -p /opt/conet-kubo-ingest /etc/conet-kubo-ingest /var/lib/ipfs/conet-fragment-map /var/lib/ipfs/tmp'
scp "$SRC_PY" "$TARGET:/tmp/conet_kubo_ingest.py"
scp "$UNIT_SRC" "$TARGET:/tmp/conet-kubo-ingest.service"
ssh "$TARGET" "set -euo pipefail
sudo install -o root -g root -m 0755 /tmp/conet_kubo_ingest.py /opt/conet-kubo-ingest/conet_kubo_ingest.py
sudo install -o root -g root -m 0644 /tmp/conet-kubo-ingest.service /etc/systemd/system/conet-kubo-ingest.service
printf '%s\n' '${TOKEN}' | sudo tee /etc/conet-kubo-ingest/token >/dev/null
sudo chown root:ipfs /etc/conet-kubo-ingest/token
sudo chmod 640 /etc/conet-kubo-ingest/token
sudo chown -R ipfs:ipfs /var/lib/ipfs/conet-fragment-map /var/lib/ipfs/tmp /opt/conet-kubo-ingest
sudo systemctl daemon-reload
sudo systemctl enable conet-kubo-ingest
sudo systemctl restart conet-kubo-ingest
sleep 1
systemctl is-active conet-kubo-ingest
curl -fsS http://127.0.0.1:9545/health
echo
"
echo "==> Done ${HOST}"
