/**
 * Main-thread gossip POST (onboarding / worker-not-ready fallback).
 * Encrypts already-built user-PGP armor as mailbox work (NoPush) and posts
 * `{ data }` to live entry A ≠ B. Never uses OPTIONS /post.
 *
 * Keyless domain fallback must POST **user-PGP** armor (same shape as
 * `scripts/testConetDepinMessage.ts` probe). Posting mailbox-work (encrypted to
 * B's route key) without wrap-to-entry lets SI `getRoute(nodeKey)` miss and
 * still return HTTP 200 `{}` — POS shows success, mailbox B never sees the packet.
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
import { wrapArmorToEntryRoute, wrapArmorToMailboxWork } from '@/vendor/beamio-chat-sdk/envelope'
import type { NodeInfo } from '@/vendor/beamio-chat-sdk/types'

function asNodeInfo(nodes: GossipNodeInfo[]): NodeInfo[] {
	return nodes as unknown as NodeInfo[]
}

function normDomainHex(raw: string): string {
	return raw.trim().toUpperCase()
}

async function mailboxDomainHexFromArmored(armored: string): Promise<string | null> {
	const key = armored.trim()
	if (!key.includes('BEGIN PGP')) return null
	try {
		const parsed = await readKey({ armoredKey: key })
		const id = parsed.getKeyIDs()[0]?.toHex().toUpperCase() ?? ''
		return /^[0-9A-F]{16}$/.test(id) ? id : null
	} catch {
		return null
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
	noPush?: boolean
}): Promise<boolean> {
	const innerArmor = params.innerArmor
	const mailboxKey = params.mailboxRoutePublicArmored?.trim() || ''
	let mailboxWorkArmor = innerArmor
	if (params.noPush) {
		if (!mailboxKey) {
			console.warn('[POS Chat] NoPush skipped: missing recipient mailbox route key')
		} else {
			try {
				mailboxWorkArmor = await wrapArmorToMailboxWork(innerArmor, mailboxKey, { NoPush: true })
			} catch (ex) {
				console.warn('[POS Chat] mailbox wrap failed', (ex as Error)?.message ?? ex)
				return false
			}
		}
	}

	const live = await fetchCoNETGossipNodes()
	const nodes = asNodeInfo(live)
	const mailboxDomains = new Set(
		pickRouteNodesByArmoredKey(nodes, mailboxKey).map((n) => n.domain).filter(Boolean).map(normDomainHex),
	)
	const mailboxHex = await mailboxDomainHexFromArmored(mailboxKey)
	if (mailboxHex) mailboxDomains.add(mailboxHex)

	const liveWithoutMailbox = live.filter((n) => !mailboxDomains.has(normDomainHex(n.domain)))
	const entries = await pickGossipEntryNodesForSend(asNodeInfo(liveWithoutMailbox), 4)
	const targets = entries.length ? entries : asNodeInfo(pickGossipNodes(liveWithoutMailbox, 4))

	if (targets.length) {
		const results = await Promise.all(
			targets.map(async (node) => {
				try {
					if (!node.armoredPublicKey?.includes('BEGIN PGP')) return false
					const wrapped = await wrapArmorToEntryRoute(mailboxWorkArmor, node.armoredPublicKey)
					return postWithTimeout(postUrl(node.domain), wrapped)
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
	/*
	 * No entry route keys on this path — do not POST mailbox-work (B route key).
	 * Post user-PGP armor so entry getRoute(userPgpKeyID) can find mailbox B.
	 */
	const fallback = await Promise.all(
		fallbackDomains.map((d) =>
			postWithTimeout(`https://${d.toLowerCase()}.conet.network/post`, innerArmor),
		),
	)
	if (fallback.some(Boolean)) {
		console.warn('[POS Chat] gossip POST used keyless entry fallback (user-PGP, no mailbox wrap)')
		return true
	}
	return false
}
