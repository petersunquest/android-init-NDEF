#!/bin/bash
set -euo pipefail

# ============================================================
# filename: 06_restart_node8533.sh
#
# Restart geth + beacon + validator on 38.102.85.33 without
# deleting chaindata, beacondata, validator wallet, or keys.
# Beacon: 6× DHT hub bootstrap only (RPC Cancun 107-117), no static --peer.
#
# Usage:
#   ./06_restart_node8533.sh start|stop|restart|status
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

NETWORK_DIR="${NETWORK_DIR:-./network}"
NODE_DIR="${NODE_DIR:-$NETWORK_DIR/node-0}"

CHAIN_ID="${CHAIN_ID:-224422}"
PUBLIC_IP="${PUBLIC_IP:-38.102.85.33}"
GETH_GCMODE="${GETH_GCMODE:-full}"
CONET_USE_DHT_BOOTSTRAP="${CONET_USE_DHT_BOOTSTRAP:-YES}"
DHT_BOOTSTRAP_ONLY="${DHT_BOOTSTRAP_ONLY:-YES}"

DEPOSIT_CONTRACT_ADDRESS="${DEPOSIT_CONTRACT_ADDRESS:-0x4242424242424242424242424242424242424242}"
FEE_RECIPIENT="${FEE_RECIPIENT:-0x0981275553A41E00ec1006fe074971285E00c2A3}"

# shellcheck disable=SC1091
source "$PROJECT_DIR/conet_backbone_el_bootnodes.sh"
EXECUTION_BOOTNODES="${EXECUTION_BOOTNODES:-$CONET_BACKBONE_EXECUTION_BOOTNODES}"

GETH_BINARY="${GETH_BINARY:-./dependencies/go-ethereum-latest/build/bin/geth}"
PRYSM_BEACON_BINARY="${PRYSM_BEACON_BINARY:-./dependencies/prysm-v7.1.5/beacon-chain}"
PRYSM_VALIDATOR_BINARY="${PRYSM_VALIDATOR_BINARY:-./dependencies/prysm-v7.1.5/validator}"

EXECUTION_GENESIS="${EXECUTION_GENESIS:-$NODE_DIR/execution/genesis.json}"
CONSENSUS_GENESIS="${CONSENSUS_GENESIS:-$NODE_DIR/consensus/genesis.ssz}"
CHAIN_CONFIG_FILE="${CHAIN_CONFIG_FILE:-$NODE_DIR/consensus/config.yml}"
JWT_SECRET_FILE="${JWT_SECRET_FILE:-$NODE_DIR/execution/jwtsecret}"

WALLET_PASSWORD_FILE="${WALLET_PASSWORD_FILE:-./secrets/prysm_wallet_password.txt}"
VALIDATOR_WALLET_DIR="${VALIDATOR_WALLET_DIR:-$NODE_DIR/consensus/validator-wallet}"
VALIDATOR_DATA_DIR="${VALIDATOR_DATA_DIR:-$NODE_DIR/consensus/validatordata}"

GETH_HTTP_PORT="${GETH_HTTP_PORT:-8889}"
GETH_ENABLE_HTTP="${GETH_ENABLE_HTTP:-NO}"
GETH_AUTH_RPC_PORT="${GETH_AUTH_RPC_PORT:-8200}"
GETH_METRICS_PORT="${GETH_METRICS_PORT:-8300}"
GETH_P2P_PORT="${GETH_P2P_PORT:-8400}"

PRYSM_BEACON_RPC_PORT="${PRYSM_BEACON_RPC_PORT:-4000}"
PRYSM_BEACON_GRPC_GATEWAY_PORT="${PRYSM_BEACON_GRPC_GATEWAY_PORT:-4100}"
PRYSM_BEACON_P2P_TCP_PORT="${PRYSM_BEACON_P2P_TCP_PORT:-4200}"
PRYSM_BEACON_P2P_UDP_PORT="${PRYSM_BEACON_P2P_UDP_PORT:-4300}"
PRYSM_BEACON_MONITORING_PORT="${PRYSM_BEACON_MONITORING_PORT:-4400}"

PRYSM_VALIDATOR_RPC_PORT="${PRYSM_VALIDATOR_RPC_PORT:-7000}"
PRYSM_VALIDATOR_GRPC_GATEWAY_PORT="${PRYSM_VALIDATOR_GRPC_GATEWAY_PORT:-7100}"
PRYSM_VALIDATOR_MONITORING_PORT="${PRYSM_VALIDATOR_MONITORING_PORT:-7200}"
VALIDATOR_SYSTEMD_UNIT="${VALIDATOR_SYSTEMD_UNIT:-conet-prysm-validator.service}"

MIN_SYNC_PEERS="${MIN_SYNC_PEERS:-1}"
ETH1_HEADER_REQ_LIMIT="${ETH1_HEADER_REQ_LIMIT:-4096}"
GETH_NAT="${GETH_NAT:-any}"

