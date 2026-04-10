Beamio Wallet - 交易历史模块 (Transactions History) 开发规格说明书
文档版本: v1.1 (Blockchain-Ready, Based on Architecture V6.0)
适用端: Consumer App (iOS/Android/PWA)
对应组件: BeamioTransactions.jsx
核心架构: Dual-Chain (Base L2 + CoNET L1)

## 1. 模块概述 (Overview)

交易历史页面是用户资产变动的“单一事实来源 (Source of Truth)”。它不仅展示资金流水，还承担 Smart Receipt (智能凭证) 功能。

本模块核心是双链融合：
- Base L2: 价值结算最终性 (Finality)、USDC/Voucher 资产确权
- CoNET L1: 业务元数据、社交信息、B-Units 燃料记录、审计存证

新增原则 (区块链特性):
- 最终一致，不保证瞬时一致
- 先事件、后聚合，UI 展示的是聚合视图
- 允许重组 (reorg) 后修正，不允许静默错误

### 1.1 链上拉取与缓存一致性守则（Fuel Center / B-Units Ledger）

为避免“网络故障被误判为零资产/零记录”，链上拉取必须遵循以下规则：

- **访问失败不等于零数据**：RPC 超时、网络错误、429/5xx、解析失败时，禁止将结果写成 `[]` 或 `0`。
- **仅成功空返回可清空**：只有链上成功响应且明确返回空数据时，才能信任“无记录”并清空缓存/UI。
- **交易记录永久性**：Transaction 视为永久审计记录。单次访问失败不得删除本地历史记录。
- **失败保留缓存**：链上拉取失败时必须保留缓存（stale but usable），并等待下一次成功校验。

items 拉取与渲染优先级：

1. 优先拉取并渲染新入库 items（最新时间戳/区块）
2. 优先满足当前视口与交互所必需的 items（首屏先可用）
3. 非可见历史 items 在后台小批量、长间隔补全（避免阻塞主线程）

推荐策略：

- 首屏使用本地缓存快速渲染，后台异步增量刷新。
- 对后台补全采用小批量（如 10~30 条/批）+ 较长间隔（如 100~500ms/批）。
- 若链上成功返回数据，以链上为准更新缓存；若链上失败，禁止负向覆盖缓存。

## 2. 数据结构定义 (Data Schema)

前端从 Indexer 获取标准化对象，不直接拼链上原始日志。数据分两层：`Raw` 和 `View`。

### 2.1 Raw 事件模型 (Indexer 内部/调试)

```ts
interface ChainEventRef {
  chain: 'base' | 'conet';
  chainId: number;
  txHash: string;
  blockNumber: number;
  blockTime: number;      // unix seconds
  logIndex: number;
  removed?: boolean;      // reorg 时 true
}

interface RawTransactionEvent {
  eventId: string;        // `${chainId}:${txHash}:${logIndex}`
  businessId: string;     // 业务聚合主键 (requestId/orderId/transferId)
  eventType: string;
  ref: ChainEventRef;
  payload: Record<string, unknown>;
}
```

### 2.2 View 模型 (前端消费)

```solidity
enum AssetType { ERC20, ERC1155 }
enum RouteSource {
  MainUSDC,
  UserCardPoint,
  UserCardCoupon,
  UserCardCashVoucher,
  TipAppend
}

struct RouteItem {
  address asset;                    // 资产合约地址（USDC / BeamioUserCard）
  uint256 amountE6;                 // 资产数量（E6 精度）
  AssetType assetType;              // ERC20 / ERC1155
  RouteSource source;               // 来源枚举
  uint256 tokenId;                  // ERC1155 使用；ERC20 置 0
  uint8 itemCurrencyType;           // BeamioCurrency.CurrencyType
  uint256 offsetInRequestCurrencyE6; // 对 request amount 的抵扣（E6）
}

// gas 链类型枚举：0=ETH, 1=SOLANA
enum GasChainType { ETH, SOLANA }

struct FeeInfo {
  uint16 gasChainType;                 // GasChainType 枚举值 0=ETH, 1=SOLANA
  uint256 gasWei;                      // 实际转账执行链的 gas（非 CoNET 链 gas）
  uint256 gasUSDC6;                    // gas 折算为 USDC 的 6 位精度值
  uint256 serviceUSDC6;               // 平台服务费 USDC 6 位精度
  uint256 bServiceUSDC6;               // B 服务费折算 USDC 6 位精度
  uint256 bServiceUnits6;              // B 服务费单位数（6 位精度）
  address feePayer;                    // 费用承担方地址
}

struct TransactionMeta {
  uint256 requestAmountFiat6;          // 原始请求金额（法币 E6，税前、折扣前）
  uint256 requestAmountUSDC6;          // 原始请求金额 USDC 6 位精度
  uint8 currencyFiat;                  // BeamioCurrency.CurrencyType
  uint256 discountAmountFiat6;         // 折扣金额（法币 E6）；NFC Container Charge 时表示**会员 tier 折扣** E6（与终端 metadata `tierRoutingDiscounts` 一致）
  uint16 discountRateBps;              // 折扣率 bps；NFC Container 时为 **tier 折扣率** bps。**小费**不写入本字段：小费单独 `TX_TIP` 交易，`finalRequestAmount*` 仅记小费金额
  uint256 taxAmountFiat6;              // 税金金额（法币 E6）
  uint16 taxRateBps;                   // 税率 bps，例如 500=5%
  string afterNotePayer;               // 交易完成后支付方附加备注（JSON string）
  string afterNotePayee;               // 交易完成后收款方附加备注（JSON string）
}

struct Transaction {
	bytes32 id;                       // 主支付（商户 NFC Container 等）：= Base 上本笔 `relayContainerMainRelayed`（或等价）的 **tx hash**，与 `finishedHash` 一致。**TX_TIP 小费行**：须为 **新生成的随机 bytes32**（与主支付 id 不同），供 UI 按 `id` 去重时不与小费、主单混淆
	bytes32 originalPaymentHash;      // 主支付：`0x0`。**TX_TIP 小费行**：填 **主支付行的 `id`**（即同一笔 Base relay 的 tx hash），建立父子关联；勿与小费行自身的随机 `id` 混用
	uint256 chainId;                  // 单笔请求支付所属链 ID
	bytes32 txCategory;               // 可扩展分类键（可组合原 txType + settlement 语义）
	string displayJson;               // 账单附加字符 JSON（DisplayJsonData：title, source, finishedHash, handle, forText, card；金额由本 struct 其他字段表达）
	uint64 timestamp;                 // ms 时间戳（或按实现统一为 s）
	address payer;                    // 整单支付方（根层字段）
	address payee;                    // 整单收款方（根层字段）

	// --- 金额显示层（根层仅保留最终值） ---
	uint256 finalRequestAmountFiat6;   // 主支付：不含小费（= 请求小计 ± 税/会员折扣等，见 meta）；TX_TIP 行：仅小费 fiat E6
	uint256 finalRequestAmountUSDC6; // 主支付：链上本 relay 总 USDC6 − 小费 USDC6；TX_TIP 行：仅小费 USDC6

	bool isAAAccount;                 // false=EOA, true=AA

	// --- 智能路由 ---
	RouteItem[] route;                // 原始支付凭证（EOA 可为空）
	address topAdmin;                 // top-level admin (owner or direct admin) for reporting
	address subordinate;              // terminal/subordinate that processed this tx for reporting

	// --- 费用与证明 ---
	FeeInfo fees;                     // 当前原子交易对应费用（主支付或小费各自独立结算）
	TransactionMeta meta;
}
```

**txCategory 可扩展分类键一览**（组合规则：`keccak256("<biz_type>:<phase>")` 或 `keccak256("<biz_type>")`）：

| 常量名 | 原始字符串 | 语义 |
|--------|------------|------|
| TX_MERCHANT_PAY_CONFIRMED | `merchant_pay:confirmed` | 商户支付主单确认 |
| TX_MERCHANT_PAY_TIP_UPDATED | `merchant_pay:tip_updated` | 商户支付小费追加 |
| TX_TIP | `TX_TIP` | NFC Container Charge 小费单独一条 `syncTokenAction`：`id`=随机 bytes32，`originalPaymentHash`=同一笔 Base `relayContainerMainRelayed` 的 tx hash，`finalRequestAmount*` 为小费法币 E6 与当时排价 USDC6 |
| TX_TRANSFER_IN_CONFIRMED | `transfer_in:confirmed` | 转入确认 |
| TX_TRANSFER_OUT_CONFIRMED | `transfer_out:confirmed` | 转出确认 |
| TX_TOPUP_CONFIRMED | `topup:confirmed` | 充值确认 |
| TX_INTERNAL_TRANSFER_CONFIRMED | `internal_transfer:confirmed` | 内部转账（AA↔EOA）确认 |
| TX_VOUCHER_BURN_CONFIRMED | `voucher_burn:confirmed` | 券核销确认 |
| TX_REQUEST_CREATE_CONFIRMED | `request_create:confirmed` | 请求创建确认 |
| TX_REQUEST_FULFILLED_CONFIRMED | `request_fulfilled:confirmed` | 请求履行确认 |
| TX_REQUEST_EXPIRED_CONFIRMED | `request_expired:confirmed` | 请求过期确认 |
| TX_REQUEST_CANCEL_CONFIRMED | `request_cancel:confirmed` | 请求取消确认 |
| TX_BEAMIO_USERCARD_MINT_CONFIRMED | `beamio_usercard_mint:confirmed` | BeamioUserCard mint 确认 |
| TX_USDC_NEW_CARD | `usdcNewCard` | USDC 购点触发首次发行新卡 |
| TX_USDC_UPGRADE_NEW_CARD | `usdcUpgradeNewCard` | USDC 购点触发卡等级升级 |
| TX_USDC_TOPUP_CARD | `usdcTopupCard` | USDC 常规 Top Up |
| TX_NEW_CARD | `newCard` | NFC/OTC topup 首次发行新卡 |
| TX_UPGRADE_NEW_CARD | `upgradeNewCard` | NFC/OTC topup 卡等级升级 |
| TX_TOPUP_CARD | `topupCard` | NFC/OTC 常规 Top Up |
| TX_REDEEM_NEW_CARD | `redeemNewCard` | Redeem 码首次发行新卡 |
| TX_REDEEM_UPGRADE_NEW_CARD | `redeemUpgradeNewCard` | Redeem 码卡等级升级 |
| TX_REDEEM_TOPUP_CARD | `redeemTopupCard` | Redeem 码常规 Top Up |
| TX_BUINT_CLAIM | `buintClaim` | B-Unit 免费池申领 |
| TX_BUINT_USDC | `buintUSDC` | B-Unit USDC 购买 |
| buintBurn（默认） | `buintBurn` | B-Unit 焚烧（consumeFromUser，kind 未登记时） |

