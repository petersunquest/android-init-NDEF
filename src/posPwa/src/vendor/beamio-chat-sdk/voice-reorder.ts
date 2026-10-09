import type { VoiceFrame } from './types'

export type VoiceFrameDirection = 'inbound' | 'outbound' | 'uplink' | 'downlink'

export interface VoiceFrameChunk extends VoiceFrame {
	direction?: VoiceFrameDirection
	frameId?: string
	chunkIndex?: number
	chunkCount?: number
}

export interface VoiceGapEvent {
	type: 'voice_gap_v1'
	sessionId: string
	direction: VoiceFrameDirection
	missingSeq: number[]
	missingChunks?: number[]
	reason: 'timeout' | 'buffer_overflow' | 'conflict'
}

export interface VoiceConflictEvent {
	type: 'voice_conflict_v1'
	sessionId: string
	direction: VoiceFrameDirection
	seq: number
	frameId?: string
}

export type VoiceReorderEvent =
	| { type: 'frame'; frame: VoiceFrameChunk }
	| { type: 'gap'; gap: VoiceGapEvent }
	| { type: 'conflict'; conflict: VoiceConflictEvent }

export interface VoiceFrameReorderOptions {
	/** Maximum time a missing sequence may block real-time delivery. */
	reorderDelayMs?: number
	/** Maximum number of chunks held for one stream. */
	maxPendingChunks?: number
	/** Maximum UTF-16 code units held for one stream. */
	maxPendingPayloadUnits?: number
	onEvent?: (event: VoiceReorderEvent) => void
}

interface StreamState {
	nextSeq: number | null
	pending: Map<number, VoiceFrameChunk>
	pendingPayloadUnits: number
	timer: ReturnType<typeof setTimeout> | null
	gapStartedAt: number | null
}

const DEFAULT_REORDER_DELAY_MS = 150
const DEFAULT_MAX_PENDING_CHUNKS = 96
const DEFAULT_MAX_PENDING_PAYLOAD_UNITS = 1_024 * 1_024

function normalizeDirection(frame: VoiceFrameChunk): VoiceFrameDirection {
	return frame.direction || 'inbound'
}

function streamKey(frame: VoiceFrameChunk): string {
	return `${frame.sessionId}:${normalizeDirection(frame)}`
}

function frameSignature(frame: VoiceFrameChunk): string {
	return `${frame.payload}:${frame.frameId || ''}:${frame.chunkIndex ?? ''}:${frame.chunkCount ?? ''}`
}

function validChunkShape(frame: VoiceFrameChunk): boolean {
	const hasIndex = frame.chunkIndex !== undefined || frame.chunkCount !== undefined
	if (!hasIndex) return true
	return (
		Number.isSafeInteger(frame.chunkIndex) &&
		Number.isSafeInteger(frame.chunkCount) &&
		(frame.chunkIndex as number) >= 0 &&
		(frame.chunkCount as number) > 0 &&
		(frame.chunkIndex as number) < (frame.chunkCount as number)
	)
}

function reassemble(group: VoiceFrameChunk[]): VoiceFrameChunk {
	const ordered = group.slice().sort((a, b) => (a.chunkIndex || 0) - (b.chunkIndex || 0))
	const first = ordered[0]
	return {
		...first,
		seq: ordered[ordered.length - 1].seq,
		payload: ordered.map((frame) => frame.payload).join(''),
		chunkIndex: undefined,
		chunkCount: undefined,
	}
}

/**
 * Reorders one real-time media stream. A stream is isolated by session and
 * direction; timestamps never participate in ordering or deduplication.
 */
export class VoiceFrameReorderBuffer {
	private readonly streams = new Map<string, StreamState>()
	private readonly reorderDelayMs: number
	private readonly maxPendingChunks: number
	private readonly maxPendingPayloadUnits: number
	private readonly onEvent?: (event: VoiceReorderEvent) => void

	constructor(options: VoiceFrameReorderOptions = {}) {
		this.reorderDelayMs = options.reorderDelayMs ?? DEFAULT_REORDER_DELAY_MS
		this.maxPendingChunks = options.maxPendingChunks ?? DEFAULT_MAX_PENDING_CHUNKS
		this.maxPendingPayloadUnits = options.maxPendingPayloadUnits ?? DEFAULT_MAX_PENDING_PAYLOAD_UNITS
		this.onEvent = options.onEvent
	}

