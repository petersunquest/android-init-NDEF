#!/bin/bash
set -euo pipefail

# Idempotent Prysm import for append_validator_keys keystores (old + new).
# - Tracks imported keystore basenames in wallet manifest (not a one-shot marker).
# - Optionally reloads ONLY the validator client (beacon + geth untouched).
#
# Env (listener sets passwords; paths default to CoNET node-0 layout):
#   KEYSTORE_PASSWORD / KEYSTORE_PASSWORD_FILE
#   WALLET_PASSWORD / WALLET_PASSWORD_FILE
#   RELOAD_VALIDATOR_AFTER_IMPORT=YES|NO  (default YES)

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

NETWORK_DIR="${NETWORK_DIR:-./network}"
NODE_DIR="${NODE_DIR:-$NETWORK_DIR/node-0}"
VALIDATOR_KEYS_SOURCE_DIR="${VALIDATOR_KEYS_SOURCE_DIR:-./append_validator_keys}"

KEYSTORE_PASSWORD_FILE="${KEYSTORE_PASSWORD_FILE:-./secrets/validator_keystore_password.txt}"
WALLET_PASSWORD_FILE="${WALLET_PASSWORD_FILE:-./secrets/prysm_wallet_password.txt}"
VALIDATOR_WALLET_DIR="${VALIDATOR_WALLET_DIR:-$NODE_DIR/consensus/validator-wallet}"
VALIDATOR_DATA_DIR="${VALIDATOR_DATA_DIR:-$NODE_DIR/consensus/validatordata}"
CHAIN_CONFIG_FILE="${CHAIN_CONFIG_FILE:-$NODE_DIR/consensus/config.yml}"
FEE_RECIPIENT="${FEE_RECIPIENT:-0x0981275553A41E00ec1006fe074971285E00c2A3}"

PRYSM_VALIDATOR_BINARY="${PRYSM_VALIDATOR_BINARY:-./dependencies/prysm-v7.1.5/validator}"
PRYSM_BEACON_RPC_PORT="${PRYSM_BEACON_RPC_PORT:-4000}"
PRYSM_VALIDATOR_RPC_PORT="${PRYSM_VALIDATOR_RPC_PORT:-7000}"
PRYSM_VALIDATOR_GRPC_GATEWAY_PORT="${PRYSM_VALIDATOR_GRPC_GATEWAY_PORT:-7100}"
PRYSM_VALIDATOR_MONITORING_PORT="${PRYSM_VALIDATOR_MONITORING_PORT:-7200}"

RELOAD_VALIDATOR_AFTER_IMPORT="${RELOAD_VALIDATOR_AFTER_IMPORT:-${CONET_VALIDATOR_RELOAD_VALIDATOR_AFTER_IMPORT:-YES}}"

LEGACY_IMPORT_MARKER="$VALIDATOR_WALLET_DIR/.imported_append_validator_keys"
IMPORT_MANIFEST="$VALIDATOR_WALLET_DIR/.imported_append_keystores.manifest"
IMPORT_STAGING_DIR="$NODE_DIR/validator_keys_import_staging"

die() {
	echo "ERROR: $*" >&2
	exit 1
}

require_file() {
	[[ -f "$1" ]] || die "Missing required file: $1"
}

require_exec() {
	[[ -x "$1" ]] || die "Missing executable: $1"
}

resolve_password_file() {
	local inline="$1"
	local file="$2"
	if [[ -n "$inline" ]]; then
		local tmp
		tmp="$(mktemp)"
		printf '%s' "$inline" >"$tmp"
		echo "$tmp"
		return 0
	fi
	require_file "$file"
	echo "$file"
}

ensure_wallet() {
	mkdir -p "$VALIDATOR_WALLET_DIR" "$NODE_DIR/logs"
	set +e
	"$PRYSM_VALIDATOR_BINARY" accounts wallet create \
		--accept-terms-of-use \
		--wallet-dir="$VALIDATOR_WALLET_DIR" \
		--wallet-password-file="$WALLET_PASSWORD_FILE" \
		>"$NODE_DIR/logs/validator-wallet-create.log" 2>&1
	local status=$?
	set -e
	if [[ "$status" -ne 0 ]]; then
		echo "Wallet create returned $status (usually OK if wallet already exists)."
	fi
}