> consumeFromUser 的 txCategory 为 `keccak256(kind 对应 string)`，未登记 kind 时用 `keccak256("buintBurn")`。完整常量定义见 2.3 节。

**内部转账 payer/payee 语义（API 组装必须正确）**：
- **AA→EOA（Withdraw from Express Pay）**：`payer`=AA 地址，`payee`=EOA 地址。来源：ContainerRelay / AAtoEOA。
- **EOA→AA（Add to Express Pay）**：`payer`=EOA 地址，`payee`=AA 地址。来源：BeamioTransfer（EIP-3009），客户端 note 需含 `isInternalTransfer: true`。
- UI 按 `payee` 区分：payee=EOA → Withdraw；payee=AA → Add to Express Pay。
- **强制约束**：`payer` 与 `payee` 必须不同；API 收到 from=to 时返回 400 拒绝记账。

**NFC Container Charge（`payByNfcUidSignContainer`）记账扩展**（可选 body，与 Android `MainActivity` 对齐）：
- `nfcSubtotalCurrencyAmount`：商户输入小计（法币十进制字符串，如 `"10.50"`），对应 `TransactionMeta.requestAmountFiat6`；**主单** `finalRequestAmountFiat6` / `finalRequestAmountUSDC6` 为「小计 ± 折扣/税」对应的法币 E6 与排价 USDC6，**不含小费**（链上 Container 仍一次扣 `amountUsdc6` 总额；B-Unit 仍按总额计费）。
- `nfcTipCurrencyAmount`：小费（同上）；若 `>0`，除主单外再推一条 `syncTokenAction`，`txCategory`=`keccak256("TX_TIP")`，`originalPaymentHash` 为该笔 Base relay tx hash；该条 `finalRequestAmount*` 为小费法币 E6 与排价 USDC6。**读库/UI**：小费行 `id` 为随机 bytes32，与 relay tx hash 不同；需按 `originalPaymentHash = relayTxHash` 或 `txCategory = TX_TIP` 关联主单与小费。
- `nfcTipRateBps`：小费率（整数 bps，`18%`→`1800`）。**主单** `TransactionMeta.discountAmountFiat6` / `discountRateBps` 在有小费时分别写入**小费法币 E6**与**小费 bps**（与 OpenContainer 路径里「真·折扣」字段名共用；NFC 有小费时以 tip 语义为准）。无小费时这两槽位仍可用于可选的 `nfcDiscountAmountFiat6` / `nfcDiscountRateBps`（商户折扣）。
- `nfcRequestCurrency`：法币代码（如 `CAD`），与卡 `currency()` 及 `TransactionMeta.currencyFiat` 对齐。
- 可选：`nfcDiscountAmountFiat6`、`nfcDiscountRateBps`、`nfcTaxAmountFiat6`、`nfcTaxRateBps`（字符串或数值，E6/bps 与 OpenContainer 路径一致）写入 `TransactionMeta`。

#### ABI 返回为 tuple/array 时的 positional 索引（供 TypeScript/API 组装用）

合约返回 `fees`、`meta` 时可能编码为无名 tuple，按字段声明顺序对应下标：

**FeeInfo**（下标 0～6）：
| 下标 | 变量名         | 类型    |
|-----|----------------|---------|
| 0   | gasChainType   | uint16  |
| 1   | gasWei         | uint256 |
| 2   | gasUSDC6       | uint256 |
| 3   | serviceUSDC6   | uint256 |
| 4   | bServiceUSDC6  | uint256 |
| 5   | bServiceUnits6 | uint256 |
| 6   | feePayer       | address |

**TransactionMeta**（下标 0～8）：
| 下标 | 变量名              | 类型    |
|-----|---------------------|---------|
| 0   | requestAmountFiat6  | uint256 |
| 1   | requestAmountUSDC6  | uint256 |
| 2   | currencyFiat        | uint8   |
| 3   | discountAmountFiat6 | uint256 |
| 4   | discountRateBps     | uint16  |
| 5   | taxAmountFiat6      | uint256 |
| 6   | taxRateBps          | uint16  |
| 7   | afterNotePayer      | string  |
| 8   | afterNotePayee      | string  |

说明：前端可将 `enum/bytes32` 通过索引层映射为可读字符串。

智能路由业务定义（强约束）：
- 支付方可使用 `BeamioUserCard` 发行的商业 point 作为货款抵扣来源。
- `BeamioUserCard` 的 `tokenId=0` 视为与 USDC 同层的“currency 资产”（可直接参与货款抵扣）。
- `BeamioUserCard` 还可包含特殊类资产（如抵扣券、现金券等，通常为 ERC1155 非 0 tokenId）。
- 收款方同意后，可组合一个或多个卡的 `token #0` 资产共同抵扣。
- 不足金额必须由 USDC 补足，形成一次完整支付（Voucher/NFT + USDC 混合）。
- 上述每一条路由拆分都视为“原子支付记录”，必须持久化到 `BeamioIndexerDiamond`（通过对应 Facet 写入并可追溯查询）。
- `route[]` 是原始支付凭证，落链后不可被“事后小费”直接修改。
- 小费作为独立原子交易记录，通过 `txCategory` 标识 tip 阶段，并用 `originalPaymentHash` 关联父支付。
- 交易完成后，`meta.afterNotePayer` 与 `meta.afterNotePayee` 可记录双方扩展 JSON（用于记账扩张、对账注释、审计上下文）。
- 前端 `route[]` 仅为展示视图，真实结算与审计以 `BeamioIndexerDiamond` 中的原子记录为准。
- `isAAAccount=false` 时可忽略 `route[]`（普通 EOA 转账不要求容器资产拆分）。
- `isAAAccount=true` 时必须提供 `route[]`。

### 2.3 交易类型枚举

```solidity
// 建议使用 bytes32 作为可扩展分类键（示例）
// 组合规则建议：keccak256("<biz_type>:<phase>")
bytes32 constant TX_MERCHANT_PAY_CONFIRMED   = keccak256("merchant_pay:confirmed");
bytes32 constant TX_MERCHANT_PAY_TIP_UPDATED = keccak256("merchant_pay:tip_updated");
bytes32 constant TX_TRANSFER_IN_CONFIRMED    = keccak256("transfer_in:confirmed");
bytes32 constant TX_TRANSFER_OUT_CONFIRMED   = keccak256("transfer_out:confirmed");
bytes32 constant TX_TOPUP_CONFIRMED          = keccak256("topup:confirmed");
bytes32 constant TX_INTERNAL_TRANSFER_CONFIRMED = keccak256("internal_transfer:confirmed");
bytes32 constant TX_VOUCHER_BURN_CONFIRMED   = keccak256("voucher_burn:confirmed");
bytes32 constant TX_REQUEST_CREATE_CONFIRMED = keccak256("request_create:confirmed");
bytes32 constant TX_REQUEST_FULFILLED_CONFIRMED = keccak256("request_fulfilled:confirmed");
bytes32 constant TX_REQUEST_EXPIRED_CONFIRMED = keccak256("request_expired:confirmed");
bytes32 constant TX_REQUEST_CANCEL_CONFIRMED = keccak256("request_cancel:confirmed");
bytes32 constant TX_BEAMIO_USERCARD_MINT_CONFIRMED = keccak256("beamio_usercard_mint:confirmed");
// USDC 购点（purchasingCardProcess）
bytes32 constant TX_USDC_NEW_CARD = keccak256("usdcNewCard");
bytes32 constant TX_USDC_UPGRADE_NEW_CARD = keccak256("usdcUpgradeNewCard");
bytes32 constant TX_USDC_TOPUP_CARD = keccak256("usdcTopupCard");
// NFC/OTC topup（executeForAdminProcess）
bytes32 constant TX_NEW_CARD = keccak256("newCard");
bytes32 constant TX_UPGRADE_NEW_CARD = keccak256("upgradeNewCard");
bytes32 constant TX_TOPUP_CARD = keccak256("topupCard");
// Redeem 码（cardRedeemIndexerAccountingProcess）
bytes32 constant TX_REDEEM_NEW_CARD = keccak256("redeemNewCard");
bytes32 constant TX_REDEEM_UPGRADE_NEW_CARD = keccak256("redeemUpgradeNewCard");
bytes32 constant TX_REDEEM_TOPUP_CARD = keccak256("redeemTopupCard");
// B-Unit 免费池申领（BUnitAirdrop claim/claimFor 成功后记账）
bytes32 constant TX_BUINT_CLAIM = keccak256("buintClaim");
// B-Unit USDC 购买（BUnitAirdrop mintForUsdcPurchase 成功后记账）
bytes32 constant TX_BUINT_USDC = keccak256("buintUSDC");
```

#### 2.3.1 BeamioUserCard Mint Role 约束

卡 mint 必须使用固定分类键 `TX_BEAMIO_USERCARD_MINT_CONFIRMED`，不得与普通转账复用分类值。

