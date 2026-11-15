/**
 * Offline check for the unbound-terminal rule in fetchMyPosAddress.
 * Bundled with esbuild (path alias @ -> src) and run under Node; see the receipt for the command.
 *
 *   - HTTP 404 + exact "No merchant card registered for this terminal in DB" -> null (no card)
 *   - other 404 bodies, other 4xx/5xx, non-JSON 200 or 404, network failure -> PosBackendUnavailableError
 *   - timeout (headers and body never complete) -> PosBackendUnavailableError
 */
import assert from 'node:assert/strict'
import { fetchMyPosAddress, POS_NO_MERCHANT_CARD_ERROR } from '@/api/beamioApi'
import { PosBackendUnavailableError } from '@/api/posReadFetch'

const realFetch = globalThis.fetch
const WALLET = '0x3333333333333333333333333333333333333333'

function jsonResponse(status: number, body: unknown): Response {
	return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

async function expectUnavailable(label: string, p: Promise<unknown>) {
	await assert.rejects(p, (e: unknown) => e instanceof PosBackendUnavailableError, label)
	console.log(`ok ${label}: throws PosBackendUnavailableError`)
}

async function main() {
	// 1. Deterministic "no card": 404 with the exact server message -> null.
	globalThis.fetch = (async () =>
		jsonResponse(404, { ok: false, error: POS_NO_MERCHANT_CARD_ERROR })) as typeof fetch
	assert.equal(await fetchMyPosAddress(WALLET), null)
	console.log('ok 404 + exact no-card message -> null (no card)')

	// 2. Other 404 bodies are NOT "no card": they throw.
	globalThis.fetch = (async () => jsonResponse(404, { ok: false, error: 'Route not found' })) as typeof fetch
	await expectUnavailable('404 with a different message', fetchMyPosAddress(WALLET))
	globalThis.fetch = (async () => new Response('<html>404</html>', { status: 404 })) as typeof fetch
	await expectUnavailable('404 with non-JSON body', fetchMyPosAddress(WALLET))

	// 3. Other 4xx / 5xx, network failure, invalid JSON on 200: throw.
	for (const status of [400, 401, 403, 500, 502, 503]) {
		globalThis.fetch = (async () => jsonResponse(status, { ok: false, error: POS_NO_MERCHANT_CARD_ERROR })) as typeof fetch
		await expectUnavailable(`HTTP ${status} even with the no-card text`, fetchMyPosAddress(WALLET))
	}
	globalThis.fetch = (() => Promise.reject(new TypeError('fetch failed'))) as typeof fetch
	await expectUnavailable('network failure', fetchMyPosAddress(WALLET))
	globalThis.fetch = (async () => new Response('not json', { status: 200 })) as typeof fetch
	await expectUnavailable('200 with invalid JSON', fetchMyPosAddress(WALLET))

	// 4. Timeout: headers arrive, body never completes; the 10 s read timer must abort it.
	globalThis.fetch = ((_url: string, init?: RequestInit) => {
		const body = new ReadableStream({
			start(controller) {
				init?.signal?.addEventListener('abort', () => controller.error(new Error('aborted')))
			},
		})
		return Promise.resolve(new Response(body, { status: 200 }))
	}) as typeof fetch
	const t0 = Date.now()
	await expectUnavailable('body hang (timeout)', fetchMyPosAddress(WALLET))
	console.log(`   timeout aborted after ${Date.now() - t0} ms`)

	// 5. Success path still returns the parsed payload.
	globalThis.fetch = (async () => jsonResponse(200, { ok: true, cardAddress: '0x2222222222222222222222222222222222222222' })) as typeof fetch
	const ok = await fetchMyPosAddress(WALLET)
	assert.equal(ok?.ok, true)
	console.log('ok 200 with a bound card -> parsed payload')

	globalThis.fetch = realFetch
	console.log('ALL PASS')
}

main().catch((e) => {
	globalThis.fetch = realFetch
	console.error('FAIL', e)
	process.exit(1)
})
