import { generateKey, readKey } from 'openpgp'
import { BEAMIO_API } from '@/constants'
import { ROUTE_DOMAIN_HEX_POOL } from '@/conet/constants'
import { aesGcmEncrypt, normalizePrivateKeyHex, sleep, toBase64Utf8 } from '@/conet/crypto'
import { hasOnChainUserPgpPublic, isMailboxNodeRecorded, readOwnUserPgpPresence } from '@/conet/searchKey'
import { fetchCoNETGossipNodes } from '@/conet/guardianNodes'
import { pickRecordedMailbox, planOwnChatRoute, resolveCurrentMailbox } from '@/conet/chatOwnRoutePlan'
import { loadPosChatPgp } from '@/chat/posChatPgp'
import { Wallet, hexlify, keccak256, randomBytes, toUtf8Bytes } from 'ethers'

type GenerateKeyArg = Parameters<typeof generateKey>[0]

async function generatePgpKeyPair(walletAddress: string): Promise<{
	privateKey: string
	publicKey: string
	keyID: string
}> {
	const option = {
		type: 'ecc',
		passphrase: '',
		userIDs: [{ name: walletAddress }],
		curve: 'curve25519',
		format: 'armored',
	} as const
	const { privateKey, publicKey } = await generateKey(option as unknown as GenerateKeyArg)
	const publicKeyArmored = publicKey as unknown as string
	const keyObj = await readKey({ armoredKey: publicKeyArmored })
	const keyID = keyObj.getKeyIDs()[1]!.toHex().toUpperCase()
	return {
		privateKey: privateKey as unknown as string,
		publicKey: publicKeyArmored,
		keyID,
	}
}

/**
 * Message the wallet signs for `POST /api/regiestChatRoute` (EIP-191).
 * Must match x402sdk `src/chatRouteAuth.ts` `buildRegiestChatRouteMessage`.
 */
function buildRegiestChatRouteMessage(p: {
	wallet: string
	keyID: string
	publicKeyArmored: string
	encrypKeyArmored: string
	routeKeyID: string
	timestamp: number
	nonce: string
}): string {
	return [
		'Beamio regiestChatRoute',
		`wallet:${p.wallet.toLowerCase()}`,
		`keyID:${p.keyID}`,
		`publicKeyArmoredHash:${keccak256(toUtf8Bytes(p.publicKeyArmored))}`,
		`encrypKeyArmoredHash:${keccak256(toUtf8Bytes(p.encrypKeyArmored))}`,
		`routeKeyID:${p.routeKeyID}`,
		`timestamp:${p.timestamp}`,
		`nonce:${p.nonce.toLowerCase()}`,
	].join('\n')
}

/** bizSite `chat.ts` `regiestChatRoute`. Signed by the wallet; the API rejects unsigned requests. */
export async function regiestChatRoute(params: {
	walletPrivateKeyHex: string
	publicKeyArmored: string
	keyID: string
	secretKeyArmored: string
	routeKeyID: string
}): Promise<boolean> {
	const pk = normalizePrivateKeyHex(params.walletPrivateKeyHex)
	if (!pk) return false
	const wallet = new Wallet(`0x${pk}`)
	/* bizSite `regiestChatRoute`: AES password = wallet private key hex with `0x` prefix. */
	try {
		const fields = {
			wallet: wallet.address,
			keyID: String(params.keyID || '').trim(),
			publicKeyArmored: toBase64Utf8(params.publicKeyArmored).trim(),
			encrypKeyArmored: String(await aesGcmEncrypt(params.secretKeyArmored, wallet.privateKey)).trim(),
			routeKeyID: String(params.routeKeyID || '').trim(),
			timestamp: Date.now(),
			nonce: hexlify(randomBytes(16)),
		}
		const signature = await wallet.signMessage(buildRegiestChatRouteMessage(fields))
		const res = await fetch(`${BEAMIO_API}/api/regiestChatRoute`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ ...fields, signature }),
		})
		const json = (await res.json().catch(() => null)) as { ok?: boolean; error?: string } | null
		if (!res.ok || json?.ok !== true) {
			console.warn('[regiestChatRoute] failed', res.status, json?.error ?? json)
			return false
		}
		return true
	} catch (ex) {
		console.warn('[regiestChatRoute]', ex instanceof Error ? ex.message : ex)
		return false
	}
}

