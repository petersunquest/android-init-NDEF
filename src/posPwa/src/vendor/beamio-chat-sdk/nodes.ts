/**
 * Node selection + health helpers. Runtime-agnostic (Worker-safe: uses `fetch`,
 * `globalThis` timers). Ported from SilentPassUI `services/chat.ts` with window.* removed.
 *
 * Routing rule reminder: send business payloads to entry A ≠ mailbox B; listen via
 * entry C ≠ B. Mailbox B is identified by matching the contact route armored key.
 * Client → entry uses HTTPS by default (PWA mixed-content). Never set
 * `X-CoNET-Hop-Sigs` on these requests.
 */

import type { NodeInfo } from './types'

/** `{https|http}://{domain}.conet.network/post` — SI developer guide `postUrl`. */
export function postUrl(domain: string, https = true): string {
	return `${https ? 'https' : 'http'}://${domain}.conet.network/post`
}

export const getRandomNode = (allNodes: NodeInfo[]): NodeInfo | null => {
	if (!allNodes.length) return null
	return allNodes[Math.floor(Math.random() * allNodes.length)]
}

/** Random n distinct nodes (used for send fan-out / presence). */
export const getRandomNodes = (allNodes: NodeInfo[], n: number): NodeInfo[] => {
	if (!allNodes.length || n <= 0) return []
	const shuffled = [...allNodes].sort(() => Math.random() - 0.5)
	return shuffled.slice(0, Math.min(n, shuffled.length))
}

export const normalizeArmoredKey = (v?: string): string => (v || '').replace(/\r/g, '').trim()

/** Mailbox B nodes = nodes whose armored public key equals the contact route key. */
export const pickRouteNodesByArmoredKey = (
	nodes: NodeInfo[],
	routerArmoredPublicKey: string,
): NodeInfo[] => {
	const target = normalizeArmoredKey(routerArmoredPublicKey)
	if (!target) return []
	return nodes.filter((n) => normalizeArmoredKey(n.armoredPublicKey) === target)
}

const GOSSIP_HEALTH_TTL_MS = 120_000
const gossipHealthyCache = new Map<string, number>()

export const markGossipNodeHealthy = (domain: string): void => {
	gossipHealthyCache.set(domain, Date.now() + GOSSIP_HEALTH_TTL_MS)
}
export const markGossipNodeBad = (domain: string): void => {
	gossipHealthyCache.delete(domain)
}
const isGossipNodeHealthy = (domain: string): boolean => (gossipHealthyCache.get(domain) || 0) > Date.now()

async function postWithTimeout(url: string, init: RequestInit, timeoutMs = 12_000): Promise<Response> {
	const ctrl = new AbortController()
	const t = setTimeout(() => ctrl.abort(), timeoutMs)
	try {
		return await fetch(url, { ...init, signal: ctrl.signal })
	} finally {
		clearTimeout(t)
	}
}

export { postWithTimeout }

const probeGossipNode = async (node: NodeInfo, timeoutMs = 4_000): Promise<boolean> => {
	// Optional hint only. SI GET / is forwarded and often has no ACAO —
	// a CORS failure here is NOT "node down".
	// Listen must use pickListenEntryNodes (POST /post), never this probe as a gate.
	try {
		const res = await postWithTimeout(
			`https://${node.domain}.conet.network/`,
			{ method: 'GET', headers: { Accept: 'text/html' } },
			timeoutMs,
		)
		if (res.status >= 200 && res.status < 400) {
			markGossipNodeHealthy(node.domain)
			return true
		}
	} catch {
		/* ignore */
	}
	markGossipNodeBad(node.domain)
	return false
}

/** Entry C pool for listen. Never require GET / health — that homepage has no CORS. */
export function pickListenEntryNodes(pool: NodeInfo[], excludeDomains?: Set<string>): NodeInfo[] {
	const filtered = excludeDomains?.size ? pool.filter((n) => !excludeDomains.has(n.domain)) : pool
	return filtered.length ? filtered : pool
}

