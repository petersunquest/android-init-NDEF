import type { HistoryBufferEvent, HistoryEntry } from '@/vendor/beamio-chat-sdk/types'
import { isPosTerminalPermissionChatPayload } from '@/chat/posChatInbound'
import { parseChatDeliveryReceiptV1 } from '@/chat/posChatDeliveryReceipt'
import { appendWorkerHistory } from '@/chat/posChatWorkerBridge'
import {
	ensureThread,
	upsertInboundMessage,
	upsertOutboundMessage,
} from '@/chat/posChatStore'
import type { PosChatMessage, PosChatStoreSnapshot } from '@/chat/posChatTypes'

function messageDedupKey(m: PosChatMessage): string {
	return (
		(m.sendId && String(m.sendId)) ||
		(m.id && !m.id.startsWith('tmp_') ? String(m.id) : '') ||
		(m.createdAt != null ? String(m.createdAt) : '')
	)
}

function isExcludedHistoryText(text: string): boolean {
	if (!text) return true
	if (isPosTerminalPermissionChatPayload(text)) return true
	if (parseChatDeliveryReceiptV1(text)) return true
	return false
}

export function mirrorPosChatMessageToHistory(
	peerEoa: string | undefined,
	msg: PosChatMessage | undefined,
	dir: 'in' | 'out',
): void {
	const peer = (peerEoa || '').toLowerCase()
	if (!peer || !msg) return
	if (isExcludedHistoryText(msg.text)) return
	let body = ''
	try {
		body = JSON.stringify(msg)
	} catch {
		return
	}
	if (!body) return
	void appendWorkerHistory({
		peer,
		dir,
		ts: Number.isFinite(msg.createdAt) ? msg.createdAt : Date.now(),
		sendId: msg.sendId,
		body,
	})
}

function parseHistoryMessage(entry: HistoryEntry): PosChatMessage | null {
	if (!entry?.body) return null
	let parsed: PosChatMessage | null = null
	try {
		parsed = JSON.parse(entry.body) as PosChatMessage
	} catch {
		return null
	}
	if (!parsed || typeof parsed !== 'object') return null
	if (isExcludedHistoryText(String(parsed.text || ''))) return null
	if (parsed.from !== 'me' && parsed.from !== 'them') {
		parsed.from = entry.dir === 'out' ? 'me' : 'them'
	}
	if (parsed.createdAt == null && Number.isFinite(entry.ts)) parsed.createdAt = entry.ts
	if (!parsed.id) parsed.id = String(parsed.createdAt ?? entry.ts ?? Date.now())
	if (!parsed.peerAddress) parsed.peerAddress = entry.peer
	if (parsed.status == null) parsed.status = 'sent'
	return parsed
}

/** Recover must create missing threads. Never treat empty local chats as "no history". */
export function mergeHistoryBatchIntoStore(
	snap: PosChatStoreSnapshot,
	batch: HistoryBufferEvent,
	selfEoaLower: string,
): PosChatStoreSnapshot {
	const entries = Array.isArray(batch?.entries) ? batch.entries : []
	if (!entries.length) return snap

	const byPeer = new Map<string, HistoryEntry[]>()
	for (const entry of entries) {
		const peer = String(entry.peer || '').toLowerCase()
		if (!peer || peer === selfEoaLower) continue
		const list = byPeer.get(peer) ?? []
		list.push(entry)
		byPeer.set(peer, list)
	}

	let next = snap
	for (const [peer, peerEntries] of byPeer) {
		next = ensureThread(next, peer)
		const thread = next.threads.find((t) => t.peerAddress.toLowerCase() === peer)
		const seen = new Set<string>()
		for (const m of thread?.messages ?? []) {
			const key = messageDedupKey(m)
			if (key) seen.add(key)
		}
		for (const entry of peerEntries) {
			const msg = parseHistoryMessage(entry)
			if (!msg) continue
			const key = messageDedupKey(msg)
			if (!key || seen.has(key)) continue
			seen.add(key)
			next =
				msg.from === 'me'
					? upsertOutboundMessage(next, { ...msg, peerAddress: peer })
					: upsertInboundMessage(next, { ...msg, peerAddress: peer }, { incrementUnread: false })
		}
	}
	return next
}
