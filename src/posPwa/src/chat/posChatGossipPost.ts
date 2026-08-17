/**
 * Main-thread gossip POST (onboarding / worker-not-ready fallback).
 * Encrypts already-built user-PGP armor as mailbox work (NoPush) and posts
 * `{ data }` to live entry A ≠ B. Never uses OPTIONS /post.
 */
import { GOSSIP_POST_DOMAIN_HEX_IDS } from '@/conet/constants'
import { shuffleTake } from '@/conet/crypto'
import { fetchCoNETGossipNodes, pickGossipNodes, type GossipNodeInfo } from '@/conet/guardianNodes'
import {
	pickGossipEntryNodesForSend,
	pickRouteNodesByArmoredKey,
	postUrl,
} from '@/vendor/beamio-chat-sdk/nodes'
import { wrapArmorToEntryRoute, wrapArmorToMailboxWork } from '@/vendor/beamio-chat-sdk/envelope'
import type { NodeInfo } from '@/vendor/beamio-chat-sdk/types'

function asNodeInfo(nodes: GossipNodeInfo[]): NodeInfo[] {
	return nodes as unknown as NodeInfo[]
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
	noPush?: boolean
}): Promise<boolean> {
	let armor = params.innerArmor
	const mailboxKey = params.mailboxRoutePublicArmored?.trim() || ''
	if (params.noPush) {
		if (!mailboxKey) {
			console.warn('[POS Chat] NoPush skipped: missing recipient mailbox route key')
		} else {
			try {
				armor = await wrapArmorToMailboxWork(armor, mailboxKey, { NoPush: true })
			} catch (ex) {
				console.warn('[POS Chat] mailbox wrap failed', (ex as Error)?.message ?? ex)
				return false
			}
		}
	}

	const live = await fetchCoNETGossipNodes()
	const nodes = asNodeInfo(live)
	const mailboxDomains = new Set(
		pickRouteNodesByArmoredKey(nodes, mailboxKey).map((n) => n.domain).filter(Boolean),
	)
	const entries = await pickGossipEntryNodesForSend(nodes, 4, mailboxDomains)
	const targets = entries.length ? entries : asNodeInfo(pickGossipNodes(live, 4))

	if (targets.length) {
		const results = await Promise.all(
			targets.map(async (node) => {
				const wrapped = await wrapArmorToEntryRoute(armor, node.armoredPublicKey)
				return postWithTimeout(postUrl(node.domain), wrapped)
			}),
		)
		if (results.some(Boolean)) return true
	}

	const domains = shuffleTake(GOSSIP_POST_DOMAIN_HEX_IDS, 6)
	const fallback = await Promise.all(
		domains.map((d) => postWithTimeout(`https://${d.toLowerCase()}.conet.network/post`, armor)),
	)
	return fallback.some(Boolean)
}
