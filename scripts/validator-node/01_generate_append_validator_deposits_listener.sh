#!/bin/bash
set -euo pipefail

# Wrapper for listener: run 01_generate_append_validator_deposits.sh but NEVER leave
# secrets/validator_keystore_password.txt or secrets/prysm_wallet_password.txt changed.
# Prysm wallet + prior keystores depend on stable on-disk passwords.

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

PASSWORD_DIR="${PASSWORD_DIR:-./secrets}"
KEYSTORE_PW="$PASSWORD_DIR/validator_keystore_password.txt"
WALLET_PW="$PASSWORD_DIR/prysm_wallet_password.txt"

backup_dir="$(mktemp -d)"
cleanup() { rm -rf "$backup_dir"; }
trap cleanup EXIT

for f in "$KEYSTORE_PW" "$WALLET_PW"; do
	if [[ -f "$f" ]]; then
		cp "$f" "$backup_dir/$(basename "$f")"
	fi
done

./01_generate_append_validator_deposits.sh "$@"

for f in "$KEYSTORE_PW" "$WALLET_PW"; do
	b="$backup_dir/$(basename "$f")"
	if [[ -f "$b" ]]; then
		install -m 600 "$b" "$f"
	fi
done

echo "Restored Prysm password files (listener wrapper; wallet passwords unchanged)."
