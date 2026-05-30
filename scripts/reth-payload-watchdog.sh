#!/usr/bin/env bash
set -Eeuo pipefail

LOG_TAG="reth-payload-watchdog"
RETH_SERVICE="base-op-reth-native.service"
OP_NODE_SERVICE="base-op-node-native.service"
CHECK_INTERVAL=5
STALL_SECONDS=180
LOOKBACK_SECONDS=240
POST_RESTART_GRACE=15
RESTART_RECORD="/home/peter/base/reth-payload-watchdog-restarts.log"

last_num=-1
last_change_ts=$(date +%s)

log() {
  echo "$(date '+%F %T %Z') [$LOG_TAG] $*"
}

record_restart() {
  local idle="$1"
  local reth_pid="$2"
  local op_node_pid_before="$3"
  local op_node_pid_after="$4"
  printf '%s | action=restart-op-node | idle_seconds=%s | last_payload=%s | reth_pid=%s | op_node_pid_before=%s | op_node_pid_after=%s\n' \
    "$(date '+%F %T %Z')" \
    "$idle" \
    "$last_num" \
    "$reth_pid" \
    "$op_node_pid_before" \
    "$op_node_pid_after" >> "$RESTART_RECORD"
}

extract_latest_num() {
  sudo journalctl -u "$RETH_SERVICE" --since "${LOOKBACK_SECONDS} seconds ago" --no-pager 2>/dev/null \
    | python3 -c '
import re, sys
text = sys.stdin.read()
nums = [int(m.group(1)) for m in re.finditer(
    r"Received new payload from consensus engine\s+number=(\d+)", text)]
print(max(nums) if nums else "")
'
}

seed_recent() {
  local num
  num=$(extract_latest_num)
  if [[ -n "$num" ]]; then
    last_num=$num
    last_change_ts=$(date +%s)
    log "seed payload number=$num"
  else
    last_change_ts=$(date +%s)
    log "no recent payload found; timer starts now"
  fi
}

restart_op_node() {
  local idle reth_pid op_node_pid_before op_node_pid_after
  idle=$(( $(date +%s) - last_change_ts ))
  reth_pid=$(systemctl show -p MainPID --value "$RETH_SERVICE" 2>/dev/null || echo "unknown")
  op_node_pid_before=$(systemctl show -p MainPID --value "$OP_NODE_SERVICE" 2>/dev/null || echo "unknown")

  if ! systemctl is-active --quiet "$RETH_SERVICE"; then
    log "WARN: ${RETH_SERVICE} is not active; skipping op-node-only restart"
    last_change_ts=$(date +%s)
    return 0
  fi

  log "no new payload for ${STALL_SECONDS}s; restarting ${OP_NODE_SERVICE} only (leaving ${RETH_SERVICE} running)"
  sudo systemctl restart "$OP_NODE_SERVICE"

  op_node_pid_after=$(systemctl show -p MainPID --value "$OP_NODE_SERVICE" 2>/dev/null || echo "unknown")
  record_restart "$idle" "$reth_pid" "$op_node_pid_before" "$op_node_pid_after"

  last_num=-1
  last_change_ts=$(date +%s)
  sleep "$POST_RESTART_GRACE"
  seed_recent
}

touch "$RESTART_RECORD"
log "daemon started: stall=${STALL_SECONDS}s interval=${CHECK_INTERVAL}s record=${RESTART_RECORD}"
seed_recent

while true; do
  now=$(date +%s)
  num=$(extract_latest_num)

  if [[ -n "$num" ]] && (( num > last_num )); then
    last_num=$num
    last_change_ts=$now
    log "new payload number=$num"
  fi

  idle=$((now - last_change_ts))
  if (( idle >= STALL_SECONDS )); then
    restart_op_node
  fi

  sleep "$CHECK_INTERVAL"
done
