#!/bin/bash
# Patch 207.90.192.71 ethereum-pos-mainnet scripts: permanent ConetLabMiningPool fee_recipient.
set -euo pipefail

PROJECT_DIR="${1:-$HOME/ethereum-pos-mainnet}"
POOL="0x32bE583C8e778FFfC5107BF34820c2B225336201"
OLD="0x0981275553A41E00ec1006fe074971285E00c2A3"
DEFAULTS="$PROJECT_DIR/conet_fee_recipient_defaults.sh"

DEFAULTS="$PROJECT_DIR/conet_fee_recipient_defaults.sh"
SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/conet_fee_recipient_defaults.sh"
if [[ -f "$SCRIPT_SRC" && "$SCRIPT_SRC" != "$DEFAULTS" ]]; then
	cp "$SCRIPT_SRC" "$DEFAULTS"
fi
chmod 644 "$DEFAULTS"

# Replace legacy default across all shell scripts in project root.
while IFS= read -r -d '' f; do
	sed -i "s|${OLD}|${POOL}|g" "$f"
done < <(find "$PROJECT_DIR" -maxdepth 1 -name '*.sh' -print0)

patch_source_and_proposer() {
	local f="$1"
	[[ -f "$f" ]] || return 0
	if ! grep -q 'conet_fee_recipient_defaults.sh' "$f"; then
		sed -i '/^PROJECT_DIR=.*$/a\
# shellcheck disable=SC1091\
[[ -f "$PROJECT_DIR/conet_fee_recipient_defaults.sh" ]] \&\& source "$PROJECT_DIR/conet_fee_recipient_defaults.sh"' "$f"
	fi
	sed -i "s|^FEE_RECIPIENT=.*|FEE_RECIPIENT=\"\${FEE_RECIPIENT:-\${CONET_DEFAULT_FEE_RECIPIENT:-${POOL}}}\"|" "$f"
	if grep -q 'start_validator()' "$f" && ! grep -q 'proposer-settings-file' "$f"; then
		sed -i '/^start_validator() {/a\
\tPROPOSER_SETTINGS_FILE="${PROPOSER_SETTINGS_FILE:-$VALIDATOR_DATA_DIR/proposer-settings.json}"\
\tPROPOSER_EXTRA_ARGS=()\
\tif [[ -f "$PROPOSER_SETTINGS_FILE" ]]; then\
\t\tPROPOSER_EXTRA_ARGS=(--proposer-settings-file="$PROPOSER_SETTINGS_FILE")\
\tfi' "$f"
		sed -i 's|--suggested-fee-recipient="$FEE_RECIPIENT" \\|--suggested-fee-recipient="$FEE_RECIPIENT" \\\n\t\t"${PROPOSER_EXTRA_ARGS[@]}" \\|' "$f"
	fi
}

patch_source_and_proposer "$PROJECT_DIR/06_restart_node71.sh"
patch_source_and_proposer "$PROJECT_DIR/06_restart_node71_node1.sh"
patch_source_and_proposer "$PROJECT_DIR/conet_restart_validator_only.sh"

echo "OK: patched fee_recipient defaults in $PROJECT_DIR"
grep -n "FEE_RECIPIENT\|CONET_DEFAULT_FEE_RECIPIENT\|proposer-settings" \
	"$DEFAULTS" "$PROJECT_DIR/06_restart_node71.sh" "$PROJECT_DIR/conet_restart_validator_only.sh" 2>/dev/null | head -20
