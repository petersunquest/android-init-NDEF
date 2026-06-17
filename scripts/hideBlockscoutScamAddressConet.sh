#!/usr/bin/env bash
# Mark a CoNET Blockscout (scan.conet.network) address as scam so it is hidden from
# /tokens and search when HIDE_SCAM_ADDRESSES=true (see common-blockscout.env).
#
# Blockscout runs on 38.102.126.30 (docker-compose under /media/sda/blockscout).
#
# Usage:
#   ./scripts/hideBlockscoutScamAddressConet.sh 0xe747faB957eD29ec07B81Edab546AF5C6724fCf2
#
# Requires SSH to BLOCKSCOUT_HOST (default peter@38.102.126.30).

set -euo pipefail

ADDR="${1:-}"
if [[ -z "$ADDR" ]]; then
  echo "Usage: $0 <0xaddress>" >&2
  exit 1
fi

ADDR_HEX="${ADDR#0x}"
ADDR_HEX="$(echo "$ADDR_HEX" | tr '[:upper:]' '[:lower:]')"
if [[ ! "$ADDR_HEX" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Invalid address: $ADDR" >&2
  exit 1
fi

BLOCKSCOUT_HOST="${BLOCKSCOUT_HOST:-peter@38.102.126.30}"
ENV_FILE="${BLOCKSCOUT_ENV_FILE:-/media/sda/blockscout/docker-compose/envs/common-blockscout.env}"
COMPOSE_DIR="${BLOCKSCOUT_COMPOSE_DIR:-/media/sda/blockscout/docker-compose}"

ssh "$BLOCKSCOUT_HOST" bash -s -- "$ADDR_HEX" "$ENV_FILE" "$COMPOSE_DIR" <<'REMOTE'
set -euo pipefail
ADDR_HEX="$1"
ENV_FILE="$2"
COMPOSE_DIR="$3"

sudo docker exec db psql -U blockscout -d blockscout -v ON_ERROR_STOP=1 -c \
  "INSERT INTO scam_address_badge_mappings (address_hash, inserted_at, updated_at)
   VALUES (decode('${ADDR_HEX}', 'hex'), NOW(), NOW())
   ON CONFLICT (address_hash) DO NOTHING;"

if ! grep -q '^HIDE_SCAM_ADDRESSES=' "$ENV_FILE"; then
  echo 'HIDE_SCAM_ADDRESSES=true' >> "$ENV_FILE"
else
  sed -i 's/^HIDE_SCAM_ADDRESSES=.*/HIDE_SCAM_ADDRESSES=true/' "$ENV_FILE"
fi

cd "$COMPOSE_DIR"
sudo docker compose up -d backend

echo "Done. Verify: curl -s https://scan.conet.network/api/v2/tokens | jq '.items[].address_hash'"
REMOTE

echo "Scam badge set for $ADDR (hidden from /tokens when reputation=scam and list filter active)."
