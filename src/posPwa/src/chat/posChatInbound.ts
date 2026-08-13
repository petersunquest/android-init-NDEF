import { POS_TERMINAL_PERMISSION_TYPE } from '@/conet/constants'
import type { PosChatMessage } from '@/chat/posChatTypes'

function tryParseJson(raw: string): unknown {
	try {
		return JSON.parse(raw)
	} catch {
		return null
	}
}

/** Walk nested `text` fields (CoNET chat envelopes). */
function unwrapTextLayers(raw: string, maxDepth = 8): unknown {
	let cur: unknown = tryParseJson(raw) ?? raw
	for (let i = 0; i < maxDepth; i++) {
		if (typeof cur === 'string') {
			const next = tryParseJson(cur)
			if (next == null) break
			cur = next
			continue
		}
		if (cur && typeof cur === 'object' && 'text' in cur) {
			const t = (cur as { text?: unknown }).text
			if (typeof t === 'string') {
				const next = tryParseJson(t)
				cur = next ?? t
				continue
			}
		}
		break
	}
	return cur
}

function isPosTerminalPermissionPayload(v: unknown): boolean {
	if (!v || typeof v !== 'object') return false
	const type = String((v as { type?: unknown }).type ?? '')
	return type === POS_TERMINAL_PERMISSION_TYPE
}

export function isPosTerminalPermissionChatPayload(displayText: string): boolean {
	const unwrapped = unwrapTextLayers(displayText)
	if (isPosTerminalPermissionPayload(unwrapped)) return true
	if (unwrapped && typeof unwrapped === 'object' && 'text' in unwrapped) {
		const inner = unwrapTextLayers(String((unwrapped as { text?: unknown }).text ?? ''))
		return isPosTerminalPermissionPayload(inner)
	}
	return false
}

export type ParsedInboundChat = {
	fromAddress: string
	text: string
	sendId?: string
	createdAt: number
	signMessage?: string
}

/**
 * Parse decrypted gossip line into a chat bubble.
 * Returns null for mining heartbeats, delivery receipts, POS permission, or invalid.
 */
export function parseInboundChatLine(line: string): ParsedInboundChat | null {
	const root = tryParseJson(line)
	if (!root || typeof root !== 'object') return null

	const obj = root as Record<string, unknown>
	// Mining / liveness heartbeat
	if ('epoch' in obj && ('nodeWallets' in obj || 'status' in obj)) return null
	if (obj.status != null && obj.epoch != null) return null

	const from = String(obj.from ?? '').trim()
	if (!/^0x[0-9a-fA-F]{40}$/.test(from)) return null

	const textRaw = obj.text
	if (textRaw == null) return null
	const textStr = typeof textRaw === 'string' ? textRaw : JSON.stringify(textRaw)

	if (isPosTerminalPermissionChatPayload(textStr)) return null

	const unwrapped = unwrapTextLayers(textStr)
	if (isPosTerminalPermissionPayload(unwrapped)) return null

	let displayText = textStr
	let sendId: string | undefined
	let createdAt = Number(obj.timestamp ?? obj.createdAt ?? Date.now())

	if (unwrapped && typeof unwrapped === 'object') {
		const u = unwrapped as Record<string, unknown>
		if (typeof u.text === 'string' && !isPosTerminalPermissionPayload(u)) {
			displayText = u.text
		} else if (typeof u.sendId === 'string' && typeof u.text === 'string') {
			displayText = u.text
			sendId = u.sendId
			if (typeof u.createdAt === 'number') createdAt = u.createdAt
		}
		if (typeof u.sendId === 'string') sendId = u.sendId
	}

	// Nested pending row: { sendId, from:'me', text }
	const mid = tryParseJson(textStr)
	if (mid && typeof mid === 'object') {
		const m = mid as Record<string, unknown>
		if (typeof m.sendId === 'string') sendId = m.sendId
		if (typeof m.createdAt === 'number') createdAt = m.createdAt
		if (typeof m.text === 'string') {
			const inner = tryParseJson(m.text)
			if (isPosTerminalPermissionPayload(inner)) return null
			if (typeof inner === 'object' && inner && 'type' in inner) {
				if (isPosTerminalPermissionPayload(inner)) return null
				displayText = m.text
			} else {
				displayText = m.text
			}
		}
	}

	displayText = String(displayText).trim()
	if (!displayText) return null

	return {
		fromAddress: from,
		text: displayText,
		sendId,
		createdAt: Number.isFinite(createdAt) ? createdAt : Date.now(),
		signMessage: typeof obj.signMessage === 'string' ? obj.signMessage : undefined,
	}
}

export function inboundToPosChatMessage(
	parsed: ParsedInboundChat,
	selfEoaLower: string,
): PosChatMessage | null {
	const fromLower = parsed.fromAddress.toLowerCase()
	if (fromLower === selfEoaLower) return null
	return {
		id: parsed.sendId || `in-${parsed.createdAt}-${fromLower.slice(2, 10)}`,
		sendId: parsed.sendId,
		from: 'them',
		text: parsed.text,
		createdAt: parsed.createdAt,
		peerAddress: parsed.fromAddress,
	}
}
