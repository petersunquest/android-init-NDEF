# CreateCard Tiers 修复说明

## 问题根因

1. **链上**：基础设施卡 `0xC0F1c74fb95100a97b532be53B266a54f41DB615` 的 `getTiersCount()` 返回 **0**，即 tiers 从未写入合约。
2. **服务端**：`createCardPoolPress` 虽接收 `tiers` 并写入 metadata 与 DB，但**从未调用链上 `appendTier`**。`createBeamioCardAdminWithHash` 只部署卡，不配置 tiers。

## 已做修改

### 1. Factory 合约：新增 `appendTierForCard`

```solidity
function appendTierForCard(
    address cardAddr,
    uint256 minUsdc6,
    uint256 attr,
    uint256 tierExpirySeconds,
    bool upgradeByBalance
) external onlyPaymaster
```

- 仅 paymaster 可调
- 校验 `card.factoryGateway() == this`
- 转发到 `BeamioUserCard(cardAddr).appendTier(...)`

### 2. createCardPoolPress：创建卡后写入 tiers

在 `createBeamioCardAdminWithHash` 返回后，若 `tiers.length > 0`，依次调用 `factory.appendTierForCard(cardAddress, ...)` 写入链上。

### 3. ABI 更新

在 `src/x402sdk/src/ABI/BeamioUserCardFactoryPaymaster.json` 中加入了 `appendTierForCard` 的 ABI。

## 部署要求

**Factory 需重新部署或升级** 才能使用 `appendTierForCard`。当前链上 Factory `0xDdD5c17E549a4e66ca636a3c528ae8FAebb8692b` 尚无该函数。

- 若 Factory 为可升级合约，可增加该函数并升级。
- 若为不可升级，需部署新 Factory 并迁移（gateway 变更会涉及所有已部署卡）。

## 现有基础设施卡的手动修复

**卡地址**：`0xC0F1c74fb95100a97b532be53B266a54f41DB615`  
**卡 owner**：`0x9a1F3C702e722CD0e6426448010D897FFa4aC473`

卡 owner 需在 Base 上手动调用 `appendTier` 两次：

```solidity
// Tier 0: 50 CAD, upgradeByBalance=false（按单次 topup/redeem 金额升级）
appendTier(50_000_000, 0, 0, false)

// Tier 1: 100 CAD, upgradeByBalance=false
appendTier(100_000_000, 1, 0, false)
```

可通过 BaseScan 的 Write Contract 或脚本执行：

```bash
# 使用 cast（需 owner 私钥）
cast send 0xC0F1c74fb95100a97b532be53B266a54f41DB615 \
  "appendTier(uint256,uint256,uint256,bool)" \
  50000000 0 0 false \
  --private-key $OWNER_PRIVATE_KEY \
  --rpc-url https://1rpc.io/base

cast send 0xC0F1c74fb95100a97b532be53B266a54f41DB615 \
  "appendTier(uint256,uint256,uint256,bool)" \
  100000000 1 0 false \
  --private-key $OWNER_PRIVATE_KEY \
  --rpc-url https://1rpc.io/base
```

## 验证

修复后执行：

```bash
cast call 0xC0F1c74fb95100a97b532be53B266a54f41DB615 "getTiersCount()(uint256)" --rpc-url https://1rpc.io/base
# 应返回 2

cast call 0xC0F1c74fb95100a97b532be53B266a54f41DB615 "getTierAt(uint256)(uint256,uint256,uint256,bool)" 0 --rpc-url https://1rpc.io/base
# 应返回 (50000000, 0, 0, false)

cast call 0xC0F1c74fb95100a97b532be53B266a54f41DB615 "getTierAt(uint256)(uint256,uint256,uint256,bool)" 1 --rpc-url https://1rpc.io/base
# 应返回 (100000000, 1, 0, false)
```
