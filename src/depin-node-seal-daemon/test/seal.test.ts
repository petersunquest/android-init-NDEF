import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, readdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, it } from 'node:test'
import { AbiRegistry } from '../src/abiRegistry.js'
import { SealEngine } from '../src/engine.js'
import { LedgerFixture } from '../src/fixture.js'
import { sealIdempotencyKey } from '../src/idempotency.js'
import { loadJournal } from '../src/journal.js'
import { startSealLoop } from '../src/loop.js'
import { decide } from '../src/policy.js'
import { MemorySigner } from '../src/signer.js'
import type { DaemonConfig } from '../src/types.js'

const CORE = '0x1111111111111111111111111111111111111111'
const EXT = '0x2222222222222222222222222222222222222222'

function config(extra: Partial<DaemonConfig> = {}): DaemonConfig {
  return {
    chainId: 224422,
    coreAddress: CORE,
    dryRun: true,
    sendEnabled: false,
    maxGas: 6_000_000n,
    gasPriceWei: 1n,
    clientName: 'depin-node-seal',
    ...extra,
  }
}

function engine(fix: LedgerFixture, extra: Partial<DaemonConfig> = {}, abi = new AbiRegistry(), signer = new MemorySigner()) {
  return { eng: new SealEngine(fix, config(extra), abi, signer), signer, abi }
}

describe('seal policy', () => {
  it('does not seal at 599 seconds when participation is not over half', () => {
    const decision = decide({
      now: 599,
      openedAt: 0,
      population: 100,
      margin: 20,
      tally: { agree: 20, disagree: 0 },
      chainStatus: 'voting',
    })
    assert.equal(decision.action, 'wait')
  })

  it('seals at 600 seconds when the margin is met', () => {
    const decision = decide({
      now: 600,
      openedAt: 0,
      population: 100,
      margin: 20,
      tally: { agree: 20, disagree: 0 },
      chainStatus: 'voting',
    })
    assert.equal(decision.action, 'seal')
    if (decision.action === 'seal') assert.equal(decision.reason, 'window')
  })

  it('does not seal at exactly 50 percent', () => {
    const decision = decide({
      now: 100,
      openedAt: 0,
      population: 10,
      margin: 1,
      tally: { agree: 5, disagree: 0 },
      chainStatus: 'voting',
    })
    assert.equal(decision.action, 'wait')
  })

  it('seals when participation is strictly over 50 percent and the margin is met', () => {
    const decision = decide({
      now: 100,
      openedAt: 0,
      population: 10,
      margin: 1,
      tally: { agree: 6, disagree: 0 },
      chainStatus: 'voting',
    })
    assert.equal(decision.action, 'seal')
    if (decision.action === 'seal') assert.equal(decision.reason, 'early-half')
  })

  it('uses the tally at call time, not an earlier tally that once met the margin', () => {
    const later = decide({
      now: 600,
      openedAt: 0,
      population: 100,
      margin: 20,
      tally: { agree: 10, disagree: 10 },
      chainStatus: 'voting',
    })
    assert.equal(later.action, 'wait')
  })

  it('seals a frozen tally that still meets the margin after 7200 seconds', () => {
    const decision = decide({
      now: 7200,
      openedAt: 0,
      population: 100,
      margin: 20,
      tally: { agree: 30, disagree: 0 },
      chainStatus: 'voting',
    })
    assert.equal(decision.action, 'seal')
    if (decision.action === 'seal') assert.equal(decision.reason, 'late-frozen')
  })

  it('alerts when the frozen tally misses the margin and does not ask for a seal', () => {
    const decision = decide({
      now: 7200,
      openedAt: 0,
      population: 100,
      margin: 20,
      tally: { agree: 10, disagree: 0 },
      chainStatus: 'voting',
    })
    assert.deepEqual(decision, { action: 'alert', reason: 'frozen-below-margin' })
  })
})

