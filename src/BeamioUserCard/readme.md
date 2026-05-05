# BeamioUserCard Deployment Notes

## Base Mainnet Deployment

- Network: `base`
- Chain ID: `8453`
- RPC: `https://base-rpc.conet.network`
- Explorer: [https://basescan.org/](https://basescan.org/)
- Deployer: `0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1`

### Base Reused Existing Dependencies

- `BeamioOracle`: `0xDa4AE8301262BdAaf1bb68EC91259E6C512A9A2B`
- `BeamioQuoteHelperV07` used by `AA Factory`: `0xfa30c2086ff9a3D74576d55c2027586797A52F29`
- `BeamioQuoteHelperV07` used by current `Card Factory`: `0x291BDb7044B3C31e62Cb07A47fe48d4835954ffF`
- `Base USDC`: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`

### Base Current Active Contracts

- Current `BeamioUserCardFactoryPaymasterV07`: [`0x52cc9E977Ca3EA33c69383a41F87f32a71140A52`](https://basescan.org/address/0x52cc9E977Ca3EA33c69383a41F87f32a71140A52)
- Current active `BeamioUserCard` referenced by `AA Factory`: [`0xBCcfA50d2a5917C7A8662177F5F4B7A175787270`](https://basescan.org/address/0xBCcfA50d2a5917C7A8662177F5F4B7A175787270)

### Base Historical Combined Deployment Record

From `deployments/base-FullAccountAndUserCard.json` (`2026-02-13T23:36:00.000Z`):

- `BeamioUserCardPlaceholder`: [`0xE0d05CfB12a1DfE04Fb9b4ba583D306691e9313D`](https://basescan.org/address/0xE0d05CfB12a1DfE04Fb9b4ba583D306691e9313D)
- `BeamioUserCardRedeemModuleVNext`: [`0x9566ce3B07d5DB5d8c63a93179A541C8b2f11448`](https://basescan.org/address/0x9566ce3B07d5DB5d8c63a93179A541C8b2f11448)
- `BeamioUserCardDeployerV07`: [`0x719DdE8C7917AF06cd66bB7e2118fa2F2eC81ED9`](https://basescan.org/address/0x719DdE8C7917AF06cd66bB7e2118fa2F2eC81ED9)
- `BeamioUserCard`: [`0xBCcfA50d2a5917C7A8662177F5F4B7A175787270`](https://basescan.org/address/0xBCcfA50d2a5917C7A8662177F5F4B7A175787270)

From `deployments/base-UserCardFactory.json` (`2026-03-14T19:53:37.772Z`):

- Current `BeamioUserCardDeployerV07`: [`0xA6a824cA25E0cd95EEB98f2b8a911396f6672685`](https://basescan.org/address/0xA6a824cA25E0cd95EEB98f2b8a911396f6672685)
- Current `BeamioUserCardFactoryPaymasterV07`: [`0x52cc9E977Ca3EA33c69383a41F87f32a71140A52`](https://basescan.org/address/0x52cc9E977Ca3EA33c69383a41F87f32a71140A52)

### Base Registered Module Addresses

Canonical from `deployments/base-UserCardFactory.json` (2026-05-05: IssuedNft + AdminStatsQuery upgrade for `registerSeries`):

- `defaultRedeemModule`: [`0x17Db9029dEd9d5F4e4cF819d3E8eC742cf0c79e6`](https://basescan.org/address/0x17Db9029dEd9d5F4e4cF819d3E8eC742cf0c79e6)
- `defaultIssuedNftModule`: [`0x5C2e89C63fC359Fad798ea580b205A25efF8CA55`](https://basescan.org/address/0x5C2e89C63fC359Fad798ea580b205A25efF8CA55)
- `defaultFaucetModule`: [`0xb84d74E08Ea519ffCFBD8F8c5D988943e3a82a0F`](https://basescan.org/address/0xb84d74E08Ea519ffCFBD8F8c5D988943e3a82a0F)
- `defaultGovernanceModule`: [`0xc12fBEA081aD0B8143747Fd2935CE6b61734eB41`](https://basescan.org/address/0xc12fBEA081aD0B8143747Fd2935CE6b61734eB41)
- `defaultMembershipStatsModule`: [`0xbf2e5F463dF31FD483faA738FB05d9ffb17031c0`](https://basescan.org/address/0xbf2e5F463dF31FD483faA738FB05d9ffb17031c0)
- `defaultAdminStatsQueryModule`: [`0x6C73F36A5221a5840C1EAB91c70F0C9C27D8B33B`](https://basescan.org/address/0x6C73F36A5221a5840C1EAB91c70F0C9C27D8B33B)

### Base Factory Configuration

Current on-chain `BeamioUserCardFactoryPaymasterV07` configuration:

- `USDC_TOKEN`: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- `quoteHelper`: `0x291BDb7044B3C31e62Cb07A47fe48d4835954ffF`
- `deployer`: `0xA6a824cA25E0cd95EEB98f2b8a911396f6672685`
- `aaFactory`: `0x4b31D6a05Cdc817CAc1B06369555b37a5b182122`
- `metadataBaseURI`: `https://beamio.app/api/metadata/0x`

### Base Card Constructor Record

From `deployments/base-UserCard.json` (`2026-02-14T20:02:50.581Z`):

- `uri_`: `https://beamio.app/api/metadata/0x`
- `currency_`: `4`
- `pointsUnitPriceInCurrencyE6_`: `1000000`
- `initialOwner`: `0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1`
- `gateway_`: `0x4b31D6a05Cdc817CAc1B06369555b37a5b182122`

## CoNET Mainnet Deployment

- Network: `conet`
- Chain ID: `224422`
- RPC: `https://rpc1.conet.network`
- Explorer: [https://mainnet.conet.network/](https://mainnet.conet.network/)
- Deployment time: `2026-03-12`
- Deployer: `0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1`

## Reused Existing Dependencies

- `BeamioOracle`: `0x32aa4fC3D3506850b27F767Bf582f4ec449de224`
- `BeamioQuoteHelperV07`: `0x2c700841f61373FB4eDBD6710ab075c84051731d`
- `conetUsdc`: `0x28fBBb6C5C06A4736B00A540b66378091c224456`

## Deployed Contracts

- `BeamioUserCardPlaceholder`: [`0x0026e5ea3000f2c030f730b13C12f774A1939e1D`](https://mainnet.conet.network/address/0x0026e5ea3000f2c030f730b13C12f774A1939e1D)
- `BeamioUserCardRedeemModuleVNext`: [`0x03E71a400Df4F0A18Ae4dB1c6D4018a9Baf4d862`](https://mainnet.conet.network/address/0x03E71a400Df4F0A18Ae4dB1c6D4018a9Baf4d862)
- `BeamioUserCardDeployerV07`: [`0x5BEA2762417b0DF778273199131Ac1A23Cc6ed7d`](https://mainnet.conet.network/address/0x5BEA2762417b0DF778273199131Ac1A23Cc6ed7d)
- `BeamioUserCardFactoryPaymasterV07`: [`0xd57eac0372aa2fbfC6625D20fA9E4a963F3F5063`](https://mainnet.conet.network/address/0xd57eac0372aa2fbfC6625D20fA9E4a963F3F5063)
- `BeamioUserCard`: [`0xfF1AA6A6744C1aB9F76E8a0a09a12CD385cAB70e`](https://mainnet.conet.network/address/0xfF1AA6A6744C1aB9F76E8a0a09a12CD385cAB70e)

## UserCard Factory Configuration

- `USDC_TOKEN`: `0x28fBBb6C5C06A4736B00A540b66378091c224456`
- `quoteHelper`: `0x2c700841f61373FB4eDBD6710ab075c84051731d`
- `deployer`: `0x5BEA2762417b0DF778273199131Ac1A23Cc6ed7d`
- `aaFactory`: `0x16B868162963C6E540d4F2fdC8BE503c19fe6E71`
- `metadataBaseURI`: `https://beamio.app/api/metadata/0x`

## Registered Module Addresses

The following module addresses are already written on-chain into `BeamioUserCardFactoryPaymasterV07`:

- `defaultRedeemModule`: `0x03E71a400Df4F0A18Ae4dB1c6D4018a9Baf4d862`
- `defaultIssuedNftModule`: `0x6A870AFe1dB4A4E4652D85E7f3CeD70C6Fb010EF`
- `defaultFaucetModule`: `0x295Dc19B588b2886b1b950419712c054d02Ecd68`
- `defaultGovernanceModule`: `0x1442728d179019c7210B91a227b43318fb1900eE`
- `defaultMembershipStatsModule`: `0x53DDb53B2F0B015EB497E9687010d2A93191b711`

Additional deployed query module:

- `BeamioUserCardMembershipStatsQueryModuleV1`: [`0x0501f432637C2c5Ca10E8789a8644C31A0179953`](https://mainnet.conet.network/address/0x0501f432637C2c5Ca10E8789a8644C31A0179953)

Additional deployed operational modules:

- `BeamioUserCardIssuedNftModuleV1`: [`0x6A870AFe1dB4A4E4652D85E7f3CeD70C6Fb010EF`](https://mainnet.conet.network/address/0x6A870AFe1dB4A4E4652D85E7f3CeD70C6Fb010EF)
- `BeamioUserCardFaucetModuleV1`: [`0x295Dc19B588b2886b1b950419712c054d02Ecd68`](https://mainnet.conet.network/address/0x295Dc19B588b2886b1b950419712c054d02Ecd68)
- `BeamioUserCardGovernanceModuleV1`: [`0x1442728d179019c7210B91a227b43318fb1900eE`](https://mainnet.conet.network/address/0x1442728d179019c7210B91a227b43318fb1900eE)
- `BeamioUserCardMembershipStatsModuleV1`: [`0x53DDb53B2F0B015EB497E9687010d2A93191b711`](https://mainnet.conet.network/address/0x53DDb53B2F0B015EB497E9687010d2A93191b711)

Runtime-size note:

- To keep `BeamioUserCard` under the EIP-170 runtime bytecode limit, part of the admin subtree management logic was moved out of the main card runtime and into `BeamioUserCardGovernanceModuleV1`
- This now includes the subtree airdrop-limit enforcement / accumulation path and the subordinate clear path for subtree airdrop usage + admin stats reset
- External card-facing behavior stayed the same; the card now forwards these operations into the governance module through the existing delegatecall module architecture

## BeamioUserCard Constructor Arguments

- `uri_`: `https://beamio.app/api/metadata/0x`
- `currency_`: `4`
- `pointsUnitPriceInCurrencyE6_`: `1000000`
- `initialOwner`: `0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1`
- `gateway_`: `0x16B868162963C6E540d4F2fdC8BE503c19fe6E71`

## Admin Stats

The card now keeps on-chain admin-scoped hourly stats for token `0` and membership flows.

### Admin Hierarchy And Airdrop Limit Rules

- `owner` can add first-level admins directly
- A first-level admin (`adminParent == address(0)`) can add only one more layer of subordinate admins
- A second-level admin (`adminParent != address(0)`) cannot add further subordinate admins
- A second-level admin cannot manage subordinate limits and cannot clear subordinate counters
- `owner` is unlimited for admin-airdrop limit checks
- For every non-owner admin, `limit` constrains the cumulative airdrop volume of `self + all descendants` since the last clear
- When a parent admin sets a direct subordinate's `limit`, the check is `subordinate.limit <= parent.limit`; it does not depend on the parent's currently remaining headroom
- During `mintPointsByAdmin`, the card validates the signer and every ancestor admin on the `adminParent` chain; if any subtree total would exceed that admin's `limit`, the mint reverts

### Operator Attribution

- `mintPointsByAdmin`: operator = admin signer
- `burnPointsByAdmin`: operator = admin signer
- `mintPointsByGateway` / `mintPointsByGatewayWithOperator`: operator = recommender admin when provided, otherwise `owner()`
- `redeemByGateway` / `redeemBatchByGateway`: operator = redeem creator, fallback `owner()`; if the owner-signed redeem creation payload includes a recommender admin, redeem completion also increments that admin's separate `redeem_mint` counter
- `mintMemberCardByAdmin`: operator = `owner()`
- `safeTransferFrom` / `safeBatchTransferFrom` for `POINTS_ID`: operator prefers `msg.sender`; if `msg.sender` is an AA/account contract, fallback to `from.owner()`

For all supported flows, stats are written to the operator and recursively accumulated to every parent admin via `adminParent`.

### What Is Tracked

- `mint`: token `0` minted amount
- `redeemMintCounter`: separate redeem-only minted amount credited to the optional recommender admin
- `usdcMintCounter`: separate USDC-topup-only minted amount credited to the optional recommender admin
- `burn`: token `0` burned amount
- `transfer`: token `0` transfer count
- `transferAmount`: token `0` transfer amount
- `redeemMint`: redeem-only minted amount credited to the optional recommender admin
- `usdcMint`: USDC-topup-only minted amount credited to the optional recommender admin
- `issued`: membership card issued count
- `upgraded`: membership card upgraded count

### Main Query APIs

- `getAdminRedeemMintCounter(admin)`
- `getAdminUSDCMintCounter(admin)`

Admin/global stats queries were moved out of `BeamioUserCard` runtime code to reduce bytecode size. Keep calling the same card address, but use the ABI of `BeamioUserCardAdminStatsQueryModuleV1` through the card's fallback route:

- `getAdminHourlyData(admin, hourIndex)`
- `getAdminPeriodReports(admin, periodType, periods, anchorTs)`
- `getGlobalStatsFull(periodType, anchorTs, cumulativeStartTs)`
- `getAdminStatsFull(admin, periodType, anchorTs, cumulativeStartTs)`
- `getAdminAirdropLimit(admin)`
- `getAdminAndSubordinateLimits(admin)`
- `getAdminAndSubordinateLimitsPage(to, adminOffset, adminPageSize, subordinateOffset, subordinatePageSize)`

### Return Notes

The following query APIs now return structs instead of long tuples, so the ABI is easier to consume and avoids Solidity `stack too deep` issues.

**`getAdminHourlyData(admin, hourIndex) -> AdminHourlyDataView`**

| Field | Meaning |
|------|------|
| `nftMinted` | NFT mint count in the target hour |
| `tokenMinted` | token `0` mint amount in the target hour |
| `tokenBurned` | token `0` burn amount in the target hour |
| `transferCount` | token `0` transfer count in the target hour |
| `transferAmount` | token `0` transfer amount in the target hour |
| `redeemMintAmount` | redeem-only minted amount credited in the target hour |
| `usdcMintAmount` | USDC-topup-only minted amount credited in the target hour |
| `issuedCount` | membership card issued count in the target hour |
| `upgradedCount` | membership card upgraded count in the target hour |
| `hasData` | whether this hour bucket has any recorded data |

**`getAdminPeriodReports(admin, periodType, periods, anchorTs) -> AdminPeriodReportsView`**

| Field | Meaning |
|------|------|
| `periodStarts` | start timestamps of each returned period |
| `periodEnds` | end timestamps of each returned period |
| `totalNftMinteds` | NFT mint count for each period |
| `totalTokenMinteds` | token `0` mint amount for each period |
| `totalTokenBurneds` | token `0` burn amount for each period |
| `totalTransferss` | token `0` transfer count for each period |
| `totalTransferAmounts` | token `0` transfer amount for each period |
| `totalRedeemMints` | redeem-only minted amount for each period |
| `totalUSDCMints` | USDC-topup-only minted amount for each period |
| `totalIssueds` | membership card issued count for each period |
| `totalUpgradeds` | membership card upgraded count for each period |
| `adminMintCounter` | this admin's mint counter since last clear |

**`getGlobalStatsFull(periodType, anchorTs, cumulativeStartTs) -> GlobalStatsFullView`**

| Field | Meaning |
|------|------|
| `cumulativeMint` | global cumulative token `0` mint amount since `cumulativeStartTs` |
| `cumulativeBurn` | global cumulative token `0` burn amount since `cumulativeStartTs` |
| `cumulativeTransfer` | global cumulative token `0` transfer count since `cumulativeStartTs` |
| `cumulativeTransferAmount` | global cumulative token `0` transfer amount since `cumulativeStartTs` |
| `cumulativeRedeemMint` | global cumulative redeem-only minted amount since `cumulativeStartTs` |
| `cumulativeUSDCMint` | global cumulative USDC-topup-only minted amount since `cumulativeStartTs` |
| `cumulativeIssued` | global cumulative issued count since `cumulativeStartTs` |
| `cumulativeUpgraded` | global cumulative upgraded count since `cumulativeStartTs` |
| `periodMint` | token `0` mint amount in the selected period |
| `periodBurn` | token `0` burn amount in the selected period |
| `periodTransfer` | token `0` transfer count in the selected period |
| `periodTransferAmount` | token `0` transfer amount in the selected period |
| `periodRedeemMint` | redeem-only minted amount in the selected period |
| `periodUSDCMint` | USDC-topup-only minted amount in the selected period |
| `periodIssued` | issued count in the selected period |
| `periodUpgraded` | upgraded count in the selected period |
| `adminCount` | total admin count without hierarchy |

**`getAdminStatsFull(admin, periodType, anchorTs, cumulativeStartTs) -> AdminStatsFullView`**

| Field | Meaning |
|------|------|
| `cumulativeMint` | cumulative token `0` mint amount for self + subordinates since `cumulativeStartTs` |
| `cumulativeBurn` | cumulative token `0` burn amount for self + subordinates since `cumulativeStartTs` |
| `cumulativeTransfer` | cumulative token `0` transfer count for self + subordinates since `cumulativeStartTs` |
| `cumulativeTransferAmount` | cumulative token `0` transfer amount for self + subordinates since `cumulativeStartTs` |
| `cumulativeRedeemMint` | cumulative redeem-only minted amount for self + subordinates since `cumulativeStartTs` |
| `cumulativeUSDCMint` | cumulative USDC-topup-only minted amount for self + subordinates since `cumulativeStartTs` |
| `cumulativeIssued` | cumulative issued count for self + subordinates since `cumulativeStartTs` |
| `cumulativeUpgraded` | cumulative upgraded count for self + subordinates since `cumulativeStartTs` |
| `periodMint` | token `0` mint amount for the selected period |
| `periodBurn` | token `0` burn amount for the selected period |
| `periodTransfer` | token `0` transfer count for the selected period |
| `periodTransferAmount` | token `0` transfer amount for the selected period |
| `periodRedeemMint` | redeem-only minted amount for the selected period |
| `periodUSDCMint` | USDC-topup-only minted amount for the selected period |
| `periodIssued` | issued count for the selected period |
| `periodUpgraded` | upgraded count for the selected period |
| `mintCounterFromClear` | mint counter since last clear for self + subordinates |
| `burnCounterFromClear` | burn counter since last clear for self + subordinates |
| `transferCounterFromClear` | transfer counter since last clear for self + subordinates |
| `redeemMintCounterFromClear` | redeem-only mint counter since last clear for self + subordinates |
| `usdcMintCounterFromClear` | USDC-topup-only mint counter since last clear for self + subordinates |
| `subordinates` | subordinate admin address list |

**`getAdminAirdropLimit(admin) -> AdminAirdropLimitView`**

| Field | Meaning |
|------|------|
| `admin` | queried admin address |
| `parent` | direct parent admin; `address(0)` means owner-added top-level admin or no parent |
| `limit` | subtree airdrop limit; `type(uint256).max` for `owner` |
| `usedFromClear` | subtree cumulative airdrop amount since the last clear |
| `remainingAvailable` | remaining subtree airdrop headroom; `type(uint256).max` for `owner` |
| `unlimited` | whether this admin is unlimited (`owner`) |

**`getAdminAndSubordinateLimits(admin) -> (AdminAirdropLimitView self, AdminAirdropLimitView[] subordinates)`**

| Field | Meaning |
|------|------|
| `self` | current admin's own subtree limit record |
| `subordinates` | direct subordinate admins and each subordinate's subtree limit record |

**`getAdminAndSubordinateLimitsPage(to, adminOffset, adminPageSize, subordinateOffset, subordinatePageSize) -> AdminAirdropLimitPageView`**

| Field | Meaning |
|------|------|
| `queryTarget` | requested target admin; `address(0)` means query owner's direct admins |
| `adminOffset` / `adminPageSize` | pagination window applied to the returned top-level admin list |
| `adminTotal` | total number of top-level admins matched by the query |
| `subordinateOffset` / `subordinatePageSize` | pagination window applied to each returned admin's direct subordinate list |
| `admins` | page of `AdminAirdropLimitNodeView` items |

**`AdminAirdropLimitNodeView`**

| Field | Meaning |
|------|------|
| `self` | this admin's own limit / used / remaining view |
| `subordinateAdmins` | paged direct subordinate admin address list |
| `subordinateTotal` | total direct subordinate admin count before pagination |

### Clear And Limit Management Notes

- `setAdminAirdropLimitByAdmin` is restricted to first-level admins managing their direct subordinates
- `clearAdminMintCounterForSubordinate` is also restricted to first-level admins clearing their direct subordinates
- When clear succeeds, the card resets both the subordinate subtree stats counters and the subtree-level `adminAirdropUsed` tracking

## Notes

- `BeamioUserCardFactoryPaymasterV07` was deployed first, then `BeamioUserCardDeployerV07.setFactory(...)` was executed.
- After deploying `BeamioUserCard`, `BeamioFactoryPaymasterV07.setUserCard(...)` was executed so the AA factory points to the live card contract.
- Explorer verification was completed through CoNET Explorer API using minimal `standard-input` payloads, because direct `hardhat verify` fallback to full solc input hit `413 Request Entity Too Large`.
- To eliminate the Solidity runtime code size warning on `BeamioUserCard`, admin subtree limit logic and subordinate-clear bookkeeping were refactored into `BeamioUserCardGovernanceModuleV1`; this preserved the public API while reducing the main card runtime size enough for compile-time deployment checks to pass without the EIP-170 warning.
- Deployment records are stored in:
  - `deployments/conet-FullAccountAndUserCard.json`
  - `deployments/conet-UserCardModules.json`

## How To Recheck On-Chain Configuration

- Check `BeamioUserCardFactoryPaymasterV07` on-chain getters:
  - `defaultRedeemModule()`
  - `defaultIssuedNftModule()`
  - `defaultFaucetModule()`
  - `defaultGovernanceModule()`
  - `defaultMembershipStatsModule()`
  - `defaultAdminStatsQueryModule()`
  - `aaFactory()`
  - `quoteHelper()`
  - `deployer()`
  - `metadataBaseURI()`
  - `USDC_TOKEN()`
- Check `BeamioUserCard` on-chain getters:
  - `factoryGateway()`
  - `owner()`
  - `currency()`
  - `pointsUnitPriceInCurrencyE6()`
  - `uri(0)`
  - `getAdminList()` / `adminParent(address)` — admin 列表与 parent 关系
- Check `BeamioFactoryPaymasterV07.beamioUserCard()` and confirm it equals `0xfF1AA6A6744C1aB9F76E8a0a09a12CD385cAB70e`.
- Confirm all deployed module addresses show verified source code on [CoNET Explorer](https://mainnet.conet.network/).

## How To Redeploy Or Reverify

- Reuse the current CoNET dependencies:
  - `EXISTING_ORACLE_ADDRESS=0x32aa4fC3D3506850b27F767Bf582f4ec449de224`
  - `EXISTING_QUOTE_HELPER_ADDRESS=0x2c700841f61373FB4eDBD6710ab075c84051731d`
  - `USDC_ADDRESS=0x28fBBb6C5C06A4736B00A540b66378091c224456`
- Redeploy the combined account + usercard stack with:
  - `npx hardhat run scripts/deployFullAccountAndUserCard.ts --network conet`
- If UserCard auxiliary modules need to be rebound, re-run the module deployment/binding flow and update `deployments/conet-UserCardModules.json`.
- For CoNET Explorer verification, prefer the minimal `standard-input` API flow instead of plain `hardhat verify`, because the explorer may reject large fallback payloads with `413 Request Entity Too Large`.
