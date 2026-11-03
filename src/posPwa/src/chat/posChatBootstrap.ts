import { generateKey, readKey } from 'openpgp'
import { Wallet } from 'ethers'
import { fetchAddressPgpKeys } from '@/conet/addressPgpKeys'
import { ensureRegisteredForSenderGossip } from '@/conet/chatRouteRegister'
import { fetchCoNETGossipNodes, pickGossipNodes, type GossipNodeInfo } from '@/conet/guardianNodes'
import { pickRecordedMailbox } from '@/conet/chatOwnRoutePlan'
import { isMailboxNodeRecorded } from '@/conet/searchKey'
import { normalizePrivateKeyHex } from '@/conet/crypto'
import { loadPosChatPgp, savePosChatPgp, type PosChatPgpBundle } from '@/chat/posChatPgp'
import { startPosChatGossipListen, stopPosChatGossipListen } from '@/chat/posChatGossipListen'
import { regiestChatRoute } from '@/conet/chatRouteRegister'

type GenerateKeyArg = Parameters<typeof generateKey>[0]

/** A new mailbox: only a node AddressPGP has recorded; a failed check picks nothing. */
async function pickNewMailboxNode(nodes: GossipNodeInfo[]): Promise<{ node: GossipNodeInfo } | { error: string }> {
	if (!nodes.length) return { error: 'No CoNET nodes' }
	const pick = await pickRecordedMailbox({
		candidates: pickGossipNodes(nodes, 8),
		routeKeyID: (n) => n.domain,
		isRecorded: isMailboxNodeRecorded,
	})
	if (pick.skipped.length) console.warn('[posChatBootstrap] skipped unrecorded mailbox nodes', pick.skipped.join(','))
	if (pick.status === 'error') return { error: 'Could not check CoNET mailbox nodes. Try again.' }
	if (pick.status === 'none') return { error: 'No CoNET mailbox node available. Try again.' }
	return { node: pick.node }
}

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
	historyUpperAdminEoa: string
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

	// `chain === null` means the AddressPGP read failed (ensureRegistered… just
	// confirmed a record exists). A failed read never makes a new key or picks a
	// new mailbox: that would overwrite the key and move the mailbox on chain.
	if ((!privateKey || !publicKey || !router) && !chain) {
		return { ok: false, error: 'Could not read chat keys from CoNET. Try again.' }
	}

	if (!privateKey || !publicKey) {
		try {
			// Read worked but the chain key cannot be loaded (no blob, or not ours to open):
			// new key, registered on the mailbox the account already has.
			const keys = await generatePgpKeyPair(wallet.address)
			privateKey = keys.privateKey
			publicKey = keys.publicKey
			keyID = keys.keyID
			let routeKeyID = chain?.routePgpKeyID && chain.routersArmoreds ? chain.routePgpKeyID : ''
			let routeArmor = routeKeyID ? chain!.routersArmoreds : ''
			if (!routeKeyID) {
				const picked = await pickNewMailboxNode(await fetchCoNETGossipNodes())
				if ('error' in picked) return { ok: false, error: picked.error }
				const node = picked.node
				routeKeyID = node.domain
				routeArmor = node.armoredPublicKey
			}
			const ok = await regiestChatRoute({
				walletPrivateKeyHex: params.walletPrivateKeyHex,
				publicKeyArmored: publicKey,
				keyID,
				secretKeyArmored: privateKey,
				routeKeyID,
			})
			if (!ok) return { ok: false, error: 'Failed to register chat route' }
			router = routeArmor
		} catch (ex) {
			return {
				ok: false,
				error: ex instanceof Error ? ex.message : 'PGP setup failed',
			}
		}
	}

	if (!router) {
		// Read worked: neither the chain nor this terminal has a mailbox yet.
		const picked = await pickNewMailboxNode(await fetchCoNETGossipNodes())
		if ('error' in picked) return { ok: false, error: picked.error }
		const node = picked.node
		if (privateKey && publicKey && keyID) {
			const registered = await regiestChatRoute({
				walletPrivateKeyHex: params.walletPrivateKeyHex,
				publicKeyArmored: publicKey,
				keyID,
				secretKeyArmored: privateKey,
				routeKeyID: node.domain,
			})
			// Listen only on a mailbox the chain holds: a failed registration leaves none.
			if (registered) router = node.armoredPublicKey
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
		historyUpperAdminEoa: params.historyUpperAdminEoa,
		onLine: params.onLine,
	})
	if (!started) {
		return { ok: false, error: 'Gossip listen failed to start', bundle }
	}
	return { ok: true, bundle }
}

export { stopPosChatGossipListen }
