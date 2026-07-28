#!/usr/bin/env bash
# Register conet-USDC name/symbol/decimals/icon in CoNET Blockscout.
#
#   bash scripts/registerConetUsdcBlockscoutConet.sh
#
# Icon default: Streamline USDC SVG at mainnet.conet.network/usdc/erc20/USDC.svg
set -euo pipefail

HOST="${USDC_BLOCKSCOUT_HOST:-38.102.126.30}"
ADDR="${CONET_USDC_ADDRESS:-0x5209865D404aA5646eDe5B91CD4218909eA72eDA}"
ADDR_HEX="${ADDR#0x}"
ADDR_HEX="$(echo "$ADDR_HEX" | tr '[:upper:]' '[:lower:]')"
ICON_URL="${CONET_USDC_ICON_URL:-https://mainnet.conet.network/usdc/erc20/USDC.svg}"
TOKEN_NAME="${CONET_USDC_TOKEN_NAME:-CoNET USD Coin}"
TOKEN_SYMBOL="${CONET_USDC_TOKEN_SYMBOL:-conet-USDC}"

ssh -o BatchMode=yes "root@${HOST}" bash -s <<REMOTE
set -euo pipefail
PW=\$(docker exec backend printenv DATABASE_URL | sed -n 's#.*://blockscout:\\([^@]*\\)@.*#\\1#p')
docker exec -e PGPASSWORD="\$PW" db psql -U blockscout -d blockscout -c "
INSERT INTO tokens (name, symbol, decimals, type, cataloged, contract_address_hash, inserted_at, updated_at, icon_url, is_verified_via_admin_panel, skip_metadata)
VALUES ('${TOKEN_NAME}', '${TOKEN_SYMBOL}', 6, 'ERC-20', true, decode('${ADDR_HEX}','hex'), NOW(), NOW(), '${ICON_URL}', true, false)
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
