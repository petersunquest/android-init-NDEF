#!/usr/bin/env bash
# 在 CoNET Blockscout 登记 wCNET 名称/符号/decimals（icon 可选）。
# 运行: bash scripts/registerWCnetBlockscoutConet.sh
# 有 icon 时: WCNET_TOKEN_ICON_URL=https://mainnet.conet.network/wcnet/erc20/wCNET-256.png bash scripts/registerWCnetBlockscoutConet.sh
set -euo pipefail
HOST="${WCNET_BLOCKSCOUT_HOST:-38.102.126.30}"
ADDR="${WCNET_ADDRESS:-0x35bFAD2832E916e54474c4ca9DBd71843C539503}"
ADDR_HEX="${ADDR#0x}"
ADDR_HEX="$(echo "$ADDR_HEX" | tr '[:upper:]' '[:lower:]')"
ICON_URL="${WCNET_TOKEN_ICON_URL:-}"

if [[ -n "$ICON_URL" ]]; then
  ICON_SQL="'${ICON_URL}'"
else
  ICON_SQL="NULL"
fi

ssh -o BatchMode=yes "root@${HOST}" bash -s <<REMOTE
set -euo pipefail
PW=\$(docker exec backend printenv DATABASE_URL | sed -n 's#.*://blockscout:\\([^@]*\\)@.*#\\1#p')
docker exec -e PGPASSWORD="\$PW" db psql -U blockscout -d blockscout -c "
INSERT INTO tokens (name, symbol, decimals, type, cataloged, contract_address_hash, inserted_at, updated_at, icon_url, is_verified_via_admin_panel, skip_metadata)
VALUES ('Wrapped CoNET', 'wCNET', 18, 'ERC-20', true, decode('${ADDR_HEX}','hex'), NOW(), NOW(), ${ICON_SQL}, true, false)
ON CONFLICT (contract_address_hash) DO UPDATE SET
  name = EXCLUDED.name, symbol = EXCLUDED.symbol, decimals = EXCLUDED.decimals,
  cataloged = true,
  icon_url = COALESCE(EXCLUDED.icon_url, tokens.icon_url),
  is_verified_via_admin_panel = true, updated_at = NOW();
SELECT name, symbol, decimals, icon_url FROM tokens WHERE contract_address_hash = decode('${ADDR_HEX}','hex');
"
REMOTE
echo "Token: https://mainnet.conet.network/token/${ADDR}"
echo "API:   https://mainnet.conet.network/api/v2/tokens/${ADDR}"
