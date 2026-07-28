const asRecord = (v: unknown): Record<string, unknown> | null =>
	v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : null

const readString = (v: unknown): string => (typeof v === 'string' ? v.trim() : '')

function readMetadataCouponId(meta: Record<string, unknown> | null): string {
	if (!meta) return ''
	const root = readString(meta.couponId)
	if (root) return root
	const props = asRecord(meta.properties)
	const beamioCoupon = asRecord(props?.beamioCoupon)
	return readString(beamioCoupon?.couponId)
}

function readMetadataTitle(meta: Record<string, unknown> | null, tokenId: string): string {
	if (!meta) return `Coupon #${tokenId}`
	const props = asRecord(meta.properties)
	const beamioCoupon = asRecord(props?.beamioCoupon)
	return (
		readString(meta.title) ||
		readString(meta.name) ||
		readString(beamioCoupon?.title) ||
		readString(beamioCoupon?.name) ||
		`Coupon #${tokenId}`
	)
}

function readMetadataSubtitle(meta: Record<string, unknown> | null): string {
	if (!meta) return ''
	const props = asRecord(meta.properties)
	const beamioCoupon = asRecord(props?.beamioCoupon)
	return (
		readString(meta.subtitle) ||
		readString(meta.description) ||
		readString(beamioCoupon?.subtitle) ||
		readString(beamioCoupon?.description)
	)
}

function readMetadataIconUrl(meta: Record<string, unknown> | null): string {
	if (!meta) return ''
	const props = asRecord(meta.properties)
	const beamioCoupon = asRecord(props?.beamioCoupon)
	const shareTokenMetadata = asRecord(props?.shareTokenMetadata)
	const imageObj = asRecord(meta.image)
	return (
		readString(meta.iconUrl) ||
		readString(meta.icon) ||
		readString(beamioCoupon?.iconUrl) ||
		readString(beamioCoupon?.icon) ||
		readString(shareTokenMetadata?.logoUrl) ||
		readString(imageObj?.url) ||
		readString(meta.image)
	)
}

function readMetadataBackgroundImage(meta: Record<string, unknown> | null): string {
	if (!meta) return ''
	const props = asRecord(meta.properties)
	const beamioCoupon = asRecord(props?.beamioCoupon)
	return (
		readString(meta.couponImage) ||
		readString(meta.backgroundImage) ||
		readString(meta.bannerImage) ||
		readString(beamioCoupon?.couponImage) ||
		readString(beamioCoupon?.backgroundImage)
	)
}

function readMetadataBackgroundColor(meta: Record<string, unknown> | null): string {
	if (!meta) return ''
	const props = asRecord(meta.properties)
	const beamioCoupon = asRecord(props?.beamioCoupon)
	return (
		readString(meta.backgroundColorHex) ||
		readString(meta.backgroundColor) ||
		readString(beamioCoupon?.backgroundColorHex) ||
		readString(beamioCoupon?.backgroundColor)
	)
}

function readRequiresRedeemCode(meta: Record<string, unknown> | null): boolean {
	if (!meta) return false
	const toBool = (v: unknown) => v === true || v === 1 || v === '1' || v === 'true'
	if (toBool(meta.requiresRedeemCode) || toBool(meta.redeemCodeRequired)) return true
	const props = asRecord(meta.properties)
	const beamioCoupon = asRecord(props?.beamioCoupon)
	if (!beamioCoupon) return false
	return toBool(beamioCoupon.requiresRedeemCode) || toBool(beamioCoupon.redeemCodeRequired)
}

export interface MerchantActiveIssuedCoupon {
	id: string
	cardAddress: string
	tokenId: string
	couponId?: string
	displayTitle: string
	subtitle?: string
	iconUrl?: string
	backgroundImageUrl?: string
	backgroundColorHex?: string
	issuedNftValidBeforeSec?: number
	issuedNftMaxSupply?: string
	issuedNftRemainingSupply?: string
	requiresRedeemCode?: boolean
}

function readSupplyField(d: Record<string, unknown>, keys: string[]): string {
	for (const k of keys) {
		const v = d[k]
		if (v != null && String(v).trim()) return String(v).trim()
	}
	return ''
}

export function parseMerchantActiveIssuedCouponRow(row: unknown): MerchantActiveIssuedCoupon | null {
	if (!row || typeof row !== 'object') return null
	const d = row as Record<string, unknown>
	const cardAddress = readString(d.cardAddress)
	const tokenId = readString(d.tokenId)
	if (!cardAddress || !tokenId) return null
	const meta = asRecord(d.metadata)
	const beforeRaw = readString(d.issuedNftValidBefore)
	const beforeNum = beforeRaw ? Number(beforeRaw) : 0
	return {
		id: `${cardAddress.toLowerCase()}:${tokenId}`,
		cardAddress,
		tokenId,
		couponId: readMetadataCouponId(meta) || undefined,
		displayTitle: readMetadataTitle(meta, tokenId),
		subtitle: readMetadataSubtitle(meta) || undefined,
		iconUrl: readMetadataIconUrl(meta) || undefined,
		backgroundImageUrl: readMetadataBackgroundImage(meta) || undefined,
		backgroundColorHex: readMetadataBackgroundColor(meta) || undefined,
		issuedNftValidBeforeSec:
			Number.isFinite(beforeNum) && beforeNum > 0 ? beforeNum : undefined,
		issuedNftMaxSupply:
			readSupplyField(d, [
				'issuedNftMaxSupply',
				'maxSupply',
				'issuedNftSupply',
				'totalSupply',
				'supply',
			]) || undefined,
		issuedNftRemainingSupply:
			readSupplyField(d, [
				'issuedNftRemainingSupply',
				'remainingSupply',
				'leftSupply',
				'remaining',
				'availableSupply',
			]) || undefined,
		requiresRedeemCode: readRequiresRedeemCode(meta),
	}
}

export function matchActiveIssuedCoupon(
	activeCoupons: MerchantActiveIssuedCoupon[] | null | undefined,
	cardAddress: string,
	couponId: string,
	tokenId: string,
): MerchantActiveIssuedCoupon | undefined {
	if (!activeCoupons?.length) return undefined
	const c = cardAddress.trim().toLowerCase()
	const id = couponId.trim().toLowerCase()
	const t = tokenId.trim()
	if (id && t && c) {
		for (const item of activeCoupons) {
			if (
				item.cardAddress.trim().toLowerCase() === c &&
				(item.couponId ?? '').trim().toLowerCase() === id &&
				item.tokenId.trim() === t
			) {
				return item
			}
		}
	}
	if (t && c) {
		for (const item of activeCoupons) {
			if (item.cardAddress.trim().toLowerCase() === c && item.tokenId.trim() === t) {
				return item
			}
		}
	}
	return undefined
}

export function resolveCouponBackgroundHex(
	activeCoupons: MerchantActiveIssuedCoupon[] | null | undefined,
	couponId: string,
	tokenId: string,
	cardAddress: string,
): string | undefined {
	const match = matchActiveIssuedCoupon(activeCoupons, cardAddress, couponId, tokenId)
	if (match?.backgroundColorHex?.trim()) return match.backgroundColorHex.trim()
	return undefined
}
