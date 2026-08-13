# CoNET-DLE 经济费率压力模型

> **单语开发参考，无对等译本。** 原交互 Canvas：`dle-economic-fee-stress-model.canvas.tsx`。本文件保存模型思路与实现边界；实时参数计算仍以 Cursor Canvas 为准，协议规范以双语白皮书 §13 为准。

**快照日期：** 2026-08-13
**状态：** 当前白皮书的配套分析模型；示例参数尚未构成生产经济事实。

## 1. 目标

该模型回答四个可量化问题：

1. 协议价值费在给定流量和平均名义金额下能产生多少月收入？
2. 独立执行准备金是否覆盖 p95 边际执行成本？
3. 协议费、链租金、创建准备金释放和具名补贴能否覆盖归档、standby、验证人及历史保留预算？
4. 在 100 USDC 单 tip 安全封顶不变时，10 USDC 最低流入是否足以避免固定成本占比过高？

## 2. 三账本模型

### 协议价值费

```text
protocolFeePerEvent = notionalUsdc × protocolFeeBps / 10_000
monthlyProtocolRevenue = protocolFeePerEvent × eventsPerDay × 30
```

- 补偿共识安全租金，而不是承诺覆盖 L1 gas。
- 资产转账以 conet-USDC 支付；交易成交以 `quoteAsset` 支付；存储继续走 conet-GB。

### 执行准备金

```text
executionCoverage =
  monthlyExecutionReserveCollected / monthlyP95ExecutionCost
```

- 单独覆盖 L1 gas、oracle、proof、DA ingress、跨域 leg 与有界重试。
- 收费与实际成本分别输入，禁止把“收了多少”误当成“成本是多少”。
- 未使用的客观可计量 allowance 应退款。

### Epoch 可用性预算

```text
monthlyAvailabilityFunding =
  monthlyProtocolRevenue
  + monthlyChainRent
  + monthlyCreationReserveRelease
  + monthlyExplicitSubsidy

availabilityCoverage =
  monthlyAvailabilityFunding / monthlyFixedCapacityCost
```

- 覆盖归档存储、5+2 standby readiness、验证人可用性与历史保留。
- 补贴必须具名、封顶、可到期并单独报告。

## 3. 盈亏边界

```text
operatingProfitLossBeforeSubsidy =
  protocolRevenue
  + executionReserveCollected
  + chainRent
  + creationReserveRelease
  - executionCost
  - fixedCapacityCost

fundingBalanceAfterSubsidy =
  operatingProfitLossBeforeSubsidy
  + explicitSubsidy
```

**补贴后资金余额不是已赚利润。** 报表必须同时显示补贴前运营盈亏和补贴后偿付能力。

## 4. 最低流入推导

```text
p95FixedIngressCharge =
  p95ExecutionCostPerIngress
  + nonRefundableCreationChargePerIngress

costDerivedMinIngress =
  p95FixedIngressCharge × 10_000 / maxIngressOverheadBps

requiredMinIngress =
  max(10 USDC, costDerivedMinIngress)
```

判定：

- `configuredMinIngress >= requiredMinIngress` 且 `maxTip <= 100`：当前成本画像下可接受。
- `requiredMinIngress > 100`：不得抬高安全封顶；暂停新资产流入，等待成本下降或治理发布新 profile。
- 低于下限：只保留同 owner 的本地可撤销 intent，不 burn、不创建 NFT、不创建 pending receipt。

## 5. 可调参数

| 参数 | 含义 |
| --- | --- |
| Average operation notional | 平均事件名义金额 |
| Protocol fee rate | 协议价值费 bps |
| Minimum activated ingress | 激活流入下限 |
| Maximum asset tip | 单 tip 安全封顶 |
| Execution reserve charged | 每事件执行准备金 |
| P95 marginal execution cost | 每事件 p95 执行成本 |
| Non-refundable creation charge | 每次流入不可退创建费用 |
| Events per day | 每日事件流量 |
| Monthly fixed capacity cost | 月度归档 / standby / 验证人 / 历史成本 |
| Monthly chain rent | 月度链租金收入 |
| Monthly creation-reserve release | 当月可释放创建准备金 |
| Monthly explicit subsidy | 具名显式补贴 |
| Maximum ingress fixed overhead | 固定流入费用占 principal 的最大 bps |

## 6. 输出与部署门

Canvas 输出月度协议收入、执行与可用性覆盖率、补贴前盈亏、补贴后资金余额、break-even 名义金额、成本推导最低流入及流入决策。

建议部署门：

1. p95 执行覆盖率至少 1.2×；
2. 可用性预算覆盖率至少 1.2×；
3. 可承受 p99 与 3× gas shock；
4. 补贴按 epoch 封顶且不计为利润；
5. `minIngressUsdc6` 不低于 10 USDC 和成本推导值；
6. 成本推导下限超过 100 USDC 时暂停普通流入；
7. force exit 始终由独立 `emergencyReserveUsdc6` 保持可用。

## 7. 开发切分

1. **数据采集：** 记录真实 L1 gas、proof、oracle、DA、relayer、archive、standby、validator 与历史保留成本。
2. **Cost epoch：** 发布带 TTL 的 `FeeScaleProfileV1`，绑定费率、资源上限、p95/p99 和 floor/cap。
3. **链上校验：** FeeVault、AssetAdmissionRegistry 与 AssetBurnMintGateway 只接受 active cost epoch。
4. **运营面板：** 同时展示 earned revenue、补贴、执行负债和固定容量负债。
5. **回归测试：** 固定覆盖 0.01 / 1 / 10 / 100 USDC、低流量、gas shock、oracle stale、standby promotion 与 force exit。

真实证据与未闭合项见 [DLE P1 真实成本实测报告](./dle-p1-real-cost-measurement-report.md)。
