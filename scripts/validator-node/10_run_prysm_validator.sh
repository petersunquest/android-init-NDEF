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
	--suggested-fee-recipient="$FEE_RECIPIENT"
