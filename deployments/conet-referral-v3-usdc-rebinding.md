# Referral Vault → V3 unique conet-USDC（运维改绑清单）

产品口径：CoNET 上 **唯一** conet-USDC = Treasury V3  
`0x5209865D404aA5646eDe5B91CD4218909eA72eDA`

旧工厂版 `0xfD0D7B0706AaB5E4351bcED37bC3C77ed6813907` 仅存量，**不再**作为收费焚烧 mint / Referral 领取资产。

## 已由代码改绑

| 组件 | 变更 |
|---|---|
| `BUnitAirdrop` | `setConetTreasuryAndUsdc(BridgeV3, V3 USDC)` — 付费焚烧 mint 走 Bridge `mintForAdmin` |
| x402sdk / SilentPassUI / bizSite | `CONET_USDC` → `0x5209…` |
| TreasuryBridgeV3 | `feeSettlement` = Airdrop；`feeSettlementAsset` = V3 USDC |
| V3 USDC | Bridge 持有 `TREASURY_ROLE` |

## ReferralRegistryVaultV1（直付 EOA，无 claim）

Vault 代理：`0xD6252Cbf266B80231397Ac2a4f25ed2d9b01DEE6`  
**当前 impl：** `0x1a031844F436aa4eb1249843429f807B00f26D33`（2026-07-26 Admin remainder 升级）

| 项 | 值 |
|---|---|
| Settlement lib | `0xD2E9814D17E0A6df180ee1A5Cf862Fd2C374fF16` |
| Package claim lib | `0x4ca10B298F496001c5E3b52e448fc52f9229F021` |
| Upgrade tx | `0x4cec1e23bcf9deb26ee5d6f3b937fb2165f2c58d1c3b2233432d3d75b208e279` |
| `conetUsdc` | `0x5209865D…`（V3） |

### 结算语义（现行）

```text
付费 B-Unit 燃烧
  → Airdrop mint V3 USDC 到自身（总额 = paidBurn / 100）
  → Vault.onPaidBUnitConsumed
       · totalRebate = usdcAmount × L0.rebateBps / 10000（例：30%）
       · L1 份额（ratio / Merchant Share）+ L0 剩余 rebate → **立刻转入 L0/L1 EOA**
       · remainder = usdcAmount − totalRebate → **立刻转入 L0.parentAdmin（Admin EOA）**
       · claimedConetUsdc += 各收款方金额；不再累加 claimable；无 USDC 留在 Airdrop
```

升级脚本：`scripts/upgradeReferralVaultAdminRemainderConet.ts`  
详见 `deployments/conet-referral-vault-admin-remainder.json`。

**已移除** 用户侧 `claimConetUsdc`（新 impl）。历史欠条已 `flushPendingClaimable` 直付（见 `conet-referral-vault-direct-pay.json`）。

## 验收

```bash
cast call 0xD6252Cbf266B80231397Ac2a4f25ed2d9b01DEE6 "conetUsdc()(address)" --rpc-url https://rpc1.conet.network
# 期望 0x5209865D…

cast call 0x305f90A7f38289219BA1b4be98CB5b47e7b15Ac2 "conetUsdc()(address)" --rpc-url https://rpc1.conet.network
# 期望 0x5209865D…

cast call 0xa208982212978550594A7FEEB70a61665d129003 "feeSettlementAsset()(address)" --rpc-url https://rpc1.conet.network
# 期望 0x5209865D…
```

**产品口径：** 收费焚烧 mint、Referral 分润、客户端展示一律 V3；分润 **直达 L0/L1 EOA**，mint 余额 **直达 Admin（L0.parentAdmin）EOA**，无二套账本、无 claim 队列。
