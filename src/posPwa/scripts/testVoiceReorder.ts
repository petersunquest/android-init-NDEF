import { strict as assert } from 'node:assert'
import { VoiceFrameReorderBuffer } from '../src/vendor/beamio-chat-sdk/voice-reorder'

const frame = (seq: number, payload: string, extra: Record<string, unknown> = {}) => ({
	type: 'voice_frame_v1' as const,
	callId: 'call',
	sessionId: 'session',
	from: '0x1',
	to: '0x2',
	seq,
	timestamp: seq,
	payload,
	...extra,
})

const ordered = new VoiceFrameReorderBuffer({ reorderDelayMs: 10 })
assert.deepEqual(ordered.push(frame(1, 'a')).map((item) => item.seq), [1])
assert.deepEqual(ordered.push(frame(3, 'c')).map((item) => item.seq), [])
assert.deepEqual(ordered.push(frame(2, 'b')).map((item) => item.seq), [2, 3])

const events: unknown[] = []
const conflicts = new VoiceFrameReorderBuffer({ onEvent: (event) => events.push(event) })
conflicts.push(frame(1, 'a'))
conflicts.push(frame(3, 'pending'))
conflicts.push(frame(3, 'different'))
assert.equal((events.find((event) => (event as { type: string }).type === 'conflict') as { type: string }).type, 'conflict')

const gaps: unknown[] = []
const gapBuffer = new VoiceFrameReorderBuffer({ reorderDelayMs: 0, onEvent: (event) => gaps.push(event) })
gapBuffer.push(frame(1, 'a'))
gapBuffer.push(frame(3, 'c'))
gapBuffer.tick(Date.now() + 1)
assert.equal((gaps.find((event) => (event as { type: string }).type === 'gap') as { type: string }).type, 'gap')

const chunks = new VoiceFrameReorderBuffer()
assert.deepEqual(chunks.push(frame(1, 'A', { frameId: 'f', chunkIndex: 0, chunkCount: 2 })).map((item) => item.payload), [])
assert.deepEqual(chunks.push(frame(2, 'B', { frameId: 'f', chunkIndex: 1, chunkCount: 2 })).map((item) => item.payload), ['AB'])

const isolated = new VoiceFrameReorderBuffer()
isolated.push(frame(1, 'up', { direction: 'uplink' }))
assert.deepEqual(isolated.push(frame(1, 'down', { direction: 'downlink' })).map((item) => item.payload), ['down'])

assert.deepEqual(ordered.push({ ...frame(4, 'invalid'), seq: -1 }).map((item) => item.seq), [])
const limited = new VoiceFrameReorderBuffer({ maxPendingChunks: 1 })
limited.push(frame(1, 'a'))
limited.push(frame(3, 'c'))
assert.deepEqual(limited.push(frame(4, 'd')), [])

console.log('voice reorder tests passed')
