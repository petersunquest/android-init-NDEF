import { FREEZE_SEC, MIN_OPEN_SEC, type Decision, type Tally } from './types.js'

/** Strictly more than half. Exactly 50% is false. */
export function participationExceedsHalf(agree: number, disagree: number, population: number): boolean {
  if (!Number.isInteger(population) || population <= 0) return false
  return (agree + disagree) * 2 > population
}

/** Margin at the moment of the call. A tally that only met the margin in the past does not count. */
export function marginMet(tally: Tally, margin: number): boolean {
  if (!Number.isInteger(margin) || margin <= 0) return false
  return tally.agree >= tally.disagree + margin || tally.disagree >= tally.agree + margin
}

export function sealTimeOpen(
  now: number,
  openedAt: number,
  tally: Tally,
  population: number,
): 'too-early' | 'window' | 'early-half' | 'frozen' {
  const age = now - openedAt
  if (age >= FREEZE_SEC) return 'frozen'
  if (age >= MIN_OPEN_SEC) return 'window'
  if (participationExceedsHalf(tally.agree, tally.disagree, population)) return 'early-half'
  return 'too-early'
}

export function decide(input: {
  now: number
  openedAt: number
  population: number
  margin: number
  tally: Tally
  chainStatus: 'voting' | 'sealed' | 'aborted'
}): Decision {
  if (input.chainStatus === 'sealed') return { action: 'skip', reason: 'already-sealed' }
  if (input.chainStatus === 'aborted') return { action: 'alert', reason: 'contract-aborted' }
  const phase = sealTimeOpen(input.now, input.openedAt, input.tally, input.population)
  const meets = marginMet(input.tally, input.margin)
  if (phase === 'frozen' && !meets) return { action: 'alert', reason: 'frozen-below-margin' }
  if (!meets) return { action: 'wait', reason: 'margin' }
  if (phase === 'too-early') return { action: 'wait', reason: 'too-early' }
  const reason = phase === 'frozen' ? 'late-frozen' : phase
  return { action: 'seal', reason, tally: { agree: input.tally.agree, disagree: input.tally.disagree } }
}
