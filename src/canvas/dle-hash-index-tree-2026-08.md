# 每组 Hash 索引树（2026-08-15 研讨）

- **Canvas 标识：** `dle-hash-index-tree-2026-08.canvas.tsx`
- **日期：** 2026-08-15
- **状态：** **已入白皮书 §5.2.0e**；runtime 仍未改
- **规范优先级：** §5.2.0d 与上一篇 `dle-rpc-hash-proxy-2026-08.md` > 本快照

## 事实来源

- 用户问题：group 的 hash 可否做成 index 树以加速寻找。
- 既有根：`membershipRoot`、`daRoot`、`tipStateRoot`、`L1QueueAccumulator` — 均不是全组对象目录。
- 白皮书：Merkle opening ≠ 正确编码；禁止无规则的 KZG 升级。

## 假设

- 索引叶只存 locator，不存对象正文。
- 外组可复制索引树 / 根，仍必须 proxy 取回正文。

## 公式 / 数据

- 组内查找 / 包含证明：\(O(\log n)\)（压缩 Patricia / SMT）。
- 根目录：\(G_e \times 32\) 字节。
- 取回：仍 hop=1，禁止 payload 按 \(G_e\) 扇出。

## 冻结结论（建议）

1. **可以且应该**为每组建 `HashIndexTreeV1`，根为 `hashIndexRoot`，由 \(Q_A\) 经 AC 或索引检查点承诺。
2. 键 = 对象 hash；叶 = `{kind, chainNftId, height/acRef, migratedTo?}`。**`chainNftId` 是击中结果**（多链聚合），不是可选注释；成功 locate 必须回写 tip NFT，再 `route(nftId)`。
3. 必须支持**不包含证明**，否则不能把「各组都没有」写成可信 `null`。
4. **不是**全球一棵树；**不是** `daRoot` / `membershipRoot` / `tipStateRoot` 的别名。
5. 索引加速 locate，**不**改变「副本 ≠ RPC 真相」。
6. v1 用 Keccak 域隔离树，不上 Verkle/KZG。

## 替代关系

- 实现并加速 `HashLocatorV1`，不取代 §5.2.0d proxy。
- 有 `chainNftId` hint 时仍直接 `route()`。
- **热路径对照 archive geth**：本组 RPC 应答应走扁平 KV（`H`/`l` 同形），见 `dle-geth-archive-hash-lookup-2026-08.md`。本树只做外组 / 客户端的包含与不包含证明，不要用 Merkle 打开当本归档热查找。

## 未决项

- `hashIndexRoot` 是每条 AC 必带，还是独立检查点高度。
- 外组树：全量复制 vs 只复制根 + 按需节点。
- 墓碑 TTL / 索引保留策略。
- 是否写入英中白皮书（需用户确认）。

## 实现检查表

- [x] 与已有 Merkle 根区分
- [ ] 用户确认后写入 §5.2.0d 增补
- [ ] 语料：包含 / 不包含证明向量
