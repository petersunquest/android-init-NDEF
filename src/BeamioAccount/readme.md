# BeamioAccount Deployment Notes

## Base Mainnet Deployment

- Network: `base`
- Chain ID: `8453`
- RPC: `https://base-rpc.conet.network`
- Explorer: [https://basescan.org/](https://basescan.org/)
- Deployer: `0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1`

### Base Reused Existing Dependencies

- `BeamioOracle`: `0xDa4AE8301262BdAaf1bb68EC91259E6C512A9A2B`
- `BeamioQuoteHelperV07` used by current `AA Factory`: `0xfa30c2086ff9a3D74576d55c2027586797A52F29`
- `Base USDC`: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- `EntryPoint v0.7`: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`

### Base Current Active Contracts

From `config/base-addresses.ts` and on-chain reads:

- Current `BeamioFactoryPaymasterV07`: [`0x4b31D6a05Cdc817CAc1B06369555b37a5b182122`](https://basescan.org/address/0x4b31D6a05Cdc817CAc1B06369555b37a5b182122)
- Current `BeamioFactoryPaymasterV07.beamioUserCard()`: [`0xBCcfA50d2a5917C7A8662177F5F4B7A175787270`](https://basescan.org/address/0xBCcfA50d2a5917C7A8662177F5F4B7A175787270)

### Base Historical Combined Deployment Record

From `deployments/base-FullAccountAndUserCard.json` (`2026-02-13T23:36:00.000Z`):

- `BeamioAccountDeployer`: [`0xC51858BcF81D0Ce05D51fAd080fCF034B187E753`](https://basescan.org/address/0xC51858BcF81D0Ce05D51fAd080fCF034B187E753)
- `BeamioAccount`: [`0x7FA89BEf84D5047AD9883d6f4A53dE7A0D2815f2`](https://basescan.org/address/0x7FA89BEf84D5047AD9883d6f4A53dE7A0D2815f2)
- `BeamioContainerModuleV07`: [`0xF50e41dFB647F8a62F3DBAf8f3Fcb39d74C7c9C8`](https://basescan.org/address/0xF50e41dFB647F8a62F3DBAf8f3Fcb39d74C7c9C8)
- `BeamioUserCardPlaceholder`: [`0xE0d05CfB12a1DfE04Fb9b4ba583D306691e9313D`](https://basescan.org/address/0xE0d05CfB12a1DfE04Fb9b4ba583D306691e9313D)
- Current `BeamioFactoryPaymasterV07`: [`0x4b31D6a05Cdc817CAc1B06369555b37a5b182122`](https://basescan.org/address/0x4b31D6a05Cdc817CAc1B06369555b37a5b182122)

For reference, an earlier base account-only deployment also exists in `deployments/base-FullSystem.json` (`2026-02-05T08:45:14.576Z`):

- Earlier `BeamioAccountDeployer`: [`0xBD510029d0a72bE2594c1a5FF0C939d5CDAC4B87`](https://basescan.org/address/0xBD510029d0a72bE2594c1a5FF0C939d5CDAC4B87)
- Earlier `BeamioAccount`: [`0x0e640C7af0b8D69551dd6f9F362C21942d381802`](https://basescan.org/address/0x0e640C7af0b8D69551dd6f9F362C21942d381802)

### Base AA Factory On-Chain Registered References

Current on-chain values inside `BeamioFactoryPaymasterV07`:

- `containerModule`: `0xF50e41dFB647F8a62F3DBAf8f3Fcb39d74C7c9C8`
- `quoteHelper`: `0xfa30c2086ff9a3D74576d55c2027586797A52F29`
- `beamioUserCard`: `0xBCcfA50d2a5917C7A8662177F5F4B7A175787270`
- `deployer`: `0xC51858BcF81D0Ce05D51fAd080fCF034B187E753`
- `USDC`: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`

### Base BeamioFactoryPaymasterV07 Constructor Record

Using the current active factory address `0x4b31D6a05Cdc817CAc1B06369555b37a5b182122`, the recorded constructor dependencies from the combined deployment are:

- `initialAccountLimit`: `100`
- `deployer_`: `0xC51858BcF81D0Ce05D51fAd080fCF034B187E753`
- `module_`: `0xF50e41dFB647F8a62F3DBAf8f3Fcb39d74C7c9C8`
- `quoteHelper_`: `0xfa30c2086ff9a3D74576d55c2027586797A52F29`
- `userCard_`: `0xE0d05CfB12a1DfE04Fb9b4ba583D306691e9313D`
- `usdc_`: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`

### Base BeamioAccount Constructor Record

From the deployed account artifacts:

- `entryPoint_`: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`

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
- `EntryPoint v0.7`: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`

## Deployed Contracts

- `BeamioAccountDeployer`: [`0x466691E5499834c8695b37A4C868cEe79Ebc5526`](https://mainnet.conet.network/address/0x466691E5499834c8695b37A4C868cEe79Ebc5526)
- `BeamioAccount`: [`0x720e7abcD51D0A0f1f8488574c7868B9600d24e0`](https://mainnet.conet.network/address/0x720e7abcD51D0A0f1f8488574c7868B9600d24e0)
- `BeamioContainerModuleV07`: [`0xefc6Ae7C773Ff4050CD716848bCbB48508F78BcD`](https://mainnet.conet.network/address/0xefc6Ae7C773Ff4050CD716848bCbB48508F78BcD)
- `BeamioFactoryPaymasterV07`: [`0x16B868162963C6E540d4F2fdC8BE503c19fe6E71`](https://mainnet.conet.network/address/0x16B868162963C6E540d4F2fdC8BE503c19fe6E71)

## BeamioFactoryPaymasterV07 Constructor Arguments

- `initialAccountLimit`: `100`
- `deployer_`: `0x466691E5499834c8695b37A4C868cEe79Ebc5526`
- `module_`: `0xefc6Ae7C773Ff4050CD716848bCbB48508F78BcD`
- `quoteHelper_`: `0x2c700841f61373FB4eDBD6710ab075c84051731d`
- `userCard_`: `0x0026e5ea3000f2c030f730b13C12f774A1939e1D`
- `usdc_`: `0x28fBBb6C5C06A4736B00A540b66378091c224456`

## On-Chain Registered References

The following values are already registered on-chain inside `BeamioFactoryPaymasterV07`:

- `containerModule`: `0xefc6Ae7C773Ff4050CD716848bCbB48508F78BcD`
- `quoteHelper`: `0x2c700841f61373FB4eDBD6710ab075c84051731d`
- `beamioUserCard`: `0xfF1AA6A6744C1aB9F76E8a0a09a12CD385cAB70e`
- `deployer`: `0x466691E5499834c8695b37A4C868cEe79Ebc5526`
- `USDC`: `0x28fBBb6C5C06A4736B00A540b66378091c224456`

## BeamioAccount Constructor Arguments

- `entryPoint_`: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`

## Notes

- `BeamioFactoryPaymasterV07` was first deployed against `BeamioUserCardPlaceholder`.
- After the live `BeamioUserCard` was deployed, `BeamioFactoryPaymasterV07.setUserCard(0xfF1AA6A6744C1aB9F76E8a0a09a12CD385cAB70e)` was executed, so the AA system now points at the live card contract instead of the placeholder.
- `BeamioAccountDeployer` and all newly deployed account-side contracts were verified on CoNET Explorer.
- Deployment records are stored in `deployments/conet-FullAccountAndUserCard.json`.

## How To Recheck On-Chain Configuration

- Check `BeamioFactoryPaymasterV07` on-chain getters:
  - `containerModule()`
  - `quoteHelper()`
  - `beamioUserCard()`
  - `deployer()`
  - `USDC()`
- Confirm `beamioUserCard()` now points to the live card `0xfF1AA6A6744C1aB9F76E8a0a09a12CD385cAB70e`, not the placeholder.
- Check `BeamioAccount.entryPoint()` and confirm it equals `0x0000000071727De22E5E9d8BAf0edAc6f37da032`.
- Confirm all account-side contracts show verified source code on [CoNET Explorer](https://mainnet.conet.network/).

## How To Redeploy Or Reverify

- Reuse the current CoNET dependencies:
  - `EXISTING_ORACLE_ADDRESS=0x32aa4fC3D3506850b27F767Bf582f4ec449de224`
  - `EXISTING_QUOTE_HELPER_ADDRESS=0x2c700841f61373FB4eDBD6710ab075c84051731d`
  - `USDC_ADDRESS=0x28fBBb6C5C06A4736B00A540b66378091c224456`
- Redeploy the combined account + usercard stack with:
  - `npx hardhat run scripts/deployFullAccountAndUserCard.ts --network conet`
- If only account-side contracts need redeploy, make sure the new `BeamioFactoryPaymasterV07` still points at:
  - the correct `BeamioContainerModuleV07`
  - the correct `BeamioQuoteHelperV07`
  - the intended `BeamioUserCard` or placeholder during staged deployment
- For CoNET Explorer verification, prefer the minimal `standard-input` API flow when plain `hardhat verify` falls back to oversized payloads.
