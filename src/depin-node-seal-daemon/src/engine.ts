import { AbiRegistry, encodeSealCalldata } from './abiRegistry.js'
import { sealIdempotencyKey } from './idempotency.js'
import { blockingAttempt, caseKey, emptyJournal, findAttempt, loadJournal, saveJournal, tallyOf } from './journal.js'
import { decide } from './policy.js'
import {
  CONET_CHAIN_ID,
  FREEZE_SEC,
  type AttemptRecord,
  type CaseKind,
  type CaseRecord,
  type ChainReader,
  type DaemonConfig,
  type Journal,
  type LiveCase,
  type NormalizedEvent,
  type SealSigner,
} from './types.js'

const KINDS: CaseKind[] = ['admission', 'recovery', 'report']

export class SealEngine {
  readonly journal: Journal
  private readonly tails = new Map<string, Promise<void>>()
  readonly signerCalls: string[] = []

  constructor(
    private readonly reader: ChainReader,
    private readonly config: DaemonConfig,
    private readonly abi: AbiRegistry,
    private readonly signer: SealSigner,
    journal?: Journal,
  ) {
    this.journal = journal ?? loadJournal(config.journalPath)
    if (reader.chainId !== CONET_CHAIN_ID || config.chainId !== CONET_CHAIN_ID) {
      throw new Error('daemon is limited to CoNET chainId 224422')
    }
  }

  /** One pass. The next pass is scheduled by the caller with setTimeout, after this returns. */
  async tick(now: number): Promise<Journal> {
    await this.scan()
    const ids = Object.values(this.journal.cases).map((row) => row.key)
    for (const key of ids) {
      await this.enqueue(key, () => this.evaluateKey(key, now))
    }
    saveJournal(this.config.journalPath, this.journal)
    return this.journal
  }

  private enqueue(key: string, job: () => Promise<void>): Promise<void> {
    const prev = this.tails.get(key) ?? Promise.resolve()
    const next = prev.then(job, job)
    this.tails.set(key, next)
    return next
  }

  private async scan(): Promise<void> {
    const from = this.journal.cursorBlock
    const snapshot = structuredClone(this.journal.cases)
    const cursor = this.journal.cursorBlock
    try {
      const page = await this.reader.scan(from, from + 5_000)
      for (const event of page.events) this.applyEvent(event)
      this.journal.cursorBlock = page.toBlock
    } catch {
      this.journal.cases = snapshot
      this.journal.cursorBlock = cursor
      this.pushAlert('indexer', 'rpc-scan-failed')
    }
  }

  private applyEvent(event: NormalizedEvent): void {
    const contract = this.reader.coreAddress
    const key = caseKey(contract, event.kind, event.caseId)
    if (event.type === 'opened') {
      const prev = this.journal.cases[key]
      this.journal.cases[key] = {
        key,
        kind: event.kind,
        caseId: event.caseId,
        contract,
        openedAt: event.openedAt,
        population: event.population,
        margin: event.margin,
        liveAgree: prev?.liveAgree ?? 0,
        liveDisagree: prev?.liveDisagree ?? 0,
        frozenAgree: prev?.frozenAgree ?? null,
        frozenDisagree: prev?.frozenDisagree ?? null,
        chainStatus: prev?.chainStatus ?? 'voting',
        alerts: prev?.alerts ?? [],
        updatedAt: event.openedAt,
      }
      return
    }
    const rec = this.journal.cases[key]
    if (!rec) return
    if (event.type === 'sealed') {
      const own = this.journal.attempts.some(
        (row) =>
          row.kind === event.kind &&
          row.caseId === event.caseId &&
          (row.status === 'submitted' || row.status === 'mined'),
      )
      rec.chainStatus = 'sealed'
      if (!own && !rec.alerts.includes('race-sealed')) rec.alerts.push('race-sealed')
      rec.updatedAt = event.block
      return
    }
    const freezeAt = rec.openedAt + FREEZE_SEC
    if (event.timestamp >= freezeAt) return
    if (rec.frozenAgree !== null) return
    rec.liveAgree = event.agree
    rec.liveDisagree = event.disagree
    rec.updatedAt = event.timestamp
  }

