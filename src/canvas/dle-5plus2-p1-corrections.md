# CoNET-DLE 5+2 P1 修正评估

> **单语开发参考，无对等译本。** 原交互 Canvas：`dle-5plus2-p1-corrections.canvas.tsx`。本快照记录从 7+2 演进到严格 5+2 时的判断过程；冲突时以当前双语白皮书为准。

**快照日期：** 2026-08-13
**状态：** 5+2、4/5、L1 原生队列与 Tendermint 修正已被采纳；早期“两账本”费用描述已由“三账本 + 最低流入”模型替代。

## 1. 冻结参数

```text
active archives N_A = 5
Byzantine tolerance f = 1
archive quorum Q_A = 4
dedicated ordered standbys = 2
```

- Tendermint 安全阈值必须严格大于 2/3。
- 3/5 的两个 quorum 可能只在一个 Byzantine 成员处相交，不能证明安全。
- 5+2 将每组独占身份数降到 7，但安全余量只有 `f=1`。
- 降低成本的前提是保留强制轮换、operator-domain 去相关、固定 4/5 和 L1 逃生路径。

## 2. 风险解释

```text
P[X ≥ 2]  // 超出 f=1 假设；可由两名 withholding 破坏活性
P[X ≥ 4]  // 攻击者单独形成恶意 4/5 quorum
```

一次静态独立抽样不代表长期风险：多组 `any-shard` 风险随组数放大；operator、云账号、机房和密钥管理相关性会使二项独立模型过于乐观；公开固定名册会产生自适应腐化窗口。因此需要 `AdaptiveRotationV1`、`OperatorDomainRegistryV1` 与每 epoch 累计暴露上限。

## 3. 全局队列修正

```text
canonical order = L1 sequence + L1QueueAccumulatorV1 root
propagation = bounded-fanout header gossip + L1 event catch-up
payload = content-addressed, only ingress/DA/assigned group fetches full body
```

- 删除跨全部 archive group 的 `Q_G` 安全门。
- 不可用小组不得阻塞 enqueue、排序或 range freeze。
- BLS、递归证明或分层 cache 只能优化同步 / 证明大小，不能决定 canonical order。
- 单条 pending 查验只能明确选择 L1 mapping O(1) 直读或 accumulator O(log Q_max) inclusion proof。

`QueueScaleProfileV1` 应包含最大 batch/header、fanout、catch-up batch、enqueue/freeze/place 的 p50/p95/p99 gas、最大未分配队列与 L1 reorg 恢复时限。

## 4. Tendermint 线级修正

1. 本轮 proposal 与已有 lock 冲突且没有合法 higher-validRound justification 时，应 `Prevote(nil)`，不能投给本轮未提议的 `lockedValue`。
2. `PrevoteQC(nil)` 只推进 round，不能清除 `lockedValue/lockedRound`。

签票前 WAL 原子持久化：

```text
height, round, step
exact sign bytes
proposal/value hash
lockedValue, lockedRound
validValue, validRound
QC/TC references
membershipEpoch, keyEpoch, membershipRoot
```

重启后只能重发同一票；WAL 损坏进入 non-voting recovery；从至少 4 个当前成员同步证明后恢复；禁止根据本地猜测解锁或二次签票。

确定性编码：

```text
canonical bytes = SSZ
valueHash =
  keccak256("dle.archive.value.v1" || hash_tree_root(ArchiveValueV1))
```

protobuf 只可作为网络外壳；JSON、map、可省略默认字段和未知字段不得参与签名。

## 5. 成员切换

- 每次 membership switch 只替换一个 active slot。
- 五个 active 在一个完整 churn cycle 内全部轮换。
- standby 无投票权；提升前重新验证 operator/failure-domain 独立性。
- 新 root 从明确 `activationHeight=H+1` 生效。
- H 使用旧 root，H+1 使用新 root，同一高度不得接受双 root。
- `RejectCertificate` 与同 candidate 的有效 QC 冲突时冻结高度并提交 evidence。

## 6. 经济层替代关系

原 Canvas 的：

```text
protocol value fee + execution/service fee
```

已替代为：

```text
protocolFee
+ executionReserve
+ epochAvailabilityFunding
```

并新增 10–100 USDC 激活区间、`minIngressUsdc6` 成本公式、补贴前 / 后分离及 force-exit emergency reserve。开发经济层应参考 [经济费率压力模型](./dle-economic-fee-stress-model.md) 与 [P1 真实成本报告](./dle-p1-real-cost-measurement-report.md)。

## 7. 实现检查清单

- [ ] Archive quorum 是否永久固定 4/5？
- [ ] SSZ sign bytes 与 golden vectors 是否跨实现一致？
- [ ] nil polka 是否保留 lock？
- [ ] WAL 恢复是否禁止双投？
- [ ] Queue canonical order 是否只来自 L1？
- [ ] Placement retry 是否绑定递增 `attemptNonce`？
- [ ] 5+2 节约是否没有通过 roster 重叠或 operator 复用实现？
- [ ] 费用实现是否使用当前三账本？
