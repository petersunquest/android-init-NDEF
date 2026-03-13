# BeamioUserCard Deployment Notes

## Base Mainnet Deployment

- Network: `base`
- Chain ID: `8453`
- RPC: `https://base-rpc.conet.network`
- Explorer: [https://basescan.org/](https://basescan.org/)
- Deployer: `0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1`

### Base Reused Existing Dependencies

- `BeamioOracle`: `0xDa4AE8301262BdAaf1bb68EC91259E6C512A9A2B`
- `BeamioQuoteHelperV07` used by `AA Factory`: `0x50953EB5190ee7dabb0eA86a96364A540a834059`
- `BeamioQuoteHelperV07` used by current `Card Factory`: `0x291BDb7044B3C31e62Cb07A47fe48d4835954ffF`
- `Base USDC`: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`

### Base Current Active Contracts

- Current `BeamioUserCardFactoryPaymasterV07`: [`0x46E8a69f7296deF53e33844bb00D92309ab46233`](https://basescan.org/address/0x46E8a69f7296deF53e33844bb00D92309ab46233)
- Current active `BeamioUserCard` referenced by `AA Factory`: [`0xBCcfA50d2a5917C7A8662177F5F4B7A175787270`](https://basescan.org/address/0xBCcfA50d2a5917C7A8662177F5F4B7A175787270)

### Base Historical Combined Deployment Record

From `deployments/base-FullAccountAndUserCard.json` (`2026-02-13T23:36:00.000Z`):

- `BeamioUserCardPlaceholder`: [`0xE0d05CfB12a1DfE04Fb9b4ba583D306691e9313D`](https://basescan.org/address/0xE0d05CfB12a1DfE04Fb9b4ba583D306691e9313D)
- `BeamioUserCardRedeemModuleVNext`: [`0x9566ce3B07d5DB5d8c63a93179A541C8b2f11448`](https://basescan.org/address/0x9566ce3B07d5DB5d8c63a93179A541C8b2f11448)
- `BeamioUserCardDeployerV07`: [`0x719DdE8C7917AF06cd66bB7e2118fa2F2eC81ED9`](https://basescan.org/address/0x719DdE8C7917AF06cd66bB7e2118fa2F2eC81ED9)
- Historical `BeamioUserCardFactoryPaymasterV07`: [`0x19C000c00e6A2b254b39d16797930431E310BEdd`](https://basescan.org/address/0x19C000c00e6A2b254b39d16797930431E310BEdd)
- `BeamioUserCard`: [`0xBCcfA50d2a5917C7A8662177F5F4B7A175787270`](https://basescan.org/address/0xBCcfA50d2a5917C7A8662177F5F4B7A175787270)

From `deployments/base-UserCardFactory.json` (`2026-03-11T03:18:05.030Z`):

- Current `BeamioUserCardDeployerV07`: [`0x324dCda8fF2CE1E9126e528d5A41CF72a6612E96`](https://basescan.org/address/0x324dCda8fF2CE1E9126e528d5A41CF72a6612E96)
- Current `BeamioUserCardFactoryPaymasterV07`: [`0x46E8a69f7296deF53e33844bb00D92309ab46233`](https://basescan.org/address/0x46E8a69f7296deF53e33844bb00D92309ab46233)

### Base Registered Module Addresses

From on-chain reads and `deployments/base-UserCardModules.json`:

- `defaultRedeemModule`: [`0xCa220CBc4aeB8d5c59EaDfAdcFf025FC9339Cd84`](https://basescan.org/address/0xCa220CBc4aeB8d5c59EaDfAdcFf025FC9339Cd84)
- `defaultIssuedNftModule`: [`0xa6Ba46C351182206c719BA2b29A02357d5580344`](https://basescan.org/address/0xa6Ba46C351182206c719BA2b29A02357d5580344)
- `defaultFaucetModule`: [`0x60154A9C51A33994A3873a8E53f7595717ae29ED`](https://basescan.org/address/0x60154A9C51A33994A3873a8E53f7595717ae29ED)
- `defaultGovernanceModule`: [`0xF4EF9306eC41b0Ed7136db232A55600EAAfF1eFd`](https://basescan.org/address/0xF4EF9306eC41b0Ed7136db232A55600EAAfF1eFd)
- `defaultMembershipStatsModule`: [`0x2ab3534062dD731DBD6eB0cE78597DAFf17a46Bb`](https://basescan.org/address/0x2ab3534062dD731DBD6eB0cE78597DAFf17a46Bb)
- `membershipStatsQueryModule`: [`0x55bbc609101F4137eaD08cf8D47F06f58575a4e1`](https://basescan.org/address/0x55bbc609101F4137eaD08cf8D47F06f58575a4e1)

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
