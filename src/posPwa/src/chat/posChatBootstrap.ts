import { generateKey, readKey } from 'openpgp'
import { Wallet } from 'ethers'
import { fetchAddressPgpKeys } from '@/conet/addressPgpKeys'
import { ensureRegisteredForSenderGossip } from '@/conet/chatRouteRegister'
import { fetchCoNETGossipNodes, getRandomGossipNode } from '@/conet/guardianNodes'
import { normalizePrivateKeyHex } from '@/conet/crypto'
import { loadPosChatPgp, savePosChatPgp, type PosChatPgpBundle } from '@/chat/posChatPgp'
import { startPosChatGossipListen, stopPosChatGossipListen } from '@/chat/posChatGossipListen'
import { regiestChatRoute } from '@/conet/chatRouteRegister'

type GenerateKeyArg = Parameters<typeof generateKey>[0]

async function generatePgpKeyPair(walletAddress: string) {
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
 * Ensure local PGP + on-chain registration + route key, then start gossip listen.
 */
export async function bootstrapPosChatSession(params: {
	walletPrivateKeyHex: string
	onLine: (line: string) => void
}): Promise<{ ok: boolean; bundle?: PosChatPgpBundle; error?: string }> {
	const pk = normalizePrivateKeyHex(params.walletPrivateKeyHex)
	if (!pk) return { ok: false, error: 'Invalid wallet key' }
	const wallet = new Wallet(`0x${pk}`)
	const eoaLower = wallet.address.toLowerCase()

	const registered = await ensureRegisteredForSenderGossip(params.walletPrivateKeyHex)
	if (!registered) {
		return { ok: false, error: 'Chat key registration failed' }
	}

	let local = await loadPosChatPgp(eoaLower)
	const chain = await fetchAddressPgpKeys(params.walletPrivateKeyHex)

	let privateKey = local?.privateKeyArmored || chain?.privateArmored || ''
	let publicKey = local?.publicKeyArmored || chain?.publicArmored || ''
	let keyID = local?.keyID || chain?.userPgpKeyID || ''
	let router = local?.routerArmoredPublicKey || chain?.routersArmoreds || ''

	if (!privateKey || !publicKey) {
		try {
			const keys = await generatePgpKeyPair(wallet.address)
			privateKey = keys.privateKey
			publicKey = keys.publicKey
			keyID = keys.keyID
			const nodes = await fetchCoNETGossipNodes()
			const node = getRandomGossipNode(nodes)
			if (!node) return { ok: false, error: 'No CoNET nodes' }
			const ok = await regiestChatRoute({
				walletPrivateKeyHex: params.walletPrivateKeyHex,
				publicKeyArmored: publicKey,
				keyID,
				secretKeyArmored: privateKey,
				routeKeyID: node.domain,
			})
			if (!ok) return { ok: false, error: 'Failed to register chat route' }
			router = node.armoredPublicKey
		} catch (ex) {
			return {
				ok: false,
				error: ex instanceof Error ? ex.message : 'PGP setup failed',
			}
		}
	}

	if (!router) {
		const nodes = await fetchCoNETGossipNodes()
		const node = getRandomGossipNode(nodes)
		if (node && privateKey && publicKey && keyID) {
			await regiestChatRoute({
				walletPrivateKeyHex: params.walletPrivateKeyHex,
				publicKeyArmored: publicKey,
				keyID,
				secretKeyArmored: privateKey,
				routeKeyID: node.domain,
			})
			router = node.armoredPublicKey
		}
	}

	if (!router || !privateKey) {
		return { ok: false, error: 'Missing mailbox route or PGP private key' }
	}

	const bundle: PosChatPgpBundle = {
		eoaLower,
		privateKeyArmored: privateKey,
		publicKeyArmored: publicKey,
		keyID,
		routerArmoredPublicKey: router,
		updatedAt: Date.now(),
	}
	await savePosChatPgp(bundle)

	const started = await startPosChatGossipListen({
		routerArmoredPublicKey: router,
		walletPrivateKeyHex: params.walletPrivateKeyHex,
		pgpPrivateKeyArmored: privateKey,
		pgpPublicKeyArmored: publicKey,
		onLine: params.onLine,
	})
	if (!started) {
		return { ok: false, error: 'Gossip listen failed to start', bundle }
	}
	return { ok: true, bundle }
}

export { stopPosChatGossipListen }
