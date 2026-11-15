/**
 * Offline check for the POS boot timeout chain (no network, no browser).
 * Run: node --experimental-strip-types scripts/testPosReadFetch.ts
 *
 * Covers: a hung read is aborted, a failed read rejects with a typed error,
 * and the boot ceiling rejects even when the underlying promise never settles.
 */
import assert from 'node:assert/strict'
import {
	PosBackendUnavailableError,
	POS_READ_TIMEOUT_MS,
	posReadFetch,
	withPosBootCeiling,
} from '../src/api/posReadFetch.ts'

const realFetch = globalThis.fetch

async function main() {
	// 1. Hung backend: fetch never resolves unless aborted. Helper must abort after the timeout.
	globalThis.fetch = ((_url: string, init?: RequestInit) =>
		new Promise((_resolve, reject) => {
			init?.signal?.addEventListener('abort', () => reject(new Error('aborted')))
		})) as typeof fetch
	const t0 = Date.now()
	await assert.rejects(posReadFetch('https://example.invalid/hang'), /aborted/)
	const elapsed = Date.now() - t0
	assert.ok(elapsed >= POS_READ_TIMEOUT_MS - 50 && elapsed < POS_READ_TIMEOUT_MS + 2000, `abort after ${elapsed} ms`)
	console.log(`ok hung read aborted after ${elapsed} ms`)

	// 2. Boot ceiling with a promise that never settles and no abort support.
	globalThis.fetch = realFetch
	const never = new Promise<void>(() => {})
	const t1 = Date.now()
	await assert.rejects(withPosBootCeiling(never, 300), (e: unknown) => e instanceof PosBackendUnavailableError)
	assert.ok(Date.now() - t1 < 1500)
	console.log('ok boot ceiling rejects a never-settling refresh')

	// 3. Network failure (fetch rejects) surfaces as a rejection, not a silent null.
	globalThis.fetch = (() => Promise.reject(new TypeError('fetch failed'))) as typeof fetch
	await assert.rejects(posReadFetch('https://example.invalid/down'), TypeError)
	console.log('ok network failure rejects')

	// 4. Success path resolves and the timer is cleared (process exits without waiting).
	globalThis.fetch = (async () => new Response('{}', { status: 200 })) as typeof fetch
	const ok = await posReadFetch('https://example.invalid/ok')
	assert.equal(ok.status, 200)
	await withPosBootCeiling(Promise.resolve(), 60_000)
	console.log('ok success path resolves; no leftover timers')

	globalThis.fetch = realFetch
	console.log('ALL PASS')
}

main().catch((e) => {
	globalThis.fetch = realFetch
	console.error('FAIL', e)
	process.exit(1)
})
