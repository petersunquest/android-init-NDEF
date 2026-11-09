import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import type { AttemptRecord, CaseRecord, Journal } from './types.js'

export function emptyJournal(): Journal {
  return { version: 1, cursorBlock: 0, cases: {}, attempts: [] }
}

export function caseKey(contract: string, kind: string, caseId: string): string {
  return `${contract.toLowerCase()}:${kind}:${caseId}`
}

export function loadJournal(path: string | undefined): Journal {
  if (!path) return emptyJournal()
  try {
    const parsed = JSON.parse(readFileSync(path, 'utf8')) as Journal
    if (parsed.version !== 1 || !parsed.cases || !Array.isArray(parsed.attempts)) return emptyJournal()
    return parsed
  } catch {
    return emptyJournal()
  }
}

/** Trusted write. Callers must pass the journal they intend to keep, never a failed empty read. */
export function saveJournal(path: string | undefined, journal: Journal): void {
  if (!path) return
  mkdirSync(dirname(path), { recursive: true })
  const tmp = `${path}.tmp`
  writeFileSync(tmp, JSON.stringify(journal, null, 2))
  renameSync(tmp, path)
}

export function findAttempt(journal: Journal, idempotencyKey: string): AttemptRecord | undefined {
  for (let i = journal.attempts.length - 1; i >= 0; i--) {
    if (journal.attempts[i]?.idempotencyKey === idempotencyKey) return journal.attempts[i]
  }
  return undefined
}

export function blockingAttempt(attempt: AttemptRecord | undefined): boolean {
  if (!attempt) return false
  return attempt.status === 'pending-dry-run' || attempt.status === 'submitted' || attempt.status === 'mined'
}

export function tallyOf(rec: CaseRecord, now: number, freezeSec: number): { agree: number; disagree: number } {
  if (now >= rec.openedAt + freezeSec && rec.frozenAgree !== null && rec.frozenDisagree !== null) {
    return { agree: rec.frozenAgree, disagree: rec.frozenDisagree }
  }
  return { agree: rec.liveAgree, disagree: rec.liveDisagree }
}
