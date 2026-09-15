# Beamio AAC 跨链资产确权与 M2M 流动性网关白皮书

**版本：** 0.1.0-draft  
**日期：** 2026-09-14  
**状态：** 设计草案，未代表主网部署或安全审计完成

## 摘要

Beamio Cross-Chain Gateway（BCG）提出一种以 **Atomic Asset Container（AAC，
原子资产容器）** 为核心的跨链资产映射与确权协议。协议将跨链操作拆成四个
可验证阶段：

```text
来源链锁定 → 来源链状态证明 → 目标链预留 → 目标链铸造/释放
```

目标不是把“观察到事件”包装成“已经确权”，而是让目标链合约只接受满足
预定义密码学约束的证明。`isReserved` 表示目标侧资产已经为某个确定的
`assetId`、`amount`、`recipient` 和 `sourceDepositId` 保留，防止重复铸造、
重复释放和并发领取。

BCG 面向机器到机器（M2M）付款、跨链清算、AA 资金池和 x402 类资源请求。协议
可接入 LayerZero 等消息传输网络，但消息传输不等于状态确权；最终安全边界
仍由来源链最终性验证、状态证明验证器和目标链确定性状态机共同构成。

## 1. 背景与问题

现有跨链系统通常包含 relayer、观察者、多签或矿工投票。它们可以快速上线，
但会产生三个边界问题：

1. “来源链已锁定”与“目标链可用”之间存在时间差；
2. 观察结果、签名共识和链上事实容易被产品文案混为一谈；
3. 在流动性池和自动化 M2M 场景中，人工投票延迟会成为结算瓶颈。

BCG 不把观察者投票直接称作密码学证明，也不假定单个 Merkle path 可以解决
最终性。它把跨链安全问题明确拆成：

- **事实证明：** 交易/receipt、日志或状态叶确实属于某个区块状态；
- **区块证明：** 该区块头来自正确的来源链；
- **最终性证明：** 该区块不会被来源链规则回滚；
- **业务约束：** 资产、金额、接收人、域、nonce 和费用均匹配；
- **目标状态机：** 每个 deposit 只能成功消费一次。

## 2. 术语

### 2.1 AAC

AAC 是一条跨链资产凭证的确定性状态记录，至少绑定：

```text
sourceChainId
sourceGateway
sourceBlockHash / stateRoot commitment
sourceDepositId
assetKind
assetAddress
amount
recipient
targetDomain
expiry
```

AAC 不是新的可自由复制代币。它是“来源资产事实”和“目标侧权利”之间的
唯一映射对象。

### 2.2 `isReserved`

`isReserved(aacId)` 为目标网关状态机中的**预留状态**。只有来源证明已经通过、
业务条件已经满足、且该 AAC 尚未消费时，目标链才可以将其置为 reserved。

建议状态：

```text
NONE → VERIFIED → RESERVED → MINTED
                         ↘ RELEASED
NONE → REJECTED
```

状态必须单调推进；`MINTED`、`RELEASED`、`REJECTED` 不可回到 `NONE`。
`RESERVED` 不是最终到账：它是并发控制和软锁定状态，表示该权利已被目标侧
某个唯一执行路径占用。

### 2.3 M2M

M2M 指机器、AA、服务代理或自动化 Facilitator 之间以确定性接口完成付款和
结算，无需人工点击或人工投票。M2M 不降低证明要求；它只要求证明和状态机
可被程序稳定执行。

## 3. 信任模型

### 3.1 安全目标

在以下条件成立时，攻击者不能凭空铸造目标资产、重复消费一次来源存款或把
一笔存款映射给两个接收人：

1. 来源链最终性验证器正确；
2. 证明验证器正确实现来源链共识/状态规则；
3. 来源 gateway 的锁定逻辑不可绕过；
4. 目标 gateway 的 AAC 状态机不可重入、不可重复消费；
5. 资产适配器的 decimals、assetId 和转账语义正确。

