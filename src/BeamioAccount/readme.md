# BeamioAccount Deployment Notes

## Development rules (UI / API / V1·V2 split)

**Canonical product & engineering rules:** `.cursor/rules/beamio-aa-account-dev.mdc`

Summary:

- **V1** Factory/Account: keep for existing Express Pay; do **not** create new institutional wallets here; never force-upgrade deployed AAs.
- **V2** Factory/Account: all **institutional-grade** + new AA creates; on-chain multisig tasks, reserved transfers, policy lock, disable container/createRedeem when not 1-of-1.
- Old V1 institutional (index ≥ 1): **abandoned** — UI/API must not treat them as institutional.
- Cross-chain same address via Nick CREATE2 continues for **each** generation (V1 and V2 separately).

## Cross-chain same address (Nick CREATE2)

**Factory + per-EOA AA addresses are identical on every chain where the same bytecode is deployed via Nick CREATE2 with fixed initCode.**

Current status: CoNET (224422) has the EntryPoint-aware bytecode deployed at the new address below. Base (8453) still uses the previous Factory until a Base deploy signer is configured and the same bytecode is deployed there.

| Contract | CREATE2 salt | CoNET (224422) |
|---|---|---|
| **V1 BeamioFactoryPaymasterV07** | `id("beamio.aa.factory.v1")` | [`0x869B31C87ABd9bFB858F5183Ef6021b28ED225E2`](https://mainnet.conet.network/address/0x869B31C87ABd9bFB858F5183Ef6021b28ED225E2) |
| **V1 BeamioAccount** (per EOA, index) | `keccak256(abi.encode(creator, index))` | Nick + V1 Account initCode |
| **V2 BeamioFactoryInstitutionalV2** | `id("beamio.aa.factory.v2")` | [`0x02F00061ae54d76C3308EA24D2B3d0a24df60fAd`](https://mainnet.conet.network/address/0x02F00061ae54d76C3308EA24D2B3d0a24df60fAd) ✅ verified（2026-07-22 owner-first 修复重部署；旧 `0x702bA236…` 仅历史） |
| **V2 BeamioAccountInstitutionalV2** | `keccak256("beamio.aa.v2", creator, index)` | Sample AA[0]: [`0x9707864d44b0d0b21878eFFbD51f5eE499a82B71`](https://mainnet.conet.network/address/0x9707864d44b0d0b21878eFFbD51f5eE499a82B71) ✅ verified |

Deploy JSON: `deployments/conet-BeamioFactoryInstitutionalV2.json`. Client constant: `BEAMIO_AA_FACTORY_V2`.

**Same address ≠ shared state.** Container nonce, ERC1155 balances, and registry counters remain **per chain**.

### Constructor / post-deploy (per chain)

**Factory constructor** (chain-independent initCode):

```solidity
constructor(uint256 initialAccountLimit, address admin_)
// default: accountLimit=100, admin=0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1
```

**One-time chain wiring** (admin):

```solidity
initializeChainConfig(module_, quoteHelper_, userCard_, usdc_)
```

Module / QuoteHelper / default UserCard / USDC stay **per-chain**; only Factory + AA CREATE2 addresses are cross-chain constant.

### Deploy workflow

```bash
npm run clean && npm run compile
npx hardhat run scripts/predictBeamioAAStackCreate2.ts

# Nick deploy Factory (Base + CoNET; same predicted address)
npx hardhat run scripts/deployBeamioAAFactoryCreate2.ts --network base
npx hardhat run scripts/deployBeamioAAFactoryCreate2.ts --network conet

# Per-chain initializeChainConfig (+ optional Card Factory setAAFactory)
npx hardhat run scripts/configureBeamioAAFactoryOnChain.ts --network base
npx hardhat run scripts/configureBeamioAAFactoryOnChain.ts --network conet

# Card Factory owner: point _aaFactory to cross-chain Factory
CARD_FACTORY_OWNER_PK=0x... npx hardhat run scripts/setCardFactoryAAFactory.ts --network base
```

Constants: `scripts/aaDeployConstants.ts`  
Meta: `deployments/beamioAAFactory-create2-meta.json`

### Application constants

- **Base:** `BEAMIO_AA_FACTORY` = `0xe58F457Cd5674516400013E8d338054be556A730` until Base is redeployed with the current bytecode
- **CoNET:** `CONET_AA_FACTORY` = `0x869B31C87ABd9bFB858F5183Ef6021b28ED225E2`
- **Deprecated:** `BeamioAccountDeployer` per-chain addresses — AA creation uses Nick CREATE2 in Factory

After Solidity changes: re-run predict, redeploy **all** chains, sync artifacts:

```bash
node scripts/syncBeamioAccountToX402sdk.mjs
cd src/x402sdk && npm run build
```

---

## Base Mainnet Deployment (legacy reference)

- Network: `base`
- Chain ID: `8453`
- RPC: `https://base-rpc.conet.network`
- Explorer: [https://basescan.org/](https://basescan.org/)
- Deployer: `0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1`

### Base Reused Existing Dependencies

- `BeamioOracle`: `0xDa4AE8301262BdAaf1bb68EC91259E6C512A9A2B`
- `BeamioQuoteHelperV07` (configure script default): `0xfa30c2086ff9a3D74576d55c2027586797A52F29`
- `Base USDC`: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- `EntryPoint v0.7`: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`

### Legacy Factory (pre–cross-chain redesign)

- Old `BeamioFactoryPaymasterV07`: `0x4b31D6a05Cdc817CAc1B06369555b37a5b182122` (per-chain deployer model)
- Old `BeamioAccountDeployer` (Base): `0xC51858BcF81D0Ce05D51fAd080fCF034B187E753`

Historical combined deployment: `deployments/base-FullAccountAndUserCard.json`

### Base post-deploy defaults (`configureBeamioAAFactoryOnChain.ts`)

- `containerModule`: `0xF50e41dFB647F8a62F3DBAf8f3Fcb39d74C7c9C8`
- `quoteHelper`: `0xfa30c2086ff9a3D74576d55c2027586797A52F29`
- `beamioUserCard`: from `config/base-addresses.json` `BEAMIO_USER_CARD_ASSET_ADDRESS`
- `USDC`: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`

### BeamioAccount initCode

- `entryPoint_`: `0x0000000071727De22E5E9d8BAf0edAc6f37da032` only (cross-chain constant)

## CoNET Mainnet Deployment

- Network: `conet`
- Chain ID: `224422`
- RPC: `https://rpc1.conet.network`
- Explorer: [https://mainnet.conet.network/](https://mainnet.conet.network/)

### CoNET post-deploy defaults (`configureBeamioAAFactoryOnChain.ts`)

From `deployments/conet-addresses.json`:

- `beamioContainerModule`: `0xC0bd357A12100C47FB19E1a489B4375F44D63b8F`
- `beamioQuoteHelperV07`: `0x052e34ed096875D0F1ce58eEFb88Ed676Fd1305f`
- `BEAMIO_USER_CARD_DEFAULT`: `0x5237e3A10e26bE616A02b49cbDf38d413d4d847F`
- `conetUsdc`: `0x40E302aBC19f6c9f376D7Dee037192a7a203e3Aa`

Legacy per-chain AA Factory: `0x0c916C09393898D87854f340e467846cc2EAc83E` (replaced by cross-chain `BEAMIO_AA_FACTORY`).

## BaseScan verification

```bash
npm run clean && npm run compile
node scripts/exportStandardJsonFromBuildInfo.mjs BeamioFactoryPaymasterV07 --full
# Prefer pruned FORM JSON if UI times out (see beamio-base-basescan-verify.mdc)
```

Constructor args (ABI-encoded):

```
(uint256 initialAccountLimit, address admin_)
= (100, 0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1)
```

Contract name: `project/src/BeamioAccount/BeamioFactoryPaymasterV07.sol:BeamioFactoryPaymasterV07`
