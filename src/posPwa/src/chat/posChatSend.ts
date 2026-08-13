import { createMessage, encrypt, enums, readKey } from 'openpgp'
import { Wallet } from 'ethers'
import { fetchRecipientPublicArmored } from '@/conet/searchKey'
import { fetchCoNETGossipNodes, pickGossipNodes } from '@/conet/guardianNodes'
import { normalizePrivateKeyHex, utf8ToBase64 } from '@/conet/crypto'

async function postWithTimeout(url: string, init: RequestInit, timeoutMs = 12_000) {
	const ctrl = new AbortController()
	const t = setTimeout(() => ctrl.abort(), timeoutMs)
	try {
		return await fetch(url, { ...init, signal: ctrl.signal })
	} finally {
		clearTimeout(t)
	}
}

/**
 * Send a plain text chat message via CoNET gossip (encrypt to recipient EOA PGP, POST entry A).
 * Aligns SilentPassUI / Alliance `sendMessage` envelope.
 */
export async function sendPosChatTextMessage(params: {
	recipientEoa: string
	text: string
	walletPrivateKeyHex: string
	sendId?: string
}): Promise<{ ok: boolean; sendId: string; createdAt: number }> {
	const pk = normalizePrivateKeyHex(params.walletPrivateKeyHex)
	const text = params.text.trim()
	const sendId = params.sendId || `pos-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`
	const createdAt = Date.now()
	if (!pk || !text) return { ok: false, sendId, createdAt }

	const armoredPub = await fetchRecipientPublicArmored(params.recipientEoa)
	if (!armoredPub) {
		console.warn('[sendPosChatTextMessage] recipient has no PGP')
		return { ok: false, sendId, createdAt }
	}

	const nodes = await fetchCoNETGossipNodes()
	if (!nodes.length) return { ok: false, sendId, createdAt }

	const wallet = new Wallet(`0x${pk}`)
	const pendingLine = JSON.stringify({
		sendId,
		from: 'me',
		text,
		createdAt,
	})
	const signMessage = await wallet.signMessage(pendingLine)
	const envelope = {
		timestamp: createdAt,
		text: pendingLine,
		from: wallet.address,
		signMessage,
	}

	let postData: string
	try {
		const encryptObj = {
			message: await createMessage({ text: utf8ToBase64(JSON.stringify(envelope)) }),
			encryptionKeys: await readKey({ armoredKey: armoredPub }),
			config: { preferredCompressionAlgorithm: enums.compression.zlib },
		}
		postData = await encrypt(encryptObj)
	} catch (ex) {
		console.warn('[sendPosChatTextMessage] encrypt', ex)
		return { ok: false, sendId, createdAt }
	}

	const wave = pickGossipNodes(nodes, Math.min(4, nodes.length))
	const results = await Promise.all(
		wave.map(async (node) => {
			const url = `https://${node.domain}.conet.network/post`
			try {
				const res = await postWithTimeout(url, {
					method: 'POST',
					headers: { 'Content-Type': 'application/json' },
					body: JSON.stringify({ data: postData }),
					referrerPolicy: 'no-referrer',
				})
				return res.ok
			} catch {
				return false
			}
		}),
	)
	return { ok: results.some(Boolean), sendId, createdAt }
}
