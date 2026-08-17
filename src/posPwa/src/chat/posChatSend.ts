import { createMessage, encrypt, enums, readKey } from 'openpgp'
import { Wallet } from 'ethers'
import { fetchRecipientChatKeys } from '@/conet/searchKey'
import { normalizePrivateKeyHex, utf8ToBase64 } from '@/conet/crypto'
import { postArmoredGossipToEntries } from '@/chat/posChatGossipPost'
import { isWorkerGossipActive, sendWorkerChatPayload } from '@/chat/posChatWorkerBridge'

/**
 * Send a signed pending-line JSON via CoNET gossip.
 * Worker path when listen is up; otherwise main-thread mailbox wrap + live entries.
 */
export async function sendPosChatPendingLine(params: {
	recipientEoa: string
	pendingLine: string
	walletPrivateKeyHex: string
	sendId?: string
	noPush?: boolean
}): Promise<{ ok: boolean; sendId: string; createdAt: number }> {
	const pk = normalizePrivateKeyHex(params.walletPrivateKeyHex)
	const createdAt = Date.now()
	const sendId = params.sendId || `pos-${createdAt}-${Math.random().toString(36).slice(2, 10)}`
	if (!pk || !params.pendingLine.trim()) return { ok: false, sendId, createdAt }

	const keys = await fetchRecipientChatKeys(params.recipientEoa)
	if (!keys?.userPublicArmored) {
		console.warn('[sendPosChatPendingLine] recipient has no PGP')
		return { ok: false, sendId, createdAt }
	}

	const noPush = params.noPush !== false
	if (isWorkerGossipActive()) {
		const r = await sendWorkerChatPayload(
			{
				address: params.recipientEoa.toLowerCase(),
				userPublicKeyArmored: keys.userPublicArmored,
				routerArmoredPublicKey: keys.mailboxRoutePublicArmored || undefined,
			},
			params.pendingLine,
			{ sendId, beamioNoPush: noPush && !!keys.mailboxRoutePublicArmored },
		)
		return { ok: r.ok, sendId: r.sendId, createdAt }
	}

	const wallet = new Wallet(`0x${pk}`)
	const signMessage = await wallet.signMessage(params.pendingLine)
	const envelope = {
		timestamp: createdAt,
		text: params.pendingLine,
		from: wallet.address,
		signMessage,
	}

	let innerArmor: string
	try {
		innerArmor = await encrypt({
			message: await createMessage({ text: utf8ToBase64(JSON.stringify(envelope)) }),
			encryptionKeys: await readKey({ armoredKey: keys.userPublicArmored }),
			config: { preferredCompressionAlgorithm: enums.compression.zlib },
		})
	} catch (ex) {
		console.warn('[sendPosChatPendingLine] encrypt', ex)
		return { ok: false, sendId, createdAt }
	}

	const ok = await postArmoredGossipToEntries({
		innerArmor,
		mailboxRoutePublicArmored: keys.mailboxRoutePublicArmored,
		noPush,
	})
	return { ok, sendId, createdAt }
}

export async function sendPosChatTextMessage(params: {
	recipientEoa: string
	text: string
	walletPrivateKeyHex: string
	sendId?: string
}): Promise<{ ok: boolean; sendId: string; createdAt: number }> {
	const text = params.text.trim()
	const createdAt = Date.now()
	const sendId = params.sendId || `pos-${createdAt}-${Math.random().toString(36).slice(2, 10)}`
	if (!text) return { ok: false, sendId, createdAt }
	const pendingLine = JSON.stringify({
		sendId,
		from: 'me',
		text,
		createdAt,
	})
	return sendPosChatPendingLine({
		recipientEoa: params.recipientEoa,
		pendingLine,
		walletPrivateKeyHex: params.walletPrivateKeyHex,
		sendId,
		noPush: true,
	})
}
