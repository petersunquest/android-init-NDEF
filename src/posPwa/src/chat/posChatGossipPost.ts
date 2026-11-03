/**
 * Main-thread gossip POST (onboarding / worker-not-ready fallback).
 *
 * A chat delivery (recipient user-PGP armor) is always wrapped to the
 * recipient's mailbox B (mailbox work `{ data, NoPush? }`), so the entry sees
 * only B's route key ID, never the recipient's key ID; without B's route key
 * it is not sent. A command already encrypted to a mailbox route key (e.g. the
 * mailbox ACK) is posted as is (`alreadyRouted`). Each armor is wrapped to the
 * entry's key and posted through one entry at a time; the next entry only
 * after a clear failure (network error, non-2xx, `{ ok: false }`, 8 s timeout).
 */
import { readKey } from 'openpgp'
import { fetchCoNETGossipNodes, type GossipNodeInfo } from '@/conet/guardianNodes'
import {
	pickGossipEntryNodesForSend,
	pickRouteNodesByArmoredKey,
	postUrl,
} from '@conet.project/chat-sdk/nodes'
import { wrapArmorToEntryRoute, wrapArmorToMailboxWork } from '@conet.project/chat-sdk/envelope'
import type { NodeInfo } from '@conet.project/chat-sdk/types'

function asNodeInfo(nodes: GossipNodeInfo[]): NodeInfo[] {
	return nodes as unknown as NodeInfo[]
}

function normDomainHex(raw: string): string {
	return raw.trim().toUpperCase()
}

async function mailboxDomainHexesFromArmored(armored: string): Promise<string[]> {
	const key = armored.trim()
	if (!key.includes('BEGIN PGP')) return []
	try {
		const parsed = await readKey({ armoredKey: key })
		const out: string[] = []
		for (const id of parsed.getKeyIDs()) {
			const hex = id.toHex().toUpperCase()
			if (/^[0-9A-F]{16}$/.test(hex)) out.push(hex)
		}
		return out
	} catch {
		return []
	}
}

async function postWithTimeout(url: string, armored: string, timeoutMs = 8_000): Promise<boolean> {
	const ctrl = new AbortController()
	const t = setTimeout(() => ctrl.abort(), timeoutMs)
	try {
		const res = await fetch(url, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ data: armored }),
			referrerPolicy: 'no-referrer',
			signal: ctrl.signal,
		})
		if (!res.ok) return false
		const answer = await res.text().catch(() => '')
		return !/"ok"\s*:\s*false/.test(answer)
	} catch {
		return false
	} finally {
		clearTimeout(t)
	}
}

export async function postArmoredGossipToEntries(params: {
	innerArmor: string
	mailboxRoutePublicArmored?: string | null
	/** Chat delivery: the mailbox stores it without a push (delivery receipts). */
	noPush?: boolean
	/** `innerArmor` is already encrypted to a mailbox route key (mailbox command). */
	alreadyRouted?: boolean
}): Promise<boolean> {
	if (!params.innerArmor.includes('BEGIN PGP')) return false
	const mailboxKey = params.mailboxRoutePublicArmored?.trim() || ''
	if (!mailboxKey) {
		console.warn('[POS Chat] gossip POST: recipient mailbox unknown; not sent')
		return false
	}
	const innerArmor = params.alreadyRouted
		? params.innerArmor
		: await wrapArmorToMailboxWork(params.innerArmor, mailboxKey, params.noPush ? { NoPush: true } : undefined)

	const live = await fetchCoNETGossipNodes()
	const nodes = asNodeInfo(live)
	const mailboxDomains = new Set(
		pickRouteNodesByArmoredKey(nodes, mailboxKey).map((n) => n.domain).filter(Boolean).map(normDomainHex),
	)
	for (const hex of await mailboxDomainHexesFromArmored(mailboxKey)) {
		mailboxDomains.add(hex)
	}
	const tried = new Set<string>(mailboxDomains)
	for (let attempt = 0; attempt < 4; attempt++) {
		const pool = live.filter((n) => !tried.has(normDomainHex(n.domain)) && n.armoredPublicKey?.includes('BEGIN PGP'))
		const [node] = await pickGossipEntryNodesForSend(asNodeInfo(pool), 1)
		if (!node) break
		tried.add(normDomainHex(node.domain))
		try {
			const wrapped = await wrapArmorToEntryRoute(innerArmor, node.armoredPublicKey)
			if (await postWithTimeout(postUrl(node.domain), wrapped)) return true
		} catch (ex) {
			console.warn('[POS Chat] wrap-to-entry failed', node.domain, (ex as Error)?.message ?? ex)
		}
	}
	console.warn('[POS Chat] gossip POST failed on every entry')
	return false
}
