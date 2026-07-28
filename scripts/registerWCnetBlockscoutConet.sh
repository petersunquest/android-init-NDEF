#!/usr/bin/env bash
# Register wCNET name/symbol/decimals/icon in CoNET Blockscout.
#
#   bash scripts/registerWCnetBlockscoutConet.sh
#
# Icon default: https://mainnet.conet.network/wcnet/erc20/wCNET.svg
set -euo pipefail

HOST="${WCNET_BLOCKSCOUT_HOST:-38.102.126.30}"
ADDR="${WCNET_ADDRESS:-0x2DC57d67C9764DeE5788421029Abaf81B992FAaF}"
ADDR_HEX="${ADDR#0x}"
ADDR_HEX="$(echo "$ADDR_HEX" | tr '[:upper:]' '[:lower:]')"
ICON_URL="${WCNET_TOKEN_ICON_URL:-https://mainnet.conet.network/wcnet/erc20/wCNET.svg}"
TOKEN_NAME="${WCNET_TOKEN_NAME:-Wrapped CoNET}"
TOKEN_SYMBOL="${WCNET_TOKEN_SYMBOL:-wCNET}"

ssh -o BatchMode=yes "root@${HOST}" bash -s <<REMOTE
set -euo pipefail
PW=\$(docker exec backend printenv DATABASE_URL | sed -n 's#.*://blockscout:\\([^@]*\\)@.*#\\1#p')
docker exec -e PGPASSWORD="\$PW" db psql -U blockscout -d blockscout -c "
INSERT INTO tokens (name, symbol, decimals, type, cataloged, contract_address_hash, inserted_at, updated_at, icon_url, is_verified_via_admin_panel, skip_metadata)
VALUES ('${TOKEN_NAME}', '${TOKEN_SYMBOL}', 18, 'ERC-20', true, decode('${ADDR_HEX}','hex'), NOW(), NOW(), '${ICON_URL}', true, false)
ON CONFLICT (contract_address_hash) DO UPDATE SET
  name = EXCLUDED.name,
  symbol = EXCLUDED.symbol,
  decimals = EXCLUDED.decimals,
  cataloged = true,
  icon_url = EXCLUDED.icon_url,
  is_verified_via_admin_panel = true,
  updated_at = NOW();
SELECT name, symbol, decimals, icon_url
FROM tokens
WHERE contract_address_hash = decode('${ADDR_HEX}','hex');
"
REMOTE

echo "Token: https://mainnet.conet.network/token/${ADDR}"
echo "API:   https://mainnet.conet.network/api/v2/tokens/${ADDR}"
echo "Icon:  ${ICON_URL}"
