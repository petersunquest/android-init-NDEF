import { fetchCardAdminInfo, fetchCardMetadataRoot } from '@/api/beamioApi'
import { normalizeTierDiscountPercent } from '@/utils/beamioPaymentRouting'

export interface ChargeTierRoutingDetails {
	taxPercent: number
	discountByTierKey: Record<string, number>
}

function parseTierRoutingFromMetadataJson(
	metaJson: string,
	expectedInfraLower: string,
): ChargeTierRoutingDetails | null {
	try {
		const root = JSON.parse(metaJson) as Record<string, unknown>
		const tr = root.tierRoutingDiscounts as Record<string, unknown> | undefined
		if (!tr) return null
		const sv = tr.schemaVersion
		if (sv != null && sv !== 1 && sv !== '1') return null
		const infra = String(tr.infrastructureCard ?? '')
			.trim()
			.toLowerCase()
		if (!infra || infra !== expectedInfraLower) return null
		let tax = 0
		if (typeof tr.taxRatePercent === 'number') tax = tr.taxRatePercent
		else if (typeof tr.taxRatePercent === 'string') tax = Number(tr.taxRatePercent) || 0
		tax = Math.min(100, Math.max(0, tax))
		tax = Math.round(tax * 100) / 100
		const map: Record<string, number> = {}
		const tiers = tr.tiers
		if (Array.isArray(tiers)) {
			for (const rowAny of tiers) {
				if (!rowAny || typeof rowAny !== 'object') continue
				const row = rowAny as Record<string, unknown>
				let disc: number | null = null
				if (row.discountPercent != null) {
					if (typeof row.discountPercent === 'number') {
						disc = normalizeTierDiscountPercent(row.discountPercent)
					} else if (typeof row.discountPercent === 'string') {
						disc = normalizeTierDiscountPercent(Number(row.discountPercent) || 0)
					}
				}
				if (disc == null) continue
				const idx =
					typeof row.chainTierIndex === 'number'
						? row.chainTierIndex
						: Number(row.chainTierIndex)
				const tid = String(row.tierId ?? '').trim()
				if (Number.isFinite(idx)) {
					map[`chain-tier-${idx}`.toLowerCase()] = disc
				}
				if (tid) map[tid.toLowerCase()] = disc
			}
		}
		return { taxPercent: tax, discountByTierKey: map }
	} catch {
		return null
	}
}

async function fallbackFromCardMetadata(infraCard: string): Promise<ChargeTierRoutingDetails | null> {
	const root = await fetchCardMetadataRoot(infraCard)
	const meta = root?.metadata
	if (!meta || typeof meta !== 'object') return null
	const json = JSON.stringify(meta)
	const lower = infraCard.trim().toLowerCase()
	return (
		parseTierRoutingFromMetadataJson(json, lower) ??
		parseTierRoutingFromMetadataJson(json, lower.startsWith('0x') ? lower : `0x${lower}`)
	)
}

/** iOS `fetchChargeTierRoutingDetails` — tax + tier discount map for POS wallet. */
export async function fetchChargeTierRoutingDetails(
	wallet: string,
	infraCard: string,
): Promise<ChargeTierRoutingDetails | null> {
	const wNorm = wallet.trim().toLowerCase()
	const infraNorm = infraCard.trim().toLowerCase()
	const admin = await fetchCardAdminInfo(infraCard, wallet)
	if (!admin?.admins?.length) {
		return fallbackFromCardMetadata(infraCard)
	}
	const admins = admin.admins
	const metadatas = admin.metadatas ?? []
	const parents = admin.parents
	let idx = admins.findIndex((a) => String(a).trim().toLowerCase() === wNorm)
	if (idx < 0) return fallbackFromCardMetadata(infraCard)

	const adminIndex = (addr: string): number => {
		const x = addr.trim().toLowerCase()
		if (!x || x === '0x0000000000000000000000000000000000000000') return -1
		return admins.findIndex((a) => String(a).trim().toLowerCase() === x)
	}

	const parseAt = (rowIdx: number): ChargeTierRoutingDetails | null => {
		if (rowIdx < 0 || rowIdx >= metadatas.length) return null
		const metaStr = String(metadatas[rowIdx] ?? '').trim()
		if (!metaStr) return null
		return parseTierRoutingFromMetadataJson(metaStr, infraNorm)
	}

	const rowHasRouting = (rowIdx: number): boolean => {
		if (rowIdx < 0 || rowIdx >= metadatas.length) return false
		const metaStr = String(metadatas[rowIdx] ?? '').trim()
		if (!metaStr) return false
		return parseTierRoutingFromMetadataJson(metaStr, infraNorm) != null
	}

	const direct = parseAt(idx)
	if (direct) return direct

	let walk = idx
	for (let i = 0; i < 8; i++) {
		if (!parents || walk < 0 || walk >= parents.length) break
		const pRaw = String(parents[walk] ?? '').trim()
		const pIdx = adminIndex(pRaw)
		if (pIdx < 0) break
		if (rowHasRouting(pIdx)) {
			const d = parseAt(pIdx)
			if (d) return d
		}
		walk = pIdx
	}

	return fallbackFromCardMetadata(infraCard)
}
