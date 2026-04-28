# Beamio Commerce Protocol (BCP)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-%5E0.8.20-blue)](https://docs.soliditylang.org/)
[![Status](https://img.shields.io/badge/Status-Beta-orange)]()

**An open-source Beamio stack for programmable payments, ERC-4337 accounts, ERC-1155 cards, NTAG 424 DNA provisioning, and SUN verification.**

Beamio Commerce Protocol (BCP) is a set of open-source smart contracts designed to bridge the gap between Web3 asset sovereignty and Web2 commercial usability. It provides the infrastructure for **Tethered Hybrid Accounts** and **Asset-Agnostic Settlements**.

This repository also contains:

- `src/x402sdk` - the Beamio API / cluster server, including the `/api/sun` endpoint used to verify NTAG 424 DNA SUN taps.
- `src/Android-init-NDEF` - the Android app used to initialize cards, read SUN URLs, decode local payloads, and compare local results with server-side verification.

---

## Core Features

### 1. Atomic Asset Container

A universal standard for bundling heterogeneous assets (ERC20 + ERC721 + ERC1155) into a single, transferable, and claimable ephemeral contract.

- **Use case:** Social red packets ("Cashcode"), cross-marketing bundles.
- **Mechanism:** Hash-time lock (HTLC) style distribution; container module for asset deduction order and settlement.
- **In this repo:** `BeamioContainerModuleV07` (container logic), `BeamioUserCard` (ERC1155 points + membership + redeem).

### 2. Programmable Cascading Payment

A logic layer that allows merchants/developers to define the priority of asset deduction.

- **Logic:** `[Promotional Voucher] → [Stored Value] → [Base Settlement Token (USDC)]`
- **Atomicity:** Multiple asset deductions and currency conversions in a single transaction.
- **In this repo:** Implemented via the container module and quote helper (e.g. `BeamioQuoteHelperV07`).

### 3. Tethered Hybrid Account

A standard interface linking an EOA (Controller) with an ERC-4337 Smart Account (Executor) via application-layer delegation, enabling secure pull payments without exposing private keys.

- **In this repo:** `BeamioAccount` (ERC-4337 compatible), `BeamioFactoryPaymasterV07` (AA factory), `BeamioAccountDeployer` (CREATE2 deployer).

---

## Installation & Usage

### Installation

```bash
git clone https://github.com/beamio-APP/BeamioContract.git
cd BeamioContract
npm install
```

### Environment

```bash
cp .env.example .env
# Edit .env: RPC URLs, PRIVATE_KEY, BASESCAN_API_KEY (optional, for verification)
```

### Compile

```bash
npm run compile
```

### Build The Android APK

The Android NTAG 424 DNA app lives in `src/Android-init-NDEF`.

```bash
cd src/Android-init-NDEF
./gradlew assembleDebug
```

The debug APK will be generated under:

```bash
src/Android-init-NDEF/app/build/outputs/apk/debug/
```

For a quick Kotlin-only validation during development:

```bash
cd src/Android-init-NDEF
./gradlew :app:compileDebugKotlin
```

### Run The SUN Server

The SUN verification endpoint is implemented in `src/x402sdk`.

```bash
cd src/x402sdk
corepack enable
corepack yarn install
corepack yarn build
node dist/server.js
```

The app expects the canonical endpoint:

```text
https://beamio.app/api/sun
```

You must deploy the cluster entry so that `GET /api/sun` returns JSON from the x402 server.

### Example: Resolving a Tethered Account

```solidity
// Resolve the ERC-4337 account for an EOA (via factory)
IBeamioFactoryPaymasterV07 factory = IBeamioFactoryPaymasterV07(AA_FACTORY_ADDRESS);
address account = factory.beamioAccountOf(creatorEOA);
// account is the smart account; EOA remains the controller.
```

### Example: Creating a UserCard (ERC1155) via Factory

```solidity
// Create a user card bound to an EOA (price in E6, e.g. 1 CAD = 1 token → 1e6)
IBeamioUserCardFactoryPaymasterV07 cardFactory = IBeamioUserCardFactoryPaymasterV07(CARD_FACTORY_ADDRESS);
// Only paymaster/owner can call createCardCollectionWithInitCode(cardOwner, currency, priceE6, initCode);
address card = cardFactory.latestCardOfOwner(cardOwnerEOA);
```

---

## Repository Structure

```
├── src/
│   ├── BeamioAccount/              # Tethered Hybrid Account (ERC-4337)
│   │   ├── BeamioAccount.sol
│   │   ├── BeamioAccountDeployer.sol
│   │   ├── BeamioContainerModuleV07.sol   # Atomic container + cascading payment
│   │   ├── BeamioFactoryPaymasterV07.sol
│   │   └── BeamioTypesV07.sol
│   ├── BeamioUserCard/             # ERC1155 cards, redeem, pricing
│   │   ├── BeamioUserCard.sol
│   │   ├── BeamioUserCardFactoryPaymasterV07.sol
│   │   ├── BeamioUserCardDeployerV07.sol
│   │   ├── BeamioERC1155Logic.sol
│   │   ├── BeamioQuoteHelperV07.sol
│   │   ├── RedeemModule.sol
│   │   └── ...
│   ├── Android-init-NDEF/          # Android NTAG 424 DNA init/check app
│   ├── x402sdk/                    # Beamio API server, SUN verification, helpers
│   └── contracts/                  # Shared (ERC20, ERC721, ERC1155, utils)
├── scripts/                        # Deployment and tooling
│   ├── deployUserCardFactory.ts
│   ├── createUserCardForEOA.ts
│   ├── deployBeamioAccount.ts
│   └── ...
├── deployments/                    # Deployment records and addresses
│   └── BASE_MAINNET_FACTORIES.md   # Canonical AA & Card factory addresses
├── hardhat.config.ts
└── package.json
```

---

## NTAG 424 DNA Quick Rules

These are the final practical rules used in this repo to avoid repeated SUN provisioning regressions.

### Route Detection

- `fresh`: authenticate with `defaultKey0` only after `globalKey0` fails with the expected auth error.
- `rewritten`: authenticate with `globalKey0` successfully. This includes cards that were partially initialized before and now already carry Beamio keys.

### Fresh Card Flow

1. Authenticate with `defaultKey0`.
2. Change `key0` to `globalKey0`.
3. Re-authenticate with `globalKey0`.
4. Change `key2` to `globalKey2`.
5. Prefer secure chunked NDEF write; if needed, fall back to ISO `UPDATE BINARY`.
6. Apply compact SDM settings derived from the template URL.
7. Success for `fresh` means the readback URL matches the expected template exactly.

### Rewritten Card Flow

1. Authenticate with `globalKey0`.
2. Refresh `key2` using `globalKey2` when possible; fall back only when the card clearly requires it.
3. Prefer native NDEF file `0x02`.
4. If a valid dynamic Beamio SUN URL is already active, preserve it instead of destroying and rebuilding it.
5. If repair is needed, prefer same-session write and settings changes first, then ISO rewrite fallback, then post-write fallback.
6. Success for `rewritten` means the card exposes a valid dynamic URL under `https://beamio.app/api/sun` and local decode returns a non-placeholder `tagId` / `counter`.

### Verification Rules

- Android `check` first performs local decode with `globalKey2`.
- Android then calls `https://beamio.app/api/sun?debug=1`.
- A healthy result means:
  - local `tagId` equals server `tagId`
  - local `counter` equals server `counter`
  - server `valid=true`
  - server `macValid=true`

### Operational Notes

- A card may enter the `rewritten` path even when the user believes it is "new" if a prior attempt already rotated keys or partially enabled dynamic SUN.
- For user-facing success screens, only compact notes should be shown. Deep fallback probes and low-level APDU diagnostics are for failure analysis, not normal success output.
- The canonical SUN endpoint in this repo is `https://beamio.app/api/sun`.

---

## NFC Components

### Android App

- Path: `src/Android-init-NDEF`
- Purpose: initialize NTAG 424 DNA cards, read dynamic URLs, locally decode `tagId` / `counter`, and compare with server verification.

### Server Verification

- Path: `src/x402sdk`
- Endpoint: `GET /api/sun`
- Purpose: verify `uid`, `e`, `c`, and `m`, derive `tagId`, and maintain counter freshness state.

### Deployment Notes

- Android app package: `com.beamio.beamiondefinit`
- Android app requires `INTERNET` permission for `/api/sun?debug=1`
- `x402sdk` uses Yarn 4 via Corepack
- Production routing must expose `GET /api/sun` through the cluster server, not just the website frontend

---

## Deployed Addresses (Base Mainnet)

Canonical infrastructure; do not redeploy. See [deployments/BASE_MAINNET_FACTORIES.md](deployments/BASE_MAINNET_FACTORIES.md) for details.

| Role            | Address |
|-----------------|--------|
| AA Factory      | `0x4b31D6a05Cdc817CAc1B06369555b37a5b182122` |
| Card Factory    | `0x2EB245646de404b2Dce87E01C6282C131778bb05` |

---

## Contributing

We welcome contributions from the community. Whether it's a bug fix, new feature, or documentation improvement, please open a Pull Request.

1. **Fork** the project  
2. **Create** your feature branch (`git checkout -b feature/AmazingFeature`)  
3. **Commit** your changes (`git commit -m 'Add some AmazingFeature'`)  
4. **Push** to the branch (`git push origin feature/AmazingFeature`)  
5. **Open** a Pull Request  

---

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — System architecture and dependencies  
- [DEPLOY.md](DEPLOY.md) — Deployment instructions  
- [deployments/BASE_MAINNET_FACTORIES.md](deployments/BASE_MAINNET_FACTORIES.md) — Canonical factory addresses for apps  

---

## License

Distributed under the MIT License. See [LICENSE](LICENSE) for more information.
