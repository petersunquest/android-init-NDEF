#!/bin/bash
# Foreground Prysm validator for systemd (conet-prysm-validator.service).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/08_import_append_validator_keys.sh"

require_exec "$PRYSM_VALIDATOR_BINARY"
require_file "$CHAIN_CONFIG_FILE"
WALLET_PASSWORD_FILE="$(resolve_password_file "${WALLET_PASSWORD:-}" "$WALLET_PASSWORD_FILE")"

# Every systemd start: import any missing append keystores before loading wallet (no double reload).
RELOAD_VALIDATOR_AFTER_IMPORT=NO sync_import_cli

# Per-validator EL fee_recipient (claim beneficiary). Fall back to FEE_RECIPIENT only when a pubkey
# has no entry in this file. Written by 07_update_fee_recipient.sh / redeem listener.
PROPOSER_SETTINGS_FILE="${PROPOSER_SETTINGS_FILE:-$VALIDATOR_DATA_DIR/proposer-settings.json}"
mkdir -p "$(dirname "$PROPOSER_SETTINGS_FILE")"
if [[ ! -f "$PROPOSER_SETTINGS_FILE" ]]; then
	# Seed empty map so --proposer-settings-file always loads; default_config mirrors process FEE_RECIPIENT.
	FEE_JSON="${FEE_RECIPIENT:-0x0000000000000000000000000000000000000000}"
	printf '%s\n' "{\"proposer_config\":{},\"default_config\":{\"fee_recipient\":\"${FEE_JSON}\"}}" >"$PROPOSER_SETTINGS_FILE"
fi

exec "$PRYSM_VALIDATOR_BINARY" \
	--beacon-rpc-provider="127.0.0.1:${PRYSM_BEACON_RPC_PORT}" \
	--datadir="$VALIDATOR_DATA_DIR" \
	--accept-terms-of-use \
	--wallet-dir="$VALIDATOR_WALLET_DIR" \
	--wallet-password-file="$WALLET_PASSWORD_FILE" \
	--rpc-port="$PRYSM_VALIDATOR_RPC_PORT" \
	--grpc-gateway-port="$PRYSM_VALIDATOR_GRPC_GATEWAY_PORT" \
	--monitoring-port="$PRYSM_VALIDATOR_MONITORING_PORT" \
	--graffiti="conet-append-validator" \
	--chain-config-file="$CHAIN_CONFIG_FILE" \
	--proposer-settings-file="$PROPOSER_SETTINGS_FILE" \
	--suggested-fee-recipient="$FEE_RECIPIENT"
