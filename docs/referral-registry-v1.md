# CoNET ReferralRegistryVaultV1 / BUnitAirdropV2 使用说明

部署网络：CoNET `chainId=224422`
部署记录：`deployments/conet-ReferralRegistryVaultV1-stack.json`

本次部署采用两个独立 ERC1967/UUPS 代理：

- `ReferralRegistryVaultV1`：Admin → L0 → L1/Merchant 关系、兑换码、额度、claimable CONET-USDC。
- `BUnitAirdropV2`：paidPool B-Unit 空投、B-Unit 扣款、CONET-USDC 铸造、claimable 资金隔离。

代理地址是业务 canonical 地址；implementation 地址只用于验证和升级，不应写入 UI/API 配置。

> 当前已部署版本已完成 UUPS 代理、B-Unit 原子扣款、paidPool 空投、Merchant
> claim/create 两阶段流程和 claimable 资金隔离。Treasury 已切换至
> `BUnitAirdropV2`；L1 redeem/offline-signature 注册、地址迁移仍需后续升级实现。
> x402sdk 的地址已在本地源码更新并通过 build，但尚未提交/推送到生产 API。

## 当前部署地址

以 `deployments/conet-ReferralRegistryVaultV1-stack.json` 为准。部署脚本会同时记录：

- proxy / implementation
- initialize 参数
- deploy block / transaction hash
- BUint、ConetTreasury、CONET-USDC、BusinessStartKet、UserCard Factory 依赖地址

## 初始化和权限

部署脚本已完成以下新权限：

1. `BUint.addAdmin(BUnitAirdropV2Proxy)`
2. `BusinessStartKet.addAdmin(ReferralRegistryVaultV1Proxy)`
3. 每个 settle/admin 钱包加入两个新 UUPS 的 `admins`
4. Referral Vault 的 `bunitAirdrop` 指向 BUnitAirdropV2

旧 `BUnitAirdrop` 不会自动清除权限。只有 API 已切换并完成回归测试后，才允许移除旧权限。

脚本默认不会修改 `ConetTreasury.bunitAirdrop`，必须显式使用：

```bash
CONET_V2_SWITCHOVER=1 \
npx hardhat run scripts/deployReferralRegistryVaultV1ToConet.ts --network conet
```

这一步必须和 x402sdk API 的地址切换同一发布窗口执行；否则 Treasury 可能已经把请求导向 V2，而 API 仍写旧合约。

## UI/API 只读接口

### B-Unit 余额

优先调用 BUnitAirdropV2：

```solidity
getBUnitBalance(address account) returns (uint256 total)
balanceOfAll(address account) returns (uint256 total, uint256 free, uint256 paid)
```

UI 必须区分 `free` 与 `paid`，不得把 paidPool 当作第三种余额。

### 关系和 claimable

```solidity
members(address) returns (
  uint8 role,
  address parentAdmin,
  address parentL0,
  uint256 rebateBps,
  uint256 ratioBps,
  bool active
)
claimableUsdc(address) returns (uint256)
claimNonces(address) returns (uint256)
l0ClaimPaused(address) returns (bool)
l1ClaimPaused(address l0, address l1) returns (bool)
```

角色枚举：

- `0=None`
- `1=L0`
- `2=L1`
- `3=Merchant`

所有金额按合约最小单位读取。B-Unit 展示必须使用两位小数；CONET-USDC 展示按 token decimals 格式化。

## 业务写入流程

### 1. Admin 创建 L0

```solidity
addL0(l0, parentAdmin, rebateBps)
setL0Quota(l0, starterKetRemaining, paidBunitRemaining)
```

`rebateBps` 使用 `0..10000`。L0 配额在发行 Merchant redeem code 时立即扣除，不是在 claim 时扣除。

### 2. L0 发行 Merchant onboarding code

客户端生成秘密 `secret`，只把 `keccak256(bytes(secret))` 写入链上：

```solidity
issueMerchantRedeemCode(
  redeemHash,
  paidBunitAmount,
  validAfter,
  validBefore
)
```

秘密本身不得发送 API、写日志或写链。

用户使用秘密：

```solidity
claimMerchantCode(secret)
```

该交易原子完成：

1. 兑换码置为已使用；
2. 给用户铸造 `BusinessStartKet #0`；
3. 通过 BUnitAirdropV2 进入 `paidPool`；
4. 保存 Merchant → L0 的待创建归属。

### 3. 创建 Merchant card

