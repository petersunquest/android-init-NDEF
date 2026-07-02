#!/usr/bin/env bash
# 在 CoNET Blockscout 数据库登记 GBToken 名称/符号/decimals/icon。
# 运行: GB_TOKEN_ADDRESS=0xC3EF... bash scripts/registerGBTokenBlockscoutConet.sh
set -euo pipefail
HOST="${GB_BLOCKSCOUT_HOST:-38.102.126.30}"
ADDR="${GB_TOKEN_ADDRESS:-0xC3EF02DaE632b4C10abB66e07d92a387c10838D8}"
ADDR_HEX="${ADDR#0x}"
ADDR_HEX="$(echo "$ADDR_HEX" | tr '[:upper:]' '[:lower:]')"
ICON_URL="${GB_TOKEN_ICON_URL:-https://mainnet.conet.network/gb/erc20/GB-256.png}"

ssh -o BatchMode=yes "root@${HOST}" bash -s <<REMOTE
set -euo pipefail
PW=\$(docker exec backend printenv DATABASE_URL | sed -n 's#.*://blockscout:\\([^@]*\\)@.*#\\1#p')
docker exec -e PGPASSWORD="\$PW" db psql -U blockscout -d blockscout -c "
INSERT INTO tokens (name, symbol, decimals, type, cataloged, contract_address_hash, inserted_at, updated_at, icon_url, is_verified_via_admin_panel, skip_metadata)
VALUES ('CONET GB', 'GB', 9, 'ERC-20', true, decode('${ADDR_HEX}','hex'), NOW(), NOW(), '${ICON_URL}', true, false)
ON CONFLICT (contract_address_hash) DO UPDATE SET
  name = EXCLUDED.name, symbol = EXCLUDED.symbol, decimals = EXCLUDED.decimals,
  cataloged = true, icon_url = EXCLUDED.icon_url, is_verified_via_admin_panel = true, updated_at = NOW();
SELECT name, symbol, decimals, icon_url FROM tokens WHERE contract_address_hash = decode('${ADDR_HEX}','hex');
"
REMOTE
echo "API: https://mainnet.conet.network/api/v2/tokens/${ADDR}"
