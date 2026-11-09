# DePIN node-case seal daemon

Project-operated monitor for CoNET DePIN node cases (admission, recovery, report). When a case is still voting, its decision margin is met, and a legal seal condition is met, the daemon prepares one permissionless finalize on the core contract. Default mode is dry-run: it records one pending intent and does not broadcast.

This package is not deployed. It does not hold a private key. It does not enable a production signer policy.

## Knowledge base (read in this order)

1. `/Users/peter/.claude/pm-notes/reports/pending-decisions-ledger-2026-11-08.md` lines 143, 159, and 160. Line 143 is the permissionless seal. Line 159 is the early seal at strict majority. Line 160 is the 7,200-second frozen-tally late seal and it supersedes the earlier "after the deadline, still undecided" note. Line 161 is DAO and is out of scope. Companion notes: `/Users/peter/.claude/pm-notes/pm-dependency-board.md` lines 1244 and 1257–1262.
2. `/Users/peter/.claude/pm-notes/reports/node-online-vote-rewards-v0.1.md` sections 13.1–13.5 are entry history only. Older "wait" or "delete finalize" wording loses to the ledger. `/Users/peter/.claude/pm-notes/reports/node-registry-v2-vote-settlement-comparison-v0.1.md` covers reports, the first settlement batch versus later batches, and the execution reward.
3. Read-only worktree, not mainnet: `/Users/peter/Downloads/BeamioContract/.claude/worktrees/node-registry-stake-a67ba1/src/b-unit/node-registry-v2/`. `NodeRegistryV2.sol` `finalizeReport(uint256)`. `NodeRegistryV2Ext.sol` `finalizeAdmission(bytes32)` and `finalizeRecovery(bytes32)` are `viaCore` and must not be sent to the extension. Also `OnlineVoteLib.sol`, `OfflineReportLib.sol`, `NodeRegistryLens.sol`. Tests live in that worktree under `test/node-registry-v2/`.
4. `/Users/peter/.claude/pm-notes/reports/dashboard.md` lines 7–20: incremental event scan, block snapshot, and case index. Rust is reference only: `/Users/peter/Downloads/BeamioContract/.claude/worktrees/conet-si-rust-design-7c111b/src/conet-node/crates/conet-node/src/online_gate.rs`, `vote_gate.rs`, and that crate's tests. Old numeric defaults do not override the ledger.
5. Signer: `/Users/peter/Downloads/wallet-signer-review-2026-11-08/packages/wallet-signer/src/rpcServer.ts`, `service.ts`, `policy.ts`, `txJournal.ts`, and `/Users/peter/Documents/Codex/2026-11-05/new-chat/wallet-signer-runbook.md`.

Work order copy: `/Users/peter/Downloads/BeamioContract/signer-ssh-rollback/efce061-deploy/depin-seal-daemon-work-order-2026-11-09.md`.

## Rules implemented

- Chain id 224422 only. DAO Governor `seal(id)`, the 2/3 threshold, and the 7-day window are not used.
- Before 7,200 seconds: seal only when the margin is met and either 600 seconds have elapsed or valid votes are strictly more than half of the opening qualified-node snapshot. Exactly 50% does not seal. 599 seconds does not seal unless that strict half is already met. The daemon does not vote.
- At and after 7,200 seconds the tally used for the decision is frozen. A frozen tally that still meets the margin produces one late seal on the same entry. A frozen tally that misses the margin raises an alert only. This process does not send an abort, refund, or cleanup transaction.
- The decision uses the tally at call time. An earlier tally that once met the margin is not remembered.
- Votes at or after the freeze do not rewrite the frozen tally.
- One chain, contract, case kind, and case id is evaluated serially. State is re-read and `eth_call`'d before a seal intent is recorded. `eth_call` runs only when the daemon has already decided to seal, so a below-margin case is not pushed into a contract path that might abort it.
- A case another party has already sealed is not sent again.
- A reverted simulation or receipt does not mark the case settled. A failed read does not replace the last trusted tally.
- The same in-flight idempotency key is not submitted twice after a restart. A case that reached the freeze while the process was down is scanned again and, if the frozen margin is met, gets one pending intent.
- Idempotency key: `chainId:contract:kind:caseId:seal`. It does not contain a timestamp. The signer scopes that key by client name, matching `TxManager` idempotency.

## Missing contract interface (send stays closed)

The worktree is not a final read-only ABI snapshot and it is not a mainnet address. Until every item below is injected as a confirmed snapshot, selectors stay unconfirmed and the daemon refuses to build a sendable transaction.

| Gap | Why it blocks a broadcast |
|---|---|
| Final read-only ABI JSON for the core | Candidate signatures are listed with `selector: null` and `confirmed: false` |
| Core contract address on chain 224422 | No address is built in |
| Deploy block | Incremental scan has no production start block |
| Opened, voted, sealed, and aborted event signatures | The indexer accepts normalized events only |
| Opening-snapshot denominator view | Worktree field name `population` is not a confirmed public view for this daemon |
| "Can seal now" and "can seal after freeze" views | `NodeRegistryLens` does not expose them |
| Confirmed selectors for `finalizeReport(uint256)`, `finalizeAdmission(bytes32)`, `finalizeRecovery(bytes32)` on the core | Admission and recovery are `viaCore`. Sending those selectors to `NodeRegistryV2Ext` is refused |

Worktree source still reverts `finalizeAdmission` / `finalizeRecovery` / `finalizeReport` once `voteExpiresAt` / `expiresAt` is reached (7,200 seconds). Ledger line 160 allows a late seal on the frozen tally. A live `eth_call` against that bytecode would revert, the daemon would alert `simulation-reverted`, and it would not broadcast and would not mark the case settled. The local fixture follows the ledger so the late-seal tests can run without a production RPC.

## Build and test

```bash
cd src/depin-node-seal-daemon
npm install
npm test
```

`npm test` compiles with `tsc` and runs `node --test`. No production RPC. No broadcast.

See `RUNBOOK.md` for the dry-run default and the signer draft that is not enabled.