角色语义（用于索引与统计）：
- `asset`：必须是目标 `BeamioUserCard` 合约地址。
- `payee`：mint 接收地址（统计“mint 钱包地址数”时按 `payee` 去重）。
- `payer`：可记录为发起方/系统执行方（不作为 mint 钱包去重口径）。
- `chainId`：必须写真实发生链 ID，供 `chainIdFilter` 精确过滤。

与查询接口对应关系：
- `getBeamioUserCardMintStatsBy*` 的 `mintTxCategoryFilter` 必须传 `TX_BEAMIO_USERCARD_MINT_CONFIRMED`。
- `mintTxTotal` 统计该分类命中交易数；`mintWalletCount` 按窗口内 `payee` 去重计数。

#### 2.3.2 BUnit Claim 记账（buintClaim）

BUnitAirdrop 在 claim/claimFor 成功后向 BeamioIndexerDiamond 调用 `syncTokenAction` 记账。

**数据来源**：BUnitAirdrop（部署地址见 `deployments/conet-BUintAirdrop.json`），BeamioIndexerDiamond 地址见 `deployments/conet-addresses.json`（当前 `0xd990719B2f05ccab4Acdd5D7A3f7aDfd2Fc584Fe`）。

**Transaction 字段**：

| 字段 | 值 |
|------|-----|
| txCategory | `keccak256("buintClaim")` |
| chainId | 224400（CoNET 主网） |
| payer | BUint 合约地址 |
| payee | claimant（申领人） |
| finalRequestAmountFiat6 | claimAmount（BUnitAirdrop.claimAmount，6 位精度） |
| route | 空数组 |
| isAAAccount | false |

**权限**：BUnitAirdrop 需为 BeamioIndexerDiamond 的 admin（`AdminFacet.setAdmin(BUnitAirdrop, true)`），否则 syncTokenAction 调用失败（BUnitAirdrop 使用 try/catch，失败不阻塞 claim）。

**USDC 购买（buintUSDC）**：`mintForUsdcPurchase(to, bunitAmount)` 成功后同样记账，txCategory=`keccak256("buintUSDC")`，payer=BUint，payee=to，finalRequestAmountFiat6=bunitAmount，route 为空。

**焚烧（consumeFromUser）**：`consumeFromUser(user, amount, baseHash, baseGas, kind)` 成功后记账，txCategory=`keccak256(kind 对应 string)`（未登记 kind 时用 `keccak256("buintBurn")`），payer=user，payee=BUint，finalRequestAmountFiat6=焚烧总额 amount，finalRequestAmountUSDC6=焚烧付费池 paidBurned，fees 含 baseGas/gasUSDC/feePayer=user。

#### 2.3.3 Top Up 记账规则（purchasingCardProcess）

Top Up 业务按入口使用以下 `txCategory`：

**USDC 购点**（purchasingCardProcess）：
- 首次发行新卡：`keccak256("usdcNewCard")`
- Top Up 导致升级：`keccak256("usdcUpgradeNewCard")`
- 其余普通 Top Up：`keccak256("usdcTopupCard")`

**NFC/OTC topup**（executeForAdminProcess）：
- 首次发行新卡：`keccak256("newCard")`
- Top Up 导致升级：`keccak256("upgradeNewCard")`
- 其余普通 Top Up：`keccak256("topupCard")`

**Redeem 码**（cardRedeemIndexerAccountingProcess）：
- 首次发行新卡：`keccak256("redeemNewCard")`
- Top Up 导致升级：`keccak256("redeemUpgradeNewCard")`
- 其余普通 Top Up：`keccak256("redeemTopupCard")`

`TransactionMeta` 记账口径（Top Up 专用）：

- `meta.discountAmountFiat6`：记录 `beforePoint`（本次 Top Up 前用户 points 余额，E6）
- `meta.requestAmountFiat6`：记录 `currentTopupPoint`（本次 Top Up 增加的 points，E6）
- `meta.requestAmountUSDC6`：记录本次 Top Up 的 USDC 金额（E6）

**Top Up 专用 RouteItem 守则**（USDC 购点、OTC/NFT 卡 topup 均须遵守）：

| 字段 | 值 | 说明 |
|------|-----|------|
| `asset` | 该 Top Up 卡（BeamioUserCard）合约地址 | 必填 |
| `assetType` | `1`（ERC1155） | 固定 |
| `source` | `RouteSource.UserCardPoint`（枚举值 1） | 固定；Top Up 分类由 txCategory 区分 |
| `tokenId` | 用户新发行的 NFT 卡号，或已持有的 NFT 卡号 | upgrade 时填入**新获得的** NFT 卡号 |
| `itemCurrencyType` | 该卡 metadata 中的 `currency`（BeamioCurrency.CurrencyType） | 必填 |
| `amountE6` | Top Up 时 currency 的 amount（E6 精度） | 即本次增加的 points |
| `offsetInRequestCurrencyE6` | `0` | 固定 |

说明：以上 RouteItem 使 BeamioIndexerDiamond 能按 BeamioUserCard 维度索引 Top Up 交易，支持 OTC（NFT 卡）topup、redeem 码兑换与 USDC 购点统一记账口径。Top Up 细分由 txCategory 表达（usdcNewCard/usdcUpgradeNewCard/usdcTopupCard、newCard/upgradeNewCard/topupCard、redeemNewCard/redeemUpgradeNewCard/redeemTopupCard）。

ethers.js 调用示例（mintTxCategoryFilter + chainIdFilter）：

```ts
import { ethers } from "ethers";

// 仅示例：请替换为实际 RPC、Diamond 地址与 ABI
const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const indexer = new ethers.Contract(process.env.BEAMIO_INDEXER_DIAMOND!, [
  "function getBeamioUserCardMintStatsByWeekOffset(address beamioUserCard,uint256 periodOffset,bytes32 mintTxCategoryFilter,uint8 accountMode,uint256 chainIdFilter) view returns ((uint256 mintTxTotal,uint256 mintWalletCount,uint256 periodStart,uint256 periodEnd))",
], provider);

// 约定的卡 mint 分类键（必须与写入端一致）
const mintTxCategoryFilter = ethers.keccak256(
  ethers.toUtf8Bytes("beamio_usercard_mint:confirmed")
);

// chainIdFilter 语义：
// 1) 不过滤：uint256.max
const CHAIN_ID_FILTER_ALL = ethers.MaxUint256;
// 2) 精确过滤：例如 Base 主网 chainId=8453（按你的实际链替换）
const CHAIN_ID_FILTER_BASE = 8453n;

async function queryMintStats() {
  const beamioUserCard = "0xYourBeamioUserCardAddress";
  const periodOffset = 0n; // 0=本周,1=上周...
  const accountMode = 0;   // 0=ALL,1=EOA,2=AA

  // 示例 A：不过滤 chainId
  const allChains = await indexer.getBeamioUserCardMintStatsByWeekOffset(
    beamioUserCard,
    periodOffset,
    mintTxCategoryFilter,
    accountMode,
    CHAIN_ID_FILTER_ALL
  );

  // 示例 B：仅统计指定 chainId
  const baseOnly = await indexer.getBeamioUserCardMintStatsByWeekOffset(
    beamioUserCard,
    periodOffset,
    mintTxCategoryFilter,
    accountMode,
    CHAIN_ID_FILTER_BASE
  );

  console.log("allChains:", allChains);
  console.log("baseOnly:", baseOnly);
}
```

### 2.4 小时原子统计与商业报表模型

链上统计以“小时桶”作为最小原子单位，所有日/周/月/季/年报表都由小时桶聚合而来，避免重复口径和精度漂移。

**Admin 维度统计**：当 `syncTokenAction` 传入 `operator != address(0)` 且 route 含 `UserCardPoint` 时，自动按 admin 地址记录 token #0 (points) 的 mint/burn 到 `adminHourlyData`。可通过 `getAggregatedStats(mode=3, admin, startTs, endTs)` 或 `getBusinessPeriodReports(mode=3, admin, periodType, periods, anchorTs)` 按时/日/周/月/季/年聚合查询。

```ts
interface HourlyStats {
  nftMinted: number;
  tokenMinted: number;
  tokenBurned: number;
  transferCount: number;
  hasData: boolean;
}

interface AggregatedStats {
  totalNftMinted: number;
  totalTokenMinted: number;
  totalTokenBurned: number;
  totalTransfers: number;
}

interface PeriodReport {
  periodStart: number;    // UTC 起始秒级时间戳（含）
  periodEnd: number;      // UTC 结束秒级时间戳（含）
  stats: AggregatedStats;
}
```

### 2.5 BeamioUserCard Mint 权限与统计口径

