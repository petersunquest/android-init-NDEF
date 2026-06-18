# BeamioAccount Deployment Notes

## Cross-chain same address (Nick CREATE2)

**Factory + per-EOA AA addresses are identical on every chain where the same bytecode is deployed via Nick CREATE2 with fixed initCode.**

Current status: CoNET (224422) has the EntryPoint-aware bytecode deployed at the new address below. Base (8453) still uses the previous Factory until a Base deploy signer is configured and the same bytecode is deployed there.

| Contract | CREATE2 salt | Predicted (current bytecode) |
|---|---|---|
| **BeamioFactoryPaymasterV07** | `id("beamio.aa.factory.v1")` | CoNET current: [`0x23a331ee3BD3ab8F8772c7AC4a57fc45867C5B07`](https://scan.conet.network/address/0x23a331ee3BD3ab8F8772c7AC4a57fc45867C5B07) |
| **BeamioAccount** (per EOA, index=0) | `keccak256(abi.encode(creator, index))` | Nick factory + `BeamioAccount` initCode(`EntryPoint v0.7`) |

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
- **CoNET:** `CONET_AA_FACTORY` = `0x23a331ee3BD3ab8F8772c7AC4a57fc45867C5B07`
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
