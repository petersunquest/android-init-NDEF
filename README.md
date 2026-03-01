# Beamio Commerce Protocol (BCP)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-%5E0.8.20-blue)](https://docs.soliditylang.org/)
[![Status](https://img.shields.io/badge/Status-Beta-orange)]()

**A standard interface for programmable cascading payments and atomic asset containers on EVM chains.**

Beamio Commerce Protocol (BCP) is a set of open-source smart contracts designed to bridge the gap between Web3 asset sovereignty and Web2 commercial usability. It provides the infrastructure for **Tethered Hybrid Accounts** and **Asset-Agnostic Settlements**.

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

## Deployed Addresses (Base Mainnet)

Canonical infrastructure; do not redeploy. See [deployments/BASE_MAINNET_FACTORIES.md](deployments/BASE_MAINNET_FACTORIES.md) for details.

| Role            | Address |
|-----------------|--------|
| AA Factory      | `0xFD48F7a6bBEb0c0C1ff756C38cA7fE7544239767` |
| Card Factory    | `0xDdD5c17E549a4e66ca636a3c528ae8FAebb8692b` |

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
