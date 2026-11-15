/**
 * Offline check: customer QR / NDEF link identity is host-independent, so legacy beamio.app
 * payloads on existing cards still parse locally, and new beamio.ca payloads parse the same way.
 * Bundled with esbuild (alias @ -> src) and run under Node; no network.
 */
import assert from 'node:assert/strict'
import { parseCustomerIdentity } from '@/utils/beamioQrIdentity'

const WALLET = '0x3333333333333333333333333333333333333333'
const cases: Array<[string, { beamioTag?: string; wallet?: string }]> = [
	['https://beamio.app/app/?beamio=qa-merchant', { beamioTag: 'qa-merchant' }],
	['https://beamio.ca/app/?beamio=qa-merchant', { beamioTag: 'qa-merchant' }],
	['https://www.beamio.app/?wallet=' + WALLET, { wallet: WALLET }],
	['https://www.beamio.ca/?wallet=' + WALLET, { wallet: WALLET }],
	['https://pos.beamio.app/?beamio=qa-merchant', { beamioTag: 'qa-merchant' }],
	['https://pos.beamio.ca/?beamio=qa-merchant', { beamioTag: 'qa-merchant' }],
]
for (const [text, want] of cases) {
	const got = parseCustomerIdentity(text)
	assert.ok(got, `no identity for ${text}`)
	assert.equal(got.beamioTag, want.beamioTag, `tag ${text}`)
	assert.equal(got.wallet, want.wallet, `wallet ${text}`)
	console.log(`ok ${text} -> ${JSON.stringify(got)}`)
}
console.log('ALL PASS')
