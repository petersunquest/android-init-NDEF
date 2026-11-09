import type { CaseKind } from './types.js'

/**
 * Aligns with wallet-signer TxManager idempotencyKey: stable across restarts.
 * Date.now() is intentionally absent. The signer scopes the key by client name.
 */
export function sealIdempotencyKey(input: {
  chainId: number
  contract: string
  kind: CaseKind
  caseId: string
}): string {
  const contract = input.contract.toLowerCase()
  return `${input.chainId}:${contract}:${input.kind}:${input.caseId}:seal`
}
