import type { ChainReader, CaseKind, LiveCase, NormalizedEvent, ScanPage } from './types.js'
import { FREEZE_SEC } from './types.js'

export type FixtureCase = LiveCase & { votesRejectedAfterFreeze: number }

/**
 * In-memory chain that follows the 2026-11-09 ledger: late seal is allowed on the
 * frozen tally. It never aborts a case as a side effect of a read or a failed seal.
 * Votes at or after 7,200 seconds are rejected and do not change the tally.
 */
export class LedgerFixture implements ChainReader {
  readonly chainId = 224422
  readonly coreAddress: string
  now = 0
  head = 1
  balance = 10n ** 18n
  sealGas = 4_000_000n
  failReads = false
  failScan = false
  /** When set, eth_call reports revert even if the ledger would seal. */
  forceSimulateRevert = false
  readonly ethCallLog: string[] = []
  readonly cleanupLog: string[] = []
  private cases = new Map<string, FixtureCase>()
  private events: NormalizedEvent[] = []

  constructor(coreAddress: string) {
    this.coreAddress = coreAddress
  }

  open(input: Omit<LiveCase, 'status' | 'agree' | 'disagree'> & { agree?: number; disagree?: number }): void {
    const row: FixtureCase = {
      ...input,
      agree: input.agree ?? 0,
      disagree: input.disagree ?? 0,
      status: 'voting',
      votesRejectedAfterFreeze: 0,
    }
    this.cases.set(this.id(input.kind, input.caseId), row)
    this.events.push({
      type: 'opened',
      kind: input.kind,
      caseId: input.caseId,
      openedAt: input.openedAt,
      population: input.population,
      margin: input.margin,
      block: this.head,
    })
    this.head += 1
  }

  /** Returns false when the vote is rejected. The stored tally is unchanged. */
  vote(kind: CaseKind, caseId: string, side: 'agree' | 'disagree'): boolean {
    const row = this.must(kind, caseId)
    if (this.now >= row.openedAt + FREEZE_SEC) {
      row.votesRejectedAfterFreeze += 1
      return false
    }
    if (side === 'agree') row.agree += 1
    else row.disagree += 1
    this.events.push({
      type: 'voted',
      kind,
      caseId,
      agree: row.agree,
      disagree: row.disagree,
      timestamp: this.now,
      block: this.head,
    })
    this.head += 1
    return true
  }

  markSealed(kind: CaseKind, caseId: string): void {
    const row = this.must(kind, caseId)
    row.status = 'sealed'
    this.events.push({ type: 'sealed', kind, caseId, block: this.head })
    this.head += 1
  }

  /** Test hook: mutate the stored tally without an event. The engine must ignore this after freeze. */
  overwriteTally(kind: CaseKind, caseId: string, agree: number, disagree: number): void {
    const row = this.must(kind, caseId)
    row.agree = agree
    row.disagree = disagree
  }

  async getCase(kind: CaseKind, caseId: string): Promise<LiveCase | null> {
    if (this.failReads) throw new Error('rpc down')
    const row = this.cases.get(this.id(kind, caseId))
    if (!row) return null
    return {
      kind: row.kind,
      caseId: row.caseId,
      openedAt: row.openedAt,
      population: row.population,
      margin: row.margin,
      agree: row.agree,
      disagree: row.disagree,
      status: row.status,
    }
  }

  async ethCallSeal(kind: CaseKind, caseId: string): Promise<{ ok: boolean; error?: string }> {
    this.ethCallLog.push(`${kind}:${caseId}`)
    if (this.forceSimulateRevert) return { ok: false, error: 'forced-revert' }
    const row = this.must(kind, caseId)
    if (row.status !== 'voting') return { ok: false, error: 'not-voting' }
    const age = this.now - row.openedAt
    const early = (row.agree + row.disagree) * 2 > row.population
    if (age < 600 && !early) return { ok: false, error: 'too-early' }
    const margin = row.agree >= row.disagree + row.margin || row.disagree >= row.agree + row.margin
    if (!margin) return { ok: false, error: 'margin' }
    return { ok: true }
  }

  async balanceWei(): Promise<bigint> {
    return this.balance
  }

  async estimateSealGas(): Promise<bigint> {
    return this.sealGas
  }

  async scan(fromBlock: number, toBlock: number): Promise<ScanPage> {
    if (this.failScan) throw new Error('scan failed')
    const tip = Math.max(this.head - 1, 0)
    const end = Math.min(toBlock, Math.max(tip, fromBlock))
    const events = this.events.filter((event) => event.block > fromBlock && event.block <= end)
    return { events, toBlock: end }
  }

  snapshot(kind: CaseKind, caseId: string): FixtureCase {
    return { ...this.must(kind, caseId) }
  }

  private must(kind: CaseKind, caseId: string): FixtureCase {
    const row = this.cases.get(this.id(kind, caseId))
    if (!row) throw new Error(`missing ${kind} ${caseId}`)
    return row
  }

  private id(kind: CaseKind, caseId: string): string {
    return `${kind}:${caseId}`
  }
}