die() {
	echo "ERROR: $*" >&2
	exit 1
}

require_file() {
	[[ -f "$1" ]] || die "Missing required file: $1"
}

require_dir() {
	[[ -d "$1" ]] || die "Missing required directory: $1"
}

require_exec() {
	[[ -x "$1" ]] || die "Missing executable: $1"
}

wait_for_port() {
	local host="$1"
	local port="$2"
	local name="$3"
	local retries="${4:-120}"

	echo "Waiting for $name at $host:$port ..."
	for ((i = 1; i <= retries; i++)); do
		if timeout 1 bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
			echo "$name is up at $host:$port"
			return 0
		fi
		sleep 1
	done

	echo "Warning: $name did not open $host:$port after $retries seconds"
	return 1
}

wait_for_port_closed() {
	local host="$1"
	local port="$2"
	local name="$3"
	local retries="${4:-30}"

	for ((i = 1; i <= retries; i++)); do
		if ! timeout 1 bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
			return 0
		fi
		sleep 1
	done

	echo "Warning: $name port still open at $host:$port"
	return 1
}

stop_process_by_pid_file() {
	local name="$1"
	local pid_file="$2"

	if [[ ! -f "$pid_file" ]]; then
		return 0
	fi

	local pid
	pid="$(cat "$pid_file" 2>/dev/null || true)"

	if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
		echo "Stopping $name pid=$pid ..."
		kill "$pid" 2>/dev/null || true

		for _ in {1..30}; do
			if ! kill -0 "$pid" 2>/dev/null; then
				rm -f "$pid_file"
				return 0
			fi
			sleep 1
		done

		echo "Force killing $name pid=$pid ..."
		kill -9 "$pid" 2>/dev/null || true
	fi

	rm -f "$pid_file"
}

validator_systemd_unit_installed() {
	systemctl list-unit-files "${VALIDATOR_SYSTEMD_UNIT}" 2>/dev/null | grep -q "${VALIDATOR_SYSTEMD_UNIT}"
}

validator_systemctl() {
	sudo -n /bin/systemctl "$@" "$VALIDATOR_SYSTEMD_UNIT"
}

stop_validator_client() {
	if validator_systemd_unit_installed; then
		echo "Stopping ${VALIDATOR_SYSTEMD_UNIT} ..."
		validator_systemctl stop 2>/dev/null || true
		for _ in {1..60}; do
			validator_systemctl is-active --quiet 2>/dev/null && sleep 1 || break
		done
	fi

	stop_process_by_pid_file "validator" "$NODE_DIR/validator.pid"
	pkill -f "validator.*$NODE_DIR" 2>/dev/null || true
	pkill -f "dependencies/prysm.*validator.*consensus/validatordata" 2>/dev/null || true
	sleep 2
}

sync_validator_keys_before_start() {
	if [[ ! -x "$PROJECT_DIR/08_import_append_validator_keys.sh" ]]; then
		echo "WARN: 08_import_append_validator_keys.sh missing; skipping pre-start key sync" >&2
		return 0
	fi
	echo "Syncing append validator keys into Prysm wallet before start ..."
	RELOAD_VALIDATOR_AFTER_IMPORT=NO "$PROJECT_DIR/08_import_append_validator_keys.sh" --sync-import
}

stop_all() {
	echo "Stopping node processes (data preserved) ..."

	stop_validator_client
	stop_process_by_pid_file "beacon" "$NODE_DIR/beacon.pid"
	stop_process_by_pid_file "geth" "$NODE_DIR/geth.pid"

	pkill -f "beacon-chain.*$NODE_DIR" 2>/dev/null || true
	pkill -f "geth.*$NODE_DIR" 2>/dev/null || true

	sleep 2

	wait_for_port_closed "127.0.0.1" "$PRYSM_VALIDATOR_RPC_PORT" "validator-rpc" 10 || true
	wait_for_port_closed "127.0.0.1" "$PRYSM_BEACON_RPC_PORT" "beacon-rpc" 10 || true
	wait_for_port_closed "127.0.0.1" "$GETH_AUTH_RPC_PORT" "geth-authrpc" 10 || true
	if [[ "$GETH_ENABLE_HTTP" == "YES" ]]; then
		wait_for_port_closed "127.0.0.1" "$GETH_HTTP_PORT" "geth-http" 10 || true
	fi

	echo "All node processes stopped."
}

