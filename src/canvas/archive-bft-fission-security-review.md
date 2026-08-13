# Archive BFT 与裂变安全审查

> **单语开发参考，无对等译本。** 原交互 Canvas：`archive-BFT-fission-security-review.canvas.tsx`。这是协议基线冻结前的只读审查；当前白皮书已选择 Tendermint 风格并加入 5+2/4-of-5，本文件用于保留“为什么这样改”的推理。

**快照日期：** 2026-08-13
**状态：** 历史审查。BFT 混搭、裂变变量、成员重叠和 Placement 5/5 四个核心问题已被当前设计修正。

## 1. 原始发现

1. **BFT 基线混搭：** 同时使用 Prepare/Commit、lockedQC、Jolteon/两链术语，没有对应单一已发表证明。
2. **五人组长期风险：** `X≥2` 已超出 `f=1` 假设；多组情况下 any-shard 风险迅速放大。
3. **裂变变量双义：** 同一变量同时表达应有组数和已注册组数，使 `canFission` 数学上不可达。
4. **3 旧 + 2 新成员：** 会使来源组失活并造成永久 roster 重叠。
5. **Placement 5/5：** 单节点可阻断；“最后签名者”没有客观全局意义；重抽后旧 Genesis 没有失效规则。

## 2. BFT 基线选择

审查给出两个合法方向：

### Jolteon / DiemBFT v4

- 每轮一种 Vote/QC；
- 连续下一轮子块获得 QC 后提交父块；
- TC 必须保留 TimeoutVote 的 highQC；
- proposer 扩展 TC 中最高安全 QC；
- 无业务事件时可使用不改变应用状态的 ANCHOR 控制块。

### Tendermint 同高度两阶段

- Proposal → Prevote → Precommit；
- 完整定义 `lockedValue/lockedRound` 与 `validValue/validRound`；
- 使用 nil vote 推进 round；
- 明确 higher-validRound 解锁条件。

当前白皮书选择第二条，开发时不得再称作两链 HotStuff/Jolteon。

## 3. 唯一共识对象

所有 proposal、vote、QC、lock 必须绑定同一 value：

```text
valueHash =
  H(
    domain
    || decision
    || blockHash
    || tipStateRoot
    || daRoot
    || encodingParams
  )
```

当前规范另加入 chain/tip ID、height、round、step、`attemptNonce`、membership/key epoch、`membershipRoot` 与 `prevoteQCRef`。

Reject 不应成为同一高度的第二个可提交账本值；应作为 `CandidateRejectCertificate` 触发淘汰与重选。

## 4. 五人组风险量化

```text
q = P[X ≥ 2], X ~ Binomial(5, p)
P[at least one bad group among G] = 1 - (1 - q)^G
```

- `P[X≥2]` 是 assumption breach / liveness-loss 风险，不等于攻击者可伪造 4/5 AC。
- `P[X≥4]` 才是直接 quorum capture。
- 无重叠抽样应使用超几何 / 组合模型。
- operator 与基础设施相关性必须单独建模。
- 长期运行必须加入自适应腐化窗口和强制轮换。

## 5. 非重叠成组

```text
G_e = L1 已注册且 live 的归档组数量
U_e = 合格、已激活且不属于任何 live roster 的归档数量
canFormGroup ⇔ U_e ≥ 7   // 5 active + 2 dedicated standby
```

核心不变量：

- 任一 archive NFT 同时最多属于一个 live group 的 active/standby roster；
- 任意两组 roster 不重叠；
- 历史同步节点不计入 consensus roster；
- 新组从 UnassignedPool 可验证随机选取完整 5+2；
- 来源组只提供形成证明和历史同步，不迁出成员；
- operator、cloud、region、ASN 与机房域满足去相关约束。

## 6. Placement 状态机

```text
QUEUED
  -> RESERVED(assignmentId, groupId, deadline, attemptNonce)
  -> GENESIS_AC
  -> BOUND
  -> optional FULLY_REPLICATED

RESERVED --deadline--> EXPIRED
EXPIRED -> reroll with attemptNonce + 1
```

- Genesis AC 绑定 assignmentId 与 attemptNonce；
- `BOUND` 只需 4/5 PlacementCertificate；
- 任意 relayer 可幂等提交；
- 5/5 只表示 `FULLY_REPLICATED`，不能阻塞可用状态；
- deadline 后旧 Genesis/证书永久失效；
- 重抽不能继承旧 assignment 签名。

## 7. 当前替代关系

| 审查阶段建议 | 当前冻结 |
| --- | --- |
| Jolteon 或 Tendermint 二选一 | Tendermint 风格 |
| 五个全新 permanent members | 五个全新 active + 两个 dedicated standby |
| 4/5 Placement | 保留 |
| 5/5 FullReplication 可选 | 保留 |
| `canFormGroup ⇔ U_e≥5` | 因 standby 冻结为 `U_e≥7` |

## 8. 实现检查清单

- [ ] 是否只存在一种共识术语和一种安全证明？
- [ ] Vote/QC 是否绑定同一 canonical `valueHash`？
- [ ] roster 是否完整 5+2 且组间不重叠？
- [ ] `U_e` 是否按完整新组所需 7 个身份计算？
- [ ] Placement 是否 4/5 即 BOUND？
- [ ] assignment deadline/nonce 是否让旧证书不可重放？
- [ ] 5/5 是否只作为完整复制状态？
- [ ] 风险章节是否分开 assumption breach、liveness loss 与 quorum capture？
