/** Map claim / relay errors to cashier-friendly English (ui-english.mdc). */
export function formatCouponClaimErrorMessage(raw: string | undefined | null): string {
	const msg = (raw ?? '').trim()
	if (!msg) return 'Coupon claim failed. Please try again.'
	const lower = msg.toLowerCase()
	if (lower.includes('paymaster deposit too low') || lower.includes('aa31')) {
		return 'Payment relay is temporarily unavailable. Please try again in a minute.'
	}
	if (lower.includes('already claimed') || lower.includes('already used')) {
		return 'This wallet already claimed this coupon.'
	}
	if (lower.includes('not available for open claim') || lower.includes('inactive') || lower.includes('expired')) {
		return msg.length <= 160 ? msg : 'This coupon is not available for claim right now.'
	}
	if (lower.includes('insufficient funds') || lower.includes('low on gas')) {
		return 'Network relay wallet is low on gas. Please try again shortly.'
	}
	if (msg.length > 160) {
		return 'Coupon claim failed. Please try again.'
	}
	return msg
}
