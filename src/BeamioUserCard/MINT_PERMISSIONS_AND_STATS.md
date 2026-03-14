# BeamioUserCard Mint 权限与统计口径

本文档整理 UserCard points (token #0) 的 mint 权限及 admin 维度统计口径，按空投、Redeem、USDC Topup 分类。

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
| `safeTransferFrom` / `safeBatchTransferFrom`（`POINTS_ID`） | 优先 `msg.sender`；若 `msg.sender` 为 AA 合约则回退取 `owner()` | 仅真实 token 0 转账计 `transferCount` 与 `transferAmount`，并归属到 operator 及其 parent 链 |

### 查询接口

- `getAdminMintCounter(admin)` / `getAdminBurnCounter(admin)` / `getAdminTransferCounter(admin)` / `getAdminRedeemMintCounter(admin)` / `getAdminUSDCMintCounter(admin)`：从上次 clear 起的累计
- admin/global 时间维度统计查询已从主卡 runtime 中拆出，使用 `BeamioUserCardAdminStatsQueryModuleV1` 的 ABI 对着 **同一个 card 地址** 调用：
- `getAdminHourlyData(admin, hourIndex)`：指定小时的 mint/burn/transfer/transferAmount/redeemMint/usdcMint/issued/upgraded 统计
- `getAdminPeriodReports(admin, periodType, periods, anchorTs)`：日/周/月/季/年周期报表
- `getAdminStatsFull(admin, periodType, anchorTs, cumulativeStartTs)`：**完整统计**（自己及下层 admin 聚合）
- `getGlobalStatsFull(periodType, anchorTs, cumulativeStartTs)`：**全局累计统计**（所有 admin 聚合，无分层）
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

## 七、对照表

| 分类 | 权限主体 | operator | operatorParentChain | txCategory 示例 |
|------|----------|----------|---------------------|-----------------|
| **空投** | Admin | Admin signer | admin 的 parent 链 | usdcTopupCard (NFC) |
| **Burn** | Admin | Admin signer（可 burn 任意地址） | signer 的 parent 链 | - |
| **Redeem** | Owner 创建 | Redeem creator (owner) | creator 的 parent 链 | redeemNewCard / redeemTopupCard |
| **USDC Topup** | 用户自助 | Recommender 非零且为 admin 时 recommender，否则 owner | operator 的 parent 链 | usdcNewCard / usdcTopupCard |
