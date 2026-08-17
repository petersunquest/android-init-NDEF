# DLE MVP：P11 之后的下一闸（2026-08-17）

- **Canvas 标识：** `dle-mvp-p12-milestones-2026-08.canvas.tsx`
- **日期：** 2026-08-17
- **状态：** **P12 / P13 / P14 / P15 / P16 / P17 / P18 / P19 / P20 / P21 / P22 / P24 已落地（引擎 + 单测，2026-08-17；`runtime:test` 154/154）。P25 Explorer overlay 已落地（`explorer:test` 8/8）。** P8–P11 控制面已过。未改白皮书生产条款，未开 `pilotStartedAt`。
- **规范优先级：** 英中白皮书 §5.2.0f（生产协议）> runtime `RULES.md` §ArchiveSyncQualificationV1 / §P12 / §P13 / §P14 / §P15 / §P16 / §P17 / §P18 / §P19 / §P20 / §P21 / §P22 / §P24 / §P25 / §After P11 > 本快照。本页不改生产 \(C_G\)、生产 EIP-712 成员密钥、CL RANDAO 公式。

## 事实来源

- 白皮书：`src/conet-layer2/src/whitepaper/Decentralization Cluster multi-chain.md` 与 `.zh-CN.md` §5.2.0f（IdentityEligible ≠ SyncQualified；生产信标与 EIP-712；30 天门是另一时钟）。
- 入座后评估：`src/canvas/dle-mvp-next-phase-2026-08.md`（P8–P11 已过）。
- 08-15 里程碑评估：`src/canvas/dle-mvp-milestone-assessment-2026-08.md`（P0 问题：可伪造 HMAC；资格时钟未开）。
- 实验室守则：`src/conet-layer2/runtime/RULES.md` §P9 / §P10 / §P11。
- P11 证据：`pilot/evidence/conet-dle-sync-join-2026-08/p11-accept.json`（`ok:true`，`at=2026-08-17T07:52:17.884Z`；opening **2249===2249**）。
- L1 栈：`deployments/conet-DLE-MVP.json`（`ArchiveCertificateVerifierV1` 等 16/16 已验证；**未**接入入座 settle）。

## 假设

- 「实验室完成」只表示对应控制面门有证据，不表示生产可发布。
- 再做一次从零加入（无新授权主机）只重复 P8d/P11，不关闭 HMAC 缺口。
- CoNET 是否已有 **终局** CL RANDAO / 等价 beacon view：**本页视为不可测**；有则只读绑定，无则诚实实验室等待。
- 不重启 EL/CL；P12–P22 默认 **keep-only**。
- `fd-08` 仍是 extra standby，不是第 8 个投票域。

## 公式 / 数据