/** Poll `searchKey` until AddressPGP reflects a new registration (CoNET lag after API success). */
async function waitForOnChainUserPgpPublic(walletEoaLower: string): Promise<boolean> {
	// bizSite re-register path waits 5s once; POS retries for block / RPC lag.
	const pollDelaysMs = [1500, 2000, 2000, 3000, 3000, 4000]
	for (const delay of pollDelaysMs) {
		if (delay > 0) await sleep(delay)
		if (await hasOnChainUserPgpPublic(walletEoaLower)) return true
	}
	return false
}

/**
 * Before first gossip send: ensure sender has on-chain PGP via `regiestChatRoute`.
 * Align iOS `BeamioConetChatRouteRegister.ensureRegisteredForSenderGossip`.
 */
export async function ensureRegisteredForSenderGossip(walletPrivateKeyHex: string): Promise<boolean> {
	const pk = normalizePrivateKeyHex(walletPrivateKeyHex)
	if (!pk) return false
	const wallet = new Wallet(`0x${pk}`)
	const addrLower = wallet.address.toLowerCase()

	/* Already on AddressPGP → skip generate / re-register (protocol §3.1). */
	const presence = await readOwnUserPgpPresence(addrLower)
	if (presence === 'present') return true
	if (presence === 'error') {
		/* A failed read is not an empty record: never register (or make a new key) on it. */
		console.warn('[ensureRegisteredForSenderGossip] AddressPGP read failed; not registering')
		return false
	}

	/*
	 * Chain has no record. Register this terminal's saved key on its saved
	 * mailbox if it has one (chatOwnRoutePlan.ts); a new key and a random
	 * mailbox only for a terminal that never had them.
	 */
	const local = await loadPosChatPgp(addrLower).catch(() => null)
	let keys: Awaited<ReturnType<typeof generatePgpKeyPair>>
	if (local?.privateKeyArmored && local.publicKeyArmored && local.keyID) {
		keys = { privateKey: local.privateKeyArmored, publicKey: local.publicKeyArmored, keyID: local.keyID }
	} else {
		try {
			keys = await generatePgpKeyPair(wallet.address)
		} catch (ex) {
			console.warn('[ensureRegisteredForSenderGossip] PGP generate failed', ex)
			return false
		}
	}
	if (!keys.keyID) return false

	const current = local?.routerArmoredPublicKey
		? resolveCurrentMailbox(local.routerArmoredPublicKey, await fetchCoNETGossipNodes().catch(() => []), null)
		: { armor: '', mailbox: null }
	const plan = planOwnChatRoute({ read: { status: 'empty' }, localKeyID: keys.keyID, current: current.mailbox, currentArmor: current.armor })
	let routeKeyID: string
	if (plan.action === 'register' && plan.target !== 'random') {
		routeKeyID = plan.target.routeKeyID
	} else {
		// New mailbox only on a node AddressPGP has recorded; a failed check picks nothing.
		const pick = await pickRecordedMailbox({
			candidates: [...ROUTE_DOMAIN_HEX_POOL].sort(() => Math.random() - 0.5),
			routeKeyID: (id) => id,
			isRecorded: isMailboxNodeRecorded,
		})
		if (pick.skipped.length) console.warn('[ensureRegisteredForSenderGossip] skipped unrecorded mailbox nodes', pick.skipped.join(','))
		if (pick.status !== 'ok') {
			console.warn('[ensureRegisteredForSenderGossip] no recorded mailbox node', pick.status === 'error' ? pick.reason : 'none')
			return false
		}
		routeKeyID = pick.node
	}
	let ok = await regiestChatRoute({
		walletPrivateKeyHex: pk,
		publicKeyArmored: keys.publicKey,
		keyID: keys.keyID,
		secretKeyArmored: keys.privateKey,
		routeKeyID,
	})
	if (!ok) {
		await sleep(1000)
		ok = await regiestChatRoute({
			walletPrivateKeyHex: pk,
			publicKeyArmored: keys.publicKey,
			keyID: keys.keyID,
			secretKeyArmored: keys.privateKey,
			routeKeyID,
		})
	}
	if (!ok) return false

	/* Master returns ok before tx.wait — poll searchKey until visible. */
	const visible = await waitForOnChainUserPgpPublic(addrLower)
	if (visible) return true
	/* Final check: RPC lag after queue — one more probe before failing send. */
	await sleep(2500)
	return hasOnChainUserPgpPublic(addrLower)
}
