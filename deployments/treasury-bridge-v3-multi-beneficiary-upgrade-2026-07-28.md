# TreasuryBridgeV3 implementation — multi-beneficiary upgrade (2026-07-28)

Proxy (unchanged, Base + CoNET CREATE2 same address):
  0xa208982212978550594A7FEEB70a61665d129003

## New implementations

| Chain | Implementation | Upgrade tx | Explorer |
|---|---|---|---|
| CoNET 224422 | `0x089FA035177532f1384f8D3dD8ae39253A24C0E8` | `0xa42e8f222b2f27e66e0d5517090e905fedb7d5197db85b7912fe8d3106b909ef` | https://mainnet.conet.network/address/0x089FA035177532f1384f8D3dD8ae39253A24C0E8#code |
| Base 8453 | `0x55572D2D76451A223717cE78F6Ace9D177F92c61` | `0x1debcedfdb9d52fefc0725e266f205d839fbb49eb04eb91511a20cf430e00eeb` | https://basescan.org/address/0x55572D2D76451A223717cE78F6Ace9D177F92c61#code |

## Verification

- CoNET Blockscout v2: **verified** (`is_verified` + `is_partially_verified`) via
  `deployments/base-TreasuryBridgeV3-standard-input-VERIFY-FORM.json`
  (`npx tsx scripts/verifyTreasuryBridgeV3ImplOnScan.ts`)
- BaseScan: local bytecode precheck **passed**; API key missing in this environment —
  manual upload of the same VERIFY-FORM JSON:
  - Type: Solidity (Standard-Json-Input)
  - Compiler: `v0.8.35+commit.47b9dedd`
  - Contract Name: `project/src/b-unit/TreasuryBridgeV3.sol:TreasuryBridgeV3`
  - Optimizer: yes, runs=0, viaIR, evmVersion=cancun, bytecodeHash=none

Regenerate verify JSON (must use artifact `buildInfoId`, not largest build-info):

```bash
npm run compile
npm run export:treasury-bridge-v3-verify-json
VERIFY_CHAIN=both npx tsx scripts/verifyTreasuryBridgeV3ImplOnScan.ts
```

## Breaking ABI

`BridgeOperation` / `voteBridgeOperation` now use `address[] beneficiaries` + `uint256[] amounts`.
CoNET-SI `treasuryV3Listen` must be redeployed on miner hosts before new bridge ops.