```text
IdentityEligible ≠ SyncQualified ≠ PilotQualificationGate

P11 opening = 2249 === 2249     // 实验室 freezer hosted-set；当时 HMAC openings
P11 membershipRoot = 0xdeb200a9…e22241
lab vote (P12) = EIP-712 ArchiveSyncQualificationCertificate
                 domain CoNET-DLE-Archive / chainId 224422
                 verifyingContract ArchiveCertificateVerifierV1 0xdA06…948f
                 recoverAddress == labSeatingAddress(domainId) == vote.signer
lab seating key = keccak256(utf8("dle.archive.lab.seating.operator.v1|" + domainId))
                 // 确定性实验室密钥；eip712:true hmacForgeable:false
                 // labDeterministicSeatingKey / notProductionOperatorKey / notL1Settled
hmac seating vote = ERR_SYNC_HMAC_CUTOVER
challenge / opening = EIP-712 ArchiveStateChallenge  // P15；samplesRoot；hmacForgeable:false
hmac challenge    = ERR_SYNC_CHALLENGE_HMAC_CUTOVER
BFT AC vote   = EIP-712 ArchiveBftVote   // P16；同域；复用入座钥；hmacForgeable:false
hmac BFT vote = ERR_BFT_HMAC_CUTOVER
on-demand attest = EIP-712 ArchiveOnDemandAttest  // P17；同域；复用入座钥
hmac on-demand attest = ERR_ONDEMAND_HMAC_CUTOVER
on-demand freeze = ondemandFreezeHex     // P19；先冻 poolRoot，无 beacon
on-demand beacon = labOnDemandBeaconAfterFreeze(freezeHex, honestWaitReveal)
                 // 默认 honest-wait；injected-cl-view / options-beacon 可选
                 // instant labBeaconAfterFreeze(poolRoot) 仅 contrast
                 // ≠ 生产 CL RANDAO；publicrpc/rpc1 forbidden
P6 Q_V = EIP-712 ArchiveValidatorQuorumAttest  // P18；同域；复用入座钥(validatorId)
hmac Q_V = ERR_VALIDATOR_QUORUM_HMAC_CUTOVER
P20 hook ingest = ERR_ONDEMAND_HOOK_NOT_GOSSIP  // miners/hooks/hook 整包拒绝
P20 fanout     = POST same hook to every active archive
                 // one accept ≠ group pool; lab HTTP ≠ production DePIN gossip
lab beacon    = P13 freeze-then-bind     // 非生产 R^{sync}_e
prod vote     = OperatorDomain / L1 member EIP-712  // 尚未
prod seed     = H("dle.archive.sync.challenge.v1" || L1BeaconFinalizedRandomness_e || …)
lab freeze    = ArchiveSyncFreezeV1      // 无 seed / samples；先 persist
lab seed now  = keccak AFTER freeze      // labSyncBeaconAfterFreeze 或 injected-cl-view
                                         // ≠ keccak(freezeHex)；仍 notProductionBeacon
publicrpc/rpc1 = forbidden_el_rpc_as_cl  // 不得当 live CL RANDAO
prod C_G      = L1 archiveGroupId(G) ∪ {lastAC, membershipRoot, hashIndexRoot}
lab hosted    = freezer chainNftIds      // 2249；≠ prod C_G
P14 probe     = no_l1_archive_group_id_view   // default; publicrpc/rpc1 forbidden
injected C_G  = small-set smoke only     // ≠ lab hosted-set; still notProductionCg
official standby ready = EIP-712 ArchiveStandbyReadiness  // P22；string groupId；无 domainId
                 // recoverAddress == labSeatingAddress(domainId)
hmac standby ready = ERR_SYNC_STANDBY_HMAC_CUTOVER
official count = fd-06 + fd-07 only     // OFFICIAL_STANDBY_COUNT=2
extra fd-08    = ingest-only            // extraStandbyReadyDoesNotCount
newchain accept = officialStandbysReady // lab-cli syncHolder + isolated node.ts；else 409
node.ts        = P24 wired              // 同一回调；不 sync.start() / 不冻库存
explorer UI    = P25 overlays           // 非绿芯片；绿点仍 seatingQualified
pilotStartedAt = null
```

## 冻结结论

