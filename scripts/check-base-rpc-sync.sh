#!/bin/bash
# Base 主网 RPC 同步压力检测脚本（默认对比 base-rpc.conet.network）
# 在 base RPC 节点所在机器执行（或 SSH 进去后执行）

set -e

echo "=== 1. op-geth RPC (localhost:8547) ==="
curl -s -m 5 http://127.0.0.1:8547 -H "content-type:application/json" \
  --data '{"jsonrpc":"2.0","id":1,"method":"net_peerCount","params":[]}' 2>/dev/null | jq -r '.result // .error.message' || echo "RPC 不可达"
curl -s -m 5 http://127.0.0.1:8547 -H "content-type:application/json" \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' 2>/dev/null | jq -r 'if .result then "区块: " + (.result | tonumber) else .error.message end'
curl -s -m 5 http://127.0.0.1:8547 -H "content-type:application/json" \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_syncing","params":[]}' 2>/dev/null | jq -r '.result'

echo ""
echo "=== 2. 磁盘 iostat (2 次 x 2s 采样) ==="
iostat -x 2 2 2>/dev/null || echo "iostat 未安装，可: apt install sysstat"

echo ""
echo "=== 3. 进程磁盘写入 pidstat (2s 采样) ==="
pidstat -d 2 1 2>/dev/null || echo "pidstat 未安装"

echo ""
echo "=== 4. op-node 日志 (最近 80 行) ==="
docker logs base-op-node 2>&1 | tail -80 | grep -E "waiting|timeout|error|L1|beacon|sidecar|WARN|ERROR" || docker logs base-op-node 2>&1 | tail -30

echo ""
echo "=== 5. op-geth 日志 (最近 20 行) ==="
docker logs base-op-geth 2>&1 | tail -20

echo ""
echo "=== 6. 数据盘挂载与使用 ==="
df -h /media/sda/base 2>/dev/null || df -h | grep -E "sda|base"
ls -la /media/sda/base/ 2>/dev/null || echo "数据目录不可直接列出"
