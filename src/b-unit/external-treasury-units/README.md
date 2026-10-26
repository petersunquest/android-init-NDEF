# 外部储备单元国库（External Treasury Units）

依据《CoNET 隐私与资产碎片化白皮书》第三章（外部入库单元）落实的国库合约。

**状态**：合约与本地测试已完成；**未部署、未审计、未提交**。白皮书 §17 要求审计前不部署。

## 文件

- `ExternalTreasuryUnits.sol`：国库。入库、兑付、退款、单元状态、损失、分桶会计。
- `DepositUnitFactory.sol`：为每笔入库用 CREATE2 + ERC-1167 派生单元，只接受国库调用。
- `DepositUnit.sol`：单元。只绑定一次，只接受国库的 `pay`。
- `IDepositUnit.sol`、`IUnitStateVerifier.sol`：接口。
- `mocks/DepositUnitMockUSDC.sol`：测试用代币，含黑名单与全局暂停。
- `mocks/UnitStateMockVerifier.sol`：测试用状态证明与损失证明。
- 复用 `../external-treasury-immutable/IConetProofVerifier.sol` 及其 mock。

## 单元状态（白皮书 §3.6）

| 状态 | 进入条件 | 能否付款 | 记账 |
|---|---|---|---|
| Registered | 入库时 | 否 | registered |
| Active | 状态证明：未受限，且余额不少于登记本金 | 是 | active（A） |
| Restricted | 状态证明：外部受限 | 否 | restricted（F） |
| ReconciliationPending | 状态证明：余额少于登记本金 | 否 | unverified（未核实） |
| Spent | 本金按支付耗尽 | 否 | 不计入 |
| LossConfirmed | 损失证明写销全部本金 | 否 | confirmedLoss（累计） |

## 关键约束

- **入库**：先派生单元，再把代币直接转入单元，国库本身不持币。只接受到账额与申报额完全一致的代币（§3.3）。受益权益承诺绑定进 `depositId`。
- **兑付**：只从 Active 单元按先进先出选取，调用方不能指定单元，单笔最多 16 个单元。任一单元转账失败则整笔回滚，证明不被消耗，单元状态不变（§3.9 C3、C4、C5）。
- **证明**：状态证明的区块必须晚于入库区块，并严格递增。超过 `MAX_PROOF_AGE` 区块未更新的单元不能付款，付款以 `StaleUnitState` 回滚，刷新证明后恢复。过期单元位于队列最前时会阻塞该代币的全部兑付，这是有意设计：跳过过期单元会使 A 高估可动用储备。
- **会计**：`buckets(token)` 给出各桶；`principalOf(token)` 即 D。链上不保存 R、U、P、W，见下文。
- **权限**：无所有者、无暂停、无升级、无管理员函数。

## 测试

```bash
npx hardhat --no-typechain test test/external-treasury-units.test.ts
```

26 项，覆盖白皮书 §9.2 中可在合约层验证的场景。与 `external-treasury-immutable`（13 项）、`gb-immutable`（28 项）一并运行，共 67 项全部通过。

## 未完成与待定

1. **证明适配器**：Base 单元状态（存储证明、终局性、USDC 实现升级的版本绑定）与损失证明的真实实现，目前只有 mock。
2. **真实 USDC 语义**：黑名单与暂停的行为须对目标链上合约逐项核实，mock 只是模型。
3. **参数**：`MAX_PROOF_AGE`（部署参数）、单笔 16 个单元、扫描上限 256，白皮书 Q11 待定。
4. **损失分摊**：C9（风险储备先承担且设上限，超出部分进入覆盖率）在合约外，合约只记录 `confirmedLoss`。
5. **退款语义**：退款与兑付共用同一先进先出池，退款所得可能来自其他入库的单元。退款证明须由 CoNET 侧确认“从未铸造”。
6. **链上未记的量**：R、U 需要与代币余额逐单元比对；P 为 CoNET 侧未履行权益；W 为 0，因为单笔兑付在一笔交易内原子完成，不存在待执行预留。
7. **受益权益承诺**：入库时已绑定，CoNET 侧如何使用由其他组件负责。