1. **总评：** 实验室入座 **控制面**（P7–P11）已闭环。下一阶段 MVP 的主缺口是 **密码学诚实**，不是再加入一台机器。
2. **建设序已串行完成：P12 → P13 → P14 → P15 → P16 → P17 → P18 → P19 → P20 → P21 → P22 → P24 → P25。十三闸均已落地（P23 是 live keep-deploy，不是本页引擎闸）。**
   - **P12 入座 EIP-712（landed，引擎 + `runtime:test`）：** 只替换 `ArchiveSyncQualificationCertificate` / `POST /sync/vote` / `/sync/reject`。cutover 后拒绝 HMAC 入座票。`recoverAddress` 必须等于 `labSeatingAddress(domainId)` 且落在现任 active `membershipRoot`。keep-only（磁盘旧 HMAC 证仍可恢复 `QUALIFIED`）。**不** settle 到 L1 MembershipCheckpoint。**不**同闸替换 BFT AC 或 on-demand HMAC。
   - **P13 先冻后信标（landed，引擎 + `runtime:test`）：** 在绑定 beacon 已知前冻结 `hostedChainSetRoot` / `lastACRef` / 候选集（`ArchiveSyncFreezeV1`，无 seed）。引擎先 persist freeze 再 bind。有注入终局 CL view 则绑定该 hex（仍 `notClRandao`）；无则诚实实验室 `labSyncBeaconAfterFreeze`。**禁止**把 `publicrpc` / `rpc1` 读成 live CL RANDAO。**禁止**把 freeze 后 keccak 宣传为生产 \(R^{\mathrm{sync}}_e\)。BFT 后于 **P16** 切；on-demand attest 后于 **P17** 切（beacon / P6 \(Q_V\) 未换）。
   - **P14 \(C_G\) 分轨（landed，引擎 + `runtime:test`）：** 实验室 hosted-set 继续当实验室开口（P9/P11 全开语义不变）；生产 \(C_G\) 只认 L1 `archiveGroupId` ∪ `{lastAC, membershipRoot, hashIndexRoot}`。默认无 L1 view。可选注入小集 smoke **不替代** freezer opening，且不得等于非空实验室 hosted-set。**禁止**把 2249 条实验室链写进白皮书当生产 \(C_G\)。**禁止** HTTP 扫 `publicrpc`/`rpc1` 当生产 \(C_G\)。**禁止**把 live 七台入座改成只抽 L1 小集。BFT 后于 **P16** 切；on-demand attest 后于 **P17** 切（beacon / P6 \(Q_V\) 未换）。
   - **P15 挑战 / opening EIP-712（landed，引擎 + `runtime:test`）：** 同域签发 `ArchiveStateChallenge`（`samplesRoot` 绑定开口，**不**把 2250 条 samples 放进 typed data）。`recoverAddress` 绑 `labSeatingAddress(challenger)`。HMAC / 未签名信封 `ERR_SYNC_CHALLENGE_HMAC_CUTOVER`；验签失败 `ERR_SYNC_CHALLENGE_SIG`；samples≠seed `ERR_SYNC_CHALLENGE_SAMPLES`。`challengeHashOf` 公式不变。不签 answer。不强制 `challenger === candidate`。BFT 后于 **P16** 切；on-demand attest 后于 **P17** 切（beacon / P6 \(Q_V\) 未换）。
   - **P16 BFT AC 票 EIP-712（landed，引擎 + `runtime:test` 当时 125/125）：** 同域签发 `ArchiveBftVote`（`valueHash, height, round, step, membershipRoot, prevoteQCRef`；typed data **不含** `domainId`）。复用 P12 入座钥。`recoverAddress` 必须等于 `labSeatingAddress(domainId)` 且等于 `vote.signer`。HMAC / 未签名票 `ERR_BFT_HMAC_CUTOVER`；验签失败 `ERR_BFT_VOTE_SIG`。keep-only：磁盘旧 HMAC **证书**仍可恢复 tip 终局；新票必须 EIP-712。**不**换 on-demand HMAC / on-demand beacon。**不**改 P6 \(Q_V\) HMAC。**不**改 `membershipRootOf` / Mode A `valueHash`。**不得**把 `bftEip712` 画成冻结 L1 wrapper / corpus SSZ。
   - **P17 on-demand attest EIP-712（landed，引擎 + `runtime:test` 当时 128/128）：** 同域签发 `ArchiveOnDemandAttest`（`poolRoot, epoch, shardId, roulette`；typed data **不含** `domainId`）。复用 P12 入座钥。`recoverAddress` 必须等于 `labSeatingAddress(domainId)` 且等于 `attest.signer`。HMAC / 未签名 attest `ERR_ONDEMAND_HMAC_CUTOVER`；验签失败 `ERR_ONDEMAND_ATTEST_SIG`。keep-only：磁盘旧 HMAC attest 仍可恢复并计入 `endorsed`；新 ingest 必须 EIP-712。**只换 attest。不**换 on-demand lab beacon。**不**改 P6 \(Q_V\) HMAC（后于 **P18** 切）。**不**改 gossip wait-hook。**不得**把 `ondemandEip712` / `endorsed` 画成 30 天资格或生产信标。
   - **P18 \(Q_V\) EIP-712（landed，引擎 + `runtime:test` 当时 131/131）：** 同域签发 `ArchiveValidatorQuorumAttest`（`requestId, valueHash, tipStateRoot, bodyCommitment`；typed data **不含** `validatorId` / `domainId`）。复用 P12 入座钥于 request 派生 `validatorId`（`labValidatorId`；**不**另造 validator 钥前缀）。`recoverAddress` 必须等于 `labSeatingAddress(validatorId)` 且等于 `attest.signer`。HMAC / 未签名票 `ERR_VALIDATOR_QUORUM_HMAC_CUTOVER`；验签失败 `ERR_VALIDATOR_QUORUM_SIG`。keep-only：磁盘旧 HMAC \(Q_V\) 仍可恢复；新 `POST /newchain/request` 必须 EIP-712。**不**换 on-demand lab beacon。**不**改 gossip wait-hook。**不**改 `membershipRootOf` / Mode A `valueHash` / `chainNftId` / NFT 42 tip。**不得**把 `newchainValidatorQuorumEip712` 画成生产 secp256k1 或 30 天资格。
   - **P19 on-demand 先冻后绑（landed，引擎 + `runtime:test` 当时 134/134）：** 对齐 P13。先 persist `ondemandFreezeHex`（无 beacon / roulette / committee），再 bind：默认 honest-wait `labOnDemandBeaconAfterFreeze`；可选注入 CL view / `options.beacon`。即时 `labBeaconAfterFreeze(poolRoot)` 仅 contrast。**禁止**把 `publicrpc` / `rpc1` 读成 live CL RANDAO。**禁止**把 `ondemandLabBeaconAfterFreeze` 画成生产信标。keep-only：磁盘旧即时 keccak SelectionLog 仍可恢复 `endorsed`（`legacy-instant`）。**不**换 P17 attest / P18 \(Q_V\) / 入座 / 挑战 / BFT。**不**改 gossip wait-hook（后于 **P20** 切诚实）。**不**改 7+2 公式。
   - **P20 gossip wait-hook honesty（landed，引擎 + daemon + `runtime:test` 140/140）：** 白皮书 §5.4 / §8.1：等待钩 **不得假定**已在同组归档间 gossip。`ingest` 若带 `miners` / `hooks` / `hook` → 整包拒绝 `ERR_ONDEMAND_HOOK_NOT_GOSSIP`。`gossip()` 仍只转发 attests + selection。miner / daemon **必须**对组内每一台活跃归档 POST 同一钩；一台 accept ≠ 组等待池一致。daemon `fanoutComplete` 仅当全部 queued；单台 `submitWaitHook` 标 `singleArchiveAcceptNotGroupPool`。实验室 `POST /ondemand/hook`（TCP **27101**）**不是**生产 DePIN gossip。Explorer nginx **不得**暴露 hook。**不是**把 HTTP 钩改成生产 DePIN gossip。**不**换 P12–P19 票 / beacon / \(Q_V\)。**不得**把 `ondemandHookNotGossip` 画成生产 gossip。
   - **P21 hashIndexRoot into lab BFT（landed，引擎 + `runtime:test` 当时 148/148）：** 把 live/bound `hashIndexRoot` 写入实验室 BFT 票 / QC / AC typed data（在 `membershipRoot` 之后），并 **改** `topicQcRef` 编码。树视图 / `dle_getHashIndexRoot` / `dle_proveHash` 仍 `committedInAc: false`。overlay `hashIndexCommittedInAc` 仅当 AC 根 ≠ `ZERO32`（`emptyHashIndexRoot()` ≠ `ZERO32` → overlay true；磁盘 HMAC 缺字段 → `ZERO32` → overlay false）。keep-only：已有证书则跳过 QC/AC 重建；重建 `qcRef` 不一致则保留磁盘 QC。HMAC / 坏签仍优先于 `ERR_BFT_HASH_INDEX_ROOT`。**不**改 `membershipRootOf` / Mode A `valueHash` / daemon / on-demand。**不得**把 overlay 画成生产 AC 承诺或 30 天门。
   - **P22 official standby readiness（landed，引擎 + `runtime:test` 当时 153/153）：** 官方 standby（`fd-06` / `fd-07`）`QUALIFIED` 后签实验室 EIP-712 `ArchiveStandbyReadiness`（`groupId` 为 **string**；typed data **不含** `domainId`；复用 P12 入座钥）。HMAC / 未签名 → `ERR_SYNC_STANDBY_HMAC_CUTOVER`。extra `fd-08` / `fd-08-hosthatch-hk1` 可 ingest，**不计入** `OFFICIAL_STANDBY_COUNT=2`。`POST /sync/standby-ready`。`REJECTED` 重载保留 `standbyReady` map。`lab-cli` 经 `syncHolder` 把门注入 newchain accept；未就绪 → 409 `ERR_NEWCHAIN_STANDBY_NOT_READY`。Explorer 绿点仍只看 `seatingQualified`。**不得**把 `standbyReadyEip712` / `officialStandbysReady` / `newchainOfficialStandbysReady` 画成生产 OperatorDomain / secp256k1 / 30 天门。**不**改入座票 / 挑战 / BFT / on-demand / \(Q_V\)。
   - **P24 isolated `node.ts` gate（landed，引擎 + `runtime:test` 154/154）：** `startArchiveNode` 把同一 `officialStandbysReady` 回调注入 `createNewChainEngine`。extra `fd-08` 仍不计。隔离节点 **不** `sync.start()`、**不**冻库存。测试：`runtime/test/node-standby-gate.test.ts`。**不是** 7/7 健康 / **不是** 30 天资格。
   - **P25 Explorer overlays（landed，Explorer + `explorer:test` 8/8）：** Certificates + Home **非绿**芯片展示 `officialStandbysReady` / `hashIndexCommittedInAc`。绿点仍只 `seatingQualified === true`。`archiveSeating.ts` 未改。树 `committedInAc` 仍 false。**不是** 生产 AC / **不是** 30 天资格。
