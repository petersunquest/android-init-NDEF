# ConetTreasury / ConetTreasuryPeer 跨链与 Swap 使用说明

**受众**：前端 UI、链下 API / Relayer、Indexer。  
**合约源码**：`src/b-unit/conetTreasury.sol`、`src/b-unit/ConetTreasuryPeer.sol`  
**Relayer 实现细节**：`scripts/conetTreasury-relayer-validator.md`  
**地址常量（须随 bytecode 重跑 predict 更新）**：`scripts/conetTreasuryDeployConstants.ts`

---

## 1. 合约分工

| 合约 | 职责 | UI / API 是否直接调用 |
|------|------|------------------------|
| **ConetTreasury** | Miner 治理、ETH/ERC20 投票出金、FactoryERC20 minter、B-Unit 空投购买等 **本链国库** | 入金 / 治理 / 本链 USDC 购买 B-Unit |
| **ConetTreasuryPeer** | **跨链 burn**、稳定币/GB/B-Unit **兑换跨链**、peer 登记、目标链 **voteMint*** | **所有跨链用户入口** |

跨链 burn / mint **不在 Treasury 上**；须对接 **Peer**（各链 CREATE2 同址）。

---

## 2. CREATE2 同址（Nick factory）

运行 `npx hardhat run scripts/predictCrossChainAssets.ts` 复核；当前仓库预测值见 `conetTreasuryDeployConstants.ts`。

| 合约 / 资产 | 用途 |
|-------------|------|
| `CONET_TREASURY_CREATE2_PREDICTED` | 统一国库 |
| `CONET_TREASURY_PEER_CREATE2_PREDICTED` | 跨链 Peer 模块 |
| `NATIVE_CROSS_CHAIN_GB` | GB ERC20（9 decimals）— **UUPS proxy 同址** |
| `NATIVE_CROSS_CHAIN_BUINT` | B-Unit ERC20（6 decimals）— **UUPS proxy 同址** |
| `NATIVE_CROSS_CHAIN_WCNET` | Wrapped CoNET（18 decimals） |
| `CONET_USDC` / `BASE_USDC` | 各链 canonical USDC（6 decimals）；CoNET 侧为 **FactoryERC20Upgradeable UUPS proxy** |

**ChainId**：CoNET `224422`；Base `8453`（`CONET_CHAIN_ID` / `BASE_MAINNET_CHAIN_ID`）。

### 2.1 ERC20 UUPS（地址不变、逻辑可升级）

B-Unit、GB、CoNET-USDC 已改为 **ERC1967Proxy + UUPS implementation**（守则：`beamio-contract-upgradeable-address-stable.mdc`）：

| 资产 | canonical（proxy，跨链同址） | impl salt | proxy salt |
|------|------------------------------|-----------|------------|
| B-Unit | `0x54ac4672cE75EC5ACebaeF1a7aFC6F49E77Ae9Ae` | `beamio.bunits.impl.v1` | `beamio.bunits.proxy.v1` |
| GB | `0xC3EF02DaE632b4C10abB66e07d92a387c10838D8` | `beamio.gb.erc20.impl.v1` | `beamio.gb.erc20.proxy.v1` |
| conet-USDC | `0xfA9a4DC94D9CEA58E9b8D8C76524fc3D511Bef81` | `beamio.conet_usdc.impl.v1` | `beamio.conet_usdc.proxy.v1` |

- **对外引用、Peer `setBUint` / `setGbTokenErc20`、钱包与 Indexer 一律用 proxy 地址**；升级只换 impl（`upgradeErc20UupsImpl.ts`），proxy 不变。
- **首次部署**：`npx hardhat run scripts/deployErc20UupsCreate2.ts --network <chain>`，`TOKEN=buint|gb|usdc`。
- **预测地址**：`npx hardhat run scripts/predictErc20UupsCreate2.ts` → 常量见 `scripts/erc20UupsDeployConstants.ts`。
- **@deprecated** 直连 CREATE2（无代理）：B-Unit v1 `0xa354…427f0`、v2 `0x4289…cdA9`、GB `0xBDa7…6cef`、Treasury 内 USDC `0x2975…DBdC` — 新部署勿再使用。

