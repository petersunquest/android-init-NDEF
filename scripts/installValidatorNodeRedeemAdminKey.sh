#!/usr/bin/env bash
# Install ONLY key_38.102.85.33 from local ~/.master.json onto the validator host as redeem-admin
# signing material (NOT a copy of the whole ~/.master.json). See beamio-no-master-json-remote-copy.mdc.
#
# Usage: scripts/installValidatorNodeRedeemAdminKey.sh
# Env:   VALIDATOR_LISTENER_HOST (default 38.102.85.33)
#        VALIDATOR_LISTENER_USER (default peter)
#        VALIDATOR_NEWCONET_DIR   (default /home/peter/ethereum-pos-mainnet)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR_LISTENER_HOST="${VALIDATOR_LISTENER_HOST:-38.102.85.33}"
VALIDATOR_LISTENER_USER="${VALIDATOR_LISTENER_USER:-peter}"
VALIDATOR_NEWCONET_DIR="${VALIDATOR_NEWCONET_DIR:-/home/peter/ethereum-pos-mainnet}"
DEPOSIT_KEY_FILE="${VALIDATOR_NEWCONET_DIR}/secrets/deposit_sender_private_key.txt"
EXPECTED_ADMIN="0xE974c5d10cc36738bC2619FC73b075504D5c6d1E"
SSH_TARGET="${VALIDATOR_LISTENER_USER}@${VALIDATOR_LISTENER_HOST}"

MASTER="${HOME}/.master.json"
if [[ ! -f "$MASTER" ]]; then
	echo "ERROR: missing local $MASTER" >&2
	exit 1
fi

echo "==> Verify local key_38.102.85.33 -> ${EXPECTED_ADMIN}"
node "$SCRIPT_DIR/installValidatorNodeRedeemAdminKey.mjs" "$MASTER" "$EXPECTED_ADMIN" | ssh "$SSH_TARGET" "mkdir -p '$(dirname "$DEPOSIT_KEY_FILE")' && umask 077 && cat > '${DEPOSIT_KEY_FILE}'"

ssh "$SSH_TARGET" "chmod 600 '${DEPOSIT_KEY_FILE}' && test -s '${DEPOSIT_KEY_FILE}' && echo OK: installed redeem admin key at ${DEPOSIT_KEY_FILE}"

echo "==> Done. Key signs fundAndDepositValidators; 32 CNET/validator comes from ValidatorDepositRedeem contract balance."