check_prerequisites() {
	command -v jq >/dev/null || die "jq is not installed"
	command -v curl >/dev/null || die "curl is not installed"

	require_exec "$GETH_BINARY"
	require_exec "$PRYSM_BEACON_BINARY"
	require_exec "$PRYSM_VALIDATOR_BINARY"
	require_exec "./fetch_bootstrap_enrs.sh"

	require_dir "$NODE_DIR"
	mkdir -p "$NODE_DIR/logs"
	require_dir "$NODE_DIR/execution"
	require_dir "$NODE_DIR/consensus"

	require_file "$EXECUTION_GENESIS"
	require_file "$CONSENSUS_GENESIS"
	require_file "$CHAIN_CONFIG_FILE"
	require_file "$JWT_SECRET_FILE"
	require_file "$WALLET_PASSWORD_FILE"
	require_dir "$VALIDATOR_WALLET_DIR"
	require_dir "$VALIDATOR_DATA_DIR"
}

load_bootstrap_args() {
	BOOTSTRAP_ARGS=()
	if [[ "$CONET_USE_DHT_BOOTSTRAP" != "YES" ]]; then
		return 0
	fi

	export PUBLIC_IP
	export DHT_BOOTSTRAP_ONLY
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		BOOTSTRAP_ARGS+=("$line")
	done < <(./fetch_bootstrap_enrs.sh --beacon-args)

	if (( ${#BOOTSTRAP_ARGS[@]} == 0 )); then
		die "DHT bootstrap: fetch_bootstrap_enrs.sh returned no ENRs"
	fi
	echo "DHT bootstrap ENRs: ${#BOOTSTRAP_ARGS[@]} (6× DHT :4110 from RPC Cancun 107-117, no static peers)"
}

start_geth() {
	echo "Starting geth (gcmode=$GETH_GCMODE, http=${GETH_ENABLE_HTTP}) ..."

	local geth_http_args=()
	if [[ "$GETH_ENABLE_HTTP" == "YES" ]]; then
		geth_http_args=(
			--http
			--http.addr "0.0.0.0"
			--http.port "$GETH_HTTP_PORT"
			--http.api "eth,net,txpool,debug,admin"
			--http.corsdomain "*"
			--http.vhosts "*"
		)
	fi

	nohup "$GETH_BINARY" \
		--datadir "$NODE_DIR/execution" \
		--state.scheme=hash \
		--networkid "$CHAIN_ID" \
		--port "$GETH_P2P_PORT" \
		--bootnodes "$EXECUTION_BOOTNODES" \
		"${geth_http_args[@]}" \
		--authrpc.addr "127.0.0.1" \
		--authrpc.port "$GETH_AUTH_RPC_PORT" \
		--authrpc.vhosts "*" \
		--authrpc.jwtsecret "$JWT_SECRET_FILE" \
		--metrics \
		--metrics.addr "127.0.0.1" \
		--metrics.port "$GETH_METRICS_PORT" \
		--syncmode "full" \
		--gcmode "$GETH_GCMODE" \
		--nat "$GETH_NAT" \
		> "$NODE_DIR/logs/geth.log" 2>&1 &

	echo $! > "$NODE_DIR/geth.pid"

	wait_for_port "127.0.0.1" "$GETH_AUTH_RPC_PORT" "geth-authrpc" 120 || true
	if [[ "$GETH_ENABLE_HTTP" == "YES" ]]; then
		wait_for_port "127.0.0.1" "$GETH_HTTP_PORT" "geth-http" 120 || true
	fi
}

start_beacon() {
	echo "Starting beacon (p2p-host-ip=$PUBLIC_IP, DHT bootstrap only, no static peers) ..."
	load_bootstrap_args

	nohup "$PRYSM_BEACON_BINARY" \
		--datadir="$NODE_DIR/consensus/beacondata" \
		--accept-terms-of-use \
		--genesis-state="$CONSENSUS_GENESIS" \
		--chain-config-file="$CHAIN_CONFIG_FILE" \
		--execution-endpoint="http://127.0.0.1:${GETH_AUTH_RPC_PORT}" \
		--jwt-secret="$JWT_SECRET_FILE" \
		--chain-id="$CHAIN_ID" \
		"${BOOTSTRAP_ARGS[@]}" \
		--rpc-host="0.0.0.0" \
		--rpc-port="$PRYSM_BEACON_RPC_PORT" \
		--grpc-gateway-host="0.0.0.0" \
		--grpc-gateway-port="$PRYSM_BEACON_GRPC_GATEWAY_PORT" \
		--p2p-tcp-port="$PRYSM_BEACON_P2P_TCP_PORT" \
		--p2p-udp-port="$PRYSM_BEACON_P2P_UDP_PORT" \
		--p2p-host-ip="$PUBLIC_IP" \
		--disable-staking-contract-check \
		--min-sync-peers="$MIN_SYNC_PEERS" \
		--monitoring-host="0.0.0.0" \
		--monitoring-port="$PRYSM_BEACON_MONITORING_PORT" \
		--suggested-fee-recipient="$FEE_RECIPIENT" \
		--contract-deployment-block=0 \
		--deposit-contract="$DEPOSIT_CONTRACT_ADDRESS" \
		--eth1-header-req-limit="$ETH1_HEADER_REQ_LIMIT" \
		> "$NODE_DIR/logs/beacon.log" 2>&1 &

	echo $! > "$NODE_DIR/beacon.pid"

	wait_for_port "127.0.0.1" "$PRYSM_BEACON_RPC_PORT" "beacon-rpc" 120 || true
	wait_for_port "127.0.0.1" "$PRYSM_BEACON_GRPC_GATEWAY_PORT" "beacon-gateway" 120 || true
}

start_validator() {
	echo "Starting validator client (all claimed append keys must be in wallet) ..."
	sync_validator_keys_before_start

	if validator_systemd_unit_installed; then
		echo "Starting ${VALIDATOR_SYSTEMD_UNIT} via systemd (single validator process) ..."
		validator_systemctl start
		for _ in {1..60}; do
			if validator_systemctl is-active --quiet 2>/dev/null; then
				local main_pid
				main_pid="$(systemctl show -p MainPID --value "$VALIDATOR_SYSTEMD_UNIT" 2>/dev/null || true)"
				if [[ -n "$main_pid" && "$main_pid" != "0" ]]; then
					echo "$main_pid" >"$NODE_DIR/validator.pid"
				fi
				echo "${VALIDATOR_SYSTEMD_UNIT} active MainPID=${main_pid:-unknown}"
				return 0
			fi
			sleep 1
		done
		die "${VALIDATOR_SYSTEMD_UNIT} failed to become active after 60s"
	fi

	echo "WARN: ${VALIDATOR_SYSTEMD_UNIT} not installed; falling back to legacy nohup validator" >&2
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
		> "$NODE_DIR/logs/validator.log" 2>&1 &

	echo $! > "$NODE_DIR/validator.pid"

	wait_for_port "127.0.0.1" "$PRYSM_VALIDATOR_RPC_PORT" "validator-rpc" 60 || true
}

start_all() {
	echo "============================================================"
	echo "Starting CoNET node on $PUBLIC_IP (preserve existing data)"
	echo "NODE_DIR=$NODE_DIR CONET_USE_DHT_BOOTSTRAP=$CONET_USE_DHT_BOOTSTRAP DHT_BOOTSTRAP_ONLY=$DHT_BOOTSTRAP_ONLY"
	echo "============================================================"

	check_prerequisites
	stop_all
	start_geth
	start_beacon
	start_validator

	echo "Node started."
	echo "  geth pid:      $(cat "$NODE_DIR/geth.pid" 2>/dev/null || echo n/a)"
	echo "  beacon pid:    $(cat "$NODE_DIR/beacon.pid" 2>/dev/null || echo n/a)"
	echo "  validator pid: $(cat "$NODE_DIR/validator.pid" 2>/dev/null || echo n/a)"
}

show_status() {
	echo "=== process status ==="
	if validator_systemd_unit_installed; then
		echo "validator systemd: $(systemctl is-active "${VALIDATOR_SYSTEMD_UNIT}" 2>/dev/null || echo unknown) MainPID=$(systemctl show -p MainPID --value "${VALIDATOR_SYSTEMD_UNIT}" 2>/dev/null || echo n/a)"
	fi
	for name in geth beacon validator; do
		local pid_file="$NODE_DIR/${name}.pid"
		if [[ -f "$pid_file" ]]; then
			local pid
			pid="$(cat "$pid_file" 2>/dev/null || true)"
			if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
				echo "$name: running pid=$pid"
			else
				echo "$name: pid file exists but process not running"
			fi
		else
			echo "$name: not running (no pid file)"
		fi
	done

	if curl -sf "http://127.0.0.1:${PRYSM_BEACON_GRPC_GATEWAY_PORT}/eth/v1/node/version" >/dev/null 2>&1; then
		echo "=== beacon ==="
		curl -s "http://127.0.0.1:${PRYSM_BEACON_GRPC_GATEWAY_PORT}/eth/v1/node/syncing" | jq -c '.data' 2>/dev/null || true
		curl -s "http://127.0.0.1:${PRYSM_BEACON_GRPC_GATEWAY_PORT}/eth/v1/node/peer_count" | jq -c '.data' 2>/dev/null || true
	fi
}

usage() {
	cat <<EOF
Usage: $0 {start|stop|restart|status}

  start    Stop old processes, then start geth + beacon + validator
  stop     Stop all node processes (preserve chaindata/wallet)
  restart  stop + start
  status   Show pid files and basic health
EOF
}

ACTION="${1:-start}"

case "$ACTION" in
start)
	start_all
	;;
stop)
	stop_all
	;;
restart)
	stop_all
	start_all
	;;
status)
	show_status
	;;
*)
	usage
	exit 1
	;;
esac
