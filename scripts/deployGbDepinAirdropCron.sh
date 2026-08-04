#!/usr/bin/env bash
# Deploy x402sdk Master with DePIN GB paid airdrop cron (every 60s, Settle_ContractPool admins).
#
# Usage:
#   ./scripts/deployGbDepinAirdropCron.sh
#   ./scripts/deployGbDepinAirdropCron.sh --dry-run
#
# Env:
#   BEAMIO_DEPLOY_HOST (default conet.network)
#   BEAMIO_DEPLOY_USER (default peter)
#   X402SDK_ROOT       (default /home/peter/x402sdk on remote)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
X402SDK_LOCAL="$ROOT/src/x402sdk"
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

HOST="${BEAMIO_DEPLOY_HOST:-conet.network}"
USER="${BEAMIO_DEPLOY_USER:-peter}"
REMOTE_ROOT="${X402SDK_ROOT:-/home/peter/x402sdk}"
SERVICE="${BEAMIO_MASTER_SERVICE:-conet-beamio-api.service}"
ENV_FILE="/etc/default/conet-gb-depin-airdrop-cron"
GB_DEPIN_AIRDROP="${CONET_GB_DEPIN_AIRDROP:-0x62bcc59cC36C737E8AfBb0914F840d12cd33025f}"

echo "== Build x402sdk locally =="
(cd "$X402SDK_LOCAL" && npm run build)

echo "== Rsync dist + service env to ${USER}@${HOST}:${REMOTE_ROOT} =="
RSYNC_OPTS=(-az)
if [[ "$DRY_RUN" == "1" ]]; then
  RSYNC_OPTS+=(--dry-run -n)
fi
rsync "${RSYNC_OPTS[@]}" \
  "$X402SDK_LOCAL/dist/" "${USER}@${HOST}:${REMOTE_ROOT}/dist/"
rsync "${RSYNC_OPTS[@]}" \
  "$X402SDK_LOCAL/service/conet-gb-depin-airdrop-cron.env.example" \
  "${USER}@${HOST}:/tmp/conet-gb-depin-airdrop-cron.env.example"

REMOTE_CMD=$(cat <<EOF
set -euo pipefail
sudo tee ${ENV_FILE} >/dev/null <<ENVEOF
CONET_GB_DEPIN_AIRDROP=${GB_DEPIN_AIRDROP}
CONET_GB_DEPIN_AIRDROP_CRON=1
CONET_GB_DEPIN_AIRDROP_CRON_MS=60000
CONET_GB_DEPIN_AIRDROP_PAGE_SIZE=10
CONET_GB_DEPIN_AIRDROP_MAX_GAS_LIMIT=18000000
CONET_GB_DEPIN_AIRDROP_MAX_GAS_PRICE_GWEI=2
CONET_GB_DEPIN_AIRDROP_GAS_WAIT_FORCE_MS=600000
ENVEOF
sudo chmod 644 ${ENV_FILE}
DROP_IN="/etc/systemd/system/${SERVICE}.d/50-gb-depin-airdrop-cron.conf"
sudo mkdir -p "\$(dirname "\$DROP_IN")"
sudo tee "\$DROP_IN" >/dev/null <<UNITEOF
[Service]
EnvironmentFile=-${ENV_FILE}
UNITEOF
sudo systemctl daemon-reload
sudo systemctl restart ${SERVICE}
sleep 2
sudo systemctl is-active ${SERVICE}
journalctl -u ${SERVICE} -n 30 --no-pager | grep -E 'gbDepinAirdropCron|Starting express' || true
EOF
)

echo "== Configure systemd + restart ${SERVICE} =="
if [[ "$DRY_RUN" == "1" ]]; then
  echo "[dry-run] would ssh ${USER}@${HOST} and run remote setup"
  echo "$REMOTE_CMD"
  exit 0
fi

ssh "${USER}@${HOST}" bash -s <<EOF
$REMOTE_CMD
EOF

echo "Done. Cron: CONET_GB_DEPIN_AIRDROP_CRON=1 interval=60s pageSize=10"
