# BeamioMyBrandsDashboard RPC budget

- Proxy: `0x1e156e2aDaBce8f7a03445ee6A8939D3B90eb05D`
- Measured: 2026-08-11T02:35:04.815Z
- EOA: `0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1`
- Cards in call: 3
- `snapshotCards` eth_call count: **1** (expected 1)
- Latency: 343 ms

SilentPassUI My Brands feeder uses this for display-card assets; coupon filter uses `balanceBatch` (1 eth_call per card with known tokenIds).
