#!/bin/bash
# Base RPC 同步进度检测：对比当前与上次，估算剩余同步时间
# 用法：
#   本地节点: ./check-base-rpc-sync-progress.sh
#   远程节点: ./check-base-rpc-sync-progress.sh https://base-rpc.conet.network
#   SSH 到服务器后: ./check-base-rpc-sync-progress.sh http://127.0.0.1:8547

set -e

RPC="${1:-http://127.0.0.1:8547}"
STATE_FILE="${2:-$(dirname "$0")/.base-sync-state}"
PUBLIC_RPC="${PUBLIC_BASE_RPC:-https://base-rpc.conet.network}"
BASE_BLOCK_TIME=2  # Base 主网约 2 秒/块

jq_cmd() {
  curl -s -m 10 "$RPC" -H "content-type:application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" 2>/dev/null
}

public_block() {
  curl -s -m 10 "$PUBLIC_RPC" -H "content-type:application/json" \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' 2>/dev/null | jq -r '.result // empty'
}

hex2dec() {
  printf '%d' "$1"
}

echo "=== Base RPC 同步进度 ==="
echo "节点: $RPC"
echo "参考链: $PUBLIC_RPC"
echo ""

# 1. 获取节点当前区块与同步状态
block_res=$(jq_cmd "eth_blockNumber" "[]")
syncing_res=$(jq_cmd "eth_syncing" "[]")

local_block_hex=$(echo "$block_res" | jq -r '.result // empty')
syncing_raw=$(echo "$syncing_res" | jq -r '.result // empty')

if [[ -z "$local_block_hex" ]]; then
  echo "❌ 无法获取节点区块 (RPC 不可达或返回错误)"
  echo "$block_res" | jq . 2>/dev/null || echo "$block_res"
  exit 1
fi

local_block=$(hex2dec "$local_block_hex")

# 2. 获取公网最新区块
public_block_hex=$(public_block)
if [[ -z "$public_block_hex" ]]; then
  echo "⚠ 无法获取公网最新区块，使用节点自身 highestBlock 估算"
  public_block=$local_block
else
  public_block=$(hex2dec "$public_block_hex")
fi

# 3. 解析 eth_syncing
if [[ "$syncing_raw" == "false" ]]; then
  syncing=false
  highest_block=$public_block
  current_block=$local_block
else
  syncing=true
  # eth_syncing 返回对象: { currentBlock, highestBlock, ... }
  current_block=$(echo "$syncing_res" | jq -r '.result.currentBlock // empty')
  highest_block=$(echo "$syncing_res" | jq -r '.result.highestBlock // empty')
  if [[ -n "$current_block" && "$current_block" =~ ^0x ]]; then
    current_block=$(hex2dec "$current_block")
  else
    current_block=$local_block
  fi
  if [[ -n "$highest_block" && "$highest_block" =~ ^0x ]]; then
    highest_block=$(hex2dec "$highest_block")
  else
    highest_block=$public_block
  fi
fi

lag=$((public_block - local_block))
# 节点内部剩余（eth_syncing）；若为 0 则用与公网的差距作为待同步量
remaining=$((highest_block - current_block))
[[ $remaining -lt $lag ]] && remaining=$lag

# 4. 读取上次状态
last_local=""
last_ts=""
if [[ -f "$STATE_FILE" ]]; then
  last_local=$(grep '^local_block=' "$STATE_FILE" 2>/dev/null | cut -d= -f2)
  last_ts=$(grep '^ts=' "$STATE_FILE" 2>/dev/null | cut -d= -f2)
fi

# 5. 计算速率与预估
now=$(date +%s)
rate_msg=""
eta_msg=""

if [[ -n "$last_local" && -n "$last_ts" && "$last_ts" -gt 0 ]]; then
  elapsed=$((now - last_ts))
  if [[ $elapsed -gt 0 ]]; then
    blocks_synced=$((local_block - last_local))
    if [[ $blocks_synced -gt 0 ]]; then
      rate=$(echo "scale=2; $blocks_synced / $elapsed" | bc 2>/dev/null || awk "BEGIN {printf \"%.2f\", $blocks_synced / $elapsed}")
      rate_msg="过去 ${elapsed}s 同步了 ${blocks_synced} 块，速率约 ${rate} 块/秒"
      if [[ "$syncing" == "true" && $remaining -gt 0 && -n "$rate" && "$rate" != "0" ]]; then
        eta_sec=$(echo "scale=0; $remaining / $rate" | bc 2>/dev/null || awk "BEGIN {printf \"%.0f\", $remaining / $rate}")
        if [[ -n "$eta_sec" && "$eta_sec" -gt 0 ]]; then
          eta_h=$((eta_sec / 3600))
          eta_m=$(((eta_sec % 3600) / 60))
          eta_msg="预估剩余时间: 约 ${eta_h} 小时 ${eta_m} 分钟"
        fi
      fi
    elif [[ $blocks_synced -lt 0 ]]; then
      rate_msg="(节点可能重启或回滚，上次: $last_local)"
    else
      rate_msg="过去 ${elapsed}s 无新区块"
      if [[ $lag -gt 0 ]]; then
        # 理论估算：按 0.5 块/秒（Base 2s/块，同步可更快）
        eta_h=$(awk "BEGIN {printf \"%.1f\", $lag / 0.5 / 3600}")
        eta_msg="(若按 0.5 块/秒估算，约需 ${eta_h} 小时)"
      fi
    fi
  fi
fi

# 6. 输出
echo "当前区块:     $local_block"
echo "公网最新:     $public_block"
echo "落后块数:     $lag"
echo "同步状态:     $([ "$syncing" = "true" ] && echo "同步中 (节点 current: $current_block, 待追: $remaining 块)" || echo "已同步")"
echo ""
if [[ -n "$rate_msg" ]]; then
  echo "$rate_msg"
fi
if [[ -n "$eta_msg" ]]; then
  echo "$eta_msg"
fi
echo ""

# 7. 保存本次状态
mkdir -p "$(dirname "$STATE_FILE")"
cat > "$STATE_FILE" << EOF
local_block=$local_block
ts=$now
public_block=$public_block
lag=$lag
EOF
echo "状态已保存到 $STATE_FILE (下次运行将对比)"
