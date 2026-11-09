/** CoNET L1 only. DAO Governor is not a case kind. */
export const CONET_CHAIN_ID = 224422

export const MIN_OPEN_SEC = 600
export const FREEZE_SEC = 7200

export type CaseKind = 'admission' | 'recovery' | 'report'

export type ChainStatus = 'voting' | 'sealed' | 'aborted'

export type Tally = { agree: number; disagree: number }

export type LiveCase = {
  kind: CaseKind
  caseId: string
  openedAt: number
  population: number
  margin: number
  agree: number
  disagree: number
  status: ChainStatus
}

export type NormalizedEvent =
  | {
      type: 'opened'
      kind: CaseKind
      caseId: string
      openedAt: number
      population: number
      margin: number
      block: number
    }
  | {
      type: 'voted'
      kind: CaseKind
      caseId: string
      agree: number
      disagree: number
      timestamp: number
      block: number
    }
  | {
      type: 'sealed'
      kind: CaseKind
      caseId: string
      block: number
    }

export type ScanPage = { events: NormalizedEvent[]; toBlock: number }

export interface ChainReader {
  readonly chainId: number
  readonly coreAddress: string
  getCase(kind: CaseKind, caseId: string): Promise<LiveCase | null>
  /** Preflight the seal entry only. Must not abort or clean a case. */
  ethCallSeal(kind: CaseKind, caseId: string): Promise<{ ok: boolean; error?: string }>
  balanceWei(): Promise<bigint>
  estimateSealGas(kind: CaseKind, caseId: string): Promise<bigint>
  scan(fromBlock: number, toBlock: number): Promise<ScanPage>
}

export type SealReason = 'window' | 'early-half' | 'late-frozen'

export type Decision =
  | { action: 'wait'; reason: string }
  | { action: 'skip'; reason: string }
  | { action: 'alert'; reason: string }
  | { action: 'seal'; reason: SealReason; tally: Tally }

export type AttemptStatus = 'pending-dry-run' | 'submitted' | 'mined' | 'reverted' | 'refused'

export type AttemptRecord = {
  idempotencyKey: string
  kind: CaseKind
  caseId: string
  contract: string
  status: AttemptStatus
  broadcast: boolean
  cleanup: false
  hash?: string
  reason: string
  tally: Tally
  error?: string
}

export type CaseRecord = {
  key: string
  kind: CaseKind
  caseId: string
  contract: string
  openedAt: number
  population: number
  margin: number
  liveAgree: number
  liveDisagree: number
  frozenAgree: number | null
  frozenDisagree: number | null
  chainStatus: ChainStatus
  alerts: string[]
  updatedAt: number
}

export type Journal = {
  version: 1
  cursorBlock: number
  cases: Record<string, CaseRecord>
  attempts: AttemptRecord[]
}

export type AbiEntry = {
  kind: CaseKind
  signature: string
  /** Null until a confirmed snapshot supplies the 4-byte selector. */
  selector: string | null
  confirmed: boolean
  /** Admission and recovery are viaCore: the target is the core, never the extension. */
  target: 'core'
}

export type DaemonConfig = {
  chainId: number
  coreAddress: string
  /** If set, any send aimed at this address is refused. */
  extensionAddress?: string
  /** Default true. No transaction is broadcast. */
  dryRun: boolean
  /** Must be true, and the selector confirmed, before calldata may be handed to a signer. */
  sendEnabled: boolean
  maxGas: bigint
  gasPriceWei: bigint
  clientName: string
  journalPath?: string
}

export type SealSendRequest = {
  client: string
  idempotencyKey: string
  chainId: number
  to: string
  data: string
  gasLimit: bigint
}

export type SealSendResult = {
  hash: string
  status: 'submitted' | 'reverted' | 'duplicate'
  duplicate?: boolean
}

export interface SealSigner {
  send(req: SealSendRequest): Promise<SealSendResult>
}
