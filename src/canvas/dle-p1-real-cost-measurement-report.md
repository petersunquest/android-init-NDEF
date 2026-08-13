# CoNET-DLE P1 真实成本实测报告

> **单语开发参考，无对等译本。** 原交互 Canvas：`dle-p1-real-cost-measurement-report.canvas.tsx`。本报告区分真实实测、现役非 DLE 组件代理数据、确定性容量公式与不可测项；不得把代理数据写成生产 DLE 经济事实。

**证据窗口：** 2026-08-13
**链：** CoNET 224422
**状态：** P1 尚未经济闭环；10 USDC 下限与两项 1.2× coverage 仍是设计参数。

## 1. 核心结论

当前仓库存在 DLE 规范、形式化模型和测试向量，但没有 canonical DLE queue、Genesis AC、AssetBurnMintGateway、force-exit、roster transition 合约部署，也没有 5 active + 2 standby 的 DLE Archive runtime。

因此：

| 经济主张 | 当前状态 | 缺失证据 |
| --- | --- | --- |
| 10 USDC 最低流入 | 临时设计参数 | 完整流入 p95/p99 USDC 成本、允许固定开销 bps、Archive 边际成本 |
| 1.2× execution coverage | 不可计算 | 执行准备金实际流入与完整 DLE 执行负债分布 |
| 1.2× availability coverage | 不可计算 | 30 天 5+2 独立故障域计量与可归属账单 |

## 2. 测量状态矩阵

| 目标 | 状态 | 现有证据 / 缺口 |
| --- | --- | --- |
| L1 enqueue / freeze / reserve | **不可测** | 无合约、部署或 receipt |
| Genesis AC submit | **不可测** | 仅规范与向量；签名验证 / storage gas 未知 |
| Burn ingress | **代理数据** | 4 笔 TreasuryBridgeV3 `initiateBurnMintForUser`，不含 DLE receipt 状态机 |
| Activation | **不可测** | 无 gateway activation 路径 |
| Refund | **不可测** | 无 failed-genesis refund 路径 |
| Exit mint | **代理数据** | 3 笔 `mintForAdmin`，不含 DLE exit-right 验证 |
| 1 KiB / 64 KiB / 1 MiB DA | **字节公式 + 临时参考 benchmark** | 无生产编码器、第二语言实现、冻结 WAL 或 Archive runtime |
| Archive 月度成本 | **资源代理数据** | `.50` L1 双 archive；不是 DLE 5+2，且无账单 |
| Standby readiness | **不可测** | 无 DLE standby、sync lag、readiness proof、takeover 记录 |
| Forced-exit challenge | **不可测** | 无 request/challenge/finalize 合约 |
| Oracle p95/p99 | **现役 Oracle 代理数据** | 非 DLE TWAP / breaker adapter |
| Rotation / re-home | **不可测** | 无 roster transition / dual-quorum 运行路径 |

## 3. Treasury V3 gas 代理数据

采样 gas price：`1,000,007 wei/gas`。由于没有带置信度和时间戳的 CNET/USDC 转换，本报告不虚构 USDC 成本。

| 路径 | 样本 | gasUsed | 当前 gas price 下成本 | DLE 使用边界 |
| --- | ---: | --- | --- | --- |
| 完整三票 Treasury operation | 11 | p50 444,989；p95 479,340；max 486,095 | p95 `4.7934e-7 CNET` | quorum execution 代理；不含 DLE AC/receipt/credit |
| `initiateBurnMintForUser` | 4 | 107,654–120,314 | max `1.2031e-7 CNET` | burn 代理 |
| `mintForAdmin` | 3 | 58,922–76,044 | max `7.6045e-8 CNET` | exit mint 代理 |
| BeamioOracle `updateRatesBatch` | 50 | min 82,699；p50/p95/p99 89,081 | p95 `8.9082e-8 CNET` | Oracle 写入代理 |

## 4. DA 字节与参考 benchmark

冻结编码为系统型 RS `(n,k)=(7,4)`，纯 codeword 膨胀固定为 `1.75×`：

