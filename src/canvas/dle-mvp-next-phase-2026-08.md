# DLE MVP 入座后评估与 P8 / P9 / P10 / P11 建设序（2026-08-16 / P9–P11 2026-08-17）

- **Canvas 标识：** `dle-mvp-next-phase-2026-08.canvas.tsx`
- **日期：** 2026-08-17
- **状态：** **P8a–P8d、P9、P10 与 P11 已落地。** P9 keep + smoke：七台 G1 unique hosted **2103 === opened 2103**（`p9-opening.json` `at=2026-08-17T06:35:54.834Z`）。P10 live keep + safety smoke：七台 `QUALIFIED`、无 active `REJECTED`（`p10-rejected-safety.json` `ok:true`，`at=2026-08-17T06:55:13.921Z`）。P11 extra standby `fd-08-hosthatch-hk1` @ `167.104.98.104` 空 datadir 全开入座（`p11-accept.json` `ok:true`，`at=2026-08-17T07:52:17.884Z`；opening **2249 === 2249**；官方七台 + `fd-05` 仍 `QUALIFIED`；`membershipRoot` 未变）。**不是** 30 天 `PilotQualificationGate`，完成本页 **不得** 开 `pilotStartedAt`。
- **规范优先级：** 英中白皮书 §5.2.0f（生产协议）> runtime `RULES.md` §ArchiveSyncQualificationV1 / §P8 / §P9 / §P10 / §P11 > 本快照。本页不改生产 \(C_G\)、EIP-712、CL RANDAO。

## 事实来源

- 白皮书：`src/conet-layer2/src/whitepaper/Decentralization Cluster multi-chain.md` 与 `.zh-CN.md` §5.2.0f 三层可靠性。
- 实验室守则：`src/conet-layer2/runtime/RULES.md` §ArchiveSyncQualificationV1。
- 入座证据（P7）：`src/conet-layer2/pilot/evidence/conet-dle-sync-join-2026-08/` 当时 `accept.json`（`ok:true`，`at=2026-08-17T05:35:26.713Z`，leaf **4956**）。
- P8d 证据：同目录现役 `wipe.json` + `accept.json` + `p8d-selection.json`（随机 **fd-05 + fd-06**，`at=2026-08-17T06:18:41.255Z`，`waitedMs=128098`，leaf **5194 → 5194**）。
- P9 证据：同目录 `p9-opening.json`（七台 `opened===hosted` unique **2103**，`sampleCount=2104`，`ok:true`，`at=2026-08-17T06:35:54.834Z`）。keep 后 `/health` leaf **5225**，七台 `QUALIFIED`。
- P10 证据：同目录 `p10-rejected-safety.json`（`ok:true`，`at=2026-08-17T06:55:13.921Z`；七台 `QUALIFIED`；`neverWipe` / `neverInjectMissingObject`）。对抗演练只在 `runtime/test/sync-qualification.test.ts`。
- P11 证据：同目录 `p11-probe.json` / `p11-keep.json` / `p11-deploy.json` / `p11-accept.json` / `p11-opening.json`（`ok:true`，`at=2026-08-17T07:52:17.884Z`；`waitedMs=333122`；opening **2249===2249**，`sampleCount=2250`）。路径：`pilot/lab/hosts-p11-joiner.json`（`PilotLabP11JoinerV1`，`notOfficialFivePlusTwo`）。**不要**复用 P8d `wipe.json` / `accept.json`。
- 前序评估：`src/canvas/dle-mvp-milestone-assessment-2026-08.md`（2026-08-15，P0–P5）；`dle-mvp-phased-runtime-2026-08.md`；`dle-archive-sync-qualification-2026-08.md`。
- 08-16 已闭环轨：M6 裂变、G2 L1 登记、M7 typed roots、P6 新链独立 AC。

## 假设

- 「实验室完成」只表示对应控制面门有证据，不表示生产可发布。
- 实验室 HMAC + keccak beacon **不是** EIP-712 / CL RANDAO。
- 实验室 P9 全开 hosted `chainNftId`（HMAC）**不是** 生产全 \(C_G\)。旧 8 链帽只作回滚常量。
- 不重启 EL/CL；P8d wipe 只清 wipe-safe 入座机（`fd-05` / `fd-06` / `fd-07`）的 `~/dle-30d-lab/data`，永不 wipe keeper。P11 **不走** P8d wipe：只清 extra joiner `167.104.98.104`。
- 5 个 active 若永久 `REJECTED`，\(Q_A=4\) 死锁（单测已证 `hasUnseatedActive` + freeze）；不得为修单个 keeper 去 wipe keeper。

