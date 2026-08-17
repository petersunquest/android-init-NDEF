/**
 * CoNET Chat delivery receipts (POS copy — no Buffer, no SilentPassUI import).
 * 1) Mailbox ACK — encrypt to mailbox B route PGP (`gossip_delivery_ack`)
 * 2) Sender receipt — encrypt to sender user PGP (`beamio_chat_delivery_receipt_v1`)
 */
import { Wallet } from 'ethers'
import { encryptRouteCommand } from '@/vendor/beamio-chat-sdk/envelope'
import { fetchRecipientChatKeys } from '@/conet/searchKey'
import { normalizePrivateKeyHex } from '@/conet/crypto'
import { postArmoredGossipToEntries } from '@/chat/posChatGossipPost'
import { sendPosChatPendingLine } from '@/chat/posChatSend'
import {
	getPosChatListenContext,
	isWorkerGossipActive,
	postWorkerMailboxCommand,
} from '@/chat/posChatWorkerBridge'

export const BEAMIO_CHAT_DELIVERY_RECEIPT_V1 = 'beamio_chat_delivery_receipt_v1' as const

export type ChatDeliveryReceiptV1 = {
	type: typeof BEAMIO_CHAT_DELIVERY_RECEIPT_V1
	sendId: string
	armorHash?: string
	deliveredAt: number
	from: string
}

const ackedArmorHashes = new Set<string>()
const receiptedSendIds = new Set<string>()

export function parseChatDeliveryReceiptV1(displayText: unknown): ChatDeliveryReceiptV1 | null {
	let cur: unknown = displayText
	for (let i = 0; i < 6; i++) {
		if (typeof cur === 'string') {
			const t = cur.trim()
			if (!t) return null
			try {
				cur = JSON.parse(t)
			} catch {
				return null
			}
			continue
		}
		if (!cur || typeof cur !== 'object') return null
		const o = cur as Record<string, unknown>
		if (o.type === BEAMIO_CHAT_DELIVERY_RECEIPT_V1 && typeof o.sendId === 'string' && o.sendId) {
			const from = typeof o.from === 'string' ? o.from : ''
			const deliveredAt = Number(o.deliveredAt)
			return {
				type: BEAMIO_CHAT_DELIVERY_RECEIPT_V1,
				sendId: String(o.sendId),
				armorHash: typeof o.armorHash === 'string' ? o.armorHash : undefined,
				deliveredAt: Number.isFinite(deliveredAt) ? deliveredAt : Math.floor(Date.now() / 1000),
				from,
			}
		}
		if (typeof o.text === 'string') {
			cur = o.text
			continue
		}
		return null
	}
	return null
}

export function extractInboundArmorHash(line: string): string {
	try {
		const obj = JSON.parse(line) as { _beamioPgpArmorHash?: unknown }
		const h = typeof obj._beamioPgpArmorHash === 'string' ? obj._beamioPgpArmorHash.trim().toLowerCase() : ''
		return /^0x[0-9a-f]{64}$/.test(h) ? h : ''
	} catch {
		return ''
	}
}

export async function postMailboxDeliveryAck(params: {
	armorHash: string
	sendId?: string | null
	walletPrivateKeyHex: string
}): Promise<boolean> {
	const hash = (params.armorHash || '').trim().toLowerCase()
	if (!/^0x[0-9a-f]{64}$/.test(hash)) return false
	if (ackedArmorHashes.has(hash)) return true
	const pk = normalizePrivateKeyHex(params.walletPrivateKeyHex)
	const ctx = getPosChatListenContext()
	if (!pk || !ctx?.routerArmoredPublicKey) return false

	const wallet = new Wallet(`0x${pk}`)
	const timestamp = Math.floor(Date.now() / 1000)
	const command: Record<string, unknown> = {
		command: 'gossip_delivery_ack',
		walletAddress: wallet.address,
		armorHash: hash,
		timestamp,
	}
	if (params.sendId) command.sendId = params.sendId

	let ok = false
	if (isWorkerGossipActive()) {
		ok = await postWorkerMailboxCommand(ctx.routerArmoredPublicKey, command)
	}
	if (!ok) {
		try {
			const innerArmor = await encryptRouteCommand(wallet, command, ctx.routerArmoredPublicKey)
			ok = await postArmoredGossipToEntries({
				innerArmor,
				mailboxRoutePublicArmored: ctx.routerArmoredPublicKey,
				noPush: false,
			})
		} catch (ex) {
			console.warn('[POS Chat] mailbox ACK', (ex as Error)?.message ?? ex)
			ok = false
		}
	}
	if (ok) ackedArmorHashes.add(hash)
	return ok
}

