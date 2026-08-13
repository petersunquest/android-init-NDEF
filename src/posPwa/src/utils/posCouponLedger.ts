import type { PosLedgerItem } from '@/utils/posLedgerMetrics'

export type PosCouponLedgerKind = 'couponClaim' | 'couponRedeem'

export function isPosCouponLedgerKind(
	type: string,
): type is PosCouponLedgerKind {
	return type === 'couponClaim' || type === 'couponRedeem'
}

function parsePosLedgerDisplayJson(displayJson: string): {
	source?: string
	title?: string
	handle?: string
	forText?: string
} | null {
	try {
		if (!displayJson.trim()) return null
		return JSON.parse(displayJson) as {
			source?: string
			title?: string
			handle?: string
			forText?: string
		}
	} catch {
		return null
	}
}

export function isPosCouponSurrenderDisplayJson(displayJson: string): boolean {
	const d = parsePosLedgerDisplayJson(displayJson)
	if (!d) return false
	const src = String(d.source ?? '').trim().toLowerCase()
	if (src === 'poscouponsurrender') return true
	const handle = String(d.handle ?? d.forText ?? '')
		.trim()
		.toLowerCase()
	if (handle === 'pos coupon surrender') return true
	return String(d.title ?? '').trim().toLowerCase() === 'in-store coupon redeem'
}

/** Align SilentPassUI / biz: Claim Coupon / Claim Catalog / In-Store Coupon Redeem. */
export function posCouponLedgerHeadline(tx: PosLedgerItem): string {
	if (tx.type === 'couponRedeem' || isPosCouponSurrenderDisplayJson(tx.displayJson)) {
		return 'In-Store Coupon Redeem'
	}
	const title = String(parsePosLedgerDisplayJson(tx.displayJson)?.title ?? '')
		.trim()
		.toLowerCase()
	if (title.includes('claim catalog')) return 'Claim Catalog'
	return 'Claim Coupon'
}

export function posCouponLedgerAmountLabel(tx: PosLedgerItem): string {
	if (tx.type === 'couponClaim') return 'Claimed'
	return 'Redeemed'
}
