# Archive geth hash 快路径 vs DLE（2026-08-15 研讨）

- **Canvas 标识：** `dle-geth-archive-hash-lookup-2026-08.canvas.tsx`
- **日期：** 2026-08-15
- **状态：** **已入白皮书 §5.2.0e**；runtime 仍未改
- **规范优先级：** §5.2.0d、`dle-rpc-hash-proxy-2026-08.md`、`dle-hash-index-tree-2026-08.md` > 本快照

## 事实来源

- 用户问题：对照存档 geth 如何按 hash 快速返回；DLE 可否用同一思路。
- go-ethereum `core/rawdb/schema.go`：`headerNumberPrefix = "H"`（hash → number）；`txLookupPrefix = "l"`（tx hash → lookup）。
- `core/rawdb/accessors_indexes.go`：现代 TxLookup 值常为 **block number**；再 `ReadCanonicalHash` + body 按下标取交易。
- Geth freezer（v1.9+）：终局 header/body/receipts 进 append-only ancient；**索引留在 LevelDB/Pebble**。freezer 内按高度 × 6 字节偏移表定位，不是对文件做 hash 扫描。
- Archive（`gcmode=archive`）额外保留的是**历史 state trie**，服务 `eth_getBalance(addr, oldBlock)`；与 tx-by-hash 全文索引（`TransactionIndexTail` / `txlookuplimit`）不是同一开关。
- 当前 DLE：`src/conet-layer2/runtime/src/archive/jsonrpcFacade.ts` 的 `eth_getBlockByHash` **只比本地合成 `tip.hash`**，对不上即 `null`。

## 假设

- 用户说的「存档 geth」指执行层 archive 节点按 `eth_getBlockByHash` / `eth_getTransactionByHash` 的本地快路径，不是 CL RANDAO，也不是把 DLE `/rpc` 反代到 `publicrpc`。
- DLE 仍是多组平面；权威在托管组。

## 公式 / 数据

- Geth 块 hash：1 次 `H+hash` Get + 按 number 读 header/body。
- Geth 交易 hash：约 2–3 次磁盘读（lookup → canonical hash → body）。
- DLE 组内热路径目标：同形 **O(1) KV**，不要用 Merkle 打开当热路径。
- 跨组：仍 hop=1；禁止 payload 按 \(G_e\) 扇出。

## 冻结结论（建议）

1. **能用，而且组内就该用。** Archive geth 快，是因为热库扁平索引 `hash → 高度`，再按高度读正文（热库或 freezer）。不是扫 ancient，也不是走 state trie。
2. DLE 每个托管组应对本组权威对象建 **Pebble 前缀索引**（对标 `H` / `l`）。因一组托管多条 tip，值必须是 **`(chainNftId, kind, height)`**，不能只存 number（见 `dle-hash-must-hit-chain-2026-08.md`）。
3. 已 AC 正文进 **append-only freezer**；槽位键为 **`(chainNftId, height)`**，不是 `(groupId, height)`。索引留热库。
4. **不能借**「本地 miss ⇒ JSON-RPC `null`」。Geth 是单条 canonical 链；DLE 必须再走 HashLocator + hop-1 proxy。部分组不可达 ⇒ unavailable，不是可信空。
5. **不能借** archive 的历史 state trie 当全球对象目录；DLE 无 tip VM / 账户模型（现行 facade 已拒 `eth_call` / `eth_getBalance`）。
6. **不能**把 DLE `/rpc` 代理到 `publicrpc` / `rpc1` 的 archive geth。
7. `HashIndexTreeV1` / `hashIndexRoot` **仍然要做**，但是给外组 / 客户端的**包含与不包含证明**（O(log n)），**不替代**本组 O(1) KV 热路径。

## 替代关系

- 实现并加速组内 `HashLocatorV1` 的热路径 = 抄 geth rawdb，不是抄 EVM。
- 跨组语义仍以 `dle-rpc-hash-proxy-2026-08.md` 为准。
- 可证明「没有」仍以 `dle-hash-index-tree-2026-08.md` 为准。
- 有 `chainNftId` hint 时仍直接 `route()`。

## 未决项

- 热索引是每条 AC 增量写，还是检查点批量重建。
- freezer 偏移表用 geth 式 6 字节槽，还是自研 length-prefix。
- 是否写入英中白皮书（需用户确认）。

## 实现检查表

- [x] 区分「热 KV」与「证明树」
- [x] 标明 archive state ≠ txlookup
- [ ] 用户确认后写入 §5.2.0d 增补
- [ ] runtime：本组历史 hash 不再只比 `tip.hash`
