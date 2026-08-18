import { Contract, JsonRpcProvider } from 'ethers'
import { CONET_RPC, CONET_RPC_FALLBACK } from '@/constants'

/** CoNET GuardianNodesInfoV6 — same as SilentPassUI / Alliance chat node pool. */
export const CONET_GUARDIAN_NODES_INFO_V6 = '0xBC6b53065b5647261396d002bDBA0d3396E0722f'

/** On-chain: `getAllNodes(uint256 start, uint256 length)` — param names do not affect the selector. */
const GUARDIAN_ABI = [
	'function getAllNodes(uint256 start, uint256 length) view returns (tuple(uint256 id, string PGP, string PGPKey, string ip_addr, string regionName)[])',
] as const

export type GossipNodeInfo = {
	ip_addr: string
	armoredPublicKey: string
	domain: string
	nftNumber: number
	region: string
}

let nodesCache: { at: number; nodes: GossipNodeInfo[] } | null = null
const NODES_TTL_MS = 5 * 60_000
const PAGE_LEN = 80
const MAX_NODES = 640

function decodePgpBase64(b64: string): string {
	try {
		const bin = atob(b64)
		return new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)))
	} catch {
		return b64
	}
}

function appendBatch(
	out: GossipNodeInfo[],
	batch: Array<{ id: bigint; PGP: string; PGPKey: string; ip_addr: string; regionName: string }>,
): void {
	for (const row of batch ?? []) {
		const id = Number(row.id?.toString?.() ?? (row as unknown as [bigint])[0] ?? 0)
		const pgpB64 = String(row.PGP ?? (row as unknown as string[])[1] ?? '')
		const domain = String(row.PGPKey ?? (row as unknown as string[])[2] ?? '').trim()
		const ip = String(row.ip_addr ?? (row as unknown as string[])[3] ?? '')
		const region = String(row.regionName ?? (row as unknown as string[])[4] ?? '')
		if (!domain) continue
		out.push({
			nftNumber: id,
			armoredPublicKey: decodePgpBase64(pgpB64),
			domain,
			ip_addr: ip,
			region,
		})
	}
}

async function fetchPagesFromRpc(rpc: string): Promise<GossipNodeInfo[]> {
	const provider = new JsonRpcProvider(rpc, 224422, { staticNetwork: true })
	const sc = new Contract(CONET_GUARDIAN_NODES_INFO_V6, GUARDIAN_ABI, provider)
	const out: GossipNodeInfo[] = []
	for (let start = 0; start < MAX_NODES; start += PAGE_LEN) {
		try {
			const batch = (await sc.getAllNodes(start, PAGE_LEN)) as Array<{
				id: bigint
				PGP: string
				PGPKey: string
				ip_addr: string
				regionName: string
			}>
			if (!batch?.length) break
			appendBatch(out, batch)
			if (batch.length < PAGE_LEN) break
		} catch (ex) {
			console.warn(
				'[fetchCoNETGossipNodes] page failed',
				rpc,
				start,
				ex instanceof Error ? ex.message : ex,
			)
			if (out.length) break
			throw ex
		}
	}
	return out
}

/** Fetch Guardian gossip nodes (entry A / C pool). Page locally so one oversized call cannot empty the pool. */
export async function fetchCoNETGossipNodes(): Promise<GossipNodeInfo[]> {
	if (nodesCache && Date.now() - nodesCache.at < NODES_TTL_MS) {
		return nodesCache.nodes
	}
	for (const rpc of [CONET_RPC, CONET_RPC_FALLBACK]) {
		try {
			const out = await fetchPagesFromRpc(rpc)
			if (out.length) {
				nodesCache = { at: Date.now(), nodes: out }
				return out
			}
		} catch (ex) {
			console.warn('[fetchCoNETGossipNodes]', rpc, ex instanceof Error ? ex.message : ex)
		}
	}
	return nodesCache?.nodes ?? []
}

export function getRandomGossipNode(nodes: GossipNodeInfo[]): GossipNodeInfo | null {
	if (!nodes.length) return null
	return nodes[Math.floor(Math.random() * nodes.length)]!
}

export function pickGossipNodes(nodes: GossipNodeInfo[], n: number): GossipNodeInfo[] {
	if (!nodes.length || n <= 0) return []
	const shuffled = [...nodes].sort(() => Math.random() - 0.5)
	return shuffled.slice(0, Math.min(n, shuffled.length))
}
