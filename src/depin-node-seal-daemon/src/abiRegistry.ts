import type { AbiEntry, CaseKind } from './types.js'

/**
 * Worktree candidates only. Selectors stay unconfirmed until a final read-only
 * ABI snapshot is registered by the caller. Guessed 4-byte values are not filled in.
 */
export const CANDIDATE_ABI: readonly AbiEntry[] = [
  { kind: 'report', signature: 'finalizeReport(uint256)', selector: null, confirmed: false, target: 'core' },
  { kind: 'admission', signature: 'finalizeAdmission(bytes32)', selector: null, confirmed: false, target: 'core' },
  { kind: 'recovery', signature: 'finalizeRecovery(bytes32)', selector: null, confirmed: false, target: 'core' },
]

export class AbiRegistry {
  private rows = new Map<CaseKind, AbiEntry>()

  constructor(seed: readonly AbiEntry[] = CANDIDATE_ABI) {
    for (const row of seed) this.rows.set(row.kind, { ...row })
  }

  get(kind: CaseKind): AbiEntry | undefined {
    return this.rows.get(kind)
  }

  /** Caller-supplied snapshot. `confirmed` without a 4-byte selector is rejected. */
  register(entry: AbiEntry): void {
    if (entry.confirmed) {
      if (!isSelector(entry.selector)) throw new Error(`confirmed ABI for ${entry.kind} needs a 4-byte selector`)
      if (entry.target !== 'core') throw new Error('seal selectors are core-only')
    }
    this.rows.set(entry.kind, { ...entry })
  }

  confirmedSelector(kind: CaseKind): string | null {
    const row = this.rows.get(kind)
    if (!row?.confirmed || !row.selector) return null
    return row.selector.toLowerCase()
  }
}

export function isSelector(value: string | null): value is string {
  return typeof value === 'string' && /^0x[0-9a-fA-F]{8}$/.test(value)
}

export function encodeSealCalldata(selector: string, kind: CaseKind, caseId: string): string {
  const sel = selector.toLowerCase()
  if (!isSelector(sel)) throw new Error('selector is not 4 bytes')
  if (kind === 'report') return sel + uint256Word(caseId)
  return sel + bytes32Word(caseId)
}

function uint256Word(caseId: string): string {
  if (!/^\d+$/.test(caseId)) throw new Error('report id must be a decimal string')
  return BigInt(caseId).toString(16).padStart(64, '0')
}

function bytes32Word(caseId: string): string {
  const hex = caseId.toLowerCase().replace(/^0x/, '')
  if (!/^[0-9a-f]{64}$/.test(hex)) throw new Error('admission and recovery ids must be bytes32')
  return hex
}
