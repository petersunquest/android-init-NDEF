/** Map relay / prepare errors to cashier-friendly English (ui-english.mdc). */
export function formatCouponConsumeErrorMessage(raw: string | undefined | null): string {
	const msg = (raw ?? '').trim()
	if (!msg) return 'Coupon consume failed. Please try again.'
	const lower = msg.toLowerCase()
	if (lower.includes('paymaster deposit too low') || lower.includes('aa31')) {
		return 'Payment relay is temporarily unavailable. Ask the customer to refresh Pay QR and try again in a minute.'
	}
	if (lower.includes('payment code was already used') || lower.includes('bad nonce') || lower.includes('stale nonce')) {
		return 'This Pay QR was already used or expired. Ask the customer to open Pay again and scan the new QR.'
	}
	if (lower.includes('pay qr wallet does not match')) {
		return 'Pay QR wallet does not match the coupon holder. Ask the customer to open Pay on the same wallet.'
	}
	if (lower.includes('missing transaction receipt') || lower.includes('transaction reverted')) {
		return 'Payment did not complete on-chain. Ask the customer to refresh Pay QR and try again.'
	}
	if (lower.includes('insufficient funds')) {
		return 'Network relay wallet is low on gas. Please try again shortly.'
	}
	if (msg.length > 160) {
		return 'Coupon consume failed. Ask the customer to refresh Pay QR and try again.'
	}
	return msg
}
