import type { MerchantActiveIssuedCoupon } from '@/utils/couponMetadata'

function readSupply(row: MerchantActiveIssuedCoupon, field: 'max' | 'remaining'): string {
	const raw =
		field === 'max' ? row.issuedNftMaxSupply : row.issuedNftRemainingSupply
	return raw?.trim() ?? ''
}

/** iOS `openClaimUrl(for:)` */
export function couponOpenClaimUrl(row: MerchantActiveIssuedCoupon): string | null {
	if (row.requiresRedeemCode) return null
	const couponId = row.couponId?.trim() ?? ''
	const card = row.cardAddress.trim()
	if (!couponId || !card) return null
	const cardEnc = encodeURIComponent(card)
	const couponEnc = encodeURIComponent(couponId)
	return `https://beamio.app/app/?beamiocard=${cardEnc}&couponId=${couponEnc}&claim=open`
}

/** iOS `canShareOpenClaim` */
export function canShareCouponOpenClaim(row: MerchantActiveIssuedCoupon): boolean {
	return couponOpenClaimUrl(row) != null
}

/** iOS `couponSupplySummaryText` */
export function couponSupplySummaryText(row: MerchantActiveIssuedCoupon): string | null {
	const total = readSupply(row, 'max')
	const remaining = readSupply(row, 'remaining')
	if (total && remaining) return `TOTAL ${total} · LEFT ${remaining}`
	if (total) return `TOTAL ${total} · LEFT --`
	if (remaining) return `LEFT ${remaining}`
	return null
}