seed_manifest_from_legacy_marker() {
	[[ -f "$LEGACY_IMPORT_MARKER" ]] || return 0
	[[ -s "$IMPORT_MANIFEST" ]] && return 0
	echo "Seeding import manifest from legacy marker (keystores at or before marker mtime only)."
	mkdir -p "$VALIDATOR_WALLET_DIR"
	touch "$IMPORT_MANIFEST"
	local marker_mtime
	marker_mtime="$(stat -c %Y "$LEGACY_IMPORT_MARKER" 2>/dev/null || stat -f %m "$LEGACY_IMPORT_MARKER")"
	find "$VALIDATOR_KEYS_SOURCE_DIR" -maxdepth 10 -type f -name 'keystore-*.json' | sort -V | while read -r keystore; do
		local keystore_mtime
		keystore_mtime="$(stat -c %Y "$keystore" 2>/dev/null || stat -f %m "$keystore")"
		if [[ "$keystore_mtime" -le "$marker_mtime" ]]; then
			echo "$(basename "$keystore")" >>"$IMPORT_MANIFEST"
		fi
	done
}

manifest_contains() {
	local name="$1"
	[[ -f "$IMPORT_MANIFEST" ]] && grep -qxF "$name" "$IMPORT_MANIFEST"
}

append_manifest() {
	local name="$1"
	mkdir -p "$VALIDATOR_WALLET_DIR"
	if manifest_contains "$name"; then
		return 0
	fi
	echo "$name" >>"$IMPORT_MANIFEST"
}

import_log_is_duplicate() {
	local log_file="$1"
	[[ -f "$log_file" ]] || return 1
	grep -Eiq 'already exists|already imported|duplicate|same pubkey|key already present' "$log_file"
}

import_one_keystore() {
	local keystore="$1"
	local base
	base="$(basename "$keystore")"
	if manifest_contains "$base"; then
		echo "  skip (manifest): $base"
		return 0
	fi

	rm -rf "$IMPORT_STAGING_DIR"
	mkdir -p "$IMPORT_STAGING_DIR"
	cp "$keystore" "$IMPORT_STAGING_DIR/"

	local log_file="$NODE_DIR/logs/validator-import-${base}.log"
	echo "  import $base ..."
	set +e
	"$PRYSM_VALIDATOR_BINARY" accounts import \
		--accept-terms-of-use \
		--wallet-dir="$VALIDATOR_WALLET_DIR" \
		--wallet-password-file="$WALLET_PASSWORD_FILE" \
		--keys-dir="$IMPORT_STAGING_DIR" \
		--account-password-file="$KEYSTORE_PASSWORD_FILE" \
		>"$log_file" 2>&1
	local status=$?
	set -e

	if [[ "$status" -eq 0 ]] || import_log_is_duplicate "$log_file"; then
		append_manifest "$base"
		echo "  ok: $base"
		return 0
	fi

	echo "--- import failed for $base (exit $status) ---"
	tail -n 40 "$log_file" >&2 || true
	return 1
}

import_one_keystore_via_ethstaker() {
	local keystore="$1"
	local base ethstaker_py
	base="$(basename "$keystore")"
	ethstaker_py="${ETHSTAKER_PYTHON:-$PROJECT_DIR/ethstaker-deposit-cli/venv/bin/python3}"
	[[ -x "$ethstaker_py" ]] || return 1

	local sk_hex_file log_file
	sk_hex_file="$(mktemp)"
	log_file="$NODE_DIR/logs/validator-import-pk-${base}.log"

	echo "  import via ethstaker decrypt + private key: $base ..."
	if ! KEYSTORE_PASSWORD_FILE="$KEYSTORE_PASSWORD_FILE" "$ethstaker_py" - "$keystore" "$sk_hex_file" <<'PY' 2>"$log_file"
import json, os, sys
from ethstaker_deposit.key_handling.keystore import Keystore
path = sys.argv[1]
out = sys.argv[2]
pw_file = os.environ["KEYSTORE_PASSWORD_FILE"]
with open(pw_file, "r", encoding="utf-8") as pf:
    pw = pf.read().strip()
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
sk = Keystore.from_json(data).decrypt(pw)
open(out, "w", encoding="utf-8").write("0x" + sk.hex())
PY
	then
		rm -f "$sk_hex_file"
		return 1
	fi

	set +e
	"$PRYSM_VALIDATOR_BINARY" accounts import \
		--accept-terms-of-use \
		--wallet-dir="$VALIDATOR_WALLET_DIR" \
		--wallet-password-file="$WALLET_PASSWORD_FILE" \
		--import-private-key-file="$sk_hex_file" \
		>>"$log_file" 2>&1
	local status=$?
	set -e
	rm -f "$sk_hex_file"

	if [[ "$status" -eq 0 ]] || import_log_is_duplicate "$log_file"; then
		append_manifest "$base"
		echo "  ok (private key): $base"
		return 0
	fi

	echo "--- private-key import failed for $base (exit $status) ---" >&2
	tail -n 40 "$log_file" >&2 || true
	return 1
}