export const pickHealthyGossipNodes = async (nodes: NodeInfo[]): Promise<NodeInfo[]> => {
	if (!nodes.length) return []
	const cached = nodes.filter((n) => isGossipNodeHealthy(n.domain))
	if (cached.length >= 2) return cached
	const sample = getRandomNodes(nodes, Math.min(10, nodes.length))
	const checks = await Promise.all(sample.map(async (node) => ({ node, ok: await probeGossipNode(node) })))
	return checks.filter((n) => n.ok).map((n) => n.node)
}

/** Pick up to n entry nodes for gossip send (healthy preferred, exclude mailbox B). */
export const pickGossipEntryNodesForSend = async (
	pool: NodeInfo[],
	n = 4,
	excludeDomains?: Set<string>,
): Promise<NodeInfo[]> => {
	const filtered = excludeDomains?.size ? pool.filter((node) => !excludeDomains.has(node.domain)) : pool
	if (!filtered.length) return []
	const healthy = await pickHealthyGossipNodes(filtered)
	const source = healthy.length >= 2 ? healthy : filtered
	return getRandomNodes(source, Math.min(n, source.length))
}

/** Per-attempt wait for an answer, and entries tried, for one delivery. */
export const POST_ATTEMPT_TIMEOUT_MS = 8_000
export const POST_MAX_ENTRIES = 4
const POST_TOTAL_BUDGET_MS = 25_000

/** A 2xx whose JSON body says `{ "ok": false }` is a failure too. */
export const isExplicitFailureBody = (text: string): boolean => {
	try {
		const parsed = JSON.parse(text.trim()) as unknown
		return !!parsed && typeof parsed === 'object' && (parsed as { ok?: unknown }).ok === false
	} catch {
		return false
	}
}

/**
 * Deliver one ciphertext through ONE entry at a time; try the next entry only
 * when this one clearly failed: connection error or reset before an answer,
 * non-2xx, a `{ ok: false }` body, or no answer within `timeoutMs`. A
 * timed-out POST may still have arrived; retrying is safe because the mailbox
 * keeps one copy per ciphertext and clients dedupe by `sendId`.
 */
export async function postArmorOneEntryAtATime(args: {
	nodes: NodeInfo[]
	exclude: Set<string>
	/** JSON body for this entry (e.g. armor wrapped to that entry's key). */
	buildBody: (node: NodeInfo) => Promise<string>
	maxAttempts?: number
	timeoutMs?: number
}): Promise<{ ok: boolean; body: string; domain?: string; attempts: number }> {
	const tried = new Set(args.exclude)
	const maxAttempts = Math.max(1, args.maxAttempts ?? POST_MAX_ENTRIES)
	const started = Date.now()
	let attempts = 0
	while (attempts < maxAttempts && Date.now() - started < POST_TOTAL_BUDGET_MS) {
		const [node] = await pickGossipEntryNodesForSend(args.nodes, 1, tried)
		if (!node) break
		tried.add(node.domain)
		attempts++
		try {
			const body = await args.buildBody(node)
			const left = POST_TOTAL_BUDGET_MS - (Date.now() - started)
			const res = await postWithTimeout(postUrl(node.domain), {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body,
				referrerPolicy: 'no-referrer',
			}, Math.max(1_000, Math.min(args.timeoutMs ?? POST_ATTEMPT_TIMEOUT_MS, left)))
			if (!res.ok) {
				markGossipNodeBad(node.domain)
				continue
			}
			const text = await res.text().catch(() => '')
			if (isExplicitFailureBody(text)) continue
			markGossipNodeHealthy(node.domain)
			return { ok: true, body: text, domain: node.domain, attempts }
		} catch {
			markGossipNodeBad(node.domain)
		}
	}
	return { ok: false, body: '', attempts }
}