## 公式 / 数据

```text
IdentityEligible ≠ SyncQualified ≠ PilotQualificationGate

Q_A = 4 / 5          // 候选人 / standby 不投票
lab P9 open = all hosted  // HMAC；unique 2103 === opened 2103；sampleCount 2104
lab open ≤ 8 chains      // 已废止的实验室帽；仅回滚
P7 wipe leaf = 4951     // keepers 四根对齐后才 wipe
P7 accept leaf = 4956   // join 窗口 +5；已由 P8d 关闭
P8d wipe/accept leaf = 5194  // leafGrew=false；stale=false
P8d waitedMs = 128098   // ~2.1 min SYNCING → QUALIFIED
P9 unique hosted / opened = 2103  // 七台 G1；policy=all-hosted
P9 sampleCount = 2104   // tip-heavy + 1 hashIndex
P9 health leaf = 5225   // keep 后编目已恢复；七台 QUALIFIED
P10 voter miss = CHALLENGER_MISSING  // skip reject；inbound no-op
P10 candidate miss + holdClaimed = terminal REJECTED
P10 live smoke = 2026-08-17T06:55:13.921Z  // 七台 QUALIFIED；无 active REJECTED
P11 joiner = fd-08-hosthatch-hk1 @ 167.104.98.104  // extra standby；官方 7 不动
P11 wipe = joiner datadir only  // never fd-01..07 / never fd-05
P11 accept = 2026-08-17T07:52:17.884Z  // QUALIFIED；waitedMs 333122
P11 opening = 2249 === 2249  // sampleCount 2250；policy=all-hosted
P11 membershipRoot = 0xdeb200a9…e22241  // 与 P8d 相同；未因 extra standby 改变
P11 leaf = joiner 5673 / official 5674
```

P8d 现场四根（wipe 与 accept 相同，全组一致）：

| 根 | 值（前缀） |
|---|---|
| `hostedChainSetRoot` | `0x3a5441b1be30…` |
| `lastACRef` | `0x6216d0fb08bf…` |
| `membershipRoot` | `0xdeb200a9c35e…` |
| `hashIndexRoot` | `0xb42210d4c01e…` |

## 冻结结论

1. **总评：** 实验室控制面（P0–P5）+ 08-16 轨（M6/M7/P6）+ **P7 入座门面**已闭环。可以建设 P8。**不得**宣称 30 天资格或生产 DePIN 就绪。
2. **P7 已证：** 空 datadir 能从同组最富 donor catch-up，过 `ArchiveStateChallengeV1`（9 samples / ≤8 链），拿到 \(Q_A=4/5\) HMAC 证书，`seatingQualified === true`。四根绑定 + 本地 freezer 作答 + hop-1 即拒在从零加入路径上闭环。Explorer 绿 pill 只信 `seatingQualified`。
3. **P8a–d 已落地：** join / `STATE_CHALLENGE` 冻新编目；双方有 AC 必须打开 AC；`/health` 不重建挑战。P8d 随机 **fd-05 + fd-06**（必含唯一可 wipe 的 active），leaf **5194 → 5194**。P7 的 4951→4956 缺口已在实验室复验关闭。
4. **P8 实验室诚实窗口已过。** 不得把 HMAC 证书写成生产「随机抽测 = 已持有」。
   - **P8a–P8d** 均已落地。
5. **P9 已过线：** `LAB_SYNC_OPEN_ALL_HOSTED_CHAINS`；按链分组；`GET /sync/opening` 只读。live keep 七台 LIVE_OK（不 wipe）。smoke 七台 unique **2103 === 2103**。`/health` 不建样本。旧 8 帽 persist 形状须重建。
6. **P10 已过线：** 白皮书「缺对象」= **候选人** freezer miss（`OBJECT_MISMATCH`），不是抽检方 miss（`CHALLENGER_MISSING` → skip / inbound no-op）。`holdClaimed` + 缺对象才永久 `REJECTED`。\(Q_A=4\) 死锁只单测。live keep 七台 `LIVE_OK`（不 wipe）；`lab:smoke-rejected-safety` 七台 `QUALIFIED`、无 active `REJECTED`。
7. **P11 已过线（2026-08-17T07:52:17Z）：** extra standby `fd-08-hosthatch-hk1`（`167.104.98.104`）空 datadir 追上同组 donor，过全开 HMAC 挑战（opening **2249===2249**），`seatingQualified === true`。官方 7 台 + `fd-05` 仍 `QUALIFIED`（未 wipe）。`membershipRoot` 仍 `0xdeb200a9…`（五台 seeded active）。accept ~5.6 min。仍 HMAC，**不是** 生产 \(C_G\)。
8. **本页不改白皮书生产条款。** 不得把实验室全开 HMAC 开口写进白皮书当生产 \(C_G\)。下一阶段建设序见 `dle-mvp-p12-milestones-2026-08.md`（P12 入座 EIP-712 → P13 先冻后信标 → P14 \(C_G\) 分轨 → P15 挑战 EIP-712 → P16 BFT AC EIP-712 → P17 on-demand attest EIP-712 → P18 \(Q_V\) EIP-712 → P19 on-demand 先冻后绑 → P20 gossip wait-hook honesty）。**不得**开 `PilotQualificationGate`。

