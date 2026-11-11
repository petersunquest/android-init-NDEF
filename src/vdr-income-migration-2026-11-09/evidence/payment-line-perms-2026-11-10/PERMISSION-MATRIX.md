# Permission matrix — payment-line members (lab)

**Legend:** PASS = action allowed by design · FAIL = must revert / be rejected (over-privilege)

Contracts under test (lab):

- **ExecA / ExecB** — `LabLineMemberManagedExecutor` instances (line A / line B)
- **VDR mock** — `MockVdrPaymentLine` (stand-in for `ValidatorDepositRedeem` escalate surface)
- Roles: **owner**, **PM** (`memberManager`), **memberA** (line A), **memberB** (line B), **stranger**

## Role × action × contract

| # | Actor | Action | Contract | Expected |
|---|---|---|---|---|
| 1 | owner | `setMemberManager(PM)` | ExecA | PASS |
| 2 | owner | `setCaps` / `setPaused` / `transferOwnership` | ExecA | PASS |
| 3 | owner | `setMember(memberA, true)` | ExecA | FAIL (`NotMemberManager`) — day-to-day members are PM’s job |
| 4 | PM | `setMember(memberA, true)` | ExecA | PASS |
| 5 | PM | `setMember(memberA, false)` (revoke) | ExecA | PASS |
| 6 | PM | `topUpMemberGas(memberA, wei)` within caps | ExecA | PASS |
| 7 | PM | `setCaps` / `setPaused` / `transferOwnership` | ExecA | FAIL |
| 8 | PM | `setMemberManager(stranger)` | ExecA | FAIL (`NotOwner`) |
| 9 | PM | VDR `addAdmin(PM)` | VDR mock | FAIL |
| 10 | PM | VDR `setRedeemAdmin(PM, true)` | VDR mock | FAIL |
| 11 | PM | VDR `withdrawNative(...)` | VDR mock | FAIL |
| 12 | memberA | `payoutBatch` on ExecA | ExecA | PASS |
| 13 | memberA | `payoutBatch` on ExecB | ExecB | FAIL (`NotExecutor`) — cross-line |
| 14 | memberB | `payoutBatch` on ExecA | ExecA | FAIL (`NotExecutor`) |
| 15 | memberA | `setMember` / `topUpMemberGas` / `setCaps` | ExecA | FAIL |
| 16 | stranger | any privileged setter / payout | ExecA | FAIL |
| 17 | PM | `setMember` on ExecB without being its memberManager | ExecB | FAIL |
| 18 | memberA (after revoke) | `payoutBatch` mid-flight (next tx after revoke) | ExecA | FAIL (`NotExecutor`) |

## Over-privilege cases (must FAIL)

| Case | Why forbidden |
|---|---|
| PM holds VDR `admins` | Upgrade / arbitrary withdraw class |
| PM holds VDR `redeemAdmins` | Business config mutation |
| PM is Exec `owner` | Caps, pause, ownership transfer |
| TipSink used as VDR | Wrong settlement surface (out of scope; asserted by immutable `vdr` pointer ≠ tip sink) |
| Shared executor across lines | Cross-line payout isolation fails |

## Mid-flight revoke (documented behavior)

1. Member is authorized → can call `payoutBatch`.
2. PM calls `setMember(member, false)`.
3. **Same block or later:** next `payoutBatch` from that member **FAIL** (`NotExecutor`).
4. In-flight off-chain job that already sent a signed/broadcast tx **before** revoke may still land if mined first; ops must treat revoke as **stop-new-settlement**, not atomic abort of a pending mempool tx. Lab test asserts post-revoke call FAIL.

## Gas top-up bounds

| Check | Expected |
|---|---|
| amount ≤ `maxGasTopUpWei` | PASS |
| amount > `maxGasTopUpWei` | FAIL (`GasTopUpTooLarge`) |
| period sum > `maxGasTopUpPeriodWei` | FAIL (`GasTopUpPeriodExceeded`) |
| target not a member | FAIL (`NotMember`) |
| gas purse balance insufficient | FAIL (`InsufficientGasPurse`) |

---

## CAA §3.A absorb (2026-11-11T04:30Z) — Total PM (R2 sync Auto incomplete)

Source: `PM-CL-CENTRAL-ADMIN-ALLOCATOR-DESIGN/NEGTEST` §3.A. **Default = whole approved amount or whole reject**; do **not** `min(...)` then consume `eventKey`. Optional partial only with on-chain **residual claim** under **original source id**. **Budget = governance**; PM = Gas envelope + member add/remove only.

| # | Actor | Action | Expected | Negtest map |
|---|---|---|---|---|
| 19 | pay / exec key | `grantApprover` / change approval set | FAIL | N-PRIV-01 |
| 20 | PM key | `grantApprover` / change approval threshold | FAIL | N-PRIV-02 |
| 21 | submitter key | Grant approval or raise budget | FAIL | N-PRIV-03 |
| 22 | PM | `setPeriodBudget` / `setCumulativeBudget` / raise `perTxCap` above governance envelope | FAIL | N-PRIV-04 / N-PMBUDGET |
| 23 | exec key | Same budget / cap setters | FAIL | N-PRIV-05 |
| 24 | budget governance | Raise period budget within policy | PASS | N-PRIV-06 |
| 25 | PM | Add/remove pay member within rules | PASS | N-PMBUDGET-01 |
| 26 | PM | Gas refill ≤ envelope | PASS | N-PMBUDGET-02 |
| 27 | PM | Gas refill **above** envelope | FAIL | N-PMBUDGET-03 |
| 28 | PM | Change FIXED recipient / move principal | FAIL | N-PMBUDGET-04 |
| 29 | submitter | Pay approved A when accrued/budget &lt; A (`partialPayMode=FORBIDDEN`) | FAIL whole; **key not consumed** | N-FULL-01..04 |
| 30 | submitter | Re-batch already-paid source into new batchId | FAIL | N-REPLAY-07..08 |
| 31 | line | `partialPayMode=ALLOWED` partial pay | Residual claim under **same** source id until cleared | N-PARTIAL-01..04 |
