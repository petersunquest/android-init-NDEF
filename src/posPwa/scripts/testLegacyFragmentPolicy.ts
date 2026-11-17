/**
 * Offline check: legacy beamio.app fragment links are recognised only to extract the hash,
 * requests go to the current fragment service, similar domains are not recognised, and no
 * request is ever sent to a retired beamio.app host. Last verified: see DM-POS-01 receipt.
 * Bundled with esbuild (no alias needed) and run under Node:
 *   ./node_modules/.bin/esbuild scripts/testLegacyFragmentPolicy.ts --bundle --platform=node --format=esm --outfile=<scratch>/t.mjs && node <scratch>/t.mjs
 */
import assert from 'node:assert/strict'
import {
	isLegacyBeamioAppUrl,
	parseFragmentHashFromUrl,
	resolveIpfsImageUrlToObjectUrl,
	safeImgSrcForUnresolved,
} from '../src/utils/ipfsImageLibrary'

const HASH = 'ab'.repeat(32)
const HASH0X = `0x${HASH}`
const realFetch = globalThis.fetch
const seenUrls: string[] = []

function stubFetch(impl: (url: string) => Promise<Response>) {
	globalThis.fetch = ((input: RequestInfo | URL) => {
		const url = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url
		seenUrls.push(url)
		return impl(url)
	}) as typeof fetch
}

function pngResponse(): Response {
	const bytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0])
	return new Response(bytes, { status: 200, headers: { 'Content-Type': 'image/png' } })
}

function assertNoLegacyRequest(label: string) {
	const bad = seenUrls.filter((u) => /https?:\/\/([a-z0-9.-]*\.)?beamio\.app(\/|$|\?)/i.test(u))
	assert.deepEqual(bad, [], `${label}: request to a retired beamio.app host`)
}

async function main() {
	// Positive: legacy and current /api/fragment links yield the hash.
	for (const u of [
		`https://beamio.app/api/fragment?hash=${HASH0X}`,
		`https://www.beamio.app/api/fragment?hash=${HASH0X}`,
		`https://beamio.ca/api/fragment?hash=${HASH0X}`,
		`https://www.beamio.ca/api/fragment?hash=${HASH0X}`,
		`https://ipfs.conet.network/api/getFragment?hash=${HASH0X}`,
	]) {
		assert.equal(parseFragmentHashFromUrl(u), HASH0X, u)
	}
	console.log('ok positive: legacy and current fragment links extract the hash')

	// Negative: similar or other hosts are not recognised.
	for (const u of [
		`https://evil-beamio.app/api/fragment?hash=${HASH0X}`,
		`https://xbeamio.app/api/fragment?hash=${HASH0X}`,
		`https://beamio.app.evil.example/api/fragment?hash=${HASH0X}`,
		`https://cashtrees.beamio.app/api/fragment?hash=${HASH0X}`,
		`https://api.beamio.app/api/fragment?hash=${HASH0X}`,
		`https://pos.beamio.app/api/fragment?hash=${HASH0X}`,
		`https://evil.beamio.ca/api/fragment?hash=${HASH0X}`,
		`https://beamio.app/other?hash=${HASH0X}`,
		`https://beamio.app/api/fragment`,
		`https://beamio.app/api/fragment?hash=nothex`,
		`http://beamio.app/api/fragment?hash=${HASH0X}`,
	]) {
		assert.equal(parseFragmentHashFromUrl(u), null, u)
	}
	console.log('ok negative: similar domains and malformed legacy links are not recognised')

	// Legacy host detection and the unresolved img src rule.
	assert.equal(isLegacyBeamioAppUrl('https://beamio.app/any/thing.png'), true)
	assert.equal(isLegacyBeamioAppUrl('https://www.beamio.app/x'), true)
	assert.equal(isLegacyBeamioAppUrl('https://beamio.ca/x'), false)
	assert.equal(isLegacyBeamioAppUrl('https://evil-beamio.app/x'), false)
	assert.equal(safeImgSrcForUnresolved('https://beamio.app/legacy.png'), '')
	assert.equal(safeImgSrcForUnresolved('https://beamio.app/api/fragment?hash=bad'), '')
	assert.equal(safeImgSrcForUnresolved('https://example.com/a.png'), 'https://example.com/a.png')
	console.log('ok img src: retired beamio.app URLs never become an img src when unresolved')

	// Resolve: a legacy link fetches from the current fragment service only.
	seenUrls.length = 0
	stubFetch(async () => pngResponse())
	const okObj = await resolveIpfsImageUrlToObjectUrl(`https://beamio.app/api/fragment?hash=${HASH0X}`)
	assert.ok(okObj !== '' && !okObj.includes('beamio.app'), 'resolved source must be a local object URL')
	assert.ok(seenUrls.length >= 1, 'expected one request to the fragment service')
	for (const u of seenUrls) assert.ok(u.startsWith('https://ipfs.conet.network/api/getFragment?hash='), u)
	assertNoLegacyRequest('resolve ok')
	console.log('ok resolve: legacy link fetched only from ipfs.conet.network/getFragment')

	// Resolve failure: no image, and the old URL is never returned as the source.
	seenUrls.length = 0
	stubFetch(async () => new Response('nope', { status: 500 }))
	const failed = await resolveIpfsImageUrlToObjectUrl(`https://beamio.app/api/fragment?hash=${HASH0X}`)
	assert.equal(failed, '', 'failed legacy resolve must not return the old URL')
	assertNoLegacyRequest('resolve failure')
	console.log('ok failure: failed legacy resolve returns empty src, no request to beamio.app')

	// Unparseable legacy URL: empty, no request at all.
	seenUrls.length = 0
	stubFetch(async () => pngResponse())
	const unparsed = await resolveIpfsImageUrlToObjectUrl('https://beamio.app/legacy/photo.png')
	assert.equal(unparsed, '')
	assert.equal(seenUrls.length, 0, 'unparseable legacy URL must not be requested')
	console.log('ok unparseable: legacy URL without a fragment hash is neither requested nor shown')

	globalThis.fetch = realFetch
	console.log('ALL PASS')
}

main().catch((e) => {
	globalThis.fetch = realFetch
	console.error('FAIL', e)
	process.exit(1)
})
