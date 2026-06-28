#!/bin/bash
set -euo pipefail

# Voluntary exit for one validator pubkey on this CoNET node (Prysm v7).
# Env: EXIT_VALIDATOR_PUBKEY (required), PROJECT_DIR defaults to script directory.

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

PUBKEY="${EXIT_VALIDATOR_PUBKEY:-}"
[[ -n "$PUBKEY" ]] || { echo "ERROR: EXIT_VALIDATOR_PUBKEY required" >&2; exit 1; }
PUBKEY="${PUBKEY#0x}"
PUBKEY="0x${PUBKEY}"

NETWORK_DIR="${NETWORK_DIR:-./network}"
NODE_DIR="${NODE_DIR:-$NETWORK_DIR/node-0}"
CHAIN_CONFIG_FILE="${CHAIN_CONFIG_FILE:-$NODE_DIR/consensus/config.yml}"
WALLET_PASSWORD_FILE="${WALLET_PASSWORD_FILE:-./secrets/prysm_wallet_password.txt}"
VALIDATOR_WALLET_DIR="${VALIDATOR_WALLET_DIR:-$NODE_DIR/consensus/validator-wallet}"
PRYSM_BEACON_RPC_PORT="${PRYSM_BEACON_RPC_PORT:-4000}"
PRYSM_VALIDATOR_BINARY="${PRYSM_VALIDATOR_BINARY:-./dependencies/prysm-v7.1.5/validator}"

[[ -x "$PRYSM_VALIDATOR_BINARY" ]] || { echo "ERROR: missing validator binary: $PRYSM_VALIDATOR_BINARY" >&2; exit 1; }

echo "Voluntary exit pubkey=${PUBKEY} beacon=127.0.0.1:${PRYSM_BEACON_RPC_PORT}"
"$PRYSM_VALIDATOR_BINARY" accounts voluntary-exit \
	--beacon-rpc-provider="127.0.0.1:${PRYSM_BEACON_RPC_PORT}" \
	--wallet-dir="$VALIDATOR_WALLET_DIR" \
	--wallet-password-file="$WALLET_PASSWORD_FILE" \
	--public-keys="$PUBKEY" \
	--chain-config-file="$CHAIN_CONFIG_FILE" \
	--accept-terms-of-use

echo "Voluntary exit submitted for ${PUBKEY}"
