import type { SealSendRequest, SealSendResult, SealSigner } from './types.js'

/** Records the request and does not open a socket or hold a key. */
export class MemorySigner implements SealSigner {
  readonly sent: SealSendRequest[] = []
  revert = false
  private seen = new Map<string, SealSendResult>()

  async send(req: SealSendRequest): Promise<SealSendResult> {
    const prior = this.seen.get(req.idempotencyKey)
    if (prior && prior.status !== 'reverted') {
      return { ...prior, status: 'duplicate', duplicate: true }
    }
    this.sent.push(req)
    if (this.revert) {
      const result: SealSendResult = { hash: `0xrevert${this.sent.length}`, status: 'reverted' }
      this.seen.set(req.idempotencyKey, result)
      return result
    }
    const result: SealSendResult = { hash: `0xhash${this.sent.length}`, status: 'submitted' }
    this.seen.set(req.idempotencyKey, result)
    return result
  }
}

/**
 * Draft only. This build never connects. A future client would use one fixed
 * unix socket bound to client `depin-node-seal`, not the shared proxy socket.
 */
export class DisabledUnixSigner implements SealSigner {
  constructor(readonly socketPath: string) {}

  async send(): Promise<SealSendResult> {
    throw new Error(`unix signer ${this.socketPath} is not enabled`)
  }
}