3. **30 天门仍拒绝。** 完成本页任一闸都 **不得** 开 `pilotStartedAt` / `PilotQualificationGate`。
4. **本页不改白皮书生产条款。**

## 替代关系

| 被拒绝 | 为何 |
|---|---|
| 下一步再做全开从零加入 | 只重复 P11；不关闭 HMAC |
| 把 EIP-712 / RANDAO / 30 天绑成一闸 | 范围过大，会再次把实验室完成说成生产就绪 |
| 同闸换 BFT AC + on-demand HMAC | 入座票 / 挑战是最高杠杆；BFT 已在 P16 另闸切；on-demand attest 已在 P17 另闸切；\(Q_V\) 已在 P18 另闸切；on-demand beacon 已在 P19 另闸切；gossip wait-hook 已在 P20 另闸切诚实，**不是**生产 DePIN gossip；`hashIndexRoot` 已在 P21 另闸写入实验室 BFT（树 `committedInAc` 仍 false，**不是**生产 AC 承诺）；官方 standby 就绪签已在 P22 另闸切（extra `fd-08` 不计；**不是**生产 OperatorDomain） |
| 开 `pilotStartedAt` | 入座门面 ≠ 生产准入时钟 |
| 把 fd-08 编进官方 5+2 | `REQUIRED_DOMAIN_COUNT=7` |
| 走 P8d wipe / 清 fd-05 | P11 已证明不必清官方机 |
| 把 2249 写成生产 \(C_G\) | 缺 L1 `archiveGroupId` 绑定 |