`ConetTreasury.sol` 仍保留非升级版 `FactoryERC20` 供历史 `createERC20` 路径；**新 canonical conet-USDC 走独立 UUPS CREATE2**，不修改 Treasury bytecode。

---

## 3. 两种跨链模式（UI 须区分）

### 3.1 原生资产 1:1 跨链（同资产、同数量）

用户只选 **目标链 + 收款地址**；源链与目标链 mint **同一种** token（GB / B-Unit / wCNET）。

```solidity
// nativeAsset: NATIVE_ASSET_GB=1 | NATIVE_ASSET_BUINT=2 | NATIVE_ASSET_WCNET=3
peer.bridgeNativeAsset(nativeAsset, amount, destinationChainId, recipient);
```

| 项 | 值 |
|----|-----|
| 源链事件 | `NativeAssetBridgeOut`（及 legacy `GBBridgeOut` / `BUintBridgeOut` / `WrappedConetBridgeOut`） |
| 目标链 Relayer | `voteMintFromPeerDeposit(burnTxHash, sourceChainId, peerToken, recipient, amount)` |
| `peerToken` | 被 burn 的 **同址 ERC20 地址**（见 §5） |
| `amount` | 与 burn **相同**（1:1） |

**UI 文案**：Cross-chain transfer（同资产），**不是** swap。

**严禁**：用 `bridgeNativeAsset(GB)` + 目标链 `voteMintFromPeerCredit(USDC)` 冒充「GB 换 USDC」——会 **绕过** CoNET `usdcOutboundBalance` 守卫。

### 3.2 稳定币 / GB / B-Unit 跨链兑换（Swap）

源链 burn **一种** 资产，目标链 mint **另一种**（含同资产跨链：`creditKind == burnKind`）。

```solidity
uint256 credit = peer.quoteStableSwap(burnKind, burnAmount, creditKind);
peer.bridgeStableSwap(burnKind, burnAmount, destinationChainId, recipient, creditKind);
```

| kind 常量 | 值 | 精度 |
|-----------|-----|------|
| `CANONICAL_GB_ERC20` | 1 | 9 |
| `CANONICAL_USDC_ERC20` | 2 | 6 |
| `CANONICAL_BUINT_ERC20` | 3 | 6 |

| 项 | 值 |
|----|-----|
| 源链事件 | `StableSwapBridgeOut(user, burnKind, burnAmount, creditKind, creditAmount, destinationChainId, recipient)` |
| 目标链 Relayer | `voteMintFromPeerCredit(burnTxHash, sourceChainId, sourcePeerToken, recipient, creditAmount, creditAssetKind)` |
| `sourcePeerToken` | 源链 **被 burn** 的 token 地址（见 §5） |
| mint 数量 | 事件 **`creditAmount`**（不是 `burnAmount`） |

**UI 文案**：Cross-chain swap；展示 `quoteStableSwap` / `previewStableSwapOutbound` 结果后再提交。

### 3.3 本链 USDC ↔ GB / B-Unit（Local Swap）

**CoNET 单链**内 CONET-USDC 与 GB / B-Unit 互换：调用 **`bridgeStableSwap`** 且 **`destinationChainId == block.chainid`**（224422）。同 tx 内 burn + `mintPaid`；**不**走 Relayer，**不**扣 `usdcOutboundBalance`。

```solidity
uint256 credit = peer.quoteStableSwap(burnKind, burnAmount, creditKind);
peer.bridgeStableSwap(burnKind, burnAmount, block.chainid, recipient, creditKind);
// recipient=0 时本链 swap 自动使用 msg.sender
```

