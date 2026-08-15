# 修正 MVP：Hash 检索管道（2026-08-15）

- **Canvas 标识：** `dle-mvp-hash-lookup-fix-2026-08.canvas.tsx`
- **日期：** 2026-08-15
- **状态：** 实验室已落地 **M0–M4**（清零后 hash 管道 + hop-1 `historyProviders` + Explore 检索）；**M5–M6** 未做
- **规范优先级：** 英中白皮书 §5.2.0e > 本快照。本页不是第二份规范。

## 事实来源

- 本对话冻结：hash-only 必须先击中 `chainNftId`，再 `route()` + hop-1；组内 geth 式热 KV；每组 `HashIndexTreeV1`。
- 白皮书：§5.2.0d（已知 nft 的 proxy）+ 新 §5.2.0e（hash-only）。
- Runtime：`jsonrpcFacade.ts` + `hashPipe.ts` + `hop1.ts` — `dle_locateHash` / `dle_getByHash` / `eth_*ByHash` 共用管道；命中后 hop-1 `dle_getObject` 到 `historyProviders`（实验室 HTTP :27101）。`dle_getObject` 只读本地 freezer。
- Runtime：`hashStore.ts` — 文件 KV `hash-index.json` + freezer `hash-freezer.json`，键 `(chainNftId, height)`。**尚无** `hashIndexRoot`（M5）。
- 实验室：单组 7 归档 TCP 27101；`70.35.205.77` 上 30 HTTP miner；P5 L1 16/16；`pilotStartedAt=null`。
- 前序快照：`dle-hash-must-hit-chain-2026-08.md`、`dle-geth-archive-hash-lookup-2026-08.md`、`dle-hash-index-tree-2026-08.md`、`dle-rpc-hash-proxy-2026-08.md`（均已入 §5.2.0e）。

## 假设

- 用户已授权清零并重启 **DLE 实验室**（不是 CoNET L1 / Base EL·CL）。不宣称 30 天资格。
- 实验室 HMAC / HTTP hook / lab beacon 保持非生产标签。
- M5 证明树可晚于 M1–M4 热路径。

## 公式 / 数据

```text
M0  未知 hash ≠ null
M1  hash → (chainNftId, kind, height)     // 本组 O(1)
M2  freezer key = (chainNftId, height)
M3  locate/getByHash 成功 ⇒ chainNftId
M4  groupId = route(nft) → hop-1 historyProviders
M5  每组 hashIndexRoot（含不包含证明）
M6  第二实验室组 + 跨组证据
```

## 冻结结论（M0–M4 已在实验室落地）

1. **先停错误 `null`（M0）。** 现行门面把本组未命中写成全平面没有。
2. **先本组索引（M1–M3），再 hop-1（M4），跨组第二组仍是 M6。** 单组实验室现在就能验收 M1–M4。
3. **热路径是 KV，不是树。** M5 不得替代 M1。
4. **成功必须回 `chainNftId`。** 只回 `groupId` 不算完成 M3。
5. **做完 M0–M6 仍不是 30 天资格**，也不是生产 DePIN。

## 替代关系

- 收紧并落地前四篇研讨：proxy / 热 KV / 索引树 / 必须击中链 → 现为白皮书 §5.2.0e。
- 不推翻 §5.2.0d：已知 nft 仍直接 `route()`。
- 不重开 P0–P5 实验室门或 L1 验证。

## 未决项

- **M5** `hashIndexRoot`、**M6** 第二实验室组。
- M4 实验室 hop 走 HTTP `:27101` + `dle_getObject`；**不是** 生产 DePIN gossip。
- 热 KV 现为文件（`hash-index.json` / `hash-freezer.json`）；Pebble 可后换，键语义不变。
- M6 第二组的实验室主机是否新开，另需运维确认（本页不分配主机）。

## 实现检查表

- [x] 写入英中白皮书 §5.2.0e + 摘要 + §7.13 + 附录 A + §15.20
- [x] 排出 M0–M6 与正/反验收
- [x] 实验室 runtime M0–M3 + Explore `/hash/:hash`
- [x] 用户授权后清零 DLE `data/` 并重启归档（非 L1）
- [x] 实验室 runtime M4 hop-1 `historyProviders`（不清零发版）+ Explore hop 回执
- [x] 公开 `https://dle.conet.network/hash/<tip>` 目视：Hit + `chainNftId 42` + hop pills；`lab:accept-archive` `ok/meshOk`（health JSON 与 `DAEMON_EXIT` 粘行已按括号提取）
