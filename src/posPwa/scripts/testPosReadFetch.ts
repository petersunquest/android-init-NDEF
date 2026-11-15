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

	// 5. Body hang: headers arrive, body never completes. The same timer must abort it.
	globalThis.fetch = ((_url: string, init?: RequestInit) => {
		const hangingBody = new ReadableStream({
			start(controller) {
				init?.signal?.addEventListener('abort', () => controller.error(new Error('body aborted')))
			},
		})
		return Promise.resolve(new Response(hangingBody, { status: 200 }))
	}) as typeof fetch
	const t2 = Date.now()
	await assert.rejects(posReadFetch('https://example.invalid/body-hang'), /body aborted/)
	const bodyElapsed = Date.now() - t2
	assert.ok(bodyElapsed >= POS_READ_TIMEOUT_MS - 50, `body abort after ${bodyElapsed} ms`)
	console.log(`ok body hang aborted after ${bodyElapsed} ms`)

	// 6. Successful body is re-readable as JSON with the original status.
	globalThis.fetch = (async () => new Response('{"ok":true}', { status: 201 })) as typeof fetch
	const okRes = await posReadFetch('https://example.invalid/json')
	assert.equal(okRes.status, 201)
	assert.deepEqual(await okRes.json(), { ok: true })
	console.log('ok body is returned intact (status and JSON)')

	// 7. Null-body statuses (204/205/304) must not throw when re-wrapped.
	for (const status of [204, 205, 304]) {
		globalThis.fetch = (async () => new Response(null, { status })) as typeof fetch
		const nb = await posReadFetch('https://example.invalid/null-body')
		assert.equal(nb.status, status)
	}
	console.log('ok null-body statuses 204/205/304 returned intact')

	globalThis.fetch = realFetch
	console.log('ALL PASS')
}

main().catch((e) => {
	globalThis.fetch = realFetch
	console.error('FAIL', e)
	process.exit(1)
})
