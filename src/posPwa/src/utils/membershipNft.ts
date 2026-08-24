/** Membership NFTs live in [100, 1e11). Exclude #0 points, #1–#30 stats, and issued coupons. */
export const MEMBERSHIP_NFT_MIN_ID = 100n
export const ISSUED_NFT_START_ID = 100_000_000_000n

export function parseNftTokenId(raw: unknown): bigint | null {
	try {
		const s = String(raw ?? '').replace(/,/g, '').trim()
		if (!s || s === 'Default/Max') return null
		return BigInt(s)
	} catch {
		return null
	}
}

export function isMembershipNftTokenId(raw: unknown): boolean {
	const id = parseNftTokenId(raw)
	if (id == null) return false
	return id >= MEMBERSHIP_NFT_MIN_ID && id < ISSUED_NFT_START_ID
}
