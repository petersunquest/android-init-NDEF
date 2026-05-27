import { createMessage, encrypt, enums, readKey } from 'openpgp'
import { Wallet } from 'ethers'
import { GOSSIP_POST_DOMAIN_HEX_IDS, POS_TERMINAL_PERMISSION_TYPE } from '@/conet/constants'
import { normalizePrivateKeyHex, shuffleTake, toBase64Utf8 } from '@/conet/crypto'
import { fetchRecipientPublicArmored } from '@/conet/searchKey'

export interface TerminalPermissionInner {
	type: typeof POS_TERMINAL_PERMISSION_TYPE
	sendId: string
	createdAt: number
	childEoa: string
	childBeamioTag: string
	parentBeamioTag: string
}

function jsonTerminalPermissionInner(params: {
	sendId: string
	createdAt: number
	childEoa: string
	childBeamioTag: string
	parentBeamioTag: string
}): string {
	const inner: TerminalPermissionInner = {
		type: POS_TERMINAL_PERMISSION_TYPE,
		sendId: params.sendId,
		createdAt: params.createdAt,
		childEoa: params.childEoa.toLowerCase(),
		childBeamioTag: params.childBeamioTag,
		parentBeamioTag: params.parentBeamioTag,
	}
	return JSON.stringify(inner)
}

/** SilentPassUI pending row — signed by EIP-191 personal_sign. */
function jsonChatOuterLine(params: {
	sendId: string
	createdAt: number
	innerText: string
}): string {
	return JSON.stringify({
		sendId: params.sendId,
		from: 'me',
		text: params.innerText,
		createdAt: params.createdAt,
	})
}

async function postGossipPayload(domainHex: string, armored: string): Promise<boolean> {
	const url = `https://${domainHex.toLowerCase()}.conet.network/post`
	try {
		const res = await fetch(url, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ data: armored }),
			signal: AbortSignal.timeout(12_000),
		})
		return res.ok
	} catch {
		return false
	}
}

/**
 * Encrypt + POST POS terminal permission request via CoNET gossip.
 * Align bizSite `chat.ts` `sendMessage` + iOS `BeamioConetGossipSend.sendTerminalPermissionRequest`.
 */
export async function sendTerminalPermissionRequest(params: {
	recipientEoa: string
	childEoa: string
	childBeamioTag: string
	parentBeamioTag: string
	walletPrivateKeyHex: string
}): Promise<boolean> {
	const pk = normalizePrivateKeyHex(params.walletPrivateKeyHex)
	if (!pk) return false

	const armoredPub = await fetchRecipientPublicArmored(params.recipientEoa)
	if (!armoredPub) return false

	const wallet = new Wallet(`0x${pk}`)
	const sendId = crypto.randomUUID().toLowerCase()
	const createdAt = Date.now()
	const innerText = jsonTerminalPermissionInner({
		sendId,
		createdAt,
		childEoa: params.childEoa,
		childBeamioTag: params.childBeamioTag,
		parentBeamioTag: params.parentBeamioTag,
	})
	const outerLine = jsonChatOuterLine({ sendId, createdAt, innerText })
	const signMessage = await wallet.signMessage(outerLine)

	const envelope = {
		timestamp: Date.now(),
		text: outerLine,
		from: wallet.address.toLowerCase(),
		signMessage,
	}
	const envelopeB64 = toBase64Utf8(JSON.stringify(envelope))

	let postData: string
	try {
		postData = await encrypt({
			message: await createMessage({ text: envelopeB64 }),
			encryptionKeys: await readKey({ armoredKey: armoredPub }),
			config: { preferredCompressionAlgorithm: enums.compression.zlib },
		})
	} catch {
		return false
	}

	const domains = shuffleTake(GOSSIP_POST_DOMAIN_HEX_IDS, 6)
	const results = await Promise.all(domains.map((d) => postGossipPayload(d, postData)))
	return results.some(Boolean)
}
