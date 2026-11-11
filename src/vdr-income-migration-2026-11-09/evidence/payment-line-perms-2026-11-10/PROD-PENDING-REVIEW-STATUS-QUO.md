# Production authorization — PENDING REVIEW (STATUS QUO)

**Status:** DO NOT ENABLE  
**Date:** 2026-11-10  
**Scope:** Payment-line member permissions for CL settlement / Gas top-up  
**Lab evidence:** `src/vdr-income-migration-2026-11-09/evidence/payment-line-perms-2026-11-10/`

---

## STATUS QUO (current production)

| Surface | Current | Allowed for PM / derived pay wallets? |
|---|---|---|
| `ValidatorDepositRedeem.addAdmin` | owner/admin | **NO** — upgrade / arbitrary withdraw class |
| `ValidatorDepositRedeem` redeemAdmin | owner/admin | **NO** — business-config class |
| `ValidatorDepositRedeem.withdrawNative` | admin | **NO** |
| `LabMiningPoolPayoutExecutor.setExecutor` | `onlyOwner` | **NO** change in prod until this review clears |
| `LabMiningPoolPayoutExecutor` ownership | lab/ops owner | **NO** `transferOwnership` to PM |
| TipSink as VDR | n/a | **FORBIDDEN** forever |

No production bytecode, Factory binding, or ownership transfer is authorized by this document.

---

## Proposed production delta (NOT APPROVED)

Introduce a **new** least-privilege proxy (or carefully reviewed upgrade of lab executor) that:

1. Separates `owner` from `memberManager` (PM).
2. Lets PM only: `setMember` / `topUpMemberGas` (caps enforced).
3. Lets members only: `payoutBatch` to an **immutable** per-line pool.
4. Never grants VDR `addAdmin` / redeemAdmin / withdraw to PM or members.
5. Never redirects settlement recipient away from the line’s fixed pool.

Lab reference implementation: `contracts/LabLineMemberManagedExecutor.sol`.

---

## Gate checklist before any prod enable

- [ ] Security review of role matrix (`PERMISSION-MATRIX.md`) signed off
- [ ] Negative tests green on Anvil (`results/anvil-payment-line-perms.json`)
- [ ] Explicit written PM authorization for **deployment only** (separate message)
- [ ] No `transferOwnership` to PM in deploy script
- [ ] No VDR admin grant in deploy script
- [ ] Per-line executor addresses recorded in deployments JSON
- [ ] Cap values (payout / gas top-up / period) reviewed by ops

Until all boxes are checked: **STATUS QUO remains**. Lab fixtures only.

---

## Explicit non-authorizations

- Production deploy of `LabLineMemberManagedExecutor` or forks
- Patching live `LabMiningPoolPayoutExecutor` on mainnet without a new approval
- Granting Total PM (or any CAA-derived wallet) VDR admin / redeemAdmin
- Using TipSink, treasury, or any non-VDR contract as skim source