| 方向 | burn | mint（均为 **paidPool**） |
|------|------|---------------------------|
| USDC → B-Unit | Treasury `burnFactoryFrom(usdc, user, …)` | `buint.mintPaid` |
| USDC → GB | 同上 | `gbTokenErc20.mintPaid` |
| B-Unit → USDC | `consumePaidFuel` | Treasury `mintFactoryToken(usdc, …)` |
| GB → USDC | `burnPaidFrom` | 同上 |

| 项 | 说明 |
|----|------|
| 事件 | 同 `StableSwapBridgeOut`；`destinationChainId == 224422` 且同 tx 有 `MintExecuted` → 本链 swap |
| 限制 | 须 **USDC 参与**（USDC↔GB 或 USDC↔B-Unit）；GB↔B-Unit 本链请分两步或走跨链 |
| USDC 授权 | USDC → GB/B-Unit：`approve(ConetTreasury, amount)` on `CONET_USDC` |
| 免费池 | 仅 freePool 的 GB/B-Unit **不可** 换 USDC（paid 不足 revert） |

---

## 4. 链上汇率（单一事实来源）

| 交易对 | 规则 | 配置 |
|--------|------|------|
| USDC ↔ B-Unit | 固定 **1 USDC = 100 B-Unit** | `USDC_TO_BUNIT_RATE = 100` |
| USDC ↔ GB | `creditUsdc6 = burnGb9 * usdc6PerFullGb / 1e9`（及反算） | Miner `setUsdc6PerFullGb`；默认 0.01 USDC/GB → `10000` |
| GB ↔ B-Unit | 经 USDC hub 换算 | 只读 `quoteStableSwap` |

**UI**：换汇预览 **必须** 调 `quoteStableSwap` 或 `previewStableSwapOutbound`，勿本地重算汇率。

---

## 5. `peerToken` / 源链 burn 地址对照表

Swap 与 1:1 跨链 Relayer 均须用 **源链真实 burn 的 token 地址** 作为 `peerToken` / `sourcePeerToken`。

| burn kind | CoNET / Base 同址 token |
|-----------|-------------------------|
| GB (1) | `0xCF48A95dB36276bf20335b93Ccb1acc4269C8B2a`（UUPS proxy；free+paid 均可 transfer） |
| B-Unit (3) | `0x9FAF3bCB390dBc0ce25dBB13e672B6a54c3B2a70`（UUPS proxy；仅 paid 可 transfer） |
| wCNET | `WRAPPED_CONET_CREATE2_PREDICTED`（`nativeAssetToken(3)`） |
| USDC (2) | CoNET: `CONET_USDC`；Base: `BASE_USDC` |

Legacy（v1 Peer）：B-Unit `…B001`、GB 1155 `…B002`、wCNET `NATIVE_PEER_TOKEN` — 见 Relayer 文档 Legacy 节。

---

## 6. CoNET 跨出 USDC 流动性（`usdcOutboundBalance`）

**仅 CoNET 链 Peer** 维护 `usdcOutboundBalance[peerChainId]`（USDC6）：向该 **对端链** 仍可兑现的跨出 USDC 额度。

### 6.1 语义（双向同一 key）

`peerChainId` 始终指 **对端链**（如 Base `8453`），不是 CoNET `224422`。

| 方向 | 触发 | 记账 |
|------|------|------|
| 对端 → CoNET，mint USDC | 目标链 CoNET 上 `voteMint*` 执行成功 | `usdcOutboundBalance[peerChainId] += amount` |
| CoNET → 对端，用户收 USDC | `burnUsdcForBridge` 或 `bridgeStableSwap(..., creditKind=USDC)` **burn 前** | `usdcOutboundBalance[peerChainId] -= creditAmount` |

含 **GB / B-Unit burn → 对端 USDC**（须 `bridgeStableSwap`，见 §3.2）。

### 6.2 可用额度

```solidity
availableOutboundUsdc(destinationChainId)
// = min(usdcOutboundBalance[dest], Treasury 上 conet-USDC balanceOf)
```

