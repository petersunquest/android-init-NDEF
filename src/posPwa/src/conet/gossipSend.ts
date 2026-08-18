import { createMessage, encrypt, enums, readKey } from 'openpgp'
import { Wallet } from 'ethers'
import { POS_TERMINAL_PERMISSION_TYPE } from '@/conet/constants'
import { normalizePrivateKeyHex, toBase64Utf8 } from '@/conet/crypto'
import { fetchRecipientChatKeys } from '@/conet/searchKey'
import { postArmoredGossipToEntries } from '@/chat/posChatGossipPost'

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

/**
 * Encrypt + POST POS terminal permission via CoNET gossip.
 * Onboarding runs before chat Worker init — main-thread user-PGP to entry A ≠ B
 * (probe-aligned; do not mailbox-wrap the routed packet).
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

	const keys = await fetchRecipientChatKeys(params.recipientEoa)
	if (!keys?.userPublicArmored) return false

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

	let innerArmor: string
	try {
		innerArmor = await encrypt({
			message: await createMessage({ text: toBase64Utf8(JSON.stringify(envelope)) }),
			encryptionKeys: await readKey({ armoredKey: keys.userPublicArmored }),
			config: { preferredCompressionAlgorithm: enums.compression.zlib },
		})
	} catch {
		return false
	}

	return postArmoredGossipToEntries({
		innerArmor,
		mailboxRoutePublicArmored: keys.mailboxRoutePublicArmored,
		noPush: false,
	})
}
