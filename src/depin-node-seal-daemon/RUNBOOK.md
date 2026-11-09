# Runbook — DePIN node-case seal daemon

This runbook is local only. Do not deploy this daemon. Do not broadcast. Do not enable a production signer policy. Do not copy `~/.master.json` or any signer config onto a host. The daemon process does not hold a private key.

## Dry-run is the default

`DaemonConfig.dryRun` defaults to `true` and `sendEnabled` defaults to `false`.

In that mode the process may:

- scan normalized case events
- re-read case state
- `eth_call` the seal entry only after the local policy already decided to seal
- append one `pending-dry-run` journal row with `broadcast: false` and `cleanup: false`

It does not construct a sendable transaction unless both of these are true:

1. `dryRun` is false and `sendEnabled` is true.
2. The case kind's selector was registered from a confirmed ABI snapshot (`confirmed: true` and a 4-byte selector).

Unconfirmed candidate signatures are `finalizeReport(uint256)`, `finalizeAdmission(bytes32)`, and `finalizeRecovery(bytes32)`. Their selectors are null in this tree. A guessed selector is not a default.

Admission and recovery calldata, when a snapshot eventually allows it, must target the verified core contract. `viaCore` on the extension means a direct call to the extension address is refused.

## What is not deployed

- No systemd unit, no host install, no chain transaction.
- No CoNET RPC broadcast. Tests use an in-memory ledger fixture.
- The node-registry worktree is not mainnet. Its current seal functions still revert at 7,200 seconds. Ledger line 160 allows a late seal. Until a confirmed core ABI and matching bytecode exist, leave `sendEnabled` false.
- DAO `seal(uint256)` is not a configured selector.

## Cadence

The loop awaits one pass, then schedules the next pass with `setTimeout`. It does not use a repeating interval timer. One case key (chain, contract, kind, id) is serialized. Before a seal intent is kept, the case is read again.

## Journal

The journal is the trusted local record. A failed RPC scan or read does not replace the last good tally, cursor, or seal status. A reverted seal stays `voting` and is not marked settled. After 7,200 seconds the first trusted tally is frozen; later vote observations do not replace it.

Idempotency key: `{chainId}:{core}:{kind}:{caseId}:seal`. No clock value is included. An in-flight `submitted` or `pending-dry-run` row blocks a second submit of that key. This matches wallet-signer `TxManager` idempotency (client-scoped key, journalled attempt) without importing that package.

## Signer draft (not enabled)

Do not add this client on the production signer. Do not reuse the Oracle admin wallet `0xccB259772944c1c8Ff9b3F877cD81519c33063EE` or the key array `beamio_oracle_owner`. Do not run `array add` as part of this ticket.

Draft, for a later change that the project owner applies on the signer host:

| Item | Draft |
|---|---|
| Client name | `depin-node-seal` |
| Listener | One Unix socket bound to that client only, for example `/run/wallet-signer/depin-node-seal.sock` |
| Forbidden | Sharing the proxied nginx socket. Do not send `X-WS-*` headers on the Unix listener; `rpcServer.ts` treats those headers as a forgery |
| Chain | `224422` only |
| `to` | The confirmed core registry address only |
| Selectors | The confirmed finalize selectors only |
| Key array | A new least-privilege array, not an Oracle array |
| Value | `0` |
| Gas | A ceiling at or below the measured seal plus first batch, refused above `maxGas` |
| Idempotency | Required on every `signer_sendTransaction` |

`DisabledUnixSigner` throws if called. Tests use `MemorySigner`, which stores no key and opens no socket.

## Alerts that must not spend gas

- Frozen tally below the margin (`frozen-below-margin`). Identify the case. Do not call refund, close, or abort.
- Simulation revert. Leave the case unsealed.
- Gas above the ceiling, or balance below `gas * gasPrice`.
- RPC failure. Keep the previous trusted row.

## Local test

```bash
cd src/depin-node-seal-daemon
npm install
npm test
```

Write the test log next to this tree. Do not overwrite an oracle-restore log.
