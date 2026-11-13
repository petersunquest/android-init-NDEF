/**
 * §50 2.4 (2026-11-13): the outer entry wrap is strict in the POS vendor too. A wrap that cannot be made
 * throws (never the inner armor), and an entry without a PGP key is not a listen or send target.
 *
 *   tsx scripts/testEntryWrap.ts
 */
import { strict as assert } from 'node:assert'
import * as openpgp from 'openpgp'
import { EntryWrapError, wrapArmorToEntryRoute, wrapWouldHitSameNode } from '../src/vendor/beamio-chat-sdk/envelope'
import { hasEntryPgpKey, pickGossipEntryNodesForSend, pickListenEntryNodes } from '../src/vendor/beamio-chat-sdk/nodes'

type KeyPair = { publicArmored: string; privateArmored: string }

async function newKey(name: string): Promise<KeyPair> {
	const { privateKey, publicKey } = await openpgp.generateKey({
		type: 'ecc',
		curve: 'curve25519Legacy',
		userIDs: [{ name }],
		format: 'armored',
	})
	return { publicArmored: publicKey, privateArmored: privateKey }
}

/** Inner armor as a sender builds it: encrypted to the recipient's user PGP key. */
async function innerTo(recipientPublicArmored: string, text: string): Promise<string> {
	const encrypted = await openpgp.encrypt({
		message: await openpgp.createMessage({ text }),
		encryptionKeys: await openpgp.readKey({ armoredKey: recipientPublicArmored }),
		config: { preferredCompressionAlgorithm: openpgp.enums.compression.zlib },
	})
	return String(encrypted)
}

async function decryptWith(armor: string, privateArmored: string): Promise<string> {
	const { data } = await openpgp.decrypt({
		message: await openpgp.readMessage({ armoredMessage: armor }),
		decryptionKeys: await openpgp.readPrivateKey({ armoredKey: privateArmored }),
		format: 'utf8',
	})
	return String(data)
}

const node = (domain: string, armoredPublicKey = '') => ({
	region: 'x',
	ip_addr: '10.0.0.1',
	armoredPublicKey,
	nftNumber: 0,
	domain,
})

async function check(name: string, fn: () => Promise<void>): Promise<void> {
	try {
		await fn()
		console.log(`ok  ${name}`)
	} catch (ex) {
		console.error(`FAIL ${name}`)
		throw ex
	}
}

async function main(): Promise<void> {
	const entry = await newKey('entry-a')
	const recipient = await newKey('recipient')
	const inner = await innerTo(recipient.publicArmored, 'hello')

	await check('hasEntryPgpKey: true only for an armored PGP public key', async () => {
		assert.equal(hasEntryPgpKey({ armoredPublicKey: entry.publicArmored }), true)
		assert.equal(hasEntryPgpKey({ armoredPublicKey: '' }), false)
		assert.equal(hasEntryPgpKey({}), false)
		assert.equal(hasEntryPgpKey(undefined), false)
		assert.equal(hasEntryPgpKey({ armoredPublicKey: 'not a key' }), false)
	})

	await check('wrapArmorToEntryRoute: only the entry key opens the wrap, to the inner armor', async () => {
		const wrapped = await wrapArmorToEntryRoute(inner, entry.publicArmored)
		assert.notEqual(wrapped, inner)
		assert.equal(await decryptWith(wrapped, entry.privateArmored), inner)
	})

	await check('wrapArmorToEntryRoute: no PGP key on the entry throws no_entry_key', async () => {
		await assert.rejects(wrapArmorToEntryRoute(inner, ''), (ex: unknown) => ex instanceof EntryWrapError && ex.reason === 'no_entry_key')
	})

	await check('wrapArmorToEntryRoute: input that is not armor throws not_pgp', async () => {
		await assert.rejects(wrapArmorToEntryRoute('plain text', entry.publicArmored), (ex: unknown) => ex instanceof EntryWrapError && ex.reason === 'not_pgp')
	})

	await check('wrapArmorToEntryRoute: entry equal to the inner recipient throws unsafe_route', async () => {
		assert.equal(await wrapWouldHitSameNode(inner, recipient.publicArmored), true)
		await assert.rejects(wrapArmorToEntryRoute(inner, recipient.publicArmored), (ex: unknown) => ex instanceof EntryWrapError && ex.reason === 'unsafe_route')
	})

	await check('pickListenEntryNodes: a keyless entry is never a listen target', async () => {
		const keyed = node('ENTRYA', entry.publicArmored)
		assert.deepEqual(pickListenEntryNodes([node('NOKEY'), keyed]).map((n) => n.domain), ['ENTRYA'])
		assert.deepEqual(pickListenEntryNodes([node('NOKEY')]), [])
	})

	await check('pickGossipEntryNodesForSend: only keyed entries are chosen', async () => {
		const realFetch = globalThis.fetch
		globalThis.fetch = (async () => new Response('', { status: 200 })) as typeof fetch
		try {
			const picked = await pickGossipEntryNodesForSend(
				[node('NOKEY'), node('ENTRYA', entry.publicArmored), node('ENTRYB', recipient.publicArmored)],
				4,
			)
			assert.deepEqual(picked.map((n) => n.domain).sort(), ['ENTRYA', 'ENTRYB'])
		} finally {
			globalThis.fetch = realFetch
		}
	})

	console.log('\nPASS 7 checks (entry wrap, POS vendor)')
}

main().catch((ex) => {
	console.error(ex)
	process.exit(1)
})
