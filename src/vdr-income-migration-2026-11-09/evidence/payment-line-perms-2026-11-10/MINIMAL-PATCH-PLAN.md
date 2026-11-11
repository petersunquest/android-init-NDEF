# Minimal patch plan — payment-line permissions (lab)

**Date:** 2026-11-10  
**Scope:** Local / Anvil / fixture only. **No production deploy.**  
**Status:** Lab fixture implemented under this directory. Production code path stays STATUS QUO pending review.

## Problem

| Contract | Current | Risk if PM/derived wallets get full control |
|---|---|---|
| `ValidatorDepositRedeem` | `admins` → upgrade / arbitrary `withdrawNative`; `redeemAdmins` → business config | PM must **never** hold either |
| `LabMiningPoolPayoutExecutor` | `setExecutor` is `onlyOwner` | Giving PM `owner` = caps + pause + ownership transfer — **over-privilege** |

## Design (least privilege)

```
owner (ops) ── setCaps / setPaused / setMemberManager / transferOwnership
                    │
                    ▼
memberManager (PM) ── setMember / topUpMemberGas only
                    │
                    ▼
members[] (line EOAs) ── payoutBatch only → immutable (vdr, linePool)
```

- **One executor proxy per payment line** (`paymentLineId` in constructor events / off-chain registry).
- `vdr` + `linePool` **immutable** — no redirect.
- Settlement: member calls `payoutBatch` on **that line’s** proxy only.
- Gas top-up: `memberManager` pulls from a **dedicated gas purse** on the proxy (receive ETH / `fundGasPurse`), with per-tx + period caps — **not** VDR `withdrawNative` and **not** TipSink-as-VDR.

## Minimal Solidity delta (lab)

**New lab contract:** `contracts/LabLineMemberManagedExecutor.sol`  
(Fork of `LabMiningPoolPayoutExecutor` + memberManager role; **do not** rewrite prod `src/mainnet/` until PROD-PENDING-REVIEW is approved.)

| Change | Before | After (lab) |
|---|---|---|
| Member registry | `setExecutor` `onlyOwner` | `setMember` / `setExecutor` **`onlyMemberManager`** |
| New role | — | `memberManager` set by `owner` via `setMemberManager` |
| Restricted gas | — | `topUpMemberGas(member, amount)` `onlyMemberManager` |
| Owner retains | caps, pause, ownership | + `setMemberManager` only (not day-to-day members) |
| VDR | contract is intended `admins` grantee | Unchanged; PM EOA never `addAdmin` |

**Mock:** `MockVdrPaymentLine.sol` — records escalate attempts (`addAdmin` / `setRedeemAdmin` revert for non-admin).

## Production path (STATUS QUO — do not enable)

See `PROD-PENDING-REVIEW-STATUS-QUO.md`. Until owner sign-off:

1. Do **not** patch live `LabMiningPoolPayoutExecutor` on CoNET.
2. Do **not** `transferOwnership` to PM.
3. Do **not** grant VDR `admins` / `redeemAdmins` to PM or derived pay wallets.

## API / off-chain (minimal)

No Cluster/Master change required for lab. Optional later (pending review):

- Register `(paymentLineId → executorProxy)` in ops config.
- PM service calls `setMember` / `topUpMemberGas` with PM key; never calls VDR admin setters.

## Acceptance

- Matrix: `PERMISSION-MATRIX.md`
- Negtests: `anvil-payment-line-perms.mjs` → `results/anvil-payment-line-perms.json`
- Escalate / cross-line / mid-flight revoke: all FAIL or documented PASS as specified
