/** POS / SilentPassUI coupon expiry pill — hide VALID NOW / NO EXPIRY per protocol. */

export function posCouponExpiryPresentation(validBeforeSec: number | null | undefined): {
	label: string
	urgent: boolean
	expired: boolean
} {
	if (!validBeforeSec || validBeforeSec <= 0) {
		return { label: 'NO EXPIRY', urgent: false, expired: false }
	}
	const now = Math.floor(Date.now() / 1000)
	if (validBeforeSec <= now) {
		return { label: 'EXPIRED', urgent: true, expired: true }
	}
	const delta = validBeforeSec - now
	const hours = delta / 3600
	if (hours <= 48) {
		const h = Math.max(1, Math.ceil(hours))
		return { label: `EXPIRES IN ${h}H`, urgent: true, expired: false }
	}
	const days = Math.max(1, Math.ceil(delta / 86400))
	return { label: `EXPIRES IN ${days}D`, urgent: false, expired: false }
}

export function shouldShowCouponExpiryPill(expiresLabel: string): boolean {
	const normalized = expiresLabel.trim().toUpperCase()
	if (!normalized) return false
	return normalized !== 'VALID NOW' && normalized !== 'NO EXPIRY'
}

export function couponExpiryUsesUrgentVariant(expiresLabel: string): boolean {
	return expiresLabel === 'EXPIRED' || /\bEXPIRES IN \d+H\b|\bEXPIRES IN \d+M\b/.test(expiresLabel)
}
