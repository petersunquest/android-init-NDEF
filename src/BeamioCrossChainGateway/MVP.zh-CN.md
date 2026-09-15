# Beamio AAC 跨链网关 MVP 计划

**目标：** 在不触碰现网资产和现有 Treasury 生产权限的前提下，证明一条
可审计的“锁定 → 证明 → 预留 → 铸造/释放”最小闭环。

**MVP 不等于主网可用。** MVP 完成只能说明测试环境中的状态机和接口满足
验收条件，不能说明 Base 主网最终性验证、经济模型或安全审计已经完成。

## 1. MVP 范围

### 1.1 只支持一条来源链和一个测试资产

- 来源链：Base Sepolia 或本地 fork；
- 目标链：CoNET 本地 Hardhat 网络或隔离测试网络；
- 资产：Mock ERC20；
- 目标资产：Mock ERC20 或受限 mintable representation；
- 不接入生产 USDC、GB、B-Unit、TreasuryBridgeV3 或既有用户卡资金。

如果测试环境无法提供可靠的 Base 状态证明，MVP 必须明确使用
`MockStateProofVerifier`，并将其标为测试替身，不得包装成生产轻客户端。

### 1.2 MVP 组件

建议新增以下组件，名称可在实现阶段调整：

1. `AACRegistry`：记录 AAC、状态、sourceDepositId 和版本；
2. `IStateProofVerifier`：证明验证器接口；
3. `MockStateProofVerifier`：本地/测试网替身；
4. `AssetAdapterRegistry`：登记 source gateway、asset、decimals 和 target；
5. `AACMintGateway`：执行 verify/reserve/mint/release；
6. `CnetFeeBurnSink`：记录并销毁 MVP 费用；
7. TypeScript SDK/CLI：生成 request、提交 proof、查询状态；
8. Foundry/Hardhat 测试：状态机、重放、错误证明和并发场景。

## 2. MVP 状态机

```text
NONE
  └─ submitProof + verify ──> VERIFIED
                               └─ reserve ──> RESERVED
                                               ├─ mint ──> MINTED
                                               └─ release -> RELEASED
```

要求：

- 每个 `sourceDepositId` 在一个 `(sourceChain, sourceGateway, targetDomain)`
  域内只能被消费一次；
- `reserve` 和 `mint` 必须检查 AAC 字段的完整哈希；
- `mint` 只能接受 `RESERVED`；
- `release` 只能接受 `RESERVED`，具体资产语义由 adapter 定义；
- 所有终态不可逆；
- pause 只能阻止新请求，不得伪造或删除已有 AAC。

## 3. 请求数据结构

MVP 请求至少包含：

```text
requestId
sourceChainId
sourceGateway
sourceDepositId
sourceBlockHash
assetAddress
assetKind
amount
recipient
targetDomain
proof
proofVersion
deadline
nonce
```

`requestId` 不可只由客户端生成后直接信任。合约应重新计算 canonical
digest，并在事件中同时记录 `requestId` 与 AAC hash。

## 4. 分阶段交付

### MVP-0：规格冻结与威胁模型

**工作内容：**

- 冻结 AAC 字段、状态转移、域分离和错误码；
- 冻结 `isReserved` 的语义；
- 定义测试资产与测试网；
- 列出与 `TreasuryBridgeV3`、`ConetTreasuryPeer` 的隔离边界；
- 写出 proof verifier 的安全假设和替换接口。

**完成条件：**

- 白名单资产、目标域、版本和费用规则全部有文档；
- 每个状态转移均有正向和反向拒绝用例；
- 无任何生产地址被写入测试配置。

### MVP-1：本地确定性状态机

**工作内容：**

- 实现 `AACRegistry`、`AACMintGateway` 和 mock adapter；
- 用 mock proof 验证完整状态机；
- 实现 CNET fee burn sink 的测试版本；
- 编写事件和查询接口。

**完成条件：**

- 正常流程可完成 `lock → verified → reserved → minted`；
- 重复 proof、重复 sourceDepositId、错误 amount、错误 recipient、错误
  domain、过期 request 全部 revert；
- 状态机通过 property-based tests；
- 测试覆盖 pause、重入、nonce、deadline 和权限边界。

### MVP-2：测试网 lock 与证明适配器

**工作内容：**

- 在 Base Sepolia 部署测试锁定 gateway；
- 生成真实 receipt/log proof 或明确的测试 fixture；
- 实现第一版 `StateProofVerifier`；
- 将证明验证和 AAC digest 对齐；
- 记录 proof gas、失败率和端到端延迟。

**完成条件：**

- 测试网真实锁定事件可以被目标侧验证；
- 任何篡改 block hash、receipt、log index、amount 或 recipient 的 proof
  都无法 reserve；
- 同一 deposit 在并发提交下最多成功一次；
- 能导出可复现的 proof fixture 和 deployment manifest。

### MVP-3：M2M / x402 Facilitator 集成

