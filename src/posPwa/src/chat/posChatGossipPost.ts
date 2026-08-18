/**
 * Main-thread gossip POST (onboarding / worker-not-ready fallback).
 *
 * Delivery packet must be recipient **user-PGP** armor posted to entry A ≠ B
 * (same shape as `scripts/testConetDepinMessage.ts probe`).
 *
 * Do **not** route mailbox-work (encrypted to B's route key) through A:
 * SI `forwardEncryptedSocket` → `getRoute(nodeKey)` often misses and still
 * returns HTTP 200 `{}`. POS shows success; mailbox B never sees the packet.
 * 0.1.8 Resend hit that path (`noPush` wrap then wrap-to-entry).
 */
import { readKey } from 'openpgp'
import { GOSSIP_POST_DOMAIN_HEX_IDS } from '@/conet/constants'
import { shuffleTake } from '@/conet/crypto'
import { fetchCoNETGossipNodes, pickGossipNodes, type GossipNodeInfo } from '@/conet/guardianNodes'
import {
	pickGossipEntryNodesForSend,
	pickRouteNodesByArmoredKey,
	postUrl,
} from '@/vendor/beamio-chat-sdk/nodes'
import { wrapArmorToEntryRoute } from '@/vendor/beamio-chat-sdk/envelope'
import type { NodeInfo } from '@/vendor/beamio-chat-sdk/types'

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

async function postWithTimeout(url: string, armored: string, timeoutMs = 12_000): Promise<boolean> {
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
		return res.ok
	} catch {
		return false
	} finally {
		clearTimeout(t)
	}
}

export async function postArmoredGossipToEntries(params: {
	innerArmor: string
	mailboxRoutePublicArmored?: string | null
	/** Kept for callers; mailbox-work is not used as the routed packet (see file header). */
	noPush?: boolean
}): Promise<boolean> {
	const innerArmor = params.innerArmor
	if (!innerArmor.includes('BEGIN PGP')) return false
	void params.noPush

	const mailboxKey = params.mailboxRoutePublicArmored?.trim() || ''
	const live = await fetchCoNETGossipNodes()
	const nodes = asNodeInfo(live)
	const mailboxDomains = new Set(
		pickRouteNodesByArmoredKey(nodes, mailboxKey).map((n) => n.domain).filter(Boolean).map(normDomainHex),
	)
	for (const hex of await mailboxDomainHexesFromArmored(mailboxKey)) {
		mailboxDomains.add(hex)
	}

	const liveWithoutMailbox = live.filter((n) => !mailboxDomains.has(normDomainHex(n.domain)))
	const entries = await pickGossipEntryNodesForSend(asNodeInfo(liveWithoutMailbox), 4)
	const targets = entries.length ? entries : asNodeInfo(pickGossipNodes(liveWithoutMailbox, 4))

	if (targets.length) {
		const results = await Promise.all(
			targets.map(async (node) => {
				try {
					if (!node.armoredPublicKey?.includes('BEGIN PGP')) return false
					const wrapped = await wrapArmorToEntryRoute(innerArmor, node.armoredPublicKey)
					const ok = await postWithTimeout(postUrl(node.domain), wrapped)
					if (ok) {
						console.log('[POS Chat] gossip POST user-PGP wrap-to-entry', node.domain)
					}
					return ok
				} catch (ex) {
					console.warn('[POS Chat] wrap-to-entry failed', node.domain, (ex as Error)?.message ?? ex)
					return false
				}
			}),
		)
		if (results.some(Boolean)) return true
	}

	const fallbackDomains = shuffleTake(
		GOSSIP_POST_DOMAIN_HEX_IDS.filter((d) => !mailboxDomains.has(normDomainHex(d))),
		6,
	)
	if (!fallbackDomains.length) {
		console.warn('[POS Chat] gossip POST: no entry A ≠ B available')
		return false
	}
	const fallback = await Promise.all(
		fallbackDomains.map((d) =>
			postWithTimeout(`https://${d.toLowerCase()}.conet.network/post`, innerArmor),
		),
	)
	if (fallback.some(Boolean)) {
		console.warn('[POS Chat] gossip POST used keyless entry fallback (user-PGP)')
		return true
	}
	return false
}