不替代白皮书 §5.2.0f、2026-08-15 里程碑评估、或 P8–P11 快照。

## 未决项

- P12 / P13 / P14 / P15 / P16 / P17 / P18 / P19 / P20 / P21 / P22 / P24 / P25 **已落地**。本轨下一事项是停放项，不是再开 `pilotStartedAt`。
- CoNET 终局 CL RANDAO view：P13 只读探测默认 `no_finalized_cl_view`；未 HTTP 拉 `publicrpc` / `rpc1`。生产 \(R^{\mathrm{sync}}_e\) 仍未接 live CL。
- 生产 \(C_G\) 仍无 live L1 `archiveGroupId` view（P14 默认 `no_l1_archive_group_id_view`；注入小集仍 `notLiveL1Scan` / `notProductionCg`）。
- IdentityEligible / OperatorDomain / \(U_e\)：停放。官方 standby 就绪签 **不再停放**（P22 已落地；extra `fd-08` 不计）。实验室 overlay `hashIndexCommittedInAc` 已落地（树仍 `committedInAc: false`；生产 AC 承诺公式未改）。生产 DePIN gossip 仍停放（P20 只切实验室 HTTP 钩诚实，不是生产 gossip）。
- 30 天 100/30/100 计数：未开。
- 实验室确定性入座密钥仍可从算法派生；生产 OperatorDomain / L1 成员密钥未接。