export async function sendDeliveryReceiptToSender(params: {
	senderEoa: string
	sendId: string
	armorHash?: string
	walletPrivateKeyHex: string
}): Promise<boolean> {
	if (!params.sendId || receiptedSendIds.has(params.sendId)) return true
	const pk = normalizePrivateKeyHex(params.walletPrivateKeyHex)
	if (!pk) return false
	const keys = await fetchRecipientChatKeys(params.senderEoa)
	if (!keys?.userPublicArmored || !keys.mailboxRoutePublicArmored) {
		console.warn('[POS Chat] skip sender receipt: missing sender PGP or mailbox key')
		return false
	}
	const wallet = new Wallet(`0x${pk}`)
	const inner: ChatDeliveryReceiptV1 = {
		type: BEAMIO_CHAT_DELIVERY_RECEIPT_V1,
		sendId: params.sendId,
		deliveredAt: Math.floor(Date.now() / 1000),
		from: wallet.address,
	}
	if (params.armorHash) inner.armorHash = params.armorHash
	const receiptSendId =
		typeof crypto !== 'undefined' && crypto.randomUUID
			? crypto.randomUUID()
			: `rcpt_${Date.now()}_${Math.random().toString(36).slice(2)}`
	const pendingLine = JSON.stringify({
		sendId: receiptSendId,
		from: 'me',
		text: JSON.stringify(inner),
		createdAt: Date.now(),
	})
	const r = await sendPosChatPendingLine({
		recipientEoa: params.senderEoa,
		pendingLine,
		walletPrivateKeyHex: params.walletPrivateKeyHex,
		sendId: receiptSendId,
		noPush: true,
	})
	if (r.ok) receiptedSendIds.add(params.sendId)
	return r.ok
}

export async function emitDualChatDeliveryReceipts(params: {
	armorHash?: string
	sendId?: string | null
	senderEoa?: string | null
	walletPrivateKeyHex: string
}): Promise<void> {
	const hash = (params.armorHash || '').trim().toLowerCase()
	const tasks: Promise<boolean>[] = []
	if (hash) {
		const runMailbox = async (): Promise<boolean> => {
			let ok = await postMailboxDeliveryAck({
				armorHash: hash,
				sendId: params.sendId,
				walletPrivateKeyHex: params.walletPrivateKeyHex,
			})
			if (!ok) {
				await new Promise((r) => setTimeout(r, 1500))
				ok = await postMailboxDeliveryAck({
					armorHash: hash,
					sendId: params.sendId,
					walletPrivateKeyHex: params.walletPrivateKeyHex,
				})
			}
			if (!ok) console.warn('[POS Chat] mailbox ACK failed', hash.slice(0, 12))
			return ok
		}
		tasks.push(runMailbox())
	}
	if (params.sendId && params.senderEoa) {
		tasks.push(
			sendDeliveryReceiptToSender({
				senderEoa: params.senderEoa,
				sendId: params.sendId,
				armorHash: hash || undefined,
				walletPrivateKeyHex: params.walletPrivateKeyHex,
			}),
		)
	}
	if (tasks.length) await Promise.allSettled(tasks)
}