	push(frame: VoiceFrameChunk, now = Date.now()): VoiceFrameChunk[] {
		if (
			frame.type !== 'voice_frame_v1' ||
			!frame.sessionId ||
			!Number.isSafeInteger(frame.seq) ||
			frame.seq < 0 ||
			typeof frame.payload !== 'string' ||
			!validChunkShape(frame)
		) {
			return []
		}

		const key = streamKey(frame)
		let state = this.streams.get(key)
		if (!state) {
			state = this.createState()
			this.streams.set(key, state)
		}
		if (state.nextSeq === null) state.nextSeq = frame.seq

		const existing = state.pending.get(frame.seq)
		if (existing) {
			if (frameSignature(existing) === frameSignature(frame)) return []
			this.emit({
				type: 'conflict',
				conflict: {
					type: 'voice_conflict_v1',
					sessionId: frame.sessionId,
					direction: normalizeDirection(frame),
					seq: frame.seq,
					frameId: frame.frameId,
				},
			})
			return []
		}

		if (frame.seq < state.nextSeq) return []
		if (state.pending.size >= this.maxPendingChunks || state.pendingPayloadUnits + frame.payload.length > this.maxPendingPayloadUnits) {
			this.emit({
				type: 'gap',
				gap: {
					type: 'voice_gap_v1',
					sessionId: frame.sessionId,
					direction: normalizeDirection(frame),
					missingSeq: [state.nextSeq],
					reason: 'buffer_overflow',
				},
			})
			return []
		}

		state.pending.set(frame.seq, frame)
		state.pendingPayloadUnits += frame.payload.length
		const delivered = this.drain(state)
		if (state.pending.size && !delivered.length) {
			if (state.gapStartedAt === null) state.gapStartedAt = now
			this.scheduleTimeout(key, state)
		}
		return delivered
	}

	/** Deterministic timeout hook for tests and host-driven schedulers. */
	tick(now = Date.now()): VoiceFrameChunk[] {
		const delivered: VoiceFrameChunk[] = []
		for (const [, state] of this.streams) {
			if (state.gapStartedAt !== null && now - state.gapStartedAt >= this.reorderDelayMs) {
				delivered.push(...this.skipGap(state))
			}
		}
		return delivered
	}

	clear(sessionId?: string): void {
		for (const [key, state] of this.streams) {
			if (sessionId && !key.startsWith(`${sessionId}:`)) continue
			if (state.timer !== null) clearTimeout(state.timer)
			this.streams.delete(key)
		}
	}

	private createState(): StreamState {
		const state: StreamState = {
			nextSeq: null,
			pending: new Map(),
			pendingPayloadUnits: 0,
			timer: null,
			gapStartedAt: null,
		}
		return state
	}

	private drain(state: StreamState): VoiceFrameChunk[] {
		const delivered: VoiceFrameChunk[] = []
		while (state.nextSeq !== null) {
			const first = state.pending.get(state.nextSeq)
			if (!first) break

			const expectedChunks = first.chunkCount
			if (expectedChunks && first.frameId) {
				const group = [...state.pending.values()].filter(
					(frame) => frame.frameId === first.frameId && frame.chunkCount === expectedChunks,
				)
				if (group.length !== expectedChunks) break
				group.sort((a, b) => (a.chunkIndex || 0) - (b.chunkIndex || 0))
				if (group.some((frame, index) => frame.chunkIndex !== index)) break
				const lastSeq = Math.max(...group.map((frame) => frame.seq))
				for (const frame of group) {
					state.pending.delete(frame.seq)
					state.pendingPayloadUnits -= frame.payload.length
				}
				state.nextSeq = lastSeq + 1
				delivered.push(reassemble(group))
				continue
			}

			state.pending.delete(state.nextSeq)
			state.pendingPayloadUnits -= first.payload.length
			state.nextSeq += 1
			delivered.push(first)
		}
		if (!state.pending.size) {
			state.gapStartedAt = null
			if (state.timer !== null) clearTimeout(state.timer)
			state.timer = null
		}
		for (const frame of delivered) this.emit({ type: 'frame', frame })
		return delivered
	}

	private skipGap(state: StreamState): VoiceFrameChunk[] {
		if (state.nextSeq === null || !state.pending.size) return []
		const firstPendingSeq = Math.min(...state.pending.keys())
		const first = state.pending.get(state.nextSeq)
		const missingSeq: number[] = []
		const missingChunks: number[] = []

		if (first && first.frameId && first.chunkCount) {
			const seen = new Set(
				[...state.pending.values()]
					.filter((frame) => frame.frameId === first.frameId)
					.map((frame) => frame.chunkIndex as number),
			)
			for (let index = 0; index < first.chunkCount; index += 1) {
				if (!seen.has(index)) missingChunks.push(index)
			}
			const groupSeq = [...state.pending.values()]
				.filter((frame) => frame.frameId === first.frameId)
				.map((frame) => frame.seq)
			state.nextSeq = Math.max(...groupSeq) + 1
		} else {
			for (let seq = state.nextSeq; seq < firstPendingSeq; seq += 1) missingSeq.push(seq)
			state.nextSeq = firstPendingSeq
		}

		this.emit({
			type: 'gap',
			gap: {
				type: 'voice_gap_v1',
				sessionId: [...state.pending.values()][0].sessionId,
				direction: normalizeDirection([...state.pending.values()][0]),
				missingSeq,
				...(missingChunks.length ? { missingChunks } : {}),
				reason: 'timeout',
			},
		})
		state.gapStartedAt = null
		if (state.timer !== null) clearTimeout(state.timer)
		state.timer = null
		return this.drain(state)
	}

	private scheduleTimeout(_key: string, state: StreamState): void {
		if (state.timer !== null) return
		state.timer = setTimeout(() => {
			state.timer = null
			this.skipGap(state)
		}, this.reorderDelayMs)
	}

	private emit(event: VoiceReorderEvent): void {
		this.onEvent?.(event)
	}
}