### 3.2 明确不保证的内容

- 仅有事件日志，不代表来源链交易已经最终确定；
- 仅有 Merkle inclusion proof，不代表区块头真实或不可回滚；
- LayerZero、relayer 或任何消息网络的“已送达”，不等于资产已确权；
- 目标链铸造权限开放给开发者，不等于开发者可以跳过来源证明；
- x402 Facilitator 的 HTTP 成功，不等于链上 mint 成功。

## 4. 协议流程

### 4.1 来源链锁定

用户或 AA 将受支持资产转入来源 gateway。gateway 必须在同一笔交易中：

1. 校验资产地址、金额、接收人和目标域；
2. 生成唯一 `sourceDepositId`；
3. 将资产锁定或销毁；
4. 发出 `AssetLocked` 事件；
5. 将可证明的 deposit 记录纳入来源链状态承诺。

事件是索引入口，不是唯一安全依据。证明适配器必须能从来源链状态中重新
验证关键字段。

### 4.2 来源链证明

证明提交者提供：

```text
sourceBlockHeader
finalityEvidence
receiptOrStateProof
gatewayStorageProof（如需要）
depositFields
```

目标链验证器检查：

- `chainId`、gateway 地址和版本；
- 区块头父哈希、状态根或来源链规定的等价承诺；
- receipt/log 或 storage leaf 的 Merkle path；
- 证明中的 deposit 字段与预期 AAC 完全一致；
- 最终性阈值、checkpoint 或 validity proof；
- 证明未被同一 `sourceDepositId` 使用过。

### 4.3 目标链预留

验证成功后，网关原子地写入 AAC 记录并置 `isReserved = true`。预留键不能只
由交易哈希组成，至少应包含：

```text
keccak256(sourceChainId, sourceGateway, sourceDepositId, targetDomain)
```

业务状态机必须拒绝：

- 相同预留键的第二次 reserve；
- 金额、资产、接收人或目标域不一致的证明；
- 已过期 AAC；
- 目标资产余额或铸造上限不足；
- 非授权资产适配器。

### 4.4 铸造、释放与取消

- **Mint：** 仅能消费 `RESERVED` AAC 一次，并写入 `MINTED`；
- **Release：** 对 BurnMint 或可回收资产，按协议将权利标为 `RELEASED`；
- **Cancel：** 只能由明确的超时/证明失效机制触发，不能由任意开发者撤销；
- **Emergency pause：** 只能暂停新 reserve/mint，不能任意改变已确认账本。

目标侧铸造量必须来自已验证 AAC，不接受客户端自报金额。

## 5. 证明验证器路线

### 5.1 Base L2 适配器

Base 属于 OP Stack L2。Base 区块中的 receipt proof 仍需结合 OP Stack 的
最终性语义处理。BCG 不能只验证 Base L2 的 Merkle path，然后宣称“不可回滚”。

MVP 采用以下分层：

1. **开发网/本地：** 可使用 mock finality provider 验证状态机；
2. **测试网：** 使用明确的 checkpoint/finality adapter，并记录挑战窗口；
3. **主网候选：** 使用经审计的 Base 状态证明与最终性验证方案；
4. **生产：** 证明适配器版本、最终性策略和暂停策略写入部署快照。

### 5.2 Merkle 与 ZK

- Merkle proof 适合 MVP：实现简单、链上 gas 可估算，但需要可信区块头/
  最终性层；
- ZK proof 可以压缩复杂的状态验证，但不自动解决电路输入、证明生成、
  最终性和升级治理问题；
- BCG 的接口应抽象为 `IStateProofVerifier`，以便在不改变 AAC 状态机的
  情况下替换证明后端。

## 6. 费用与 CNET 销毁

BCG 规划让每次证明验证、reserve 或 mint 请求产生可计量的协议费用，并由
x402 Facilitator 协调请求。费用路径必须与业务资产路径分离：