  private async evaluateKey(key: string, now: number): Promise<void> {
    const rec = this.journal.cases[key]
    if (!rec || rec.chainStatus !== 'voting') return
    let live: LiveCase | null
    try {
      live = await this.reader.getCase(rec.kind, rec.caseId)
    } catch {
      this.pushAlert(key, 'rpc-read-failed')
      return
    }
    if (!live) return
    if (live.status === 'sealed') {
      rec.chainStatus = 'sealed'
      rec.alerts.push('race-sealed')
      rec.updatedAt = now
      return
    }
    if (live.status === 'aborted') {
      rec.chainStatus = 'aborted'
      rec.alerts.push('contract-aborted')
      rec.updatedAt = now
      return
    }
    this.capture(rec, live, now)
    const tally = tallyOf(rec, now, FREEZE_SEC)
    const decision = decide({
      now,
      openedAt: rec.openedAt,
      population: rec.population,
      margin: rec.margin,
      tally,
      chainStatus: rec.chainStatus,
    })
    if (decision.action === 'wait' || decision.action === 'skip') return
    if (decision.action === 'alert') {
      rec.alerts.push(decision.reason)
      rec.updatedAt = now
      return
    }
    const idem = sealIdempotencyKey({
      chainId: this.config.chainId,
      contract: rec.contract,
      kind: rec.kind,
      caseId: rec.caseId,
    })
    if (blockingAttempt(findAttempt(this.journal, idem))) return
    let again: LiveCase | null
    try {
      again = await this.reader.getCase(rec.kind, rec.caseId)
    } catch {
      this.pushAlert(key, 'rpc-reread-failed')
      return
    }
    if (!again || again.status !== 'voting') {
      if (again?.status === 'sealed') {
        rec.chainStatus = 'sealed'
        rec.alerts.push('race-sealed')
      }
      return
    }
    let sim: { ok: boolean; error?: string }
    try {
      sim = await this.reader.ethCallSeal(rec.kind, rec.caseId)
    } catch {
      this.pushAlert(key, 'rpc-simulate-failed')
      return
    }
    if (!sim.ok) {
      rec.alerts.push(`simulation-reverted:${sim.error ?? 'revert'}`)
      rec.updatedAt = now
      return
    }
    if (this.config.dryRun || !this.config.sendEnabled) {
      this.journal.attempts.push(pending(idem, rec, decision.reason, tally))
      return
    }
    const built = this.buildSend(rec, idem)
    if (!built.ok) {
      rec.alerts.push(built.reason)
      this.journal.attempts.push({
        idempotencyKey: idem,
        kind: rec.kind,
        caseId: rec.caseId,
        contract: rec.contract,
        status: 'refused',
        broadcast: false,
        cleanup: false,
        reason: built.reason,
        tally,
        error: built.reason,
      })
      return
    }
    let gas: bigint
    let balance: bigint
    try {
      gas = await this.reader.estimateSealGas(rec.kind, rec.caseId)
      balance = await this.reader.balanceWei()
    } catch {
      this.pushAlert(key, 'rpc-gas-failed')
      return
    }
    if (gas > this.config.maxGas) {
      rec.alerts.push('gas-cap')
      rec.updatedAt = now
      return
    }
    if (balance < gas * this.config.gasPriceWei) {
      rec.alerts.push('low-balance')
      rec.updatedAt = now
      return
    }
    this.signerCalls.push(idem)
    const result = await this.signer.send({
      client: this.config.clientName,
      idempotencyKey: idem,
      chainId: this.config.chainId,
      to: built.to,
      data: built.data,
      gasLimit: gas,
    })
    const status = result.status === 'reverted' ? 'reverted' : result.status === 'duplicate' ? 'submitted' : 'submitted'
    this.journal.attempts.push({
      idempotencyKey: idem,
      kind: rec.kind,
      caseId: rec.caseId,
      contract: rec.contract,
      status: result.status === 'reverted' ? 'reverted' : status,
      broadcast: result.status !== 'reverted',
      cleanup: false,
      hash: result.hash,
      reason: decision.reason,
      tally,
      error: result.status === 'reverted' ? 'reverted' : undefined,
    })
    if (result.status === 'reverted') {
      rec.chainStatus = 'voting'
      rec.alerts.push('seal-reverted')
    }
  }

  private capture(rec: CaseRecord, live: LiveCase, now: number): void {
    rec.population = live.population
    rec.margin = live.margin
    rec.openedAt = live.openedAt
    if (now >= rec.openedAt + FREEZE_SEC) {
      if (rec.frozenAgree === null || rec.frozenDisagree === null) {
        rec.frozenAgree = live.agree
        rec.frozenDisagree = live.disagree
      }
      return
    }
    rec.liveAgree = live.agree
    rec.liveDisagree = live.disagree
    rec.frozenAgree = null
    rec.frozenDisagree = null
  }

  private buildSend(rec: CaseRecord, _idem: string): { ok: true; to: string; data: string } | { ok: false; reason: string } {
    if (this.config.extensionAddress && rec.contract.toLowerCase() === this.config.extensionAddress.toLowerCase()) {
      return { ok: false, reason: 'refusing extension target' }
    }
    if (rec.contract.toLowerCase() !== this.config.coreAddress.toLowerCase()) {
      return { ok: false, reason: 'target is not the injected core' }
    }
    const selector = this.abi.confirmedSelector(rec.kind)
    if (!selector) return { ok: false, reason: 'selector not confirmed' }
    try {
      return { ok: true, to: this.config.coreAddress, data: encodeSealCalldata(selector, rec.kind, rec.caseId) }
    } catch (err) {
      return { ok: false, reason: err instanceof Error ? err.message : 'encode failed' }
    }
  }

  private pushAlert(key: string, reason: string): void {
    const rec = this.journal.cases[key]
    if (rec) rec.alerts.push(reason)
  }
}

function pending(idempotencyKey: string, rec: CaseRecord, reason: string, tally: { agree: number; disagree: number }): AttemptRecord {
  return {
    idempotencyKey,
    kind: rec.kind,
    caseId: rec.caseId,
    contract: rec.contract,
    status: 'pending-dry-run',
    broadcast: false,
    cleanup: false,
    reason,
    tally,
  }
}

export function watchKeys(journal: Journal = emptyJournal()): string[] {
  return KINDS.flatMap((kind) =>
    Object.values(journal.cases)
      .filter((row) => row.kind === kind)
      .map((row) => row.key),
  )
}
