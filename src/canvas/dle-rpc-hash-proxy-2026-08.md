# DLE RPC：按 hash 检索与跨组 proxy（2026-08-15 研讨）

- **Canvas 标识：** `dle-rpc-hash-proxy-2026-08.canvas.tsx`
- **日期：** 2026-08-15
- **状态：** **已入白皮书 §5.2.0e**；**尚未**改 runtime
- **规范优先级：** 英中白皮书 §5.2.0e > 本快照。本页保留研讨过程，不再当作待确认规范。

## 事实来源

- 用户产品意图（本对话）：任一归档节点按 hash 检索；非本组内容必须 proxy 到其它 group 的归档并返回客户端。
- 白皮书 §5.2.0d：全局 RPC 面；`route(chainNftId)` → `historyProviders`；副本 ≠ RPC 真相；fail closed。
- 既有快照：`src/canvas/dle-global-rpc-proxy-2026-08.md`（按 NFT / group 分流；未覆盖 hash-only）。
- 实现：`runtime/src/archive/jsonrpcFacade.ts` — `eth_getBlockByHash` 仅比对本地 `tip.hash`，否则 `null`。
- 实验室：当前单组，跨组 proxy 未验收。

## 假设

- 客户端可以只持有 32-byte hash，不带 `chainNftId` / `groupId`。
- 公开 RPC 只服务可验证的账本/证书对象，不含版权明文或 IPFS fragment。
- 生产传输仍是 DePIN（钱包寻址）；实验室 27101 HTTP 只作对照。

## 公式 / 数据

定位复杂度（建议上限，非正式费率）：

- locate：对每个 `liveGroupId` 至多询问该组 `archivesOf` 中 1–2 个钱包，响应为常量级 locator。
- fetch：定位成功后只向 **一个** `targetGroupId` 取 payload（hop = 1）。
- 禁止：对 \(G_e\) 组各拉一份完整对象。

## 冻结结论（建议，待确认）

1. **产品语义：** 任一 live archive 必须能按 hash 取回全平面公开对象。本组权威命中可本地应答；否则必须 proxy 到托管组并原样返回。
2. **缺口：** §5.2.0d 现按 `chainNftId` 路由。hash-only 是新查询类，必须先 `HashLocatorV1` **击中 `chainNftId`**，再 `route(nftId)` 套用同一 proxy 规则。只定位到 group 不够（一组多 tip）。
3. **禁止：** 把「本组没有」写成全局 `null`；用本地跨组副本冒充成功；把完整 payload 扇出到所有组；在 L1 登记每一个 hash。
4. **失败：** 全部 live group 可信 not-found → `null`；任一组不可用且无人命中 → unavailable。
5. **方法：** 规范入口 `dle_locateHash` / `dle_getByHash`；`eth_getBlockByHash` / `eth_getTransactionByHash` / 外组 `dle_getArchiveCertificate` 走同一管道。
6. **范围：** AC、事件块 / valueHash、事件 tx hash、daRoot 证明包。等待池为组局部。版权 / IPFS 不走本 RPC。

## 替代关系

- 扩展（不取代）§5.2.0d。有 `chainNftId` hint 时仍直接 `route()`，不跑全平面 locate。
- 取代「未知 hash → 本地 null」的 ethers 门面行为。

## 未决项

- locate 超时、并发、重试、计费（谁付 proxy 流量）。
- 多组实验室验收（现为单组）。
- 是否立即写入英中白皮书（需用户同条确认）。

## 实现检查表

- [x] 对照 §5.2.0d 与现行 facade 标出 hash-only 缺口
- [ ] 用户确认后写入英中白皮书 §5.2.0d 增补
- [ ] runtime `/rpc`：locate + hop-1 proxy；禁止未知 hash 直接 null
- [ ] 多组实验室证据（非 30 天资格）