describe('daemon', () => {
  it('dry-run records one pending seal at 600 seconds and none at 599', async () => {
    const fix = new LedgerFixture(CORE)
    fix.open({ kind: 'report', caseId: '7', openedAt: 0, population: 100, margin: 20, agree: 20 })
    const { eng } = engine(fix)
    fix.now = 599
    await eng.tick(599)
    assert.equal(eng.journal.attempts.length, 0)
    assert.equal(fix.ethCallLog.length, 0)
    fix.now = 600
    await eng.tick(600)
    assert.equal(eng.journal.attempts.length, 1)
    assert.equal(eng.journal.attempts[0]?.status, 'pending-dry-run')
    assert.equal(eng.journal.attempts[0]?.broadcast, false)
    assert.equal(eng.journal.attempts[0]?.cleanup, false)
    await eng.tick(601)
    assert.equal(eng.journal.attempts.length, 1)
  })

  it('does not create a pending seal when the margin is not met', async () => {
    const fix = new LedgerFixture(CORE)
    fix.open({ kind: 'report', caseId: '8', openedAt: 0, population: 100, margin: 20, agree: 19 })
    const { eng } = engine(fix)
    fix.now = 600
    await eng.tick(600)
    assert.equal(eng.journal.attempts.length, 0)
    assert.equal(fix.ethCallLog.length, 0)
  })

  it('seals early only when participation is strictly over half', async () => {
    const half = new LedgerFixture(CORE)
    half.open({ kind: 'admission', caseId: '0x' + '11'.repeat(32), openedAt: 0, population: 10, margin: 1, agree: 5 })
    const over = new LedgerFixture(CORE)
    over.open({ kind: 'admission', caseId: '0x' + '22'.repeat(32), openedAt: 0, population: 10, margin: 1, agree: 6 })
    const a = engine(half)
    const b = engine(over)
    half.now = 100
    over.now = 100
    await a.eng.tick(100)
    await b.eng.tick(100)
    assert.equal(a.eng.journal.attempts.length, 0)
    assert.equal(b.eng.journal.attempts.length, 1)
    assert.equal(b.eng.journal.attempts[0]?.reason, 'early-half')
  })

  it('does not send again when another party already sealed', async () => {
    const fix = new LedgerFixture(CORE)
    fix.open({ kind: 'recovery', caseId: '0x' + '33'.repeat(32), openedAt: 0, population: 100, margin: 20, agree: 25 })
    fix.markSealed('recovery', '0x' + '33'.repeat(32))
    const { eng } = engine(fix)
    fix.now = 600
    await eng.tick(600)
    assert.equal(eng.journal.attempts.length, 0)
    assert.equal(fix.ethCallLog.length, 0)
    assert.equal(eng.journal.cases[Object.keys(eng.journal.cases)[0] ?? '']?.chainStatus, 'sealed')
    assert.ok(eng.journal.cases[Object.keys(eng.journal.cases)[0] ?? '']?.alerts.includes('race-sealed'))
  })

  it('late-seals a frozen tally that still meets the margin', async () => {
    const fix = new LedgerFixture(CORE)
    fix.open({ kind: 'report', caseId: '9', openedAt: 0, population: 100, margin: 20, agree: 30 })
    const { eng } = engine(fix)
    fix.now = 7200
    await eng.tick(7200)
    assert.equal(eng.journal.attempts.length, 1)
    assert.equal(eng.journal.attempts[0]?.reason, 'late-frozen')
    assert.equal(eng.journal.attempts[0]?.broadcast, false)
    assert.deepEqual(eng.journal.attempts[0]?.tally, { agree: 30, disagree: 0 })
  })

  it('after the deadline, a miss only alerts and does not send a cleanup transaction', async () => {
    const fix = new LedgerFixture(CORE)
    fix.open({ kind: 'report', caseId: '10', openedAt: 0, population: 100, margin: 20, agree: 10 })
    const { eng, signer } = engine(fix)
    fix.now = 7200
    await eng.tick(7200)
    assert.equal(eng.journal.attempts.length, 0)
    assert.equal(signer.sent.length, 0)
    assert.equal(fix.ethCallLog.length, 0)
    assert.equal(fix.cleanupLog.length, 0)
    const row = Object.values(eng.journal.cases)[0]
    assert.equal(row?.chainStatus, 'voting')
    assert.ok(row?.alerts.includes('frozen-below-margin'))
    assert.equal(row?.alerts.some((item) => item.includes('cleanup') || item.includes('refund') || item.includes('close')), false)
  })

  it('does not let votes after the freeze change the frozen tally', async () => {
    const fix = new LedgerFixture(CORE)
    fix.open({ kind: 'report', caseId: '11', openedAt: 0, population: 100, margin: 20, agree: 10 })
    const { eng } = engine(fix)
    fix.now = 7200
    await eng.tick(7200)
    const before = fix.snapshot('report', '11')
    assert.equal(fix.vote('report', '11', 'agree'), false)
    const afterVote = fix.snapshot('report', '11')
    assert.equal(afterVote.agree, before.agree)
    assert.equal(afterVote.votesRejectedAfterFreeze, 1)
    fix.overwriteTally('report', '11', 40, 0)
    await eng.tick(7300)
    const row = Object.values(eng.journal.cases)[0]
    assert.equal(row?.frozenAgree, 10)
    assert.equal(row?.frozenDisagree, 0)
    assert.equal(eng.journal.attempts.length, 0)
    assert.equal(fix.ethCallLog.length, 0)
    assert.equal(fix.cleanupLog.length, 0)
  })

  it('rescans a missed case after restart and does not double-send', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'depin-seal-'))
    const journalPath = join(dir, 'journal.json')
    const fix = new LedgerFixture(CORE)
    fix.open({ kind: 'report', caseId: '12', openedAt: 0, population: 100, margin: 20, agree: 30 })
    fix.now = 8000
    const first = new SealEngine(fix, config({ journalPath }), new AbiRegistry(), new MemorySigner())
    await first.tick(8000)
    assert.equal(first.journal.attempts.length, 1)
    const second = new SealEngine(fix, config({ journalPath }), new AbiRegistry(), new MemorySigner(), loadJournal(journalPath))
    await second.tick(8100)
    assert.equal(second.journal.attempts.length, 1)
    assert.equal(second.journal.attempts[0]?.status, 'pending-dry-run')
    assert.equal(second.signerCalls.length, 0)
  })

  it('does not send a second transaction for an in-flight idempotency key after restart', async () => {
    const fix = new LedgerFixture(CORE)
    fix.open({ kind: 'report', caseId: '13', openedAt: 0, population: 100, margin: 20, agree: 30 })
    const signer = new MemorySigner()
    const abi = new AbiRegistry()
    abi.register({
      kind: 'report',
      signature: 'finalizeReport(uint256)',
      selector: '0xabcdef01',
      confirmed: true,
      target: 'core',
    })
    const { eng } = engine(fix, { dryRun: false, sendEnabled: true }, abi, signer)
    const key = sealIdempotencyKey({ chainId: 224422, contract: CORE, kind: 'report', caseId: '13' })
    assert.equal(key.includes('Date'), false)
    assert.equal(/:\d{13}:/.test(key), false)
    eng.journal.cases[`${CORE}:${'report'}:13`] = {
      key: `${CORE}:report:13`,
      kind: 'report',
      caseId: '13',
      contract: CORE,
      openedAt: 0,
      population: 100,
      margin: 20,
      liveAgree: 30,
      liveDisagree: 0,
      frozenAgree: null,
      frozenDisagree: null,
      chainStatus: 'voting',
      alerts: [],
      updatedAt: 0,
    }
    eng.journal.attempts.push({
      idempotencyKey: key,
      kind: 'report',
      caseId: '13',
      contract: CORE,
      status: 'submitted',
      broadcast: true,
      cleanup: false,
      hash: '0xinflight',
      reason: 'window',
      tally: { agree: 30, disagree: 0 },
    })
    fix.now = 600
    await eng.tick(600)
    assert.equal(signer.sent.length, 0)
    assert.equal(eng.signerCalls.length, 0)
    assert.equal(eng.journal.attempts.filter((row) => row.idempotencyKey === key).length, 1)
  })

  it('a simulated revert does not mark the case settled', async () => {
    const fix = new LedgerFixture(CORE)
    fix.open({ kind: 'report', caseId: '14', openedAt: 0, population: 100, margin: 20, agree: 30 })
    const signer = new MemorySigner()
    signer.revert = true
    const abi = new AbiRegistry()
    abi.register({
      kind: 'report',
      signature: 'finalizeReport(uint256)',
      selector: '0xabcdef01',
      confirmed: true,
      target: 'core',
    })
    const { eng } = engine(fix, { dryRun: false, sendEnabled: true }, abi, signer)
    fix.now = 600
    await eng.tick(600)
    const row = Object.values(eng.journal.cases)[0]
    assert.equal(row?.chainStatus, 'voting')
    assert.equal(eng.journal.attempts[0]?.status, 'reverted')
    assert.equal(eng.journal.attempts.some((item) => item.status === 'mined'), false)
    assert.ok(row?.alerts.includes('seal-reverted'))
  })

  it('refuses to build a sendable transaction when the selector is not confirmed', async () => {
    const fix = new LedgerFixture(CORE)
    fix.open({ kind: 'report', caseId: '15', openedAt: 0, population: 100, margin: 20, agree: 30 })
    const signer = new MemorySigner()
    const { eng } = engine(fix, { dryRun: false, sendEnabled: true }, new AbiRegistry(), signer)
    fix.now = 600
    await eng.tick(600)
    assert.equal(signer.sent.length, 0)
    assert.equal(eng.journal.attempts[0]?.status, 'refused')
    assert.match(eng.journal.attempts[0]?.error ?? '', /not confirmed/)
  })

  it('refuses admission and recovery selectors aimed at the extension', async () => {
    const fix = new LedgerFixture(EXT)
    fix.open({ kind: 'admission', caseId: '0x' + '44'.repeat(32), openedAt: 0, population: 100, margin: 20, agree: 30 })
    const signer = new MemorySigner()
    const abi = new AbiRegistry()
    abi.register({
      kind: 'admission',
      signature: 'finalizeAdmission(bytes32)',
      selector: '0xabcdef02',
      confirmed: true,
      target: 'core',
    })
    const { eng } = engine(
      fix,
      { dryRun: false, sendEnabled: true, coreAddress: CORE, extensionAddress: EXT },
      abi,
      signer,
    )
    fix.now = 600
    await eng.tick(600)
    assert.equal(signer.sent.length, 0)
    assert.equal(eng.journal.attempts[0]?.status, 'refused')
    assert.match(eng.journal.attempts[0]?.error ?? '', /extension/)
  })

  it('keeps the last trusted tally when the RPC read fails', async () => {
    const fix = new LedgerFixture(CORE)
    fix.open({ kind: 'report', caseId: '16', openedAt: 0, population: 100, margin: 20, agree: 25 })
    const { eng } = engine(fix)
    fix.now = 100
    await eng.tick(100)
    const row = Object.values(eng.journal.cases)[0]
    assert.equal(row?.liveAgree, 25)
    fix.failReads = true
    fix.overwriteTally('report', '16', 0, 0)
    await eng.tick(200)
    assert.equal(row?.liveAgree, 25)
    assert.ok(row?.alerts.includes('rpc-read-failed'))
  })

  it('alerts on gas cap and low balance without sending', async () => {
    const gas = new LedgerFixture(CORE)
    gas.open({ kind: 'report', caseId: '17', openedAt: 0, population: 100, margin: 20, agree: 30 })
    gas.sealGas = 9_000_000n
    const gasSigner = new MemorySigner()
    const abi = new AbiRegistry()
    abi.register({ kind: 'report', signature: 'finalizeReport(uint256)', selector: '0xabcdef01', confirmed: true, target: 'core' })
    const gasEng = engine(gas, { dryRun: false, sendEnabled: true, maxGas: 6_000_000n }, abi, gasSigner)
    gas.now = 600
    await gasEng.eng.tick(600)
    assert.equal(gasSigner.sent.length, 0)
    assert.ok(Object.values(gasEng.eng.journal.cases)[0]?.alerts.includes('gas-cap'))

    const poor = new LedgerFixture(CORE)
    poor.open({ kind: 'report', caseId: '18', openedAt: 0, population: 100, margin: 20, agree: 30 })
    poor.balance = 0n
    const poorSigner = new MemorySigner()
    const poorEng = engine(poor, { dryRun: false, sendEnabled: true }, abi, poorSigner)
    poor.now = 600
    await poorEng.eng.tick(600)
    assert.equal(poorSigner.sent.length, 0)
    assert.ok(Object.values(poorEng.eng.journal.cases)[0]?.alerts.includes('low-balance'))
  })

  it('schedules the next pass with setTimeout and does not use setInterval', async () => {
    const srcDir = join(dirname(fileURLToPath(import.meta.url)), '../../src')
    const files = readdirSync(srcDir).filter((name) => name.endsWith('.ts'))
    for (const name of files) {
      const text = readFileSync(join(srcDir, name), 'utf8')
      assert.equal(text.includes('setInterval'), false, name)
    }
    let calls = 0
    const stop = startSealLoop({
      intervalMs: 5,
      run: async () => {
        calls += 1
      },
      schedule: (cb) => setTimeout(cb, 5),
    })
    await new Promise((resolve) => setTimeout(resolve, 20))
    stop()
    assert.ok(calls >= 1)
  })
})
