# BeamioUserCard Mint 权限与统计口径

本文档整理 UserCard points (token #0) 的 mint 权限及 admin 维度统计口径，按空投、Redeem、USDC Topup 分类；并固化 **本仓现版** 合约中「会员卡（会员档 NFT）mint」与「升级」的链上语义（实现以 `MembershipStatsModule.sol`、`BeamioUserCardBase.sol`、`BeamioUserCard.sol` 为准）。

---

## 一、空投 (Admin Airdrop)

### 权限

| 项目 | 说明 |
|------|------|
| **入口** | `mintPointsByAdmin(address toEOA, uint256 points6)` |
| **调用路径** | Admin 离线签 `ExecuteForAdmin` → Factory `executeForAdmin` → Card `mintPointsByAdmin` |
| **权限要求** | 签名者必须为 card admin (`card.isAdmin(signer)`) |
| **典型场景** | NFC Topup、扫码充值、Admin 手动空投 |

### Admin 层级与 limit 规则

- `owner` 可直接添加一级 admin
- 一级 admin（`adminParent == address(0)`）只可添加自己的一层下级 admin
- 二级 admin（`adminParent != address(0)`）不可再继续添加自己的下级 admin
- 二级 admin 不可执行 `setAdminAirdropLimitByAdmin`，也不可执行 `clearAdminMintCounterForSubordinate`
- `owner` 的空投 limit 视为无限制
- 非 owner admin 的 `limit` 约束的是 **自己 + 全部下层 admin** 从上次 clear 起的累计空投额
- parent admin 给直属下级设置 `limit` 时，只要求 `subordinate.limit <= parent.limit`；**不检查 parent 当前剩余额度**
- admin 空投时，会沿 `adminParent` 向上逐级校验；任一祖先 admin 的 subtree 累计空投若超过自己的 `limit`，本次空投直接拒绝

### 统计口径

| 项目 | 值 |
|------|-----|
| **operator** | Admin signer（执行空投的 admin 地址） |
| **operatorParentChain** | 从 `card.adminParent(operator)` 向上追溯的 parent 链 |
| **统计累积** | operator 及 operatorParentChain 中每个地址的 `adminHourlyData` 均累加 token0Mint |
| **route.source** | `UserCardPoint` (1) |

### 流程摘要

1. 客户端调用 `nfcTopupPrepare` 获取 `cardAddr, data, deadline, nonce`
2. Admin 签 EIP-712 `ExecuteForAdmin`
3. Master 调用 `factory.executeForAdmin(cardAddr, data, deadline, nonce, sig)`
4. 成功后 `executeForAdminProcess` 调用 `syncTokenAction`，传入 `operator=signer`、`operatorParentChain=fetchOperatorParentChain(cardAddr, signer)`

---

## 二、Redeem 兑换

### 权限

| 项目 | 说明 |
|------|------|
| **创建** | 仅 card owner 可创建 redeem，经 gateway `executeForOwner` 执行 |
| **兑换** | 任意用户持有效 code 可兑换，gateway 代付 gas |
| **入口** | `createRedeem` / `createRedeemBatch` / `createRedeemPool`（创建）<br>`redeemByGateway` / `redeemForUser`（兑换） |
| **Recommender** | 可选；若传入则**必须为 card admin**，由 owner 在离线签名的 createRedeem/createRedeemBatch/createRedeemPool 参数中指定 |

### 统计口径

| 项目 | 值 |
|------|-----|
| **operator** | `card.getRedeemCreator(redeemCode)`，即创建该 redeem 的 owner；若无则用 card owner |
| **operatorParentChain** | `fetchOperatorParentChain(cardAddr, operator)` |
| **统计累积** | operator 及 operatorParentChain 中每个地址的 `adminHourlyData` 均累加 token0Mint |
| **redeem_mintCounter** | `card.getRedeemRecommender(redeemCode)` 非零时，兑换成功后把本次 points mint 数单独计入该 admin 的 `adminRedeemMintCounter`，并沿 parent 链累积 |
| **route.source** | `UserCardPoint` (1) |

### 流程摘要

1. **创建**：Owner 签 `ExecuteForOwner`，data 为 `createRedeem` / `createRedeemBatch` / `createRedeemPool`；可选附带 `recommender admin`；Factory 拦截后调用 `createRedeemWithCreator(...)` 或 `createRedeemWithCreatorAndRecommender(...)`，将 signer 写入 `creator`
2. **兑换**：用户提交 code，Master 调用 `factory.redeemForUser(cardAddr, code, userEOA)`
3. **记账**：兑换成功后，链上会读取 `creator` 和可选 `recommender`；`creator` 继续进入普通 admin mint 统计，`recommender` 则单独进入 `adminRedeemMintCounter`

---

## 三、USDC Topup

### 权限

| 项目 | 说明 |
|------|------|
| **入口** | `buyPointsForUser(cardAddr, fromEOA, usdcAmount6, validAfter, validBefore, nonce, signature, 0)` |
| **调用路径** | 用户签 EIP-3009 授权 USDC → Factory `buyPointsForUser` → Card 收 USDC 并 mint points |
| **权限要求** | 用户（payer）签名有效，card 在 DB 已注册 |
| **Recommender** | 可选；若传入则**必须为 card admin**，Cluster 预检 `card.isAdmin(recommender)`，非 admin 返回 400 |
| **典型场景** | 用户自助购点、`/api/purchasingCard`、`/api/usdcTopup` |

### 统计口径

| 项目 | 值 |
|------|-----|
| **operator** | Recommender 非零且为 admin 时 = recommender；否则 = card owner |
| **operatorParentChain** | `fetchOperatorParentChain(cardAddr, operator)` |
| **统计累积** | operator 及 operatorParentChain 中每个地址的 `adminHourlyData` 均累加 token0Mint |
| **route.source** | `UserCardPoint` (1) |

### Recommender 规则

- **recommender 为零**：只计入 owner 链（`operator=owner`）
- **recommender 非零**：必须为 admin；计入该 admin 的统计口径（`operator=recommender`）

### 流程摘要

1. 用户签 EIP-3009，提交到 `/api/purchasingCard` 或 `/api/usdcTopup`，可选传 `recommender`
2. Cluster 若收到 recommender：调用 `validateRecommenderForTopup(cardAddr, recommender)` 校验 `card.isAdmin(recommender)`，失败返回 400
3. Master 调用 `factory.buyPointsForUser(...)`，USDC 转给 card owner，points mint 到用户 AA
4. `purchasingCardProcess` 成功后：若 recommender 非零且为 admin 则 `operator=recommender`，否则 `operator=owner`；调用 `syncTokenAction` 传入 `operator`、`operatorParentChain=fetchOperatorParentChain(cardAddr, operator)`

---

## 四、统计规则汇总 (ActionFacet)

当 `syncTokenAction` 传入 `operator != address(0)` 且 route 含 `source == UserCardPoint` 时：

- 对 route 中每条 `UserCardPoint` 的 `amountE6` 累加到 `token0Mint`
- 调用 `_recordAdminToken0Stats(ts, operator, token0Mint, token0Burn)` 写入 `adminHourlyData[operator]`
- 对 `operatorParentChain` 中每个非零地址同样调用 `_recordAdminToken0Stats`

**查询**：`StatsFacet.getAggregatedStats(mode=3, admin, startTs, endTs)` 或 `getBusinessPeriodReports(mode=3, admin, ...)`

---

## 五、Admin Mint 计数器 (adminMintCounterByCard)

### 存储与更新

- **存储**：`LibStatsStorage.adminMintCounterByCard[card][admin]`，按 (card, admin) 维度累计 token 0 mint
- **更新**：`syncTokenAction` 在写入 `adminHourlyData` 时，同时累加 `adminMintCounterByCard`（从 route 中 UserCardPoint 的 asset 取 card）
- **每小时原子**：`adminHourlyData` 为每小时原子统计；`adminMintCounterByCard` 为累计值，可被 parent 清零

### 清零权限

- **谁可清零**：仅 subordinate 的 parent admin 可清零其计数
- **层级限制**：仅 owner 直加的一级 admin 可清零自己直属 subordinate；二级 admin 不可继续执行 clear
- **调用**：`StatsFacet.clearAdminMintCounterForSubordinate(card, subordinate)`，仅 diamond owner/admin 可调用
- **流程**：Parent admin 签 EIP-712 `ClearAdminMintCounter(cardAddress, subordinate, deadline, nonce)` → Cluster 预检 `card.adminParent(subordinate)==signer` → Master 调用 Indexer

### 查询

- **单查**：`StatsFacet.getAdminMintCounter(card, admin)`
- **连同 admin 信息**：`GET /api/cardAdmins?cardAddress=xxx` 返回 `{ admins: [{ address, metadata, parent, mintCounter }] }`
- **以时间查询时一并返回累计与 mintCounter**（需传入 card；cumulativeStartTs/cumulativeStartHour 为 0 时自动取最近 MAX_HOURS）：
  - `getAdminHourlyDataFull(admin, card, hourIndex, cumulativeStartHour)` → AdminHourlyStatsResult{ hourly, cumulativeTokenMintedFromBegin, cumulativeTokenBurnedFromBegin, adminMintCounterByCard }
  - `getAdminAggregatedStatsWithMintCounter(admin, card, startTs, endTs, cumulativeStartTs)` → AdminAggregatedResult{ stats, cumulativeTokenMintedFromBegin, cumulativeTokenBurnedFromBegin, adminMintCounterByCard }
  - `getAdminBusinessPeriodReportsWithMintCounter(admin, card, periodType, periods, anchorTs, cumulativeStartTs)` → AdminPeriodReportsResult{ reports, cumulativeTokenMintedFromBegin, cumulativeTokenBurnedFromBegin, adminMintCounterByCard }

---

## 六、BeamioUserCard 链上 Admin 记账

Admin 的 mint 记账信息，**BeamioUserCard 也必须提供**，与 Indexer 双写，便于链上直接查询。

### 存储 (AdminStatsStorage)

- **adminMintCounter[admin]**：从上次 clear 起的累计 token 0 mint
- **adminRedeemMintCounter[admin]**：从上次 clear 起的累计 redeem_mint token 0（仅 redeem recommender 口径）
- **adminUSDCMintCounter[admin]**：从上次 clear 起的累计 usdc_mint token 0（仅 USDC topup recommender 口径）
- **adminHourlyData[admin][hourIndex]**：按小时的 token 0 mint/burn/transfer/transferAmount + membership issue/upgrade 统计，`hourIndex = timestamp / 3600`
- **globalAdminToAdminTransferCount / globalAdminToAdminTransferAmount**：卡级累计——**双方**均为登记 admin（EOA）、且**均非 card owner** 的 points（token #0）真实转账次数与金额；**不因** `clearAdminStatsAndAirdropUsageForSubordinate` 清零
- **globalAdminToAdminTransferCountByHour / globalAdminToAdminTransferAmountByHour[hourIndex]**：上述 admin↔admin 转账的按小时切片（全局维度，非 per-admin）

### 存储 (GovernanceStorage / airdrop limit)

- **adminAirdropLimit[admin]**：该 admin 可管理的 subtree airdrop limit；owner 视为无限制
- **adminAirdropUsed[admin]**：从上次 clear 起，**自己 + 全部下层** 的累计空投额

### 写入时机

| 入口 | stats operator | 说明 |
|------|----------------|------|
| `mintPointsByAdmin` | signer | Admin 空投；mint 与 issue/upgrade 都归属到 signer 及其 parent 链 |
| `mintPointsByGateway` / `mintPointsByGatewayWithOperator` | recommender 非零且为 admin 时 recommender，否则 owner()（merchant） | USDC Topup；issue/upgrade 归属到 operator 及其 parent 链；另外单独累加 `adminUSDCMintCounter` |
| `redeemByGateway` / `redeemBatchByGateway` | `getRedeemCreator(code)` 或 owner | Redeem 兑换；mint/issue/upgrade 归属到 creator/owner 及其 parent 链；若 code 指定 recommender admin，则另外单独累加其 `redeem_mintCounter` |
| `mintMemberCardByAdmin` | owner() | 直接发卡；issue 归属到 owner 及其 parent 链 |
| `safeTransferFrom` / `safeBatchTransferFrom`（`POINTS_ID`） | 优先 `msg.sender`；若 `msg.sender` 为 AA 合约则回退取 `owner()` | 仅真实 token 0 转账计 `transferCount` 与 `transferAmount`，并归属到 operator 及其 parent 链；若 `from` 与**原始** `to` 解析出的 admin EOA 均为登记 admin、互不相同且均非 owner，则**另外**累加全局 `adminToAdmin` 次数与金额（与 per-admin transfer 统计并存） |

### 查询接口

- `getAdminMintCounter(admin)` / `getAdminBurnCounter(admin)` / `getAdminTransferCounter(admin)` / `getAdminRedeemMintCounter(admin)` / `getAdminUSDCMintCounter(admin)`：从上次 clear 起的累计
- admin/global 时间维度统计查询已从主卡 runtime 中拆出，使用 `BeamioUserCardAdminStatsQueryModuleV1` 的 ABI 对着 **同一个 card 地址** 调用：
- `getAdminHourlyData(admin, hourIndex)`：指定小时的 mint/burn/transfer/transferAmount/redeemMint/usdcMint/issued/upgraded 统计
- `getAdminPeriodReports(admin, periodType, periods, anchorTs)`：日/周/月/季/年周期报表
- `getAdminStatsFull(admin, periodType, anchorTs, cumulativeStartTs)`：**完整统计**（自己及下层 admin 聚合）
- `getGlobalStatsFull(periodType, anchorTs, cumulativeStartTs)`：**全局累计统计**（所有 admin 聚合，无分层），并含 **admin↔admin** 转账的时间窗与终身累计字段（见下表）
- `getGlobalAdminToAdminHourlyData(hourIndex)`：指定小时的全局 admin↔admin points 转账次数与金额（与 `getAdminHourlyData` 的 per-admin 小时桶独立）
- `getGlobalAdminToAdminCounters()`：卡级终身 admin↔admin 转账次数与金额（`getGlobalStatsFull` 中 `lifetime*` 与之相同）
- `getAdminAirdropLimit(admin)`：查询某地址自己的 airdrop `limit`、`usedFromClear`、`remainingAvailable`
- `getAdminAndSubordinateLimits(admin)`：查询某地址自己的 airdrop `limit`，以及其**直属下层**每个地址的 `limit`
- `getAdminAndSubordinateLimitsPage(to, adminOffset, adminPageSize, subordinateOffset, subordinatePageSize)`：分页查询 admin limit 视图
  - `to != address(0)`：返回指定 admin 自己的 `limit / remainingAvailable`，以及其直属下层 admin 地址分页数组
  - `to == address(0)`：返回 owner 直属 admin 的分页列表；每个 admin 项都带自己的 `limit / remainingAvailable`，以及各自直属下层 admin 地址分页数组

**getGlobalStatsFull 返回结构**：

| 字段 | 说明 |
|------|------|
| cumulativeMint/Burn/Transfer | 所有 admin 的累计（从 cumulativeStartTs 起，按小时聚合） |
| cumulativeTransferAmount | 所有 admin 的累计转账金额 |
| cumulativeRedeemMint | 所有 admin 的累计 redeemMint |
| cumulativeUSDCMint | 所有 admin 的累计 usdcMint |
| cumulativeIssued | 所有 admin 的累计发行新卡数 |
| cumulativeUpgraded | 所有 admin 的累计 upgrade 卡数 |
| periodMint/Burn/Transfer | 本时间段（anchor 所在周期）的 mint/burn/transfer |
| periodTransferAmount | 本时间段转账金额 |
| periodRedeemMint | 本时间段 redeemMint |
| periodUSDCMint | 本时间段 usdcMint |
| periodIssued | 本时间段发行新卡数 |
| periodUpgraded | 本时间段 upgrade 卡数 |
| adminCount | admin 总数（无分层） |
| cumulativeAdminToAdminTransfer / cumulativeAdminToAdminTransferAmount | 时间窗 \([cumulativeStartTs, anchor]\) 内全局 admin↔admin（不含 owner）points 转账次数与金额 |
| periodAdminToAdminTransfer / periodAdminToAdminTransferAmount | anchor 所在周期内上述 admin↔admin 转账次数与金额 |
| lifetimeAdminToAdminTransferCount / lifetimeAdminToAdminTransferAmount | 卡级终身累计（不因 subordinate clear 清零） |

**getAdminStatsFull 返回结构**：

| 字段 | 说明 |
|------|------|
| cumulativeMint/Burn/Transfer | 自己+下属的累计（从 cumulativeStartTs 起，按小时聚合） |
| cumulativeTransferAmount | 自己+下属的累计转账金额 |
| cumulativeRedeemMint | 自己+下属的累计 redeemMint |
| cumulativeUSDCMint | 自己+下属的累计 usdcMint |
| cumulativeIssued | 自己+下属的累计发行新卡数 |
| cumulativeUpgraded | 自己+下属的累计 upgrade 卡数 |
| periodMint/Burn/Transfer | 本时间段（anchor 所在周期）的 mint/burn/transfer |
| periodTransferAmount | 本时间段转账金额 |
| periodRedeemMint | 本时间段 redeemMint |
| periodUSDCMint | 本时间段 usdcMint |
| periodIssued | 本时间段发行新卡数 |
| periodUpgraded | 本时间段 upgrade 卡数 |
| mintCounterFromClear / burnCounterFromClear / transferCounterFromClear / redeemMintCounterFromClear / usdcMintCounterFromClear | 从上次 clear 起的累计（自己+下属） |
| subordinates | 下层 admin 地址数组 |

**getAdminPeriodReports** 返回的每个周期增加 `totalTransferAmounts`、`totalRedeemMints`、`totalUSDCMints`、`totalIssueds`、`totalUpgradeds` 数组。

**periodType**：0=小时, 1=日, 2=周, 3=月, 4=季, 5=年

### 清零

- `clearAdminMintCounterForSubordinate(subordinate, authorizer)`：仅 gateway 可调；authorizer 必须为 `adminParent[subordinate]`
- `authorizer` 还必须是 owner 直加的一级 admin；二级 admin 不可继续清零自己的下层
- clear 时除 `adminMintCounter/adminBurnCounter/...` 外，也会清空该 subordinate subtree 的 `adminAirdropUsed`
- 流程：Parent 签 `ClearAdminMintCounter` → Master 调用 `Factory.executeClearAdminMintCounter`（Card）+ `Indexer.clearAdminMintCounterForSubordinate`

### API

- `GET /api/cardAdmins?cardAddress=xxx`：返回 admins 时，`mintCounter` 取自 **Card.getAdminMintCounter(admin)**（链上直接读）

---

## 七、会员卡 mint 与升级（链上语义，本仓现版）

本节描述 **会员档 ERC1155**（token id 落在 `[NFT_START_ID, ISSUED_NFT_START_ID)`）的 **首卡发放** 与 **档位升级**，与上文 points mint **权限/统计** 互补。逻辑主要在 **`BeamioUserCardMembershipStatsModuleV1`**，主合约经 `_callModule(MODULE_MEMBERSHIP_STATS, …)` delegatecall。

### 7.1 术语

| 概念 | 说明 |
|------|------|
| **发卡 / 首卡** | 为用户 mint **新的**会员 NFT：`BeamioUserCardBase._mintMembershipNft`（`_currentIndex++` 得新 `tokenId`）。 |
| **升级** | **不**为升级 mint 新 id；对当前 **active** 会员 NFT 调用 `_upgradeMembershipInPlace`，在同一 `tokenId` 上更新 `attributes`、`tokenTierIndexOrMax`、`expiresAt`，并修正按 tier 的 active 计数。 |
| **`upgradeType`** | 卡级构造参数（0 / 1 / 2），决定「有有效会员时」如何用 points **增量**、**余额** 或 **转给 admin 的累计** 驱动升档。 |

### 7.2 首卡（无有效会员卡时）

触发：经 `syncActiveToBestValid` / `_hasValidCard` 判定 **没有未过期的 active 会员 NFT**。

**无 `tiers`**

- Mint **一枚**会员 NFT：`tierIndexOrMax = type(uint256).max`，`attr = defaultAttrWhenNoTiers`，过期按卡级 `expirySeconds`。
- 与 `upgradeType` 无关；无档时 `_maybeUpgradeInternal` 直接 return，无升级动作。

**有 `tiers`**

- **门槛**：用于发卡的 `pointsDelta6` 必须 **≥ 全档中 `minUsdc6` 最小的那一档**（`_tierIndexWithMinThreshold()`），否则模块 **`revert UC_BelowMinThreshold()`**。
- **档位**：首卡 **永远 mint 在「`minUsdc6` 最小的那一档」**，**不会**按单次 delta 用 `_tierFromPointsDelta` 直接发到更高档。
- 过期按该档 `_effectiveExpirySeconds(lowIdx)`。

**避免「先 mint points 再拒发卡」**

- 凡会 **mint `POINTS_ID`**、用户 **尚无有效会员**、且 **配置了 tiers** 的路径，主合约先 `_requirePointsMintAllowsFirstMembership`：若 `points6` 低于最低档门槛则 **整笔 revert**。
- 覆盖例如：`faucetByGateway`、`mintFaucetByGateway`、`mintPointsByGateway*`、`mintPointsOpenContainerRelay`、`mintPointsByAdmin*`、redeem bundle 中含 points 等。

**主合约入口与模块调用（摘要）**

| 场景 | 无有效卡时的要点 |
|------|------------------|
| **免费 `faucetByGateway`** | 无 tiers：直接 `issueCardByPointsDelta_AssumingNoValidCard`；有 tiers：**仅当** mint 的是 points 且 `pointsDelta6 > 0` 才 `issueCard…`（否则不尝试发卡）。 |
| **付费 faucet / gateway mint points / admin mint points** | `_maybeIssueOnlyIfNoneOrExpiredByPointsDelta`：无卡且（无 tiers 或 `delta > 0`）才进入模块 `_issueFromPointsDelta`。 |
| **`_applyRedeemBundleToUser`（redeem）** | 无卡：`issueCardByPointsDelta_AssumingNoValidCard(acct, totalPoints6)`；若 `totalPoints6 == 0` 且有 tiers，模块因低于门槛 **revert**。 |
| **已有有效卡** | 不发首卡，只走升级（7.3）。 |

**管理员直开卡**

- 模块 `mintMemberCardInternal`：指定 `tierIndex`，用户尚无有效会员时 **mint 新会员 NFT**（与 points 流水无关）；通常经 fallback 路由到模块。

### 7.3 升级（已有有效会员卡时）

前提：同步后存在 **未过期** 的 active 会员 NFT；否则升级逻辑 **return**。

**共同规则**

- 一律 **`_upgradeMembershipInPlace`**，**不** `_mintMembershipNft`。
- `MemberNFTUpgraded` 事件中可出现 **oldTokenId == newTokenId**（表示原地改档）。

**`upgradeType == 0`（按本笔 points 增量迈一档）**

- 在 `tiers` 中取 **严格高于** 当前档 `minUsdc6` 的 **下一档**（最小步进）。
- 当且仅当 **`pointsDelta6 >= 下一档.minUsdc6`** 时升到该档；否则不升级。
- **不**用全量 points 余额决定跨多档。

**`upgradeType == 1`（按当前 points 余额对齐最高可达档）**

- **`pointsDelta6` 不参与档位计算**；用 `balanceOf(acct, POINTS_ID)` + `_tierFromPointsBalance` 得到余额能支撑的 **最高档**。
- 仅当目标档 `minUsdc6` **严格高于** 当前档时原地升级。
- 主合约通过 **`maybeUpgrade(acct, pointsDelta6)`** 调模块即可；模块内 type 1 会调用 `_applyBalanceBasedMembershipTierBump`。
- `BeamioUserCard._maybeUpgradeByPointsBalance` **当前未被调用**，与「仅余额对齐」重复暴露的模块函数为 `maybeUpgradeByPointsBalance`（外部可直接打模块 ABI，但主合约路径不依赖它）。

**`upgradeType == 2`（转给 admin 的 points 累计）**

- 在 **`_update`** 中，真实转账且含 points 时 delegatecall `handlePointsTransferForUpgradeType2`，把转给 admin 侧的 points **累加**到存储。
- 当累计 **≥ 下一档 `minUsdc6`** 时升一档（同样一步一档）；升级成功后 **清零**该累计。
- 仍用 **`_upgradeMembershipInPlace`**。

### 7.4 与 points 转账的关系

- **Type 2**：升级由 **points 转给 admin** 的路径驱动（见 7.3）。
- **Type 0 / 1**：升级主要由 **mint points**（faucet / gateway / admin / redeem 等）路径里的 **`_maybeUpgrade`** 触发；**普通用户间 points 转账** 本身 **不会**自动调用 `maybeUpgrade`（除非另有入口）。

### 7.5 与 `BeamioERC1155Logic` 的关系

库中仍保留「按余额 mint 新 id」类旧逻辑；**主卡会员流以 `MembershipStatsModule` + `_upgradeMembershipInPlace` 为准**，勿与未接线的库函数混淆。

---

## 附录：第一至六节、第八节与第七节（现版合约）的交叉说明

以下条目针对**未随第七节一并重写**的章节（一至六、八）。它们多数仍正确描述 **points mint 权限 / Indexer 统计 / 服务端流程**，但与 **第七节** 并读时易出现**遗漏、口径歧义或与旧心智模型冲突**，此处集中说明。

| 问题类型 | 位置 | 说明 |
|----------|------|------|
| **遗漏入口（链上写入/会员流）** | **第六节「写入时机」表** | 表内未列但现版同样会 **mint points + 触发会员 issue/upgrade**（并走 `_recordAdminMembershipFlowForOperatorAndParents`）的入口包括：`faucetByGateway`、`mintFaucetByGateway`、`mintPointsOpenContainerRelay`、`mintPointsByAdminWithOperator`。operator 规则与已列入口类似（faucet 见主合约实现；Open Container 使用传入的 `operatorForStats`）。阅读第七节「主合约入口摘要」时应对照补全。 |
| **遗漏兑换入口** | **第二节「入口」表** | 链上除 `redeemByGateway` 外还有 **`redeemBatchByGateway`、`redeemPoolByGateway`**（与单码兑换共用 `_applyRedeemBundleToUser`）。文档中的 `redeemForUser` 指 Factory Paymaster 封装，不是 Card 上唯一函数名。 |
| **与第七节门槛的交叉** | **第一至三节（空投/Redeem/USDC 叙事）** | 正文默认「points 到账」；现版在 **有 `tiers` 且无有效会员** 时，若 mint 量 **低于全档最低 `minUsdc6`**，主合约会 **`revert UC_BelowMinThreshold()`**（`_requirePointsMintAllowsFirstMembership`），**整笔不 mint points**。这与未读第七节时的直觉（「正数即可入账」）可能冲突；产品/运营需按卡 **tiers** 配置理解。 |
| **`upgraded` 统计语义** | **第六节 `cumulativeUpgraded` / `periodUpgraded` 等** | 字段表示 **升级动作次数**（模块 `_recordUpgradeFlow`）。现版升级多为 **同一 `tokenId` 原地改档**（第七节），**不等于**「mint 了新的会员 NFT id」。勿与「新 NFT 张数」混读。 |
| **两条发卡路径** | **第六节 `mintMemberCardByAdmin` vs 第七节 points 首卡** | **`mintMemberCardByAdmin` → `mintMemberCardInternal`**：owner/gateway 按 **指定 `tierIndex`** 直开卡，**不经过** points 最低档门槛。与 **points 驱动的 `_issueFromPointsDelta`**（第七节）并行存在；第六节未写明此差异，易误以为所有发卡都受同一门槛约束。 |
| **空投路径表述** | **第一节** | 典型 NFC 路径经 Factory 可能调用 **`mintPointsByAdminWithOperator`**（带 operator 与 limit），与表中单独写的 **`mintPointsByAdmin`** 并列存在；权限与统计以**实际 calldata 所选函数**为准。 |
| **两套存储体系** | **第四、五节 vs 第六节** | 第四、五节描述 **Indexer / Diamond**（`ActionFacet`、`StatsFacet`、`LibStatsStorage` 等）；第六节描述 **BeamioUserCard 本合约 `AdminStatsStorage`**。二者通过服务端 `syncTokenAction` 等对齐口径，但**非同一合约存储**；勿合并为「链上唯一账本」。 |
| **第八节对照表** | **第八节** | 行项目仍为 **业务分类 ↔ operator 规则** 速查，**未**反映 `upgradeType`、`tiers`、会员原地升级等；与第七节无矛盾，但**不包含**会员语义维度。 |

---

## 八、对照表

| 分类 | 权限主体 | operator | operatorParentChain | txCategory 示例 |
|------|----------|----------|---------------------|-----------------|
| **空投** | Admin | Admin signer | admin 的 parent 链 | usdcTopupCard (NFC) |
| **Burn** | Admin | Admin signer（可 burn 任意地址） | signer 的 parent 链 | - |
| **Redeem** | Owner 创建 | Redeem creator (owner) | creator 的 parent 链 | redeemNewCard / redeemTopupCard |
| **USDC Topup** | 用户自助 | Recommender 非零且为 admin 时 recommender，否则 owner | operator 的 parent 链 | usdcNewCard / usdcTopupCard |