## 实现检查表

- [x] 对照白皮书 / P11 证据 / 08-15 评估做诚实研讨
- [x] 交互 Canvas 写入 Cursor 管理目录
- [x] 本快照 + `src/canvas/README.md` 索引
- [x] runtime / explorer RULES 写回「After P11」建设序（不改生产条款）
- [x] P12 入座 EIP-712（引擎 + `sync-qualification.test.ts`；HMAC cutover；BFT/on-demand HMAC 未动）
- [x] P13 先冻后信标（引擎 + 单测 + 全 runtime；freeze 无 seed；publicrpc/rpc1 拒绝；BFT/on-demand HMAC 未动）
- [x] P14 \(C_G\) 分轨（引擎 + 单测 + 全 runtime；实验室 2249 ≠ 生产 \(C_G\)；publicrpc/rpc1 拒绝；注入小集 smoke 不替代 freezer opening；BFT/on-demand HMAC 未动）
- [x] P15 挑战 / opening EIP-712（引擎 + 单测 + 全 runtime；`ArchiveStateChallenge` + `samplesRoot`；HMAC cutover；on-demand HMAC 未动）
- [x] P16 BFT AC 票 EIP-712（引擎 + 单测 + 全 runtime 当时 125/125；`ArchiveBftVote`；HMAC cutover；keep-only 磁盘 HMAC 证书；on-demand / P6 \(Q_V\) HMAC 未动）
- [x] P17 on-demand attest EIP-712（引擎 + 单测 + 全 runtime 当时 128/128；`ArchiveOnDemandAttest`；HMAC cutover；keep-only 磁盘 HMAC attest；beacon / P6 \(Q_V\) HMAC 未动）
- [x] P18 \(Q_V\) EIP-712（引擎 + 单测 + 全 runtime 当时 131/131；`ArchiveValidatorQuorumAttest`；HMAC cutover；keep-only 磁盘 HMAC \(Q_V\)；on-demand beacon / gossip wait-hook 未动）
- [x] P19 on-demand 先冻后绑（引擎 + 单测 + 全 runtime 当时 134/134；`ondemandFreezeHex` + honest-wait / injected view；publicrpc/rpc1 拒绝；keep-only `legacy-instant`；gossip wait-hook 当时未动）
- [x] P20 gossip wait-hook honesty（引擎 + daemon + 单测 + 全 runtime 140/140；`ERR_ONDEMAND_HOOK_NOT_GOSSIP`；fan-out 诚实；**不是**生产 DePIN gossip）
- [x] P21 hashIndexRoot into lab BFT（引擎 + 单测 + 全 runtime 当时 148/148；树 `committedInAc` 仍 false；overlay 仅当 AC 根 ≠ `ZERO32`；**不是**生产 AC 承诺）
- [x] P22 official standby readiness（引擎 + 单测 + 全 runtime 当时 153/153；`ArchiveStandbyReadiness`；extra `fd-08` 不计；`lab-cli` 新链 gate；**不是**生产 OperatorDomain / 30 天门）
- [x] P24 isolated `node.ts` gate（引擎 + 单测 + 全 runtime 154/154；同一 `officialStandbysReady` 回调；不 `sync.start()` / 不冻库存；**不是** 7/7 / 30 天门）
- [x] P25 Explorer overlays（Certificates + Home 非绿芯片；`explorer:test` 8/8；绿点仍只 `seatingQualified`；**不是** 生产 AC / 30 天门）
- [ ] 30 天资格（明确未宣称）
