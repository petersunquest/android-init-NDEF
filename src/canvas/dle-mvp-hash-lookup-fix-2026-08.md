# 修正 MVP：Hash 检索管道（2026-08-15）

- **Canvas 标识：** `dle-mvp-hash-lookup-fix-2026-08.canvas.tsx`
- **日期：** 2026-08-15
- **状态：** 实验室已落地 **M0–M5**（清零后 hash 管道 + hop-1 `historyProviders` + 每组独立 `hashIndexRoot`）；**M0 语义收紧**为三分 + **方案 C** `kind=prevoteQc`（见 `dle-hash-rpc-fact-check-2026-08.md`）；**M6** 见 `dle-lab-m6-fission-2026-08.md`；**M7** 见 `dle-lab-m7-typed-roots-2026-08.md`
- **规范优先级：** 英中白皮书 §5.2.0e > 本快照。本页不是第二份规范。

## 事实来源

- 本对话冻结：hash-only 必须先击中 `chainNftId`，再 `route()` + hop-1；组内 geth 式热 KV；每组 `HashIndexTreeV1`。
- 白皮书：§5.2.0d（已知 nft 的 proxy）+ 新 §5.2.0e（hash-only）。
- Runtime：`jsonrpcFacade.ts` + `hashPipe.ts` + `hop1.ts` — `dle_locateHash` / `dle_getByHash` / `eth_*ByHash` 共用管道；命中后 hop-1 `dle_getObject` 到 `historyProviders`（实验室 HTTP :27101）。`dle_getObject` 只读本地 freezer。
- Runtime：`hashStore.ts` — 文件 KV `hash-index.json` + freezer `hash-freezer.json`，键 `(chainNftId, height)`。
- Runtime：`hashIndexTree.ts` — 组内排序 Keccak `HashIndexTreeV1`；`dle_getHashIndexRoot` / `dle_proveHash`；`committedInAc: false`；**不是**热 Get。
- 实验室：单组 7 归档 TCP 27101；`70.35.205.77` 上 30 HTTP miner；P5 L1 16/16；`pilotStartedAt=null`。
- 前序快照：`dle-hash-must-hit-chain-2026-08.md`、`dle-geth-archive-hash-lookup-2026-08.md`、`dle-hash-index-tree-2026-08.md`、`dle-rpc-hash-proxy-2026-08.md`（均已入 §5.2.0e）。

## 假设

- 用户已授权清零并重启 **DLE 实验室**（不是 CoNET L1 / Base EL·CL）。不宣称 30 天资格。
- 实验室 HMAC / HTTP hook / lab beacon 保持非生产标签。
- M5 证明树已落地为独立检查点，**不**写入 AC 投票，也 **不** 替代 M1 KV。

## 公式 / 数据

```text
M0  未知 hash ≠ null；本组查完 = notFound；未完成 = unavailable
M1  hash → (chainNftId, kind, height)     // 本组 O(1)；kind 含 prevoteQc
M2  freezer key = (chainNftId, height) + per-kind 对象
M3  locate/getByHash 成功 ⇒ chainNftId + typed object
M4  groupId = route(nft) → hop-1 historyProviders
M5  每组 hashIndexRoot（含不包含证明）
M6  第二实验室组 + 跨组证据
M7  tipStateRoot / membershipRoot 独立 HashObjectKind
```

## 冻结结论（M0–M5 已在实验室落地）

1. **先停错误 `null`（M0）。** 本组检索完成的 miss 是 `notFound`（`planeWideNull: false`），不是全平面没有，也不是 `unavailable`。`prevoteQCRef` 走独立 `kind=prevoteQc`（方案 C）。
2. **先本组索引（M1–M3），再 hop-1（M4），跨组第二组仍是 M6。** 单组实验室现在就能验收 M1–M4。
3. **热路径是 KV，不是树。** M5 不得替代 M1。
4. **成功必须回 `chainNftId`。** 只回 `groupId` 不算完成 M3。
5. **做完 M0–M7 仍不是 30 天资格**，也不是生产 DePIN。

## 替代关系

- 收紧并落地前四篇研讨：proxy / 热 KV / 索引树 / 必须击中链 → 现为白皮书 §5.2.0e。
- 不推翻 §5.2.0d：已知 nft 仍直接 `route()`。
- 不重开 P0–P5 实验室门或 L1 验证。

## 未决项

- **M6** 已落地：见 `dle-lab-m6-fission-2026-08.md`。G2 L1 `registerLiveGroup` 已由 `dle-lab-g2-l1-register-2026-08.md` 关闭。
- **M7** 已落地：见 `dle-lab-m7-typed-roots-2026-08.md`。`tipStateRoot` / `membershipRoot` 为一等 kind。
- M5 树是独立检查点（`committedInAc: false`）；生产是否改写入 AC 仍开放。
- M4 实验室 hop 走 HTTP `:27101` + `dle_getObject`；**不是** 生产 DePIN gossip。
- 热 KV 现为文件（`hash-index.json` / `hash-freezer.json`）；Pebble 可后换，键语义不变。

## 实现检查表

- [x] 写入英中白皮书 §5.2.0e + 摘要 + §7.13 + 附录 A + §15.20
- [x] 排出 M0–M6 与正/反验收
- [x] 实验室 runtime M0–M3 + Explore `/hash/:hash`
- [x] 用户授权后清零 DLE `data/` 并重启归档（非 L1）
- [x] 实验室 runtime M4 hop-1 `historyProviders`（不清零发版）+ Explore hop 回执
- [x] 公开 `https://dle.conet.network/hash/<tip>` 目视：Hit + `chainNftId 42` + hop pills；`lab:accept-archive` `ok/meshOk`（health JSON 与 `DAEMON_EXIT` 粘行已按括号提取）
- [x] 实验室 runtime M5 `hashIndexRoot` / `dle_proveHash`（不清零发版）+ Explore 证明回执