**工作内容：**

- Facilitator 只负责 quote、提交和重试；
- 费用 burn 由 `CnetFeeBurnSink` 链上确认；
- 证明校验失败时不得产生成功 mint；
- 使用 EIP-712 或等价 request authorization；
- 增加开发者 CLI 和最小 SDK。

**完成条件：**

- HTTP 200 不会被当成 mint 成功，只有目标链 receipt 确认才算成功；
- `CNETFeeBurned` 可按 requestId 对账；
- Facilitator 无法通过修改请求内容绕过 gateway；
- 重试不会重复 mint 或重复消费 deposit。

### MVP-4：安全评审与主网候选门槛

**工作内容：**

- 独立审查状态机、proof parser、finality adapter、asset mapping 和费用；
- 运行 fuzz、invariant、fork 和故障注入测试；
- 评估 proof gas 和 DoS 风险；
- 编写暂停、升级、资产适配器撤销和事故响应流程；
- 生成 Standard JSON、部署快照和验证材料。

**完成条件：**

- 没有未关闭的 Critical/High 问题；
- 证明验证器的最终性假设得到明确签字；
- 资产适配器、费用 burn 和 pause 权限最小化；
- 只有通过明确的主网 go/no-go 评审后，才允许讨论真实资产。

## 5. MVP 测试矩阵

### 正常路径

- 单笔锁定、单笔证明、单笔 reserve、单笔 mint；
- 允许 permissionless proof submit，但只允许登记 adapter 触发资产动作；
- 费用支付成功、证明成功、目标 receipt 确认。

### 必须拒绝

- 错误来源链或 gateway；
- 未达到最终性阈值；
- 错误 Merkle path / state root；
- 证明字段与 AAC 字段不一致；
- 重复 `sourceDepositId`；
- 相同 request nonce 重放；
- 过期 deadline；
- 未登记资产或目标域；
- 资产 decimals 不匹配；
- fee burn 事件与 requestId 不匹配；
- paused gateway 上的新 reserve/mint。

### 并发与故障

- 同一 proof 的 100 个并发提交；
- Facilitator 在 receipt 前断线并重试；
- 来源链 proof 服务返回空、畸形或延迟响应；
- 目标链交易被替换或 revert；
- verifier 升级前后版本号不一致；
- adapter 被暂停时已有 `RESERVED` AAC 的处理。

## 6. MVP 安全边界

MVP 必须具备：

- `ReentrancyGuard` 或等价的状态更新顺序；
- request/domain/chainId/version 域分离；
- 资产 adapter 白名单；
- 每资产和每域的额度上限；
- 新请求 pause；
- 受控升级和 storage layout 检查；
- 完整事件：lock、proof verified、reserved、minted、released、fee burned、
  paused、adapter updated；
- 不在日志中记录私钥、完整敏感证明材料或未加密用户秘密。

MVP 不允许：

- 直接把任意 ERC20/原生币设为生产资产；
- 通过 owner 特权绕过 proof 伪造 mint；
- 把 LayerZero delivery 当作 proof；
- 用 miner vote 结果伪装成 Merkle/ZK proof；
- 把 `MockStateProofVerifier` 部署到主网；
- 默认开放任意开发者的 adapter 或 mint role。

## 7. 指标

至少记录以下指标：

- proof verification gas；
- reserve/mint gas；
- 从来源确认到目标 receipt 的 P50/P95 延迟；
- proof reject 分类；
- duplicate/replay reject 数量；
- fee burn 与成功 mint 的对账率；
- adapter pause 和恢复时间；
- 并发提交下的唯一成功率。

## 8. MVP 交付物

```text
src/BeamioCrossChainGateway/
├── README.md
├── WHITEPAPER.zh-CN.md
├── MVP.zh-CN.md
├── contracts/        # MVP-1 开始创建
├── interfaces/       # proof/adapter 接口
├── test/             # 状态机与属性测试
├── scripts/          # 部署、fixture、proof CLI
└── deployments/      # 仅测试网/本地快照
```

当前提交只建立规格文档；`contracts/`、`test/` 和测试网部署应在 MVP-0
评审通过后再创建，避免把未冻结的经济与最终性假设固化进合约。

## 9. Go/No-Go 决策

### Go

- 测试网证明可复现；
- 目标状态机的 invariant 全部通过；
- 重放、并发、错误 proof 和 pause 测试通过；
- 费用 burn 可链上审计；
- finality 假设已写入 verifier 版本；
- 安全评审没有 Critical/High 未解决问题。

### No-Go

- 只能证明事件，不能证明最终性；
- 需要人工在链下“确认后再 mint”；
- owner/admin 能无 proof mint；
- 失败时可能重复铸造或重复释放；
- Facilitator 的 HTTP 响应被当成链上成功；
- 真实 USDC/GB/B-Unit 尚未完成资产适配器和审计；
- 需要重启或修改现有 CoNET/生产节点才能运行。