## 替代关系

| 被拒绝 | 为何 |
|---|---|
| 下一步开 `pilotStartedAt` / 30 天门 | 入座门面 ≠ 生产准入时钟 |
| 把实验室 P9 HMAC 全开写成生产 \(C_G\) | 缺 EIP-712 / CL RANDAO |
| 把 HMAC 证书当生产席位 | 可伪造；白皮书要求 EIP-712 |
| 为修 REJECTED 去 wipe keeper | 会拆掉 \(Q_A=4/5\) 投票面 |
| 把 `167.104.98.104` 编进官方 5+2 | `REQUIRED_DOMAIN_COUNT=7`；第 8 台不得投票 |
| 走 P8d wipe 做 P11 | 会强制 wipe 现役 `fd-05` |
| 用 `lab:deploy-m6` 只刷 G1 | 会重启 G2 |

不替代白皮书 §5.2.0f、2026-08-15 里程碑评估、或 P0–P5 分期快照。

## 未决项

- P8d 已过（2026-08-17；随机 fd-05+fd-06；leaf 5194 零增长）。
- P9 已过（2026-08-17；七台 opening 2103===2103；leaf 5225；不 wipe）。
- P10 已过（2026-08-17；keep 七台 LIVE_OK；smoke `p10-rejected-safety.json` 06:55:13Z；不 wipe、不注入缺对象）。
- P11 已过（2026-08-17T07:52:17Z；extra joiner QUALIFIED；opening 2249===2249；官方 7 + fd-05 未 wipe）。
- 下一阶段建设序：`dle-mvp-p12-milestones-2026-08.md`（**P12–P25 已落地**；`runtime:test` 154/154；`explorer:test` 8/8；入座文案为 lab EIP-712 而非 HMAC；公开 SPA `index-U1o9ul_I.js` 已发；下一闸停放 / 仅审查；不得开 `pilotStartedAt`；不得发明 P26）。
- IdentityEligible / OperatorDomain / \(U_e\)：停放。官方 standby 就绪签 **不再停放**（P22）。实验室 `hashIndexRoot` overlay 已落地（树仍 `committedInAc: false`）。生产 DePIN gossip 仍停放（P20 只切实验室 HTTP 钩诚实）。
- 30 天 100/30/100 计数：未开。

## 实现检查表

- [x] 对照白皮书 / RULES / accept.json 做诚实评估
- [x] 交互 Canvas 写入 Cursor 管理目录
- [x] 本快照 + `src/canvas/README.md` 索引
- [x] runtime / explorer RULES 写回 P8 建设序
- [x] P8a 冻新编目 + BFT 磁盘态 vs `start()`
- [x] P8b 双方有 AC 必须打开 AC
- [x] P8c `/health` 不重建 `pendingChallenge`
- [x] P8d wipe 回归（随机 fd-05+fd-06；leaf 5194 零增长）
- [x] P9a 全开 hosted + 按链分组 + `GET /sync/opening`（单测 22/22）
- [x] P9 live `lab:deploy-g1-keep` + `lab:smoke-cg-open`（2103===2103；不 wipe）
- [x] P10 voter skip + inbound `CHALLENGER_MISSING` no-op + `holdClaimed` 终端 REJECTED（单测）
- [x] P10 live `lab:deploy-g1-keep` + `lab:smoke-rejected-safety`（不 wipe、不注入缺对象）
- [x] P11 extra joiner 路径（官方 7 不动；`extraPeers`；单测 12/12）
- [x] P11 live `lab:p11-full-open-join`（probe → keep 七台 → 只清新机 → accept 07:52:17Z；2249===2249）
- [ ] 30 天资格（明确未宣称）
