import { generateKey, readKey } from 'openpgp'
import { BEAMIO_API } from '@/constants'
import { ROUTE_DOMAIN_HEX_POOL } from '@/conet/constants'
import { aesGcmEncrypt, normalizePrivateKeyHex, randomPick, sleep, toBase64Utf8 } from '@/conet/crypto'
import { hasOnChainUserPgpPublic } from '@/conet/searchKey'
import { Wallet } from 'ethers'

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

/** bizSite `chat.ts` `regiestChatRoute`. */
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
	const encrypKeyArmored = await aesGcmEncrypt(params.secretKeyArmored, wallet.privateKey)
	try {
		const res = await fetch(`${BEAMIO_API}/api/regiestChatRoute`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				wallet: wallet.address,
				keyID: params.keyID,
				publicKeyArmored: toBase64Utf8(params.publicKeyArmored),
				encrypKeyArmored,
				routeKeyID: params.routeKeyID,
			}),
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
	if (await hasOnChainUserPgpPublic(addrLower)) {
		return true
	}

	let keys: Awaited<ReturnType<typeof generatePgpKeyPair>>
	try {
		keys = await generatePgpKeyPair(wallet.address)
	} catch (ex) {
		console.warn('[ensureRegisteredForSenderGossip] PGP generate failed', ex)
		return false
	}
	if (!keys.keyID) return false

	const routeKeyID = randomPick(ROUTE_DOMAIN_HEX_POOL)
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
