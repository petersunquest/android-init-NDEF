# Hash 必须击中某条链（2026-08-15 研讨）

- **Canvas 标识：** `dle-hash-must-hit-chain-2026-08.canvas.tsx`
- **日期：** 2026-08-15
- **状态：** **已入白皮书 §5.2.0e**；runtime 仍未改
- **规范优先级：** 英中白皮书 §5.2.0e > 本快照。本页修正前两篇「只定位到组」的不足。

## 事实来源

- 用户：DLE 是多链聚合，hash 要击中某条链。
- §5.2.0d：`route(chainNftId) → groupId`；`chainsOf(groupId)` / `hostedChainNftIds[]` 为**数组**；`historyProviders` 入参是 **nftId**。
- 协议名「DLE Chain ID」= **groupId**（托管委员会），**不是** tip / 链 NFT。用户说的「某条链」= **`chainNftId`**（一条原子账本）。
- `ArchiveConsensusDomain` 已含 `chainNftId`；`valueHash` 绑在该 tip 上。
- 前序：`dle-rpc-hash-proxy-2026-08.md`、`dle-hash-index-tree-2026-08.md`、`dle-geth-archive-hash-lookup-2026-08.md`。

## 假设

- 一个 live group 同时托管多条 tip。
- 各 tip 的 `tipHeight` 独立计数；组没有单一 canonical height。
- 进入公开 hash 目录的对象，预映像必须域隔离 `chainNftId`。

## 公式 / 数据

```text
locate(hash) → { chainNftId, kind, height, acRef }     // 必须有 nft
groupId      = route(chainNftId)
hosts        = historyProviders(chainNftId)
fetch        = hop-1  (chainNftId, height)  于 hosts
```

- 禁止：`locate(hash) → groupId` 后在组内扫全部 tip。
- freezer / WAL 键：`(chainNftId, height)`，不是 `(groupId, height)`。
- 热 KV（geth `H`/`l` 同形）：`hash → (chainNftId, kind, height)`，不是只存 number。

## 冻结结论（建议）

1. **命中 = 击中 `chainNftId`。** 成功的 `dle_locateHash` / `dle_getByHash` **必须**回写 tip NFT。未带 `chainNftId` 的 200 是协议错误。
2. **组是派生量。** `groupId = route(nftId)`。只知道组无法打开正确 freezer 槽，也无法调用 `historyProviders`。
3. **Geth 差在单链。** 抄热索引时必须把 locator 从 `number` 扩成 `(chainNftId, number)`。
4. **索引仍可每组一棵树**（避免 \(G_e \times\) 链数棵全球树），但叶的 `chainNftId` 是击中结果，不是可选注释。
5. **Hint：** 请求已带 `chainNftId` 时只查该链；叶 nft 不符不得把另一条链的正文当成成功（可诊断 `foundOnChain`）。
6. **碰撞：** 同一 objectHash 出现在两条 `chainNftId` → 域隔离不变量破坏，fail closed，不返回多命中数组。
7. **可信空：** 无 hint 时，每个 live group 证明「其托管的全部 tip 都没有该 hash」。有 hint 时，只问 `route(hint)` 那一组：「**这条链**没有」。

## 替代关系

- 收紧（不推翻）前三篇：proxy 仍 hop-1；热路径仍 O(1) KV；证明树仍做不包含。全部以 **链** 为第一键。
- 有 `chainNftId` hint 时仍直接 `route()`，locate 可缩成「该链命名空间内的 Get」。

## 未决项

- 响应是否同时回 `groupId`（便于调试）——建议回，但权威路由仍以当时 L1 `route(nftId)` 为准（re-home 后组会变）。
- runtime locate 成功必须带 `chainNftId`（见 `dle-mvp-hash-lookup-fix-2026-08.md` M3）。

## 实现检查表

- [x] 区分 tip NFT vs 协议 DLE Chain ID（groupId）
- [x] freezer 键改为按链
- [x] 写入白皮书 §5.2.0e
- [ ] runtime locate 成功必须带 `chainNftId`