### 6.3 UI 预检（CoNET 源链、credit = USDC）

```solidity
(creditAmount, availableUsdc6, sufficient) =
    peer.previewStableSwapOutbound(burnKind, burnAmount, destChainId, CANONICAL_USDC_ERC20);
```

| 条件 | 行为 |
|------|------|
| `sufficient == false` | 禁用提交；提示流动性不足 |
| 链上 revert | `InsufficientOutboundUsdc()` — **未 burn** |

### 6.4 Miner 运维（非 UI）

```solidity
peer.setUsdcOutboundBalance(destChainId, balance);      // 全量对账
peer.replenishUsdcOutboundBalance(destChainId, amount); // 增量
```

---

## 7. 端到端流程（UI + API）

### 7.1 用户侧（源链一笔 tx）

```
1. 选择：目标链 destinationChainId、收款地址 recipient
2. 选择模式：
   a) 同资产 → bridgeNativeAsset
   b) 兑换   → quoteStableSwap →（CoNET 出 USDC 时）previewStableSwapOutbound → bridgeStableSwap
3. 用户 approve（ERC20 burnFrom 路径：GB / USDC / wCNET）
4. 发送 tx，等待 receipt
5. UI 展示：burnTxHash、destinationChainId、recipient、amount/creditAmount、模式（1:1 / swap）
```

### 7.2 Indexer / Relayer（源链监听）

**须订阅合约**：本链 `ConetTreasuryPeer` 地址。

| 模式 | 必监事件 | 任务 id |
|------|----------|---------|
| 1:1 原生 | `NativeAssetBridgeOut` 或 legacy `*BridgeOut` | `burnTxHash` + `destChainId` |
| Swap | `StableSwapBridgeOut` | 同上；额外存 `burnKind/creditKind/creditAmount` |

字段映射：

| 事件字段 | Relayer 用途 |
|----------|--------------|
| `transactionHash` | `depositTxHash` / `burnTxHash` |
| `block.chainId` | `sourceChainId` |
| `destinationChainId` | 选择 **目标链 RPC** 投票 |
| `recipient` | 目标链 mint 接收方 |
| Swap: `creditAmount`, `creditAssetKind` | `voteMintFromPeerCredit` |
| 1:1: `amount` | `voteMintFromPeerDeposit` |

### 7.3 Relayer（目标链投票）

| 模式 | 函数 | 通过阈值后 |
|------|------|------------|
| 1:1 | `voteMintFromPeerDeposit(hash, sourceChainId, peerToken, recipient, amount)` | `_executePeerDepositMint` → 同资产 mint |
| Swap | `voteMintFromPeerCredit(hash, sourceChainId, sourcePeerToken, recipient, creditAmount, creditKind)` | mint **credit** 资产 |

治理：`isMiner`（Treasury 委托）、`requiredVotes() = ceil(n * 2/3)`。  
完成事件：`PeerDepositExecuted(depositTxHash, mintTarget, recipient, amount)`。

### 7.4 API 层建议

| Endpoint（示例） | 职责 |
|------------------|------|
| `GET /bridge/quote-stable-swap` | 代理 `quoteStableSwap` + 可选 `availableOutboundUsdc` |
| `GET /bridge/preview-outbound-usdc` | 代理 `previewStableSwapOutbound` |
| `GET /bridge/job/:burnTxHash` | 聚合源链 receipt + 目标链 `getPeerDepositProposal` |
| `POST /bridge/relay-vote` | Miner 钱包调用 `voteMint*`（或队列） |

**可信拉取**：RPC 失败不得把任务标为「不存在」；保留上次可信状态（见项目 `beamio-trusted-vs-untrusted-fetch` 守则）。

---

## 8. 只读接口速查（UI）

