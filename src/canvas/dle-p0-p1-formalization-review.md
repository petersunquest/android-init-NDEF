# DLE P0/P1 形式化补正评估

> **单语开发参考，无对等译本。** 本文件是 `dle-p0-p1-formalization-review.canvas.tsx` 的 Git 快照，不是规范真相来源。协议实现必须以 Gateway 不变量规范、Tendermint 一致性规范与 OperatorDomainRegistryV1 独立规范为准。

**评估日期：** 2026-08-13
**状态：** Gateway 有界 TLC 检查通过；OperatorDomain 已独立成规；Tendermint Proposal/Vote SSZ 基线已冻结，但 P0 互操作闭环尚未完成。

## 1. 结论

三项批评均成立：

1. 白皮书中的 burn/mint 意图不足以证明供应安全，必须把物理 burn、未激活负债、L2 credit、refund mint、exit mint 与 replacement capacity 写成可机检状态变量。
2. Tendermint 文字描述不足以保证跨语言 signer 一致，必须冻结 SSZ bytes、`hash_tree_root`、signing root 及状态机拒签向量。
3. OperatorDomain 若只留在白皮书叙述中，会允许治理实现自行解释“独立控制”，必须拆成独立的确定性裁决规范。

## 2. Gateway 安全边界

最低守恒式：

\[
L2Credit + RefundedPending + MintedExit \le PhysicalBurned
\]

v1 应进一步维持：

\[
PhysicalBurned =
PendingBurnLiability + L2CreditLiability + RefundedPending + MintedExit
\]

并要求：

\[
ReservedReplacement =
PendingBurnLiability + L2CreditLiability
\]

因此，mint cap 不能仅在退款或退出发生时读取瞬时 headroom；burn 接收时就必须排他预留未来 replacement mint 权利。

关键竞态结论：

- genesis 永远失败：pending 不可消费；deadline 后原 burner 可退款。
- activation/refund 同块竞争：以链上顺序确定状态，但 deadline 条件必须互斥，任何时点不得同时授权两条分支。
- normal/force exit：共享一个 `exitRightId` 与共同状态机；force 只接管或 supersede，不创建第二份 mint 权。
- adapter upgrade：新 burn 绑定新 epoch；旧 epoch 在负债归零前必须保留 refund/exit 能力及 capacity。
- token/oracle pause：可阻止新 ingress 和价格依赖操作，但不得阻止 exact-unit refund、normal exit 或 force exit。
- duplicate receipt/event nonce/exit claim：单次消费域；完全相同重放幂等或拒绝，冲突载荷形成可处罚证据。

## 3. Tendermint 冻结边界

生产 signer 的一致性语料必须同时覆盖：

- `ProposalSignBytesV1`、`VoteSignBytesV1` 的容器顺序、固定宽度、little-endian 规则与 canonical bytes；
- Prevote accept、Prevote nil、Precommit accept、Precommit nil；
- `lockedRound` / `validRound`，含低轮冲突拒签与更高轮有效 QC 解锁；
- WAL 在意图、签名、发送、AC durable、height advance 各边界 crash/restart；
- 截断或 checksum/signing-root 错误 WAL 进入 non-voting recovery；
- membership/key epoch activation 前后拒签；
- 同高度旧/新 `membershipRoot` 及 mixed key epoch 冲突；
- `CandidateRejectCertificate` 与 accept QC/AC 冲突进入 dispute freeze，不按到达顺序选胜者。

当前仅 Proposal/Vote SSZ 与 22 个语义场景达到上述基线；证书容器、最终 EIP-712 签名 digest、`H(QC)`、WAL frame 和机器可执行 state replay 仍是 P0 阻塞项。

JSON 语料中占位 hash 只能锁定 schema，不能冒充最终 golden vector。发布前必须由至少两个独立实现生成并比对非零 canonical bytes、root 与 signing root。

## 4. OperatorDomain 边界

独立规范固定三值输出：

- `ELIGIBLE`
- `INELIGIBLE`
- `UNKNOWN`

缺失、过期、冲突、被挑战或不可验证证据一律是 `UNKNOWN`，并 fail closed。治理只能在版本化 evidence/attestor/challenge/appeal 状态机内行动，不能用投票直接把未知控制关系变成独立关系，也不能追溯改写已 finalized AC。

## 5. 发布门

规范完成不等于合约已验证。生产发布至少需要：

1. TLC 检查有界 TLA+ 模型。2026-08-13 已完成当前配置：612,105 generated / 73,184 distinct / depth 18 / 0 remaining / no invariant violation。
2. Certora/Halmos 等 Solidity 级不变量证明。
3. Foundry/Echidna stateful fuzz，强制随机化竞态、暂停、cap、upgrade 与重放顺序。
4. Adapter conformance suite 与 token 行为白名单。
5. 事件重放对 `PhysicalBurned / Pending / Credit / Refunded / Minted` 做差分对账。
6. 第二语言独立生成 Tendermint SSZ corpus，并把 corpus hash 固定进 CI。
7. OperatorDomain mandatory rejection vectors 全部通过。
8. 冻结唯一 SSZ→EIP-712 映射、QC/TC/AC/Reject 容器、`H(QC)`、coordinator 公式、WAL frame、机器可执行语义向量及 reject-reason enum。

未通过任一 P0 发布门时，禁止生产部署或启用对应资产。