Claim 和创建卡是两个独立交易。API 先生成完整 card `initCode`，metadata 存储在现有 metadata/API 流程中，并把 metadata 内容 hash 作为审计字段传入：

```solidity
createMerchantCard(
  currency,
  priceInCurrencyE6,
  initCode,
  metadataHash
)
```

合约内原子执行：

1. 检查调用者持有 `BusinessStartKet #0`；
2. `adminBurn` 销毁凭证；
3. 通过 UserCard Factory 创建卡；
4. 检查返回地址是 UserCard、owner 是调用者、factoryGateway 正确；
5. 只在成功后登记 Merchant → L0。

如果任一步失败，BusinessStartKet burn 和登记都会回滚。

### 4. Admin 发行收费 B-Unit code

信用卡/现金购买场景使用独立兑换码：

```solidity
issuePaidBunitRedeemCode(redeemHash, amount, validAfter, validBefore)
claimPaidBunitRedeem(secret)
```

这条路径只调用 `BUint.mintPaid`，不会增加 freePool，也不会创建 Merchant 关系。

## B-Unit 扣款和奖励

所有需要收费的 Master 写路径最终调用：

```solidity
BUnitAirdropV2.consumeFromUser(user, amount, sourceHash, baseGas, kind)
```

合约内原子完成：

1. `BUint.consumeFuel`；
2. 读取实际 `paidBurned`；
3. 按 `100 B-Unit = 1 CONET-USDC` 计算；
4. 从 `ConetTreasury.mintForAdmin` 将 CONET-USDC 铸入 V2；
5. 回调 Referral Vault 计算 L0/L1 claimable；
6. 记录 `reservedClaimableUsdc`。

L0/L1 奖励不会直接转入钱包；只增加 `claimableConetUsdc`。剩余 CONET-USDC 保留在 BUnitAirdropV2，不属于 owner/admin，也不能通过 owner withdraw 提走。

## Claimable CONET-USDC

暂停只阻止兑换，不阻止累计：

```solidity
setL0ClaimPaused(l0, trueOrFalse)       // Admin
setL1ClaimPaused(l1, trueOrFalse)       // 对应 L0
```

用户 claim 时使用 EIP-191 离线签名，签名消息：

```text
ClaimConetUsdc(address account,uint256 amount,uint256 nonce,uint256 deadline)
```

API 需要先读取：

1. `claimableUsdc(account)`
2. `claimNonces(account)`
3. 关系和 pause 状态

然后让用户签名并调用：

```solidity
claimConetUsdc(amount, nonce, deadline, signature)
```

成功后 V2 扣减 claimable，再由 Referral Vault 调 `payoutClaimable` 转账。失败不会消耗余额或 nonce。

## Indexer / Transactions 注意事项

合约是链上资金和关系的真相来源，但现有 Transactions UI 仍需要后台只读索引投影来分页、按业务类型聚合和显示时间线。建议 Indexer 监听：

- `MerchantCodeIssued`
- `MerchantCodeClaimed`
- `MerchantCardCreated`
- `PaidBunitCodeIssued`
- `PaidBunitCodeClaimed`
- `PaidBUnitConsumed`
- `ClaimableAccrued`
- `ConetUsdcClaimed`

Indexer 不得把失败 RPC/空窗口当作空列表；链上成功事件才允许更新可信记录。UI 的 B-Unit 数值统一显示两位小数。

## 发布顺序和禁止事项

1. `npm run clean && npm run compile`
2. 导出两个 FULL Standard JSON
3. 用部署时 solc 0.8.35 对两个 implementation 做 `eth_getCode` bytecode 预检
4. 分别验证两个 implementation；ERC1967 proxy 另按代理验证流程验证
5. 更新 x402sdk 内部 ABI、proxy 地址和 API 写路径
6. 部署 API 并完成只读/签名/扣款回归
7. 最后才执行 `CONET_V2_SWITCHOVER=1`
8. 观察链上事件和 Transactions 投影后，再考虑撤销旧 BUnitAirdrop 权限

禁止：

- 使用旧 `BUnitAirdrop` 地址作为新 UI/API 默认写地址；
- 在客户端把 CONET-USDC 或 B-Unit 做本地汇率换算；
- 把 redeem secret 发送到 API；
- 让 API 等待后台 indexer 才返回已确认的业务 receipt；
- 从 BUnitAirdropV2 增加 owner/admin 提取 `reservedClaimableUsdc` 的接口；
- 未完成 API 切换就修改 Treasury 的 `bunitAirdrop`。