| 函数 | 用途 |
|------|------|
| `nativeAssetToken(nativeAsset)` | GB/B-Unit/wCNET 地址与 decimals |
| `quoteStableSwap(burnKind, burnAmount, creditKind)` | 兑换 preview |
| `previewStableSwapOutbound(burnKind, burnAmount, dest, creditKind)` | 含 CoNET USDC 出桥流动性 |
| `availableOutboundUsdc(destChainId)` | 对端可兑现 USDC（CoNET only） |
| `usdcOutboundBalance(destChainId)` | 记账额度（CoNET only） |
| `usdc6PerFullGb()` | GB/USDC 汇率参数 |
| `getPeerDepositProposal(hash)` | 跨链到账进度（目标链） |
| `isPeerTokenRegistered(peerChainId, peerToken)` | Relayer 投票前检查 |
| `BUint.bridgeableBalanceOf(user)` | 跨链可用 B-Unit（仅 paidPool，在 BUint 合约上读） |
| `GBToken.bridgeableBalanceOf(user)` | 跨链可用 GB（仅 paidPool，在 GBToken 合约上读） |

---

## 9. 用户写接口速查

| 场景 | 函数 |
|------|------|
| GB/B-Unit/wCNET 同资产跨链 | `bridgeNativeAsset` |
| USDC/GB/B-Unit 兑换跨链 | `bridgeStableSwap` |
| 仅 USDC 同资产跨链（CoNET 出） | `burnUsdcForBridge` 或 `bridgeStableSwap(2, amt, dest, recv, 2)` |
| 本链 wCNET peg | `depositNative` / `withdrawNative`（CoNET） |

Legacy 单独入口（与 `bridgeNativeAsset` 等价时优先统一入口）：`burnGBForBridge`、`burnBUintForBridge`、`burnWrappedConetForBridge`。

---

## 10. 典型场景示例

### 10.1 CoNET → Base：GB 换 USDC（Swap）

```solidity
// UI: quote + preview on CoNET Peer
peer.bridgeStableSwap(1, gbAmount9, 8453, recipient, 2);
// Relayer on Base:
peer.voteMintFromPeerCredit(burnTxHash, 224422, GB_TOKEN, recipient, creditAmount, 2);
```

CoNET burn **前**自动：`usdcOutboundBalance[8453] -= creditAmount`。

### 10.2 Base → CoNET：10 USDC 换 GB

```solidity
peer.bridgeStableSwap(2, 10_000_000, 224422, recipient, 1);
// Relayer on CoNET:
peer.voteMintFromPeerCredit(burnTxHash, 8453, BASE_USDC, recipient, creditGb9, 1);
```

CoNET mint USDC 入站时（若 credit 为 USDC）：`usdcOutboundBalance[8453] += amount`。

### 10.3 CoNET → Base：B-Unit 1:1

```solidity
peer.bridgeNativeAsset(2, amount6, 8453, recipient);
// Relayer: voteMintFromPeerDeposit(..., BUINT_TOKEN, ..., amount6)
```

不涉及 `usdcOutboundBalance`。

---

## 11. 错误码（UI 映射建议）

| Error | 含义 | UI |
|-------|------|-----|
| `InsufficientOutboundUsdc` | CoNET 对目标链 USDC 额度不足 | 流动性不足，勿重试同参数 |
| `InvalidAmount` | 金额为 0 或 swap 产出为 0 | 校验输入 |
| `InvalidTarget` | recipient 为零或 dest = 本链 | 校验表单 |
| `UsdcErc20NotSet` / `GbTokenErc20NotSet` / `BUintNotSet` | 链上未配置 | 不可用态 |
| `RateNotSet` | `usdc6PerFullGb == 0` | GB↔USDC 暂不可用 |
| `PeerTokenNotRegistered` | Relayer 目标链未登记 peer | 对该路由禁用 |

用户可见文案须 **英语**（`ui-english.mdc`）。

---

## 12. 部署与登记（运维）

顺序见 `scripts/README-conet-contract-migration.md`：

