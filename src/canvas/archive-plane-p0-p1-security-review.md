# 归档平面 P0/P1 安全评估

> **单语开发参考，无对等译本。** 原交互 Canvas：`archive-plane-p0-p1-security-review.canvas.tsx`。该评估基于早期 7-active + 2-standby 草案；当前组宽已演进为 5-active + 2-standby，旧数值阈值不得直接复用。

**快照日期：** 2026-08-13
**状态：** 四个核心控制已进入当前白皮书；7 槽轮换与 5/7 quorum 已被严格 5 槽轮换与 4/5 替代。

## 1. 风险结论

| 优先级 | 风险 | 原缺口 | 被采纳的控制 |
| --- | --- | --- | --- |
| P0 | 自适应腐化 | 一次随机分组被误当作长期安全 | 强制周期单槽轮换、key epoch、安全擦除和移动攻击窗口 |
| P0 | 运营者相关性 | 地址互斥不能证明控制人、云账号或机房独立 | 可挑战 OperatorDomainRegistry 与跨角色互斥 |
| P0 | DA 错误编码 | Merkle inclusion 不证明合法 RS 码字 | `dle.rs.v1` 字节级规范和 precommit 前完整重编码 |
| P1 | 全局队列 checkpoint | 跨组 quorum 使链创建受 O(G) 协调和离线组影响 | L1 append-only sequence/root 成为唯一排序真相 |

## 2. AdaptiveRotationV1

当前 5-active 语义：

1. 每个 membership slot 替换一个 active；
2. 5 次完成全 active roster 换血；
3. standby 先通过 readiness 与 operator-domain 复核，再原子提升；
4. 退出成员至少冷却一个完整轮换周期；
5. 轮换必须更换设备 / 签名 key 并安全擦除旧 key；
6. threshold key 的 DKG / proactive resharing 不能替代主机恢复。

```text
q(T) = 1 - exp(-λT)
P[X ≥ 2 within T_full_rotation] ≤ ε_adapt
```

`λ` 必须来自红队实测、凭证泄漏统计和共同故障上界。

## 3. OperatorDomainRegistryV1

| 层 | 承诺或证据 | 用途 |
| --- | --- | --- |
| 身份域 | stake key、operator credential、受益控制人承诺 | 别名合并、同组去重 |
| 基础设施域 | cloud tenant、TPM/TEE EK、ASN、region、机房和电源域 | 分组约束与集中度熔断 |
| 角色域 | Archive/Validator 的 `canonicalOperatorId` | 托管 archive 与 tip validator 委员会互斥 |

挑战成立后应合并别名、聚合全角色 stake 与风险暴露、停止新任务并滚动换出冲突席位。风险模型必须使用：

```text
P(A ∩ V) = P(A) × P(V | A)
```

未证明独立时使用：

```text
P(A ∩ V) ≤ min(P(A), P(V))
```

并加入 operator、cloud、ASN、region 与机房共同故障压力测试。

## 4. DA 正确编码

`dle.rs.v1` 至少冻结正文 canonical encoding、`payloadLength`、4 个 data chunks、零填充、字节序、GF 域、systematic generator matrix、chunk index、Merkle domain 与跨语言 golden vectors。

每个 active archive 在 precommit 前：

1. 取得完整正文并确认 `bodyCommitment`；
2. 确定性执行 RS(7,4) 重编码；
3. 逐个复算 7 个 chunk hash 与 `daRoot`；
4. 仅全部一致才签票，否则发布 `BadEncodingEvidence`。

`BadEncodingProof` 可携带任意 4 份已承诺 chunk 与 opening，重建正文并证明某个 committed chunk 与完整码字不匹配；成立则冻结高度、罚没签署者并 re-home。

## 5. L1QueueAccumulatorV1

```text
enqueue:
  L1 QueueRegistry assigns nextSeq and updates accumulator root

freeze:
  permissionless relayer freezes [fromSeq, toSeq] against L1 roots

place:
  UniformPlacementV1 derives assignment from L1 roots
  target group confirms takeover/genesis with 4/5 certificate
```

Archive queue checkpoint 只能作为 cache / availability telemetry，不能决定 canonical queue。

## 6. 参数替代关系

| 历史 Canvas | 当前白皮书 |
| --- | --- |
| 7 active + 2 standby | 5 active + 2 standby |
| 5/7 archive quorum | 4/5 archive quorum |
| 7 次完成全组 churn | 5 次完成全组 churn |
| `P[X≥3]` assumption breach | `P[X≥2]` assumption breach |
| 5/7 PlacementCertificate | 4/5 PlacementCertificate |

周期轮换、operator-domain、DA 正确编码和 L1 队列的架构判断仍有效。

## 7. 实现切分

1. `OperatorDomainRegistry` 合约与挑战状态机；
2. membership/key epoch 激活与单槽轮换；
3. SSZ/RS golden vectors；
4. archive signer precommit full re-encode；
5. BadEncodingEvidence 验证器；
6. L1 queue accumulator、pending mapping 与清理策略；
7. operator/cloud-domain 相关风险模拟；
8. 轮换、standby promotion 与 re-home 演练。
