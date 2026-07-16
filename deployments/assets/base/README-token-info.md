# BaseScan ERC20 Token Info

The BaseScan USDC page demonstrates two separate layers:

1. The verified ERC20 implementation supplies `name`, `symbol`, `decimals`,
   balances, supply and transfer data on-chain.
2. The token logo, display name overrides, website and social links are
   BaseScan Token Info data. They are not standard ERC20 storage fields and
   cannot be set by `name()`/`symbol()` or contract verification.

For the new Base deployments, submit the three entries in `token-info.json`
through BaseScan's Token Update / Token Info form after the implementation
and ERC1967 proxy are verified. Upload the matching 256px PNG:

- `BUNIT-256.png` — the supplied B-Unit icon
- `GB-256.png` — the existing GB icon
- `wCNET-256.png` — the supplied wCNET icon

The old wCNET address
`0x35bFAD2832E916e54474c4ca9DBd71843C539503` is deprecated and must not be
submitted as the new canonical token.