```text
请求 → 费用预检 → CNET fee transfer/burn → 证明验证 → 状态写入
```

“100% 永久销毁”只有在链上存在可验证的 burn sink、金额计算和失败语义时
才成立。MVP 不把 HTTP Facilitator 的扣费结果当作销毁事实，必须让链上
`CNETFeeBurned(requestId, amount)` 成为唯一可审计结果。

若费用销毁成功而证明验证失败，协议必须预先定义：

- 费用是否不可退；
- 是否允许重试使用同一 request；
- 是否采用 quote lock；
- 如何防止 Facilitator 重放。

推荐 MVP 采用“费用不可退、证明 request 可重试但 nonce 不可重放”的清晰
语义，并在产品上线前由经济模型评审确认。

## 7. 开放给 Web3 开发者的权限模型

不建议第一阶段直接开放任意开发者的 `mint` 权限。推荐四层权限：

1. **Permissionless prove：** 任何人都可提交证明，证明正确即可进入验证；
2. **Permissioned asset adapter：** 只有已登记的资产适配器可以铸造；
3. **Rate/limit policy：** 每资产、每域、每周期有额度和延迟保护；
4. **Emergency governance：** 可暂停适配器或新请求，但不可凭投票伪造
   已锁定资产。

开发者开放的应是“提交证明和构造 M2M 请求”的能力，而不是绕过证明的
任意铸币能力。后续可通过 audited adapter registry、EIP-712 request、
`requestId` nonce 和可撤销 allowance 扩展生态。

## 8. 与 Beamio 现有系统的关系

当前仓库已有的 `TreasuryBridgeV3`、`ConetTreasuryPeer`、`GBTokenV2` 和
`AssetBurnMintGateway` 包含资产模式、paid pool、reservation/exit accounting
或矿工/治理路径。BCG 不应在未完成迁移设计前替换这些现网路径。

建议边界：

- AAC / proof verifier / gateway 是新的跨链实验面；
- 现有 Treasury 继续作为受控资产托管与结算入口；
- BCG 首期只接一种测试资产和一种目标资产；
- 现有矿工投票可作为 fallback 或 emergency route，但不能被文档表述成
  “密码学证明已取代”；
- 生产升级必须遵守代理地址稳定、整组模块升级和当场验证规则。

## 9. LayerZero 兼容性

LayerZero 可作为：

- proof request/response 的消息传输；
- 跨链 executor 调度；
- 非安全关键的通知和状态同步。

LayerZero 不应单独承担：

- 来源链区块头真实性；
- Base 最终性；
- AAC 的唯一消费状态；
- 目标链铸造安全边界。

因此 BCG 是“证明驱动的跨链状态机”，LayerZero 是可选的“消息传输层”。
两者可以组合，但不是同一个协议。

## 10. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 只证明事件、不证明最终性 | 引入 `IStateProofVerifier` 和 finality evidence |
| 证明重放 | `sourceDepositId`、domain、nonce、单调状态机 |
| 目标链重组 | 最终性阈值、延迟 reserve、可暂停适配器 |
| decimals/资产映射错误 | AssetAdapter registry、固定 decimals、端到端 invariant |
| Facilitator 欺诈 | Facilitator 不具备无证明 mint 权；费用结果上链 |
| 开发者权限扩大 | permissionless prove + permissioned adapter |
| 证明验证 gas 过高 | 批量 proof、ZK 后端、费用 quote 和上限 |
| 升级破坏历史 AAC | UUPS/稳定代理、storage layout review、版本化 verifier |

## 11. 结论

AAC 可以成为 M2M 跨链结算的确定性原语，但前提是把“事件观察”“包含性证明”
和“最终性证明”严格区分。MVP 应先验证一个可暂停、受限资产、可重复测试的
完整状态机；在证明适配器、最终性和经济费用经过测试与审计前，不应开放
无条件的开发者铸造权限，也不应宣称已经消除了所有人工共识。
