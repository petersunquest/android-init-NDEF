import { Contract, JsonRpcProvider } from 'ethers'
import { CONET_RPC } from '@/constants'
import { CONET_GUARDIAN_NODES_INFO_V6, GOSSIP_POST_DOMAIN_HEX_IDS } from '@/conet/constants'
import { shuffleTake } from '@/conet/crypto'

const GUARDIAN_NODES_ABI = [
	'function getAllNodes(uint256 start,uint256 length) view returns (tuple(uint256 id,string PGP,string PGPKey,string ip_addr,string regionName)[])',
] as const

const GOSSIP_DOMAIN_CACHE_TTL_MS = 120_000
let cachedDomains: { expiresAt: number; domains: string[] } | null = null

function normalizeDomainHex(raw: unknown): string | null {
	const domain = String(raw ?? '').trim()
	if (!/^[0-9a-fA-F]{16}$/.test(domain)) return null
	return domain.toUpperCase()
}

async function fetchGuardianNodeDomainsFromChain(): Promise<string[]> {
	const now = Date.now()
	if (cachedDomains && cachedDomains.expiresAt > now) return cachedDomains.domains

	try {
		const provider = new JsonRpcProvider(CONET_RPC)
		const contract = new Contract(CONET_GUARDIAN_NODES_INFO_V6, GUARDIAN_NODES_ABI, provider)
		const pages = await Promise.all([
			contract.getAllNodes(0, 400) as Promise<unknown[]>,
			contract.getAllNodes(400, 400) as Promise<unknown[]>,
		])
		const domains = Array.from(
			new Set(
				pages
					.flat()
					.map((node) => normalizeDomainHex((node as { PGPKey?: unknown })?.PGPKey ?? (node as readonly unknown[])?.[2]))
					.filter((domain): domain is string => Boolean(domain))
			)
		)
		if (domains.length) {
			cachedDomains = { expiresAt: now + GOSSIP_DOMAIN_CACHE_TTL_MS, domains }
			return domains
		}
	} catch (error) {
		console.warn('[CoNET chat] failed to fetch Guardian nodes from chain', error instanceof Error ? error.message : String(error))
	}

	return [...GOSSIP_POST_DOMAIN_HEX_IDS]
}

async function canReachGossipDomain(domainHex: string): Promise<boolean> {
	const ctrl = new AbortController()
	const timer = window.setTimeout(() => ctrl.abort(), 4_000)
	try {
		const res = await fetch(`https://${domainHex.toLowerCase()}.conet.network/`, {
			method: 'GET',
			headers: { Accept: 'text/html' },
			cache: 'no-store',
			signal: ctrl.signal,
		})
		return res.status > 0 && res.status < 500
	} catch {
		return false
	} finally {
		window.clearTimeout(timer)
	}
}

export async function pickReachableGossipRouteDomain(): Promise<string | null> {
	const domains = shuffleTake(await fetchGuardianNodeDomainsFromChain(), 10)
	const checks = await Promise.all(domains.map(async (domain) => ({ domain, ok: await canReachGossipDomain(domain) })))
	return checks.find((item) => item.ok)?.domain ?? null
}

export async function pickGossipPostDomains(count: number): Promise<string[]> {
	const domains = await fetchGuardianNodeDomainsFromChain()
	const sample = shuffleTake(domains, Math.max(count * 2, count))
	const checks = await Promise.all(sample.map(async (domain) => ({ domain, ok: await canReachGossipDomain(domain) })))
	const healthy = checks.filter((item) => item.ok).map((item) => item.domain)
	return shuffleTake(healthy.length ? healthy : domains, count)
}