import_all_append_keystores() {
	local imported=0
	local skipped=0
	local failed=0

	mapfile -t keystores < <(find "$VALIDATOR_KEYS_SOURCE_DIR" -maxdepth 10 -type f -name 'keystore-*.json' | sort -V)
	[[ "${#keystores[@]}" -gt 0 ]] || die "No keystore-*.json under $VALIDATOR_KEYS_SOURCE_DIR"

	echo "Found ${#keystores[@]} keystore file(s) under $VALIDATOR_KEYS_SOURCE_DIR"

	for keystore in "${keystores[@]}"; do
		local base
		base="$(basename "$keystore")"
		if manifest_contains "$base"; then
			skipped=$((skipped + 1))
			echo "  skip (manifest): $base"
			continue
		fi
		if import_one_keystore "$keystore"; then
			imported=$((imported + 1))
		elif import_one_keystore_via_ethstaker "$keystore"; then
			imported=$((imported + 1))
		else
			failed=$((failed + 1))
		fi
	done

	echo "Import summary: imported=$imported skipped=$skipped failed=$failed manifest=$IMPORT_MANIFEST"
	[[ "$failed" -eq 0 ]] || die "$failed keystore import(s) failed"
}

stop_validator_only() {
	local pid_file="$NODE_DIR/validator.pid"
	if [[ -f "$pid_file" ]]; then
		local pid
		pid="$(cat "$pid_file" || true)"
		if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
			echo "Stopping validator pid=$pid ..."
			kill "$pid" 2>/dev/null || true
			for _ in {1..30}; do
				kill -0 "$pid" 2>/dev/null || break
				sleep 1
			done
			kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
		fi
		rm -f "$pid_file"
	fi
	pkill -f "validator.*$NODE_DIR" 2>/dev/null || true
	sleep 2
}

start_validator_only() {
	echo "Starting validator client (beacon + geth unchanged) ..."
	mkdir -p "$NODE_DIR/logs" "$VALIDATOR_DATA_DIR"
	nohup "$PRYSM_VALIDATOR_BINARY" \
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
		--suggested-fee-recipient="$FEE_RECIPIENT" \
		>"$NODE_DIR/logs/validator.log" 2>&1 &
	echo $! >"$NODE_DIR/validator.pid"
	echo "Validator started pid=$(cat "$NODE_DIR/validator.pid")"
}

main() {
	echo "============================================================"
	echo "Import append validator keys into Prysm wallet"
	echo "PROJECT_DIR=$PROJECT_DIR"
	echo "NODE_DIR=$NODE_DIR"
	echo "VALIDATOR_KEYS_SOURCE_DIR=$VALIDATOR_KEYS_SOURCE_DIR"
	echo "VALIDATOR_WALLET_DIR=$VALIDATOR_WALLET_DIR"
	echo "RELOAD_VALIDATOR_AFTER_IMPORT=$RELOAD_VALIDATOR_AFTER_IMPORT"
	echo "============================================================"

	require_exec "$PRYSM_VALIDATOR_BINARY"
	require_file "$CHAIN_CONFIG_FILE"

	local keystore_pw_file wallet_pw_file
	keystore_pw_file="$(resolve_password_file "${KEYSTORE_PASSWORD:-}" "$KEYSTORE_PASSWORD_FILE")"
	wallet_pw_file="$(resolve_password_file "${WALLET_PASSWORD:-}" "$WALLET_PASSWORD_FILE")"
	KEYSTORE_PASSWORD_FILE="$keystore_pw_file"
	WALLET_PASSWORD_FILE="$wallet_pw_file"

	ensure_wallet
	seed_manifest_from_legacy_marker
	import_all_append_keystores

	if [[ "${RELOAD_VALIDATOR_AFTER_IMPORT^^}" == "YES" ]]; then
		stop_validator_only
		start_validator_only
	else
		echo "Skipping validator reload (RELOAD_VALIDATOR_AFTER_IMPORT=$RELOAD_VALIDATOR_AFTER_IMPORT)"
	fi

	echo "Done."
}

main "$@"