UserCard points (token #0) 的 mint 权限及 admin 维度统计口径，按空投、Redeem、USDC Topup 分类。

#### 2.5.1 空投 (Admin Airdrop)

| 项目 | 说明 |
|------|------|
| **权限** | Admin 离线签 `ExecuteForAdmin`，Factory 校验 `card.isAdmin(signer)` |
| **入口** | `mintPointsByAdmin`，经 `executeForAdmin` |
| **operator** | Admin signer |
| **operatorParentChain** | 从 `card.adminParent(operator)` 向上追溯的 parent 链 |
| **txCategory 示例** | usdcTopupCard (NFC)、newCard、topupCard |

#### 2.5.2 Redeem 兑换

| 项目 | 说明 |
|------|------|
| **权限** | 仅 card owner 可创建 redeem（`executeForOwner`）；任意用户可兑换 |
| **入口** | `createRedeem*`（创建）→ `redeemForUser`（兑换） |
| **operator** | `getRedeemCreator(code)`（创建者），无则用 card owner |
| **operatorParentChain** | creator/owner 的 parent 链 |
| **txCategory 示例** | redeemNewCard、redeemUpgradeNewCard、redeemTopupCard |

#### 2.5.3 USDC Topup

| 项目 | 说明 |
|------|------|
| **权限** | 用户签 EIP-3009 授权 USDC，Factory 调用 `buyPointsForUser`；可选 `recommender`，若传则**必须为 card admin** |
| **入口** | `buyPointsForUser`，经 `/api/purchasingCard` 或 `/api/usdcTopup` |
| **operator** | Recommender 非零且为 admin 时 = recommender；否则 = Card owner |
| **operatorParentChain** | operator 的 parent 链 |
| **Recommender 规则** | 为零时只计入 owner 链；非零时必须为 admin，计入该 admin 的统计口径 |
| **txCategory 示例** | usdcNewCard、usdcUpgradeNewCard、usdcTopupCard |

#### 2.5.4 统计规则 (ActionFacet)

当 `syncTokenAction` 传入 `operator != address(0)` 且 route 含 `source == UserCardPoint` 时：

- 对 route 中每条 `UserCardPoint` 的 `amountE6` 累加到 `token0Mint`
- 调用 `_recordAdminToken0Stats(ts, operator, token0Mint, token0Burn)` 写入 `adminHourlyData[operator]`
- 对 `operatorParentChain` 中每个非零地址同样调用 `_recordAdminToken0Stats`

**查询**：`StatsFacet.getAggregatedStats(mode=3, admin, startTs, endTs)` 或 `getBusinessPeriodReports(mode=3, admin, ...)`

#### 2.5.5 对照表

| 分类 | 权限主体 | operator | operatorParentChain |
|------|----------|----------|---------------------|
| **空投** | Admin | Admin signer | admin 的 parent 链 |
| **Redeem** | Owner 创建 | Redeem creator (owner) | creator 的 parent 链 |
| **USDC Topup** | 用户自助 | Recommender 非零且为 admin 时 recommender，否则 owner | operator 的 parent 链 |

## 3. 区块链规则 (Blockchain Rules)

## 3. 区块链规则 (Blockchain Rules)

### 3.1 确认数与最终性

- `pending`: 交易已广播或仅 mempool 感知，未入块
- `confirmed`: 已入块但未达最终性阈值
- `finalized`: 达到配置阈值

建议阈值（可配置）：
- Base L2: `finalityDepthBase = 12`
- CoNET L1: `finalityDepthConet = 20`

UI 规则：
- 当 `txCategory` 表示非最终态时，需显示“处理中”语义，不得渲染为不可逆完成

### 3.2 重组 (Reorg) 处理

- Indexer 必须处理 `removed=true` 日志并回滚聚合结果
- 被重组交易需记录替代链路（可通过 `businessId` + `txHash` 关联，或额外 reorg 标记字段）
- 若后续替代交易成立，复用 `businessId` 并生成新 `id`
- 不允许仅靠本地缓存“掩盖”重组

### 3.3 幂等与去重

- 事件幂等键: `${chainId}:${txHash}:${logIndex}`
- 业务幂等键: `businessId`
- 同一事件重复消费不得造成重复交易条目
- Transaction ID 规范：`Transaction.id` 必须为 bytes32，并以整单 `txHash` 作为唯一依据（可直接使用 txHash；若跨链需统一编码，必须保持可逆映射到原 txHash）
- 多基础设施兼容：`BeamioIndexerDiamond` 可支持多链基础设施；但单笔请求支付记录必须落在单一 `chainId` 上，不做跨多链拆单结算

### 3.4 双链冲突裁决

- 价值字段（`amountUSDC*`, 资产增减）以 Base L2 为准
- 元数据字段（B-Units、社交备注）以 CoNET L1 为准
- 若冲突无法自动裁决，打 `meta.conflict=true`（可选），并降级为审计态展示

### 3.5 时间与排序

- 排序主键: `timestamp desc`
- 同时间戳冲突时: `blockNumber desc -> logIndex desc -> txHash desc`
- 不允许使用客户端本地时间写入链上交易时间

### 3.6 统计时间桶与周期对齐规则

- 原子时间桶定义：`hourIndex = floor(timestamp / 3600)`
- 所有统计写入必须落到对应 `hourIndex`，禁止直接写“日报/月报”累计值
- 周期必须使用 UTC 对齐，避免时区导致报表偏移：
  - Day: UTC `00:00:00` 开始
  - Week: UTC 周一 `00:00:00` 开始
  - Month: 每月 1 日 UTC `00:00:00` 开始
  - Quarter: 1/4/7/10 月 1 日 UTC `00:00:00` 开始
  - Year: 1 月 1 日 UTC `00:00:00` 开始
- 月/季/年必须按真实日历计算，不能用固定 30/90/365 天近似
- 推荐最大查询窗口：
  - 小时聚合窗口 `MAX_HOURS >= 24 * 366`（至少覆盖 1 年，建议更高）
  - 报表返回周期数 `MAX_PERIODS` 需限制（例如 120）

## 4. 业务逻辑与状态机 (Business Logic)

### 4.1 费用逻辑 (Fee Strategy)

C 端消费/转账 (Strictly Free):
- `merchant_pay`, `transfer_out` 的 `fees.service` 必须显示 `$0.00`
- Gas Fee 显示 `Sponsored`

金额构造口径（展示层）：
- `meta.requestAmountFiat6`: 原始请求金额（税前、折扣前）
- `meta.discountAmountFiat6`: 折扣金额
- `meta.discountRateBps`: 折扣率（bps）
- `meta.taxAmountFiat6`: 税金金额
- `meta.taxRateBps`: 税率（bps）
- `finalRequestAmountFiat6`: 最终请求金额（用于对账与展示）
- 推荐计算顺序：`finalRequestAmountFiat6 = meta.requestAmountFiat6 - meta.discountAmountFiat6 + meta.taxAmountFiat6`
- 金额字段统一使用 E6 语境，链上与索引层按 6 位精度结算
- 小费 (tip) 规则：小费为“事后修改”能力，作用在既有原子记录上（增量更新），不是新建一笔独立主交易
- 凭证不可变规则：原始支付凭证 `route[]` 保持不可变；小费以独立原子交易追加（不改写原交易）。

工具调用 (Pay-with-Fuel):
- `request_create` 不扣 USDC，扣 `bServiceUnits6`
- 详情页高亮 `Fuel Cost: -5 B-Units`
- 不可退款原则: 即使 `request_expired`，已消耗 `bServiceUnits6` 不退还

### 4.2 收款请求生命周期 (Payment Request Lifecycle)

- Waiting: 用户创建 QR/Link，记录类型为 `request_create`
- Received: 对方支付成功，生成 `request_fulfilled`
- Expired: TTL 到期或手动取消，记录类型为 `request_expired`

注意:
- 本规范不再单独维护 `status` 字段；业务阶段与确认语义统一由 `txCategory`（bytes32）组合表达

### 4.3 账户过滤逻辑 (Tab Logic)

- Cash Tab: 优先显示 `isAAAccount=false`，并包含 `isAAAccount=true` 中以 `ERC20` 为主的交易
- Vouchers Tab: 显示 `isAAAccount=true` 且存在 `ERC1155` 路由的交易
- All Tab: 全量交易（EOA + AA）

## 5. UI 视觉规范 (Visual Specs)

为保证快速识别交易性质，遵循以下语义：

- Merchant Pay: Blue / `CreditCard`
- Transfer In: Green / `ArrowDownLeft`
- Request Fulfilled: Green / `QrCode`
- Transfer Out: Black / `ArrowUpRight`
- Request Create: Orange / `QrCode`
- Request Expired: Gray / `XCircle`
- Internal/Topup: Neutral / `ArrowRightLeft`
- Voucher: Purple / `Ticket`

补充：
- 当 `txCategory` 为处理中阶段时增加次级状态提示（如小圆点或 badge）
- `reorged` 必须可见（灰红色提示），防止用户误判“已完成”

## 6. 交互流程与细节 (Interactions)

### 6.1 详情页模态框 (Detail Modal)

必须包含：
- Smart Routing 可视化（当 `route.length > 1` 时展示）
- Proof of Settlement:
  - 已成交：显示 Base L2 Hash（可复制）
  - 处理中：显示 Base L2 Pending 占位
  - 始终显示 CoNET L1 Hash
- JSON View: 提供 `View Smart Receipt`，展示原始对象

建议新增：
- 显示 `txCategory` 对应阶段（例如 `confirmed` / `tip_updated` / `reorged`）
- 显示关联原子交易数量（例如按 `businessId` 聚合计数）

### 6.2 操作按钮 (Action Buttons)

- `merchant_pay`: `Add Tip` + `Chat`
- `request_create (Waiting)`: `Share Again` + `Cancel Request`
- `request_expired`: `Create New Request`

## 7. Indexer 与 API 约束 (工程落地)

### 7.1 数据摄取

- 至少一次投递 (at-least-once) 是常态，必须做幂等
- 支持回补扫描（按区块范围重扫）
- 支持断点续扫（保存每条链最新安全块高）

### 7.2 API 响应约束

- 列表接口默认返回聚合 View，不返回原始日志拼接片段
- 必须支持分页与游标（避免按页码在重组后错页）
- 字段不可静默删除；新增字段需向后兼容

### 7.3 可观测性

- 必须记录聚合日志：`businessId`, `sourceEventIds`, `finalTransactionId`
- 出现冲突或重组时打结构化告警

### 7.4 StatsFacet 接口约束（Diamond 承载）

`BeamioIndexerDiamond` 作为代理壳，统计能力通过 `StatsFacet` 暴露，建议至少提供以下接口：

```solidity
// 原子小时桶查询
function getAtomicHourStats(uint8 mode, address account, uint256 hourIndex)
  external view returns (HourlyStats memory);

// 区间聚合（小时桶累加）
function getAggregatedStats(
  uint8 mode,
  address account,
  uint256 startTimestamp,
  uint256 endTimestamp
) external view returns (AggregatedStats memory);

// 商业周期报表
function getBusinessPeriodReports(
  uint8 mode,
  address account,
  uint8 periodType,   // 1=日,2=周,3=月,4=季度,5=年
  uint256 periods,
  uint256 anchorTs    // 0 表示 block.timestamp
) external view returns (PeriodReport[] memory);
```

参数规范：
- `mode`: `0=全局`, `1=按 card`, `2=按 user`
- `mode=1/2` 时必须传对应 `account`，`mode=0` 可传 `address(0)`
- `periods` 必须限制上限（防止超大查询导致节点超时）
- 当 `endTimestamp < startTimestamp` 时返回空统计，不应 revert
- 对超范围小时查询必须显式报错（如 `range too large`）

### 7.5 ActionFacet 新结构接口约束（已移除旧结构）

为避免混乱，`BeamioIndexerDiamond` 的 `ActionFacet` 已统一为 `TransactionRecord` 主结构，旧 `Action/ActionMeta` 与对应查询接口已废弃，不再作为对外规范。

当前接口约束如下（与合约实现对齐）：

```solidity
// 写入：仅接受新结构 TransactionInput
function syncTokenAction(TransactionInput calldata in_)
  external returns (uint256 actionId);

// 主查询
function getTransactionCount() external view returns (uint256);
function getTransactionRecord(uint256 actionId)
  external view returns (TransactionRecord memory tx_, RouteItem[] memory route_);
function getTransactionRecordByTxId(bytes32 txId)
  external view returns (TransactionRecord memory tx_, RouteItem[] memory route_);
function getTransactionActionId(bytes32 txId)
  external view returns (uint256 actionId, bool exists);

// 按账户（payer/payee）查询
function getAccountActionCount(address account) external view returns (uint256);
function getAccountActionIdsPaged(address account, uint256 offset, uint256 limit)
  external view returns (uint256[] memory);
function getAccountTransactionsPaged(address account, uint256 offset, uint256 limit)
  external view returns (TransactionRecord[] memory);

// 全局最新分页（非账户维度）
function getLatestTransactionsPaged(uint256 offset, uint256 limit)
  external view returns (uint256 total, TransactionRecord[] memory page);
function getLatestTransactionsPagedFull(uint256 offset, uint256 limit)
  external view returns (uint256 total, Transaction[] memory page);

// 按分类 txCategory 的全局最新分页（bytes32(0)=不过滤）
function getLatestTransactionsByCategoryPaged(bytes32 txCategoryFilter, uint256 offset, uint256 limit)
  external view returns (uint256 total, TransactionRecord[] memory page);
function getLatestTransactionsByCategoryPagedFull(bytes32 txCategoryFilter, uint256 offset, uint256 limit)
  external view returns (uint256 total, Transaction[] memory page);

// 按时间桶 + 分类筛选
function getAccountActionIdsByPeriodPaged(
  address account,
  uint8 periodType,      // 0=小时,1=日,2=周,3=月,4=季度,5=年
  uint256 anchorTs,      // 0=block.timestamp
  uint256 offset,
  uint256 limit,
  bytes32 txCategoryFilter, // bytes32(0)=不过滤
  uint16 gasChainTypeFilter, // uint16.max=不过滤,0=ETH,1=SOLANA
  uint256 chainIdFilter      // uint256.max=不过滤, 否则按 tx.chainId 精确匹配
) external view returns (
  uint256 total,
  uint256 periodStart,
  uint256 periodEnd,
  uint256[] memory page
);

function getAccountTransactionsByPeriodPaged(
  address account,
  uint8 periodType,
  uint256 anchorTs,
  uint256 offset,
  uint256 limit,
  bytes32 txCategoryFilter,
  uint16 gasChainTypeFilter, // uint16.max=不过滤,0=ETH,1=SOLANA
  uint256 chainIdFilter      // uint256.max=不过滤, 否则按 tx.chainId 精确匹配
) external view returns (
  uint256 total,
  uint256 periodStart,
  uint256 periodEnd,
  TransactionRecord[] memory page
);

// 交易后备注更新（仅新字段）
function setAfterNotes(uint256 actionId, string calldata afterNotePayer, string calldata afterNotePayee) external;
```

说明：
- 账户维度索引以 `payer/payee` 为准，不再区分旧的 `userActions/cardActions`。
- 分类筛选以 `txCategory` 为准，不再使用 `actionType`。
- `actionId` 仅作为链上顺序索引；业务唯一性依赖 `Transaction.id(txHash)`。

### 7.5.0 分页 `offset` 语义：账户 vs 卡资产（严禁混用）

**背景（2026-04 踩坑复盘）**：链上 CoNET Indexer 已写入最新 Top-Up / Charge（如 `getAccountActionCount` 已增长、`finalRequestAmountFiat6` 正确），但 Merchant OS / Web 客户端账本**长时间不出现最新行**。根因多为：**把 `getAccountTransactionsPaged` 当成与 `getAssetTransactionsPaged` 同一套 offset 方向**，导致首轮 RPC **跳过账户索引中「最新」若干条**。

两类接口在合约中的实现**不一致**（必须以源码为准，不可凭直觉统一成「都从 `total - limit` 起算」）：

| 接口 | Facet | 实现要点 | **`offset = 0` 时** | 从新到旧拉满一页再翻页 |
|------|--------|----------|---------------------|-------------------------|
| `getAccountTransactionsPaged(account, offset, limit)` | `ActionFacet` | `revIndex = total - 1 - (offset + i)`，再取 `txRecordByActionId[ids[revIndex]]` | **当前账户下最新一条** | `offset` **从 0 递增**，`limit` 为页大小，直到 `offset >= total` |
| `getAssetTransactionsPaged(asset, offset, limit)` | `BeamioUserCardStatsFacet` | `ids` 为**追加序**（下标小 = 更旧），`page[i] = txRecordByActionId[ids[offset + i]]` | **该资产下最旧一条** | 取「最新一页」应 **`offset = total - limit`**（且 `limit <= total`），再向更小 `offset` 翻页 |

**错误模式**：对 **账户** 接口使用 **`offset = total - limit`** 作为首页 → 首轮即**丢弃** `ids` 尾部（最新）的 `total - limit` 条之前的所有**更新**都可能进不了首屏合并；若再配合「本地重复 id 提前停止翻页」，表现即为**链上有、客户端无**。

**推荐自检**：

- **账户**：探针 / 单元对照应调用 `getAccountTransactionsPaged(account, 0, N)`，首条时间戳与金额应与产品侧「最后一笔」一致。仓库脚本：`scripts/ledgerProbeIndexerAccount.mjs`（账户维度固定 `offset=0` 展示最新窗口，避免排查误判）。
- **卡资产**：最新窗口使用 `getAssetTransactionsPaged(asset, max(0, total - N), N)`（或与合约一致的尾向分页循环）。
- **多端实现**：同一产品内若同时拉账户与资产，须在注释与常量区**显式标注**两种 offset 方向，禁止复制粘贴同一套 `for` 循环变量名而不改语义。

**源码锚点**：`src/CoNETIndexTaskdiamond/facets/ActionFacet.sol` — `getAccountTransactionsPaged`；`src/CoNETIndexTaskdiamond/facets/BeamioUserCardStatsFacet.sol` — `getAssetTransactionsPaged`。

### 7.5.1 FeeStatsFacet TopN 接口约束（bServiceUnits6）

用于回答两类问题：
- `bServiceUnits6` 转账次数前 N 地址（按 `feePayer` 统计，且仅统计 `bServiceUnits6 > 0` 的交易笔数）
- 持有/消耗 `bServiceUnits6` 累计值前 N 地址（按 `feePayer` 汇总窗口内 `bServiceUnits6`）

接口（与当前合约实现对齐）：

```solidity
function getBServiceTopNByCurrentPeriodOffset(
  uint8 periodType,          // 0=小时,1=日,2=周,3=月,4=季度,5=年
  uint256 periodOffset,      // 0=当前周期,1=上一周期,n=向前第 n 个周期
  uint256 topN,              // 返回前 N 名
  bytes32 txCategoryFilter,  // bytes32(0)=不过滤
  uint8 accountMode,         // 0=ALL,1=EOA,2=AA
  uint16 gasChainTypeFilter, // uint16.max=不过滤,0=ETH,1=SOLANA
  uint256 chainIdFilter      // uint256.max=不过滤, 否则按 tx.chainId 精确匹配
) external view returns (
  uint256 periodStart,
  uint256 periodEnd,
  address[] memory topTxCountAccounts,
  uint256[] memory topTxCounts,
  address[] memory topUnitsAccounts,
  uint256[] memory topUnits6
);
```

便捷接口：

```solidity
function getBServiceTopNByHourOffset(uint256 periodOffset, uint256 topN, bytes32 txCategoryFilter, uint8 accountMode, uint16 gasChainTypeFilter, uint256 chainIdFilter) external view returns (...);
function getBServiceTopNByDayOffset(uint256 periodOffset, uint256 topN, bytes32 txCategoryFilter, uint8 accountMode, uint16 gasChainTypeFilter, uint256 chainIdFilter) external view returns (...);
function getBServiceTopNByWeekOffset(uint256 periodOffset, uint256 topN, bytes32 txCategoryFilter, uint8 accountMode, uint16 gasChainTypeFilter, uint256 chainIdFilter) external view returns (...);
function getBServiceTopNByMonthOffset(uint256 periodOffset, uint256 topN, bytes32 txCategoryFilter, uint8 accountMode, uint16 gasChainTypeFilter, uint256 chainIdFilter) external view returns (...);
function getBServiceTopNByQuarterOffset(uint256 periodOffset, uint256 topN, bytes32 txCategoryFilter, uint8 accountMode, uint16 gasChainTypeFilter, uint256 chainIdFilter) external view returns (...);
function getBServiceTopNByYearOffset(uint256 periodOffset, uint256 topN, bytes32 txCategoryFilter, uint8 accountMode, uint16 gasChainTypeFilter, uint256 chainIdFilter) external view returns (...);
```

口径说明：
- 排名主体是 `FeeInfo.feePayer`，不是 `payer/payee`。
- `topTxCounts`：窗口内满足过滤条件且 `bServiceUnits6 > 0` 的交易笔数。
- `topUnits6`：窗口内满足过滤条件的 `bServiceUnits6` 累计值（E6）。
- 返回数组按降序排列；长度可能小于 `topN`（当有效地址不足时）。
- `periodType + periodOffset` 为“离散周期窗口”查询，不是 rolling 连续窗口。
- `gasChainTypeFilter`：`uint16.max` 表示不过滤；`0=ETH`，`1=SOLANA`。
- `chainIdFilter`：`uint256.max` 表示不过滤；其他值按 `Transaction.chainId` 精确过滤。

参数示例：
- 查询“本周”Top 20：`periodType=2, periodOffset=0, topN=20`
- 查询“上周”Top 10：`periodType=2, periodOffset=1, topN=10`
- 查询“过去第 6 个小时窗口”Top 5：`periodType=0, periodOffset=6, topN=5`
- 不按分类过滤：`txCategoryFilter = bytes32(0)`
- 仅看 AA：`accountMode = 2`；仅看 EOA：`accountMode = 1`；全量：`accountMode = 0`

### 7.5.2 FeeStats 分页统计 + BeamioUserCardStats 周期查询的 chainId 约束

当前实现已统一要求周期查询显式传入 `chainIdFilter`：

- `chainIdFilter = uint256.max`：不过滤 `chainId`
- `chainIdFilter = x (>0)`：仅匹配 `Transaction.chainId == x`

FeeStats（非 TopN）分页统计接口：

```solidity
function getAccountBServiceStatsByCurrentPeriodOffsetPaged(
  address account,
  uint8 periodType,
  uint256 periodOffset,
  uint256 pageOffset,
  uint256 pageLimit,
  bytes32 txCategoryFilter,
  uint8 accountMode,
  uint256 chainIdFilter
) external view returns (FeeStatsPage memory out);
```

BeamioUserCardStatsFacet 周期查询接口（示例）：

```solidity
function getAssetTransactionsByCurrentPeriodOffsetAndAccountModePaged(
  address asset,
  address account,
  uint8 periodType,
  uint256 periodOffset,
  uint256 pageOffset,
  uint256 pageLimit,
  bytes32 txCategoryFilter,
  uint8 accountMode,
  uint256 chainIdFilter
) external view returns (...);

function getAssetTokenTransactionsByCurrentPeriodOffsetAndAccountModePaged(
  address asset,
  uint256 tokenId,
  address account,
  uint8 periodType,
  uint256 periodOffset,
  uint256 pageOffset,
  uint256 pageLimit,
  bytes32 txCategoryFilter,
  uint8 accountMode,
  uint256 chainIdFilter
) external view returns (...);

function getBeamioUserCardTransactionStatsByCurrentPeriodOffset(
  address beamioUserCard,
  uint8 periodType,
  uint256 periodOffset,
  bytes32 txCategoryFilter,
  uint8 accountMode,
  uint256 chainIdFilter
) external view returns (uint256 total, uint256 periodStart, uint256 periodEnd);
```

### 7.5.3 BeamioUserCard tokenId 维度 mint 统计接口

用于查询“某一张卡在时间窗口内，按 NFT `tokenId` 维度”的 mint 统计（总笔数 + 钱包地址去重数）。

返回结构：

```solidity
struct MintStats {
  uint256 mintTxTotal;    // mint 总交易数
  uint256 mintWalletCount; // mint 钱包地址数（按 payee 去重）
  uint256 periodStart;
  uint256 periodEnd;
}
```

主接口：

```solidity
function getBeamioUserCardTokenMintStatsByCurrentPeriodOffset(
  address beamioUserCard,
  uint256 tokenId,            // 例如 NFT#0 传 0，NFT#1 传 1
  uint8 periodType,           // 0=小时,1=日,2=周,3=月,4=季度,5=年
  uint256 periodOffset,       // 0=当前周期,1=上一周期,n=向前第 n 个周期
  bytes32 mintTxCategoryFilter, // 必须传 mint 分类键（不可为 0）
  uint8 accountMode,          // 0=ALL,1=EOA,2=AA
  uint256 chainIdFilter       // uint256.max=不过滤, 否则按 tx.chainId 精确匹配
) external view returns (MintStats memory out);
```

便捷接口：

```solidity
function getBeamioUserCardTokenMintStatsByHourOffset(address beamioUserCard, uint256 tokenId, uint256 periodOffset, bytes32 mintTxCategoryFilter, uint8 accountMode, uint256 chainIdFilter) external view returns (MintStats memory out);
function getBeamioUserCardTokenMintStatsByDayOffset(address beamioUserCard, uint256 tokenId, uint256 periodOffset, bytes32 mintTxCategoryFilter, uint8 accountMode, uint256 chainIdFilter) external view returns (MintStats memory out);
function getBeamioUserCardTokenMintStatsByWeekOffset(address beamioUserCard, uint256 tokenId, uint256 periodOffset, bytes32 mintTxCategoryFilter, uint8 accountMode, uint256 chainIdFilter) external view returns (MintStats memory out);
function getBeamioUserCardTokenMintStatsByMonthOffset(address beamioUserCard, uint256 tokenId, uint256 periodOffset, bytes32 mintTxCategoryFilter, uint8 accountMode, uint256 chainIdFilter) external view returns (MintStats memory out);
function getBeamioUserCardTokenMintStatsByQuarterOffset(address beamioUserCard, uint256 tokenId, uint256 periodOffset, bytes32 mintTxCategoryFilter, uint8 accountMode, uint256 chainIdFilter) external view returns (MintStats memory out);
function getBeamioUserCardTokenMintStatsByYearOffset(address beamioUserCard, uint256 tokenId, uint256 periodOffset, bytes32 mintTxCategoryFilter, uint8 accountMode, uint256 chainIdFilter) external view returns (MintStats memory out);
```

口径说明：
- `mintTxCategoryFilter` 必须与写入端 mint 分类键一致（例如 `keccak256("beamio_usercard_mint:confirmed")`）。
- `mintWalletCount` 按窗口内命中记录的 `payee` 地址去重统计。
- 统计底层按 `(beamioUserCard, tokenId)` 索引执行，不是先全卡后前端过滤。

### 7.6 智能路由原子记录落库约束

- 执行入口约束：支付方通过 AA 账户模块 `BeamioContainerModuleV07.containerMainRelayedOpen(...)` 提交 `ContainerItem[]`，作为混合支付的链上原子输入。
- 单笔交易 hash 约束：一次 `ContainerItem[]` 聚合支付仅对应一个链上 `payment txHash`；若存在事后小费，可追加一个 `tip txHash`。不得为每个 item 单独生成交易 hash。
- 单笔请求支付不跨多链：同一 `businessId` 的原始支付在单一 `chainId` 上完成。
- `ContainerItem[]` 语义约束（与实现对齐）：
  - `AssetKind.ERC20`：用于 USDC 现金部分（`totalUsdc6`）
  - `AssetKind.ERC1155`：用于 `BeamioUserCard` 资产
    - `tokenId == 0`：等价现金资产（point/currency）
    - `tokenId != 0`：特殊资产（如抵扣券、现金券等）
  - 实际支付上限通过 `currencyType + maxAmount(E6)` 预算约束，链上换算后校验 `totalUsdc6 + cardValueUsdc6 <= maxUsdc6`
- 多币种路由约束（商家币种与卡片币种不一致）：
  - 商家请求币种可为 `JPY`（或其它），而支付方可提交非 JPY 的 `BeamioUserCard` 资产参与抵扣。
  - `itemCurrencyType` 取值范围必须来自 `BeamioCurrency.CurrencyType`（见 `BeamioCurrency.sol`）。
  - 商家请求币种由父级 `meta.currencyFiat` 统一设定（取值来自 `BeamioCurrency.CurrencyType`），不在 `route[]` 重复声明。
  - 每个 `route` item 必须记录 `offsetInRequestCurrencyE6`，表示该 item 抵扣了多少请求金额（E6）。
- `BeamioUserCard` 相关混合支付必须在 `BeamioIndexerDiamond` 中保留原子明细，不允许只保存聚合结果。
- 每笔原子记录至少应包含：
  - `businessId`（整单支付聚合主键）
  - `routeIndex`（第几条拆分）
  - `payer`、`payee`（整单根层字段，不在 item 内重复指定）
  - `asset`（合约地址）、`tokenId`（ERC1155 时必填）
  - `amountE6`（bigint）
  - `assetType`（ERC20/ERC1155）
  - `itemCurrencyType`、`offsetInRequestCurrencyE6`
  - `chainId` + `txHash`（整单唯一 hash）+ `logIndex` 或 `actionId`（item 级可审计定位）
- 推荐补充字段（用于审计复算）：
  - `currencyType`、`maxAmount`
  - `totalUsdc6`、`cardPoints6`、`cardValueUsdc6`、`maxUsdc6`
- 安全语义：`open relayed` 签名绑定预算字段（`currencyType/maxAmount/nonce/deadline`），不直接绑定具体 `to/items`；Indexer 必须保存落链后的原子明细，避免仅凭签名离线推导。
- 查询层需同时支持：
  - 按 `businessId` 聚合还原完整支付
  - 按 `asset` / `payer` / `payee` 回溯原子拆分流水
  - 按 `txHash + routeIndex` 查看原始与小费路由明细

### 7.7 小费原子交易约束

- 小费记录方式：不得修改原始支付交易；必须新建独立原子交易并写入链上。
- 关联方式：小费交易通过 `originalPaymentHash` 指向父支付 `id`。
- 审计字段至少包含：
  - `businessId` + `routeIndex`
  - `amountE6`
  - `updatedBy`（操作者）
  - `updatedAt`（链上时间）
  - `updateTxHash`（本次修改交易哈希）
- 聚合口径：`finalRequestAmountFiat6` 需包含所有 `originalPaymentHash == parentId` 的 tip 原子交易累计增量；前端可展示 “Base Amount + Tip Total”。

### 7.8 OTC Fiat Mint API / JSON 规范草案

目标：支持“法币 OTC 入金 -> 卡 token mint -> Indexer 可审计落库”的闭环。

写操作分层（必须遵守 Cluster/Master 协议）：
- Cluster：仅做参数预检（字段完整性、格式、幂等键存在性、基础签名/权限）
- Cluster：预检通过后转发 `postLocalhost('/api/otcMint', body, res)`
- Master：执行最终校验（订单状态、风控/KYC、幂等、链上 mint、`syncTokenAction` 落库）

#### 7.8.1 请求体（POST `/api/otcMint`）

```json
{
  "idempotencyKey": "otc:fiat_settlement:bank-2026-02-16-000001",
  "otcOrderId": "OTC-20260216-000001",
  "settlementRef": "BANK_WIRE_REF_ABC123",
  "settlementRefHash": "0x5f...e1",
  "chainId": 8453,
  "beamioUserCard": "0xCardAddress",
  "tokenId": "0",
  "recipient": "0xRecipientWallet",
  "mintAmountE6": "1000000",
  "mintTxCategory": "0x...", 
  "fiat": {
    "currencyType": 1,
    "requestAmountFiat6": "1000000",
    "finalAmountFiat6": "1000000",
    "fxRateE8": "100000000",
    "finalAmountUSDC6": "1000000"
  },
  "fee": {
    "gasChainType": 0,
    "gasWei": "21000000000000",
    "gasUSDC6": "1200",
    "serviceUSDC6": "0",
    "bServiceUSDC6": "0",
    "bServiceUnits6": "0",
    "feePayer": "0xFeePayer"
  },
  "meta": {
    "provider": "BANK_WIRE",
    "providerAccountRef": "acct_001",
    "riskLevel": "LOW",
    "noteJson": "{\"source\":\"OTC_FIAT\"}"
  }
}
```

字段说明（关键）：
- `idempotencyKey`：幂等键（见 7.8.4），同一键只允许成功一次。
- `mintTxCategory`：必须为 mint 分类键（建议 `keccak256("beamio_usercard_mint:confirmed")`）。
- `chainId`：真实 mint 执行链，用于后续 `chainIdFilter` 查询。
- `tokenId` + `mintAmountE6`：本次 mint 的 NFT# 与数量（E6）。
- `settlementRefHash`：链下结算引用哈希，避免敏感明文上链。

#### 7.8.2 成功返回体

```json
{
  "ok": true,
  "idempotencyKey": "otc:fiat_settlement:bank-2026-02-16-000001",
  "otcOrderId": "OTC-20260216-000001",
  "actionId": "12345",
  "mintTxHash": "0xMintTxHash",
  "indexerTxId": "0xIndexerTxIdBytes32",
  "beamioUserCard": "0xCardAddress",
  "tokenId": "0",
  "recipient": "0xRecipientWallet",
  "mintAmountE6": "1000000",
  "chainId": 8453,
  "timestamp": 1771200000
}
```

#### 7.8.3 错误码建议

- `400100` `BAD_REQUEST`：参数缺失/格式错误
- `400101` `INVALID_AMOUNT_E6`：金额非 E6 语境或 <= 0
- `400102` `INVALID_CHAIN_ID`：`chainId` 非法
- `400103` `INVALID_MINT_CATEGORY`：`mintTxCategory` 非 mint 分类键
- `400104` `INVALID_CARD_OR_TOKEN`：卡地址/tokenId 无效
- `400105` `INVALID_RECIPIENT`：接收地址无效
- `401100` `UNAUTHORIZED`：无权限执行 OTC mint
- `403100` `KYC_REQUIRED`：KYC/风控未通过
- `403101` `ORDER_NOT_SETTLED`：链下法币尚未结算确认
- `409100` `IDEMPOTENCY_CONFLICT`：同幂等键请求体不一致
- `409101` `DUPLICATE_SETTLEMENT_REF`：同结算引用重复使用
- `409102` `ORDER_ALREADY_MINTED`：订单已完成 mint
- `500100` `CHAIN_TX_FAILED`：链上 mint 失败
- `500101` `INDEXER_SYNC_FAILED`：`syncTokenAction` 失败
- `500102` `MASTER_INTERNAL_ERROR`：Master 内部异常

#### 7.8.4 幂等键规则

- 幂等键建议格式：`otc:<provider>:<settlementRef>` 或 `otc:<merchantId>:<otcOrderId>`
- 同一 `idempotencyKey` 重放时：
  - 若请求体哈希一致：返回首次成功结果（`200`）
  - 若请求体哈希不一致：返回 `409100 IDEMPOTENCY_CONFLICT`
- 幂等存储最少字段：
  - `idempotencyKey`
  - `requestBodyHash`
  - `status`（PROCESSING/SUCCESS/FAILED）
  - `actionId` / `mintTxHash`
  - `updatedAt`
- 建议同时对 `settlementRefHash` 建唯一约束，防止跨幂等键重复 mint。

#### 7.8.5 落库口径（syncTokenAction）

Master 成功 mint 后，必须写入一条 `syncTokenAction`：
- `txCategory = mintTxCategory`
- `chainId = request.chainId`
- `payee = recipient`（mint 钱包去重口径）
- `route[]` 至少包含一条 `asset=beamioUserCard, tokenId, amountE6`
- `meta.requestAmountFiat6/finalRequestAmountFiat6/finalRequestAmountUSDC6` 与 OTC 成交一致
- `displayJson`/`meta.afterNote*` 可包含 OTC 扩展 JSON（建议仅放可公开字段或哈希）

### 7.9 查询统计工具汇总表

> 说明：下表聚焦“统计类查询”能力，不包含原始单条记录读取接口。  
> 通用过滤值：`chainIdFilter = uint256.max` 表示不过滤；`gasChainTypeFilter = uint16.max` 表示不过滤。

| 统计域 | Facet | 核心接口（示例） | 统计口径 | 关键过滤参数 | 主要返回 |
|---|---|---|---|---|---|
| 账户交易数量（周期） | `ActionFacet` | `getAccountActionIdsByPeriodPaged(...)` / `getAccountTransactionsByPeriodPaged(...)` | 某账户在周期窗口内命中交易数与分页 | `periodType/anchorTs/txCategoryFilter/gasChainTypeFilter/chainIdFilter` | `total/periodStart/periodEnd/page` |
| topAdmin 交易分页 | `ActionFacet` | `getTopAdminTransactionsByCurrentPeriodOffsetAndAccountModePaged(...)` / `...PagedFull(...)` / `getTopAdminTransactionsByWeekOffsetAndAccountModePaged(...)` | 某 topAdmin 在周期窗口内所有交易 | `topAdmin/periodOffset/txCategoryFilter/accountMode` | `total/periodStart/periodEnd/page` |
| subordinate 交易分页 | `ActionFacet` | `getSubordinateTransactionsByCurrentPeriodOffsetAndAccountModePaged(...)` / `...PagedFull(...)` / `getSubordinateTransactionsByWeekOffsetAndAccountModePaged(...)` | 某 subordinate 在周期窗口内所有交易 | `subordinate/periodOffset/txCategoryFilter/accountMode` | `total/periodStart/periodEnd/page` |
| 账户 bService 分页统计 | `FeeStatsFacet` | `getAccountBServiceStatsByCurrentPeriodOffsetPaged(...)` + `Hour/Day/Week/Month/Quarter/Year` | 窗口总量 + 当前页总量（`bServiceUnits6/bServiceUSDC6`） | `account/periodOffset/txCategoryFilter/accountMode/chainIdFilter` | `FeeStatsPage` |
| bService TopN（次数 + 数量） | `FeeStatsFacet` | `getBServiceTopNByCurrentPeriodOffset(...)` + `Hour...Year` | 按 `feePayer` 排名：交易次数 TopN + `bServiceUnits6` 累计 TopN | `periodOffset/topN/txCategoryFilter/accountMode/gasChainTypeFilter/chainIdFilter` | `topTxCountAccounts/topTxCounts/topUnitsAccounts/topUnits6` |
| gasWei 统计（按 gas 链类型） | `FeeStatsFacet` | `getGasWeiStatsByGasChainTypeCurrentPeriodOffset(...)` + `Hour...Year` | 指定 `gasChainType` 的窗口内 `gasWei` 总和与笔数 | `gasChainType/periodOffset/txCategoryFilter/accountMode` | `GasWeiStats(total,totalGasWei,periodStart,periodEnd)` |
| Asset 维度周期分页 | `BeamioUserCardStatsFacet` | `getAssetTransactionsByCurrentPeriodOffsetAndAccountModePaged(...)` / `...PagedFull(...)` | 指定资产地址（含 BeamioUserCard）的窗口分页统计 | `asset/account/periodOffset/txCategoryFilter/accountMode/chainIdFilter` | `total/periodStart/periodEnd/page` |
| Asset+Token 维度周期分页 | `BeamioUserCardStatsFacet` | `getAssetTokenTransactionsByCurrentPeriodOffsetAndAccountModePaged(...)` / `...PagedFull(...)` | 指定 `asset+tokenId` 的窗口分页统计 | `asset/tokenId/account/periodOffset/txCategoryFilter/accountMode/chainIdFilter` | `total/periodStart/periodEnd/page` |
| BeamioUserCard 交易总数（不指定 account） | `BeamioUserCardStatsFacet` | `getBeamioUserCardTransactionStatsByCurrentPeriodOffset(...)` | 某卡窗口内总交易数 | `beamioUserCard/periodOffset/txCategoryFilter/accountMode/chainIdFilter` | `total/periodStart/periodEnd` |
| BeamioUserCard topAdmin 交易总数 | `BeamioUserCardStatsFacet` | `getBeamioUserCardTransactionStatsByTopAdminAndCurrentPeriodOffset(...)` | 某卡窗口内 topAdmin 匹配的交易数 | `beamioUserCard/topAdmin/periodOffset/txCategoryFilter/accountMode/chainIdFilter` | `total/periodStart/periodEnd` |
| BeamioUserCard subordinate 交易总数 | `BeamioUserCardStatsFacet` | `getBeamioUserCardTransactionStatsBySubordinateAndCurrentPeriodOffset(...)` | 某卡窗口内 subordinate 匹配的交易数 | `beamioUserCard/subordinate/periodOffset/txCategoryFilter/accountMode/chainIdFilter` | `total/periodStart/periodEnd` |
| Asset+topAdmin 分页 | `BeamioUserCardStatsFacet` | `getAssetTransactionsByTopAdminAndCurrentPeriodOffsetAndAccountModePaged(...)` / `...PagedFull(...)` / `getBeamioUserCardTransactionsByTopAdminAndWeekOffsetAndAccountModePaged(...)` | 某资产窗口内 topAdmin 匹配的交易分页 | `asset/topAdmin/periodOffset/txCategoryFilter/accountMode/chainIdFilter` | `total/periodStart/periodEnd/page` |
| Asset+subordinate 分页 | `BeamioUserCardStatsFacet` | `getAssetTransactionsBySubordinateAndCurrentPeriodOffsetAndAccountModePaged(...)` / `...PagedFull(...)` / `getBeamioUserCardTransactionsBySubordinateAndWeekOffsetAndAccountModePaged(...)` | 某资产窗口内 subordinate 匹配的交易分页 | `asset/subordinate/periodOffset/txCategoryFilter/accountMode/chainIdFilter` | `total/periodStart/periodEnd/page` |
| BeamioUserCard 账户交易总数 | `BeamioUserCardStatsFacet` | `getBeamioUserCardAccountTxCountByCurrentPeriodOffset(...)` + `Hour...Year` | 某账户在某卡窗口内交易总数 | `beamioUserCard/account/periodOffset/txCategoryFilter/accountMode/chainIdFilter` | `total/periodStart/periodEnd` |
| Holder / Balance 快照查询 | `BeamioUserCardStatsFacet` | `getBeamioUserCardTokenHolderCount(...)` / `getBeamioUserCardTokenIndexedBalance(...)` | 当前索引余额与持币地址计数（非回溯窗口） | `beamioUserCard/tokenId/account` | `holderCount/balanceE6` |
| Holder TopN（窗口末快照） | `BeamioUserCardStatsFacet` | `getBeamioUserCardTokenTopHoldersByCurrentPeriodOffset(...)` + `Hour...Year` | 严格小时快照口径，取窗口末状态 TopN | `beamioUserCard/tokenId/periodOffset/topN` | `holders/balancesE6/periodStart/periodEnd` |
| 卡 mint 统计（全卡） | `BeamioUserCardStatsFacet` | `getBeamioUserCardMintStatsByCurrentPeriodOffset(...)` + `Hour...Year` | 窗口内 mint 总笔数 + mint 钱包去重数（按 `payee`） | `beamioUserCard/mintTxCategoryFilter/accountMode/chainIdFilter` | `MintStats(mintTxTotal,mintWalletCount,periodStart,periodEnd)` |
| 卡 mint 统计（按 tokenId） | `BeamioUserCardStatsFacet` | `getBeamioUserCardTokenMintStatsByCurrentPeriodOffset(...)` + `Hour...Year` | 窗口内指定 `tokenId` 的 mint 总笔数 + 钱包去重数 | `beamioUserCard/tokenId/mintTxCategoryFilter/accountMode/chainIdFilter` | `MintStats(mintTxTotal,mintWalletCount,periodStart,periodEnd)` |
| Admin token #0 mint/burn 统计 | `StatsFacet` | `getAtomicHourStats(3, admin, hourIndex)` / `getAdminHourlyData(admin, hourIndex)` / `getAggregatedStats(3, admin, startTs, endTs)` / `getBusinessPeriodReports(3, admin, periodType, periods, anchorTs)` | 按 admin 地址统计 token #0 (points) 的 mint/burn，可按时/日/周/月/季/年聚合 | `mode=3` 表示 admin 维度，`account` 为 admin 地址 | `HourlyStats` / `AggregatedStats` / `PeriodReport[]` |

使用建议（工程侧）：
- 报表类优先使用“周期 + offset”接口，保持与小时原子桶一致。
- 涉及多链资产时，显式传 `chainIdFilter`，避免跨链混算。
- mint 统计必须传固定 `mintTxCategoryFilter`（如 `keccak256("beamio_usercard_mint:confirmed")`）。
- TopN 类查询建议限制 `topN` 上限（如 100）以控制节点查询成本。

### 7.10 BeamioUserCard Admin 管理（adminManager）

BeamioUserCard 的 admin 增删统一为单一接口 `adminManager`，必须由 owner 离线签字后经 gateway 的 `executeForOwner` 执行。

#### 7.10.1 接口定义

```solidity
// 统一管理 admin：admin=true 添加并写入 metadata，admin=false 仅从 adminList 移除（metadata 保留）
function adminManager(address to, bool admin, uint256 newThreshold, string calldata metadata) external;

// 返回所有 admin 地址
function getAdminList() external view returns (address[] memory);

```

#### 7.10.2 约束

| 约束 | 说明 |
|------|------|
| 调用方 | 仅 gateway（Factory）可调用；owner 不可直接调用 |
| 执行路径 | 必须经 `BeamioUserCardFactoryPaymaster.executeForOwner(cardAddr, data, deadline, nonce, ownerSignature)` |
| owner 保护 | `admin=false` 时，若 `to == owner()` 则 revert `UC_OwnerCannotBeRemoved` |
| 添加时 to | `admin=true` 时，`to` 必须为 EOA（非 AA/合约） |
| newThreshold | 添加/移除后 multisig 所需签名数，必须 `> 0` 且 `<= adminList.length` |
| metadata | 添加时随 `adminManager` 写入治理存储；当前主卡不再暴露单独的 `adminMetadata(address)` getter |

#### 7.10.3 前端调用示例

```ts
import { encodeAdminManager, signExecuteForOwner } from './BeamioCard'

// 添加 admin（带 metadata）
const data = encodeAdminManager(newAdminAddress, true, 1, 'Partner: Store #001')
const sig = await signExecuteForOwner(ownerPrivateKey, cardAddress, data, deadline, nonce)
await postCardAddAdmin({ cardAddress, data, deadline, nonce, ownerSignature: sig })

// 移除 admin
const data = encodeAdminManager(adminToRemove, false, 1, '')
const sig = await signExecuteForOwner(ownerPrivateKey, cardAddress, data, deadline, nonce)
await postCardAddAdmin({ cardAddress, data, deadline, nonce, ownerSignature: sig })

// 查询所有 admin
const admins = await card.getAdminList()
```

#### 7.10.4 API 端点

- **POST `/api/cardAddAdmin`**：Cluster 预检 `data` 为 `adminManager(address,bool,uint256,string)` calldata，`admin=true` 时校验 `to` 为 EOA，合格后转发 Master `executeForOwner`。

## 8. 开发注意事项 (Dev Notes)

- 精度：后台计算必须使用整数/BigInt/decimal 库；前端只在展示层四舍五入
- 精度约定：`amountE6` 为统一记账单位；若接入 18 位资产，必须显式执行 `18 -> 6`（或 `6 -> 18`）转义并记录换算规则，禁止隐式换算
- 原子性：链上原子不等于索引层单事件；前端按 `businessId` 聚合
- 实时性：Waiting 状态通过 websocket/轮询刷新为 Received
- 安全性：禁止信任客户端时间和浮点金额作为结算依据

## 9. 附录：CoNET 主网 BeamioIndexerDiamond 数据快照

> 数据获取时间：2026-03-07；获取脚本：`npx hardhat run scripts/fetchConetIndexerData.ts --network conet`

| 项目 | 值 |
|------|-----|
| RPC | `https://mainnet-rpc.conet.network` |
| Indexer 地址 | 见 `deployments/conet-addresses.json`（当前 `0xd990719B2f05ccab4Acdd5D7A3f7aDfd2Fc584Fe`） |
| 交易总数 (txCount) | **262** |

### 9.1 最新 100 条交易 txCategory 分布

| txCategory | 数量 | 说明 |
|------------|------|------|
| internal_transfer:confirmed | 19 | 内部转账（AA↔EOA） |
| buintClaim | 16 | B-Unit 免费池申领 |
| buintUSDC | 14 | B-Unit USDC 购买 |
| request_create:confirmed | 14 | 请求创建 |
| 0xe572e693... | 12 | consumeFromUser kind 变体 |
| 0xf27bd0abb4... | 8 | consumeFromUser kind 变体 |
| transfer_out:confirmed | 6 | 转出 |
| 0x5e7605f3... | 4 | consumeFromUser kind 变体 |
| request_cancel:confirmed | 4 | 请求取消 |
| 0xc78fb7b2... | 2 | consumeFromUser kind 变体 |
| buintBurn | 1 | B-Unit 焚烧 |

### 9.2 链分布

- **chainId 8453**：Base 主网（transfer、internal_transfer、request_create 等）
- **chainId 224400**：CoNET 主网（buintClaim、buintUSDC、buintBurn 等）

## 10. 交付物清单

- 本规格说明书 (`readme.md`)
- React 原型代码 (`BeamioTransactions.jsx`)
- Figma 设计稿（参照 Screenshot）

