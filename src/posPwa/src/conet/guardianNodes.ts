import { Contract, JsonRpcProvider } from 'ethers'
import { CONET_RPC } from '@/constants'

/** CoNET GuardianNodesInfoV6 — same as SilentPassUI / Alliance chat node pool. */
export const CONET_GUARDIAN_NODES_INFO_V6 = '0xBC6b53065b5647261396d002bDBA0d3396E0722f'

const GUARDIAN_ABI = [
	'function getAllNodes(uint256 start, uint256 end) view returns (tuple(uint256 id, string PGP, string PGPKey, string ip_addr, string regionName)[])',
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

function decodePgpBase64(b64: string): string {
	try {
		const bin = atob(b64)
		return new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)))
	} catch {
		return b64
	}
}

/** Fetch Guardian gossip nodes (entry C / mailbox B pool). */
export async function fetchCoNETGossipNodes(): Promise<GossipNodeInfo[]> {
	if (nodesCache && Date.now() - nodesCache.at < NODES_TTL_MS) {
		return nodesCache.nodes
	}
	const provider = new JsonRpcProvider(CONET_RPC, 224422, { staticNetwork: true })
	const sc = new Contract(CONET_GUARDIAN_NODES_INFO_V6, GUARDIAN_ABI, provider)
	const out: GossipNodeInfo[] = []
	try {
		const batches = await Promise.all([
			sc.getAllNodes(0, 400) as Promise<
				Array<{ id: bigint; PGP: string; PGPKey: string; ip_addr: string; regionName: string }>
			>,
			sc.getAllNodes(400, 800) as Promise<
				Array<{ id: bigint; PGP: string; PGPKey: string; ip_addr: string; regionName: string }>
			>,
		])
		for (const batch of batches) {
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
	} catch (ex) {
		console.warn('[fetchCoNETGossipNodes]', ex instanceof Error ? ex.message : ex)
		return nodesCache?.nodes ?? []
	}
	nodesCache = { at: Date.now(), nodes: out }
	return out
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
