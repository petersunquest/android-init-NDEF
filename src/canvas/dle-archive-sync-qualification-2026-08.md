# 归档同步资格：追块不是席位（2026-08-16）

- **Canvas 标识：** `dle-archive-sync-qualification-2026-08.canvas.tsx`
- **日期：** 2026-08-16
- **状态：** **规范已冻结**（英中白皮书 §5.2.0f / §15.21）。实验室门面 **已实现** `ArchiveStateChallengeV1`（HMAC + 实验室 keccak beacon）。G1 从零加入验收：只清 `fd-05` + `fd-07` 的 DLE datadir。**不是** 30 天 `PilotQualificationGate`，完成本节 **不得** 开 `pilotStartedAt`。
- **规范优先级：** 英中白皮书 §5.2.0f > runtime `RULES.md` §ArchiveSyncQualificationV1 > Explorer `RULES.md` §Seating vs reachability > 本快照。本页不是第二份规范。

## 事实来源

- 产品意图：新启动 / 未追上最新 hash = 追块 `SYNCING`，无归档席位资格；自报已同步须他证随机抽检「是否真正拥有该 group **所有链** 的状态」；口语「2/3 投票」映射到已冻结 \(Q_A=4/5\)。
- 白皮书：`src/conet-layer2/src/whitepaper/Decentralization Cluster multi-chain.md` 与 `.zh-CN.md` §5.2.0f。
- 身份层已存在：`OperatorDomainRegistryV1`、bond / activate / cooldown、`UnassignedPool` \(U_e\)。
- 实验室可达信号：`GET /health`、`GET /liveness`、HMAC `lastQuorumOk`（TCP **27101**）。这些 **不是** 席位。
- 30 天门：`src/conet-layer2/pilot/src/gate.ts`，`pilotStartedAt=null`。本节 **不** 启动该时钟。

## 假设

- 投票人 = 目标组 \(G\) **当前 active** `membershipRoot`（新组成组时用见证组 active）。候选人自己不投；standby 不投。
- 「所有链」= \(C_G\)：该组全部托管 `chainNftId` 的 tip / state / DA / `lastAC` / `hashIndex`，不是只对 NFT 42。
- 成员 syncing / 离线 **不降低** \(Q_A\)。
- 实验室 keccak beacon **不是** CL RANDAO；HMAC **不是** EIP-712。
- 不实现生产 DePIN gossip；不重启 EL/CL；不 wipe geth/beacon。

## 公式 / 数据

```text
IdentityEligible  ≠  SyncQualified
U_e  counts IdentityEligible unassigned identities, not seating

Q_A = floor(2 * N_A / 3) + 1
N_A = 5  ⇒  Q_A = 4
floor(2*5/3)+1 = 4     already > 2/3
3/5 forbidden: two 3-sets may intersect only at one Byzantine member

seed = H("dle.archive.sync.challenge.v1"
         || L1BeaconFinalizedRandomness
         || groupId || candidate || challengeNonce
         || lastACRef || hostedChainSetRoot)

samples[] derived from the same seed by every current-active voter
every chain in C_G MUST appear in samples[]
answer = exact dle_getByHash / dle_getObject bytes vs challenger freezer
```

FSM：

```text
IdentityEligible
  → SYNCING            // local tip / lastAC / hashIndex lags any chain in C_G
  → CLAIMED_SYNC       // self-report only; still ineligible
  → STATE_CHALLENGE    // peer random test
  → QUALIFIED | REJECTED
```

入口：`COLD_START / RESTART`、`STANDBY_REPLACEMENT`、`NEW_GROUP_FORMATION`（\(C_G\) 为空仍抽检见证 `historySnapshotRoot` / 空库存承诺）。

## 冻结结论

1. **两层资格必须分开。** `IdentityEligible` 只进 UnassignedPool / 计 \(U_e\)。席位、投票、standby-ready、形成接受须对该目标组持有 `ArchiveSyncQualificationCertificate`。
2. **追块无席位。** `SYNCING` 不得签 AC / Prevote / Precommit，不得入席，不得计为 ready standby。
3. **自报不是证据。** `eth_syncing: false`、`/health`、`lastQuorumOk` 只证明可达。
4. **抽检覆盖 \(C_G\) 全部。** 只抽 NFT 42 或自选子集无效。「每链 1 样本」只是覆盖，不是持有证明。
4b. **三层可靠性（2026-08-16 补冻）。** 通过 = 席位级持有**已承诺库存**：(1) `lastAC` / `membershipRoot` / `hashIndexRoot` 逐字节一致（根绑定整份目录）；(2) beacon 揭晓后不可预测打开，作答必须本地 freezer（hop-1 / proxy = 拒绝）；(3) 每链分层抽 tip + 历史 + DA + 索引叶。缺失比例 \(f\) 时，\(k\) 次独立打开存活 \(\le (1-f)^k\)。不证明入席后持续可用（仍走 `UnavailableChallenge`）。
5. **口语 2/3 = \(Q_A=4/5\)。** 禁止 3/5、5/5、动态在线 quorum、对「其他 6 人」另算一套 2/3。
6. **不是 30 天门。** 完成 §5.2.0f 不得开 `pilotStartedAt`。
7. **实验室诚实。** 抽检 / 证书 **已在实验室门面实现**（HMAC，非生产）。Explorer 绿 pill **仅** `seatingQualified===true`；不得把 `/health` / `lastQuorumOk` 显示为席位。

## 替代关系

| 被拒绝 | 为何 |
|---|---|
| 3/5 | 两枚三签可只在唯一拜占庭处相交 |
| 全平面 \(Q_G\) / 「在线者的 2/3」 | 降低 quorum、让离线成员消失 |
| 候选人自投 / standby 投票 | 稀释现任 active 交叉 |
| 用 30 天 `PilotQualificationGate` 冒充席位 | 另一扇生产准入时钟 |
| 历史复制 / 临时 sync 服务 = 组成员 | §5.2 已禁 |

## 未决项

- 生产 seed 绑定 live CL RANDAO 的时间（须先有绑定 beacon）。
- 生产 EIP-712 证书（实验室 HMAC 不得冒充）。

## 实现检查表

- [x] 英中白皮书 §5.2.0f + \(U_e\) / 形成段 / 统一阈值 / AdaptiveRotation §3 / `STANDBY_SYNCING` / §7 清单 / §15.21 / 术语表
- [x] runtime `RULES.md` + README：实验室门面已落地；HMAC / 实验室 beacon 诚实标注
- [x] Explorer `RULES.md` + README：绿 pill 仅 `seatingQualified`；`/health` ≠ 席位
- [x] `.cursor/rules/conet-dle-archive.mdc` 摘要
- [x] 实验室 `ArchiveStateChallengeV1` + G1 fd-05/fd-07 从零加入
- [ ] **未做：** 生产 EIP-712 证书、开 `pilotStartedAt`