`deployConetTreasuryStackCreate2` → `configureConetTreasuryPeerBridge` → `registerPeerBridgeAssets`（含 `registerPeerNativeBridgeAssets` + `registerPeerStableSwapAssets`）→ `registerTreasuryPeerUsdc` → CoNET 上 `setUsdc6PerFullGb` / `setUsdcOutboundBalance`。

---

## 13. 严禁（UI / API）

- ❌ 在 **Treasury** 调用跨链 burn / `voteMint*`
- ❌ Swap 路径用 `voteMintFromPeerDeposit` + burn 数量（须 `voteMintFromPeerCredit` + `creditAmount`）
- ❌ `voteMint*` 的 `peerChainId` 填 **目标链**（必须为 **源链** burn 所在 chainId）
- ❌ GB→USDC 走 `bridgeNativeAsset` 或伪造 USDC credit 投票
- ❌ UI 本地硬编码汇率，不读 `quoteStableSwap` / `usdc6PerFullGb`
- ❌ CoNET 出 USDC 不检查 `previewStableSwapOutbound` / `availableOutboundUsdc`

---

## 15. GB / B-Unit 双池与跨链（free / paid）

`GBToken` 与 `BeamioBUnits` 均采用 **freePool**（空投/奖励）与 **paidPool**（USDC 购买 / 跨链入桥）。`balanceOf` = 两者之和；**跨链只认 paidPool**。

| 资产 | 空投 / 奖励 mint | USDC / 跨链入桥 mint | 跨链 burn | P2P 转账 | 可跨链余额 view |
|------|------------------|----------------------|-----------|----------|-----------------|
| **B-Unit** | `mintReward` → free | `mintPaid` → paid | Peer → `consumePaidFuel` | **仅 paidPool**（`transfer` / EIP-3009） | `bridgeableBalanceOf` |
| **GB (ERC20)** | `mintReward` / `airdrop` / `mint()` → free | `mintPaid` → paid | Peer → `burnPaidFrom` | **free + paid**（`transfer` 先扣 free 再扣 paid；EIP-3009 同） | `bridgeableBalanceOf`（仅 paid） |

**GBToken 自带投票桥**（`bridgeOut` / `executeBridgeMint`）同样只动 paidPool：出桥 `_burnPaidOnly`，入桥 `_mintPaid`。

**业务规则（链下 / Treasury 调用方）**

- 仅 **USDC 购买** 或 **paid B-Unit 等收费路径** 应调用 `GBToken.mintPaid`；普通空投须走 `mintReward` / `airdrop`。
- Legacy `ConetGB1155.issueGB` 仍为 1155 记账轨，与 ERC20 双池无关；canonical 跨链以 `gbTokenErc20` 为准。

**B-Unit 链上服务费**（非跨链）：`consumeFuel` 瀑布流先 free 后 paid。

**UI**

- B-Unit 可跨链 / 可转让：`bridgeableBalanceOf(user)` = paid 余额；`transfer` 仅移动 paid，free 不可转
- GB 可跨链：`bridgeableBalanceOf` = paid；**P2P transfer** 可移动 free+paid（跨链/swap 仍仅认 paid）
- 错误 `"Insufficient paid balance"` / `"B-Units: Insufficient paid balance"` → 仅收费池余额可跨链

---

## 16. 相关文件

| 文件 | 说明 |
|------|------|
| `src/b-unit/ConetTreasuryPeer.sol` | 跨链 + swap 实现 |
| `src/b-unit/GBToken.sol` | GB 双池；`mintPaid` / `burnPaidFrom` / `bridgeableBalanceOf` |
| `src/b-unit/BUint.sol` | B-Unit 双池；`consumePaidFuel` / `bridgeableBalanceOf` |
| `scripts/conetTreasuryDeployConstants.ts` | 地址与 chainId |
| `scripts/conetTreasury-relayer-validator.md` | Relayer daemon 细则 |
| `scripts/registerPeerBridgeAssets.ts` | Peer 登记脚本 |
| `scripts/predictCrossChainAssets.ts` | CREATE2 地址预测 |
