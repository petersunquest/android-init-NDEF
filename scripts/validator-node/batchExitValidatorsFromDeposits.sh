#!/usr/bin/env bash
# Voluntary-exit every pubkey listed in validator_deposits.json (CoNET Prysm v7).
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$HOME/ethereum-pos-mainnet}"
DEPOSITS="${VALIDATOR_DEPOSITS_FILE:-$PROJECT_DIR/validator_deposits.json}"
EXIT_SCRIPT="${EXIT_SCRIPT:-$PROJECT_DIR/06_exit_validator.sh}"
BEACON_RPC="${BEACON_RPC_PROVIDER:-127.0.0.1:4000}"
PRYSM_BEACON_RPC_PORT="${PRYSM_BEACON_RPC_PORT:-${BEACON_RPC##*:}}"
PRYSM_VALIDATOR_BINARY="${PRYSM_VALIDATOR_BINARY:-$PROJECT_DIR/dependencies/prysm-v7.1.4/validator}"

[[ -f "$DEPOSITS" ]] || { echo "ERROR: missing $DEPOSITS" >&2; exit 1; }
[[ -x "$EXIT_SCRIPT" ]] || { echo "ERROR: missing $EXIT_SCRIPT" >&2; exit 1; }
[[ -x "$PRYSM_VALIDATOR_BINARY" ]] || PRYSM_VALIDATOR_BINARY="$PROJECT_DIR/dependencies/prysm-v7.1.5/validator"

export PROJECT_DIR PRYSM_BEACON_RPC_PORT PRYSM_VALIDATOR_BINARY

count="$(python3 -c "import json; print(len(json.load(open('$DEPOSITS'))))")"

echo "==> voluntary-exit $count validators from $DEPOSITS (beacon=$BEACON_RPC)"
i=0
while IFS= read -r pk; do
  [[ -n "$pk" ]] || continue
  i=$((i + 1))
  echo "---- [$i/$count] exit $pk"
  EXIT_VALIDATOR_PUBKEY="$pk" "$EXIT_SCRIPT"
done < <(python3 - "$DEPOSITS" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    rows = json.load(f)
for row in rows:
    pk = row.get("pubkey") or row.get("pub_key")
    if not pk:
        continue
    pk = str(pk)
    if not pk.startswith("0x"):
        pk = "0x" + pk
    print(pk)
PY
)

echo "==> submitted $i voluntary-exit requests"