| Canonical body | Coded bytes | 临时 JS 参考 harness p50 / p95 | 一个 coded set、1 msg/s、30 天 |
| --- | ---: | ---: | ---: |
| 1 KiB | 1,792 B | 0.345 / 0.656 ms | 4.326 GiB |
| 64 KiB | 114,688 B | 6.437 / 14.753 ms | 276.855 GiB |
| 1 MiB | 1,835,008 B | 99.018 / 250.696 ms | 4,429.688 GiB |

CPU 数字来自 Apple M1 / 16 GB 上的临时参考实现，不是生产编码器 benchmark。尺寸不含 SSZ、签名、QC、TLS、PGP、WAL、索引、snapshot、repair 或每成员本地可重建副本。生产前还须冻结 retention policy，否则不能从 `1.75×` 推导集群存储 / 网络费用。

## 5. 现役 L1 双 archive 资源基线

采样对象是 `38.102.126.50` 上两个同机 CoNET L1 geth archive RPC，不是 DLE Archive signer。

| 资源 | 实测 / 月度外推 | 边界 |
| --- | --- | --- |
| 磁盘 | 46.86 GB / 43.64 GiB | 实测字节；无 $/GB-month 账单 |
| RSS | 27.03 GiB | 单点快照 |
| CPU | ≈1.016 cores；731.5 core-hours / 30d | 生命周期近似；无电力 / host 分摊 |
| Memory time | 19,465 GiB-hours / 30d | 容量基线 |
| 在线 | 1,440 node-hours；720 physical host-hours | 同机不构成独立故障域 |
| Geth P2P | 3.38 GB ingress；4.01 GB egress / 30d | L1 P2P，不可归因 DLE |
| 整机 NIC | 3.43 TB RX；5.65 TB TX / 30d | 含 public RPC、SSH、sync 与其它服务 |

美元换算仍需服务器月租、存储、带宽、IP、DDoS、电力与运维账单。不能把同机双 archive 简单乘以 7 作为 DLE 5+2 成本。

现有 CoNET-SI `BandwidthCount` / 遗留 socket 路径混用 string length、byte length 与 Gbyte 单位，且遗留计算存在错误数量级，不能作为 DLE 经济计量。

## 6. Oracle 代理实测

每 endpoint / method 顺序调用 100 次：

| Endpoint / method | p95 | p99 | Gas 语义 |
| --- | ---: | ---: | --- |
| rpc1 · `getRate(USDC)` | 78.09 ms | 81.06 ms | 24,136 estimated gas；`eth_call` 不付费 |
| publicrpc · `getRate(USDC)` | 81.44 ms | 102.01 ms | 同上 |
| rpc1 · QuoteHelper | 82.88 ms | 238.43 ms | 31,091 estimated gas；`eth_call` 不付费 |
| publicrpc · QuoteHelper | 138.30 ms | 222.61 ms | 同上 |

短窗尾延迟包含网络与 RPC 排队，不能证明 DLE oracle 更新、TWAP、stale rejection、breaker 或 24 小时 p99。

## 7. 最小闭环实测

1. **E0 可复现 harness：** 在隔离 devnet 部署 queue/freeze/reserve、Genesis AC、gateway、force-exit、roster transition 与 DLE oracle adapter。
2. **E1 合约 gas 矩阵：** 冷 / 热 storage、成功 / revert、4/5 签名、重放、暂停、cap、stale AC、breaker、同块竞态；每实质分支至少 1,000 成功 + 1,000 失败样本。
3. **E2 5+2 计量 pilot：** 七个独立故障域运行至少 30 天；至少 100 轮 rotation、30 次 re-home、100 次 standby takeover；账单与节点计数误差不超过 5%。
4. **E3 Oracle：** 每 endpoint/method 至少 10,000 样本、覆盖 24 小时、正常 / 3× gas shock / RPC 故障 / stale / breaker。
5. **E4 Cost epoch：** 发布 code hash、tx receipt、原始 node metrics、账单、CNET/USDC quote policy、p50/p95/p99、置信区间和失败率。

## 8. 覆盖门

```text
ingressFloor >= p99FixedIngressLiability / allowedFixedOverheadRate

epochExecutionReserve / epochP95ExecutionLiability >= 1.20

epochAvailabilityFunding / epochP95AvailabilityCost >= 1.20

emergencyReserve >= concurrentP99(forceExit + refund + reHome)
```

在上述量均可独立复算之前，白皮书必须把 10 USDC 与 1.2× 标为 provisional calibration inputs，而非经济事实。
