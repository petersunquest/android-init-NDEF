#!/bin/bash
set -euo pipefail

# Start node-5 geth from ethereum-pos-mainnet-old as a read-only archive backup.
# Uses +10000 port offset so it does not conflict with ethereum-pos-mainnet node-5.
# Does NOT stop beacon/validator/geth on the live mainnet stack.

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
NETWORK_DIR="$BASE_DIR/network"
NODE_DIR="$NETWORK_DIR/node-5"
MAINNET_DIR="${MAINNET_DIR:-/home/peter/ethereum-pos-mainnet}"
CHAIN_ID=224422

GETH_HTTP_PORT=18005
GETH_AUTH_RPC_PORT=18205
GETH_METRICS_PORT=18305
GETH_NETWORK_PORT=18405

GETH_BINARY="$BASE_DIR/dependencies/go-ethereum/build/bin/geth"
MAINNET_GETH_BINARY="$MAINNET_DIR/dependencies/go-ethereum/build/bin/geth"

BOOTNODE_ENODE="${BOOTNODE_ENODE:-enode://1386d78544632ef2ad59d48fcb1c40f5b5f70d223247383229a107fbc61d1f34435b78d104ede24b0955a610f4774294d50e02b0c146c4154728c2bfafb3c626@127.0.0.1:0?discport=30301}"

mkdir -p "$NODE_DIR/execution/geth" "$NODE_DIR/logs"

if [ ! -f "$NODE_DIR/geth_password.txt" ]; then
  printf "\n" > "$NODE_DIR/geth_password.txt"
fi

if [ ! -f "$NODE_DIR/execution/jwtsecret" ]; then
  openssl rand -hex 32 | tr -d "\n" > "$NODE_DIR/execution/jwtsecret"
  chmod 600 "$NODE_DIR/execution/jwtsecret"
fi

STATIC_NODES_JSON="$NODE_DIR/execution/geth/static-nodes.json"
if [ -x "$MAINNET_GETH_BINARY" ]; then
  ENODES=()
  for i in 0 1 2 3 4 5; do
    ipc="$MAINNET_DIR/network/node-$i/execution/geth.ipc"
    if [ -S "$ipc" ]; then
      enode="$("$MAINNET_GETH_BINARY" attach --exec admin.nodeInfo.enode "ipc:$ipc" 2>/dev/null | tr -d '"' || true)"
      if [[ "$enode" == enode://* ]]; then
        ENODES+=("$enode")
      fi
    fi
  done
  if [ "${#ENODES[@]}" -gt 0 ]; then
    printf '[\n' > "$STATIC_NODES_JSON"
    for i in "${!ENODES[@]}"; do
      sep=","
      [ "$i" -eq $((${#ENODES[@]} - 1)) ] && sep=""
      printf '  "%s"%s\n' "${ENODES[$i]}" "$sep" >> "$STATIC_NODES_JSON"
    done
    printf ']\n' >> "$STATIC_NODES_JSON"
    echo "static-nodes.json refreshed from live mainnet (${#ENODES[@]} peers)"
  fi
fi

if pgrep -af "$NODE_DIR/execution" >/dev/null 2>&1; then
  echo "Stopping existing old node-5 backup geth..."
  pkill -9 -f "$NODE_DIR/execution" 2>/dev/null || true
  sleep 2
fi

echo "=== $(date -Is) starting old node-5 geth (read-only archive backup) ===" >> "$NODE_DIR/logs/geth.log"

cd "$BASE_DIR"
nohup "$GETH_BINARY" \
  --networkid="$CHAIN_ID" \
  --port="$GETH_NETWORK_PORT" \
  --discovery.port="$GETH_NETWORK_PORT" \
  --metrics.port="$GETH_METRICS_PORT" \
  --authrpc.addr=127.0.0.1 --authrpc.vhosts="*" \
  --authrpc.jwtsecret="$NODE_DIR/execution/jwtsecret" \
  --authrpc.port="$GETH_AUTH_RPC_PORT" \
  --http --http.addr=127.0.0.1 --http.port="$GETH_HTTP_PORT" \
  --http.api=eth,net,web3,debug \
  --http.corsdomain="*" --http.vhosts="*" \
  --datadir="$NODE_DIR/execution" \
  --password="$NODE_DIR/geth_password.txt" \
  --bootnodes="$BOOTNODE_ENODE" \
  --identity=node-5-old-backup \
  --maxpendpeers=10 \
  --verbosity=3 \
  --db.engine=pebble \
  --state.scheme=hash \
  --gcmode=archive \
  --history.transactions=1 \
  >> "$NODE_DIR/logs/geth.log" 2>&1 &

sleep 8
echo "node-5 backup geth started"
echo "datadir: $NODE_DIR/execution"
echo "http rpc: http://127.0.0.1:$GETH_HTTP_PORT"
echo "auth rpc: http://127.0.0.1:$GETH_AUTH_RPC_PORT"
echo "p2p port: $GETH_NETWORK_PORT"
pgrep -af "$NODE_DIR/execution" || true
curl -s --max-time 8 -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  "http://127.0.0.1:$GETH_HTTP_PORT" || true
echo
