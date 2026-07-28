# Treasury V3 BaseScan Token Info

After `deployTreasuryV3AssetsCreate2.ts --network base` completes, run:

```bash
npm run prepare:basescan:treasury-v3-token-info
```

Submit each generated entry to BaseScan's Token Info form and upload the
matching 256px PNG:

- `wCNET-256.png`
- `USDC-256.png`
- `GB-256.png`
- `BUNIT-256.png`

The verified ERC20 proxy/implementation supplies `name`, `symbol`, `decimals`,
balances, supply and transfer data. BaseScan's logo and social metadata are
off-chain Token Info data; `contractURI` does not replace that submission.

The source images are intentionally supplied through an operator-controlled
asset staging step. No new hostname is introduced by the V3 deployment.
