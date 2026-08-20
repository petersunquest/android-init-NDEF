import type { PosChatMessage, PosChatStoreSnapshot, PosChatThread } from '@/chat/posChatTypes'
import { normalizePosChatPartition, posChatPartitionKey } from '@/chat/posChatPartition'

const STORE_PREFIX = 'beamio_pos_chat_v2:'

function storeKey(terminalEoa: string, upperAdminEoa: string): string | null {
	const partition = normalizePosChatPartition(terminalEoa, upperAdminEoa)
	return partition ? `${STORE_PREFIX}${posChatPartitionKey(partition)}` : null
}

function emptySnapshot(): PosChatStoreSnapshot {
	return { version: 1, threads: [], updatedAt: Date.now() }
}

export function loadPosChatStore(walletEoa: string, upperAdminEoa: string): PosChatStoreSnapshot {
	const key = storeKey(walletEoa, upperAdminEoa)
	if (!key || typeof localStorage === 'undefined') return emptySnapshot()
	try {
		const raw = localStorage.getItem(key)
		if (!raw) return emptySnapshot()
		const parsed = JSON.parse(raw) as PosChatStoreSnapshot
		if (!parsed || parsed.version !== 1 || !Array.isArray(parsed.threads)) return emptySnapshot()
		return parsed
	} catch {
		return emptySnapshot()
	}
}

export function savePosChatStore(walletEoa: string, upperAdminEoa: string, snap: PosChatStoreSnapshot): void {
	const key = storeKey(walletEoa, upperAdminEoa)
	if (!key || typeof localStorage === 'undefined') return
	try {
		localStorage.setItem(
			key,
			JSON.stringify({ ...snap, updatedAt: Date.now() } satisfies PosChatStoreSnapshot),
		)
	} catch {
		/* quota */
	}
}

export function totalUnreadCount(snap: PosChatStoreSnapshot): number {
	return snap.threads.reduce((n, t) => n + Math.max(0, Number(t.unreadCount || 0)), 0)
}

export function upsertInboundMessage(
	snap: PosChatStoreSnapshot,
	msg: PosChatMessage,
	opts: { incrementUnread: boolean; peerTag?: string; peerName?: string },
): PosChatStoreSnapshot {
	const peer = msg.peerAddress.toLowerCase()
	const threads = [...snap.threads]
	const idx = threads.findIndex((t) => t.peerAddress.toLowerCase() === peer)
	const existing = idx >= 0 ? threads[idx]! : null
	const messages = existing ? [...existing.messages] : []
	if (msg.sendId && messages.some((m) => m.sendId === msg.sendId)) {
		return snap
	}
	if (messages.some((m) => m.id === msg.id)) return snap
	messages.push({ ...msg, status: msg.status ?? (msg.from === 'me' ? 'sent' : undefined) })
	messages.sort((a, b) => a.createdAt - b.createdAt)
	const unread = opts.incrementUnread
		? Math.max(0, Number(existing?.unreadCount || 0)) + 1
		: Math.max(0, Number(existing?.unreadCount || 0))
	const next: PosChatThread = {
		peerAddress: existing?.peerAddress ?? msg.peerAddress,
		peerTag: opts.peerTag ?? existing?.peerTag,
		peerName: opts.peerName ?? existing?.peerName,
		peerImage: existing?.peerImage,
		lastText: msg.text,
		lastAt: msg.createdAt,
		unreadCount: unread,
		messages,
	}
	if (idx >= 0) threads[idx] = next
	else threads.unshift(next)
	threads.sort((a, b) => b.lastAt - a.lastAt)
	return { version: 1, threads, updatedAt: Date.now() }
}

export function upsertOutboundMessage(
	snap: PosChatStoreSnapshot,
	msg: PosChatMessage,
	opts?: { peerTag?: string; peerName?: string },
): PosChatStoreSnapshot {
	return upsertInboundMessage(snap, msg, {
		incrementUnread: false,
		peerTag: opts?.peerTag,
		peerName: opts?.peerName,
	})
}

export function markThreadRead(snap: PosChatStoreSnapshot, peerAddress: string): PosChatStoreSnapshot {
	const peer = peerAddress.toLowerCase()
	const threads = snap.threads.map((t) =>
		t.peerAddress.toLowerCase() === peer ? { ...t, unreadCount: 0 } : t,
	)
	return { version: 1, threads, updatedAt: Date.now() }
}

export function markOutboundDeliveredBySendId(
	snap: PosChatStoreSnapshot,
	sendId: string,
): PosChatStoreSnapshot {
	if (!sendId) return snap
	let changed = false
	const threads = snap.threads.map((t) => {
		let touched = false
		const messages = t.messages.map((m) => {
			if (m.from !== 'me') return m
			const id = m.sendId || m.id
			if (id !== sendId || m.status === 'delivered') return m
			touched = true
			changed = true
			return { ...m, status: 'delivered' as const }
		})
		return touched ? { ...t, messages } : t
	})
	return changed ? { version: 1, threads, updatedAt: Date.now() } : snap
}

export function ensureThread(
	snap: PosChatStoreSnapshot,
	peerAddress: string,
	meta?: { peerTag?: string; peerName?: string },
): PosChatStoreSnapshot {
	const peer = peerAddress.toLowerCase()
	if (snap.threads.some((t) => t.peerAddress.toLowerCase() === peer)) {
		if (!meta) return snap
		return {
			version: 1,
			updatedAt: Date.now(),
			threads: snap.threads.map((t) =>
				t.peerAddress.toLowerCase() === peer
					? {
							...t,
							peerTag: meta.peerTag ?? t.peerTag,
							peerName: meta.peerName ?? t.peerName,
						}
					: t,
			),
		}
	}
	const thread: PosChatThread = {
		peerAddress,
		peerTag: meta?.peerTag,
		peerName: meta?.peerName,
		lastText: '',
		lastAt: Date.now(),
		unreadCount: 0,
		messages: [],
	}
	return { version: 1, threads: [thread, ...snap.threads], updatedAt: Date.now() }
}
