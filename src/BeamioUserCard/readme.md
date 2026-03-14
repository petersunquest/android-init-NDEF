# BeamioUserCard Deployment Notes

## Base Mainnet Deployment

- Network: `base`
- Chain ID: `8453`
- RPC: `https://1rpc.io/base`
- Explorer: [https://basescan.org/](https://basescan.org/)
- Deployer: `0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1`

### Base Reused Existing Dependencies

- `BeamioOracle`: `0xDa4AE8301262BdAaf1bb68EC91259E6C512A9A2B`
- `BeamioQuoteHelperV07` used by `AA Factory`: `0x50953EB5190ee7dabb0eA86a96364A540a834059`
- `BeamioQuoteHelperV07` used by current `Card Factory`: `0x291BDb7044B3C31e62Cb07A47fe48d4835954ffF`
- `Base USDC`: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`

### Base Current Active Contracts

- Current `BeamioUserCardFactoryPaymasterV07`: [`0xE091a0A974a40bCee36288193376294a19a293aE`](https://basescan.org/address/0xE091a0A974a40bCee36288193376294a19a293aE)
- Current active `BeamioUserCard` referenced by `AA Factory`: [`0xBCcfA50d2a5917C7A8662177F5F4B7A175787270`](https://basescan.org/address/0xBCcfA50d2a5917C7A8662177F5F4B7A175787270)

### Base Historical Combined Deployment Record

From `deployments/base-FullAccountAndUserCard.json` (`2026-02-13T23:36:00.000Z`):

- `BeamioUserCardPlaceholder`: [`0xE0d05CfB12a1DfE04Fb9b4ba583D306691e9313D`](https://basescan.org/address/0xE0d05CfB12a1DfE04Fb9b4ba583D306691e9313D)
- `BeamioUserCardRedeemModuleVNext`: [`0x9566ce3B07d5DB5d8c63a93179A541C8b2f11448`](https://basescan.org/address/0x9566ce3B07d5DB5d8c63a93179A541C8b2f11448)
- `BeamioUserCardDeployerV07`: [`0x719DdE8C7917AF06cd66bB7e2118fa2F2eC81ED9`](https://basescan.org/address/0x719DdE8C7917AF06cd66bB7e2118fa2F2eC81ED9)
- Historical `BeamioUserCardFactoryPaymasterV07`: [`0x19C000c00e6A2b254b39d16797930431E310BEdd`](https://basescan.org/address/0x19C000c00e6A2b254b39d16797930431E310BEdd)
- `BeamioUserCard`: [`0xBCcfA50d2a5917C7A8662177F5F4B7A175787270`](https://basescan.org/address/0xBCcfA50d2a5917C7A8662177F5F4B7A175787270)

From `deployments/base-UserCardFactory.json` (`2026-03-14T00:16:32.334Z`):

- Current `BeamioUserCardDeployerV07`: [`0xc09a721dA54Ca3C492c169a0CB282f1ED8BD53e0`](https://basescan.org/address/0xc09a721dA54Ca3C492c169a0CB282f1ED8BD53e0)
- Current `BeamioUserCardFactoryPaymasterV07`: [`0xE091a0A974a40bCee36288193376294a19a293aE`](https://basescan.org/address/0xE091a0A974a40bCee36288193376294a19a293aE)

### Base Registered Module Addresses

From on-chain reads and `deployments/base-UserCardModules.json`:

- `defaultRedeemModule`: [`0x7AD391Eea7f21472872DA9E98b76aC70107432AD`](https://basescan.org/address/0x7AD391Eea7f21472872DA9E98b76aC70107432AD)
- `defaultIssuedNftModule`: [`0x6ee95325dEF45445604F5790e5690CbB6ae00150`](https://basescan.org/address/0x6ee95325dEF45445604F5790e5690CbB6ae00150)
- `defaultFaucetModule`: [`0x1406EfDC2b00881c38497E3933861934dfbaB355`](https://basescan.org/address/0x1406EfDC2b00881c38497E3933861934dfbaB355)
- `defaultGovernanceModule`: [`0x7AF12402E341007188c048175266a48b0B4440de`](https://basescan.org/address/0x7AF12402E341007188c048175266a48b0B4440de)
- `defaultMembershipStatsModule`: [`0x082F5b7d824871B2B5cc2142F2609d5F03060EF3`](https://basescan.org/address/0x082F5b7d824871B2B5cc2142F2609d5F03060EF3)
- `defaultAdminStatsQueryModule`: [`0xDF69297B891840648dafb66d2799499301561BdE`](https://basescan.org/address/0xDF69297B891840648dafb66d2799499301561BdE)

### Base Factory Configuration

Current on-chain `BeamioUserCardFactoryPaymasterV07` configuration:

- `USDC_TOKEN`: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- `quoteHelper`: `0x291BDb7044B3C31e62Cb07A47fe48d4835954ffF`
- `deployer`: `0x324dCda8fF2CE1E9126e528d5A41CF72a6612E96`
- `aaFactory`: `0xD86403DD1755F7add19540489Ea10cdE876Cc1CE`
- `metadataBaseURI`: `https://beamio.app/api/metadata/0x`

### Base Card Constructor Record

From `deployments/base-UserCard.json` (`2026-02-14T20:02:50.581Z`):

- `uri_`: `https://beamio.app/api/metadata/0x`
- `currency_`: `4`
- `pointsUnitPriceInCurrencyE6_`: `1000000`
- `initialOwner`: `0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1`
- `gateway_`: `0xD86403DD1755F7add19540489Ea10cdE876Cc1CE`

## CoNET Mainnet Deployment

- Network: `conet`
- Chain ID: `224400`
- RPC: `https://mainnet-rpc.conet.network`
- Explorer: [https://mainnet.conet.network/](https://mainnet.conet.network/)
- Deployment time: `2026-03-12`
- Deployer: `0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1`

## Reused Existing Dependencies

- `BeamioOracle`: `0x06a1e0D55B4db57Aa906Eff332902F5CA7a25dd4`
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

## BeamioUserCard Constructor Arguments

- `uri_`: `https://beamio.app/api/metadata/0x`
- `currency_`: `4`
- `pointsUnitPriceInCurrencyE6_`: `1000000`
- `initialOwner`: `0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1`
- `gateway_`: `0x16B868162963C6E540d4F2fdC8BE503c19fe6E71`

## Admin Stats

The card now keeps on-chain admin-scoped hourly stats for token `0` and membership flows.

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

## Notes

- `BeamioUserCardFactoryPaymasterV07` was deployed first, then `BeamioUserCardDeployerV07.setFactory(...)` was executed.
- After deploying `BeamioUserCard`, `BeamioFactoryPaymasterV07.setUserCard(...)` was executed so the AA factory points to the live card contract.
- Explorer verification was completed through CoNET Explorer API using minimal `standard-input` payloads, because direct `hardhat verify` fallback to full solc input hit `413 Request Entity Too Large`.
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
  - `EXISTING_ORACLE_ADDRESS=0x06a1e0D55B4db57Aa906Eff332902F5CA7a25dd4`
  - `EXISTING_QUOTE_HELPER_ADDRESS=0x2c700841f61373FB4eDBD6710ab075c84051731d`
  - `USDC_ADDRESS=0x28fBBb6C5C06A4736B00A540b66378091c224456`
- Redeploy the combined account + usercard stack with:
  - `npx hardhat run scripts/deployFullAccountAndUserCard.ts --network conet`
- If UserCard auxiliary modules need to be rebound, re-run the module deployment/binding flow and update `deployments/conet-UserCardModules.json`.
- For CoNET Explorer verification, prefer the minimal `standard-input` API flow instead of plain `hardhat verify`, because the explorer may reject large fallback payloads with `413 Request Entity Too Large`.
