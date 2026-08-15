# DLE Hash RPC 事实核查 + 方案 C PrevoteQC（2026-08-15）

- **Canvas 标识：** 无独立交互 `.canvas.tsx`（规范决策快照）
- **日期：** 2026-08-15
- **状态：** 产品冻结：方案 C（只动 prevote）；runtime / Explore / 英中白皮书 §5.2.0e 已落地；`runtime:test` 50/50；`lab:deploy-archive-keep` 7/7；Explore 已发；live smoke 通过
- **规范优先级：** 英中白皮书 §5.2.0e > 本快照。本页不是第二份规范。

## 事实来源

- 用户 2026-08-15 1:12：DLE 中出现过的任何 hash，RPC 必须给出事实。存在 → 必须能返回该事实；不存在 → 必须返回不存在。
- 用户 2026-08-15 1:18：**明确选方案 C（只动 prevote）**；今后 hash 种类增多时必须分类型细化表示，禁止 `boundField` 把 tip/membership 别名到同一张 AC。
- 线上已命中 AC `certificate` 内三个字段（实验室 `chainNftId=42` `height=0x1`）：
  - `tipStateRoot` = `0x08c8398028ff56e984c11212410d4328fe88ff04ef28546e146a804fb9ca01e1` → **不编目** → 本组 `notFound`
  - `prevoteQCRef` = `0x7e03f8cb23fd79ddb166450fbf3f39e07ad8fd6393d167cbc64f2d7c4a4cf560` → **一等 `kind=prevoteQc`** → `hit` + PrevoteQC 正文
  - `membershipRoot` = `0xdeb200a9c35eacd1709fa8c2976e307e27dd32458b666277aad52ecf79e22241` → **不编目** → 本组 `notFound`
  - `valueHash` 仍 `kind=ac`
- Runtime：`hashLookup.ts` `HASH_OBJECT_KINDS` 含 `prevoteQc`；`hashStore.ts` freezer 按 kind 合并；`hashPipe.ts` 本组 KV miss → `notFound`；`bft/engine.ts` 持久化并索引 PrevoteQC，**不** `putLocator(tipStateRoot|membershipRoot)`。
- 前序：`dle-mvp-hash-lookup-fix-2026-08.md`（M0–M5）。本页收紧 M0 语义并新增 typed kind。

## 假设

- 不 wipe 实验室；发版只用 `lab:deploy-archive-keep`。
- 不改 `DLE_ARCHIVE_CLIENT_VERSION`（仍 `0.2.0`）。
- hop-1 仍按 `(nft, height)` 取整槽；投影在 `getByHash` 侧。
- keep 发版后启动须从已持久化 prevote 票 `tryInstallPrevoteQc` 回填。

## 公式 / 数据

```text
hit         = 本组已承诺语料含 hash → locator + project(kind)
notFound    = 本组目录已完整检索且不在语料；planeWideNull=false；scope=thisGroup
unavailable = 核查未完成（超时 / hop 失败无回落 / hint 冲突 / adapter 未挂 / 非法输入）

prevoteQCRef = topicQcRef({ kind: PREVOTE_QC, valueHash, membershipRoot, height, round })
```

| 方案 | 内容 | 决策 |
| --- | --- | --- |
| A | 不把 tip/membership 编进热 KV；Explore 标 commitment | 否 |
| B | 三 hash 做 alias locator，仍回同一张 AC | **否** |
| **C** | 持久化 PrevoteQC，索引 `prevoteQCRef`，扩 `HashObjectKind` | **是** |

## 冻结结论

1. RPC 对本组已承诺 hash 负全面事实核查责任：`hit` / 本组 `notFound` / 未完成 `unavailable`。
2. 禁止把单组 miss 写成 JSON-RPC `null` / `planeWideNull: true`。
3. 禁止本组 KV 已查完却回 `unavailable`。
4. **`prevoteQCRef` 是一等对象** `kind: 'prevoteQc'`，返回 PrevoteQC 正文，不是 AC alias。
5. **`tipStateRoot` / `membershipRoot` 不编进热目录**，直到各自有独立 `HashObjectKind` + typed 对象。
6. 今后新种类必须 **新 `HashObjectKind` + 独立 typed 对象**，禁止再堆 `boundField` alias。

## 替代关系

- 收紧 `dle-mvp-hash-lookup-fix-2026-08.md` 的 M0：未知 hash 从笼统 `unavailable` 改为完成检索后的 `notFound`。
- 不推翻 §5.2.0e 的 `chainNftId` / hop-1 / HashIndexTree 热路径分工。
- 不重开 M6、不宣称 30 天资格。

## 未决项

- `tipStateRoot` / `membershipRoot` 何时各自成为独立 kind（用户明确：种类增多时再分类型细化）。
- M6 第二组 + 跨组证据。
- keep 发版后 live smoke：**已通过**（`valueHash` hit `ac`；`prevoteQCRef` hit `prevoteQc` / `DleLabPrevoteQcV1`；`tipStateRoot` / `membershipRoot` / 随机 → `notFound` `scope=thisGroup` `planeWideNull=false`；`leafCount=2`）。

## 实现检查表

- [x] `HASH_OBJECT_KINDS` 含 `prevoteQc`；禁止 tip/membership alias
- [x] freezer 按 kind 合并；`getByHash` 投影
- [x] 本组 KV miss → `notFound`；hop/adapter 失败 → `unavailable`
- [x] BFT 持久化 / 索引 / 启动回填 PrevoteQC
- [x] Explore 三分 pill + Prevote QC / Archive Certificate
- [x] 英中白皮书 §5.2.0e + 摘要 + 检查清单 + §15.20 + 附录
- [x] `npm run runtime:test` + explorer build
- [x] `lab:deploy-archive-keep` + Explore 发版 + live smoke
