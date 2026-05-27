import type {
	ReadBalanceCardItem,
	ReadBalanceNftItem,
	MerchantClaimableCouponItem,
	MerchantCouponBalanceItem,
	UIDAssetsResult,
} from '@/types/pos'

function normAddr(a: string): string {
	return a.trim().toLowerCase()
}

function padMemberNo(raw: string): string {
	const t = raw.trim()
	if (t.length >= 6) return t
	return `${'0'.repeat(Math.max(0, 6 - t.length))}${t}`
}

export function memberNoFromCard(card: ReadBalanceCardItem | undefined): string {
	if (!card) return ''
	const primary = card.primaryMemberTokenId?.trim() ?? ''
	if (primary && Number(primary) > 0) return `M-${padMemberNo(primary)}`
	const legacy = (card.nfts ?? [])
		.map((n) => Number(n.tokenId))
		.filter((n) => Number.isFinite(n) && n > 0)
		.sort((a, b) => b - a)[0]
	if (legacy != null) return `M-${padMemberNo(String(legacy))}`
	return ''
}

export function readBalanceCardList(assets: UIDAssetsResult): ReadBalanceCardItem[] {
	if (Array.isArray(assets.cards) && assets.cards.length > 0) return assets.cards
	if (assets.cardAddress?.trim()) {
		return [
			{
				cardAddress: assets.cardAddress,
				cardName: 'Asset Card',
				points: assets.points ?? '0',
				points6: assets.points6 ?? '0',
				cardCurrency: assets.cardCurrency ?? 'CAD',
				nfts: assets.nfts ?? [],
				primaryMemberTokenId: assets.primaryMemberTokenId,
			},
		]
	}
	return []
}

/** Match iOS `readBalancePosAdminCards` — show terminal program card row when bound. */
export function readBalancePrimaryCard(
	assets: UIDAssetsResult,
	merchantInfraCard: string,
): ReadBalanceCardItem | undefined {
	const list = readBalanceCardList(assets)
	const infra = normAddr(merchantInfraCard)
	if (infra) {
		const hit = list.find((c) => normAddr(c.cardAddress) === infra)
		if (hit) return hit
	}
	return list[0]
}

export function readBalanceHeroAmount(
	primary: ReadBalanceCardItem | undefined,
	assets: UIDAssetsResult,
): number {
	if (primary) {
		const p6 = Number(primary.points6)
		if (Number.isFinite(p6) && p6 > 0) return p6 / 1_000_000
		const p = Number(primary.points)
		if (Number.isFinite(p) && p !== 0) return p
	}
	const a6 = Number(assets.points6)
	if (Number.isFinite(a6) && a6 > 0) return a6 / 1_000_000
	const ap = Number(assets.points)
	if (Number.isFinite(ap) && ap !== 0) return ap
	return 0
}

export function readBalanceCardNameLine(card: ReadBalanceCardItem | undefined): string {
	if (!card?.cardName?.trim()) return '—'
	return card.cardName.replace(/\s+CARD$/i, '').trim() || card.cardName
}

export function parseUIDAssetsResponse(json: unknown): UIDAssetsResult {
	if (!json || typeof json !== 'object') {
		return { ok: false, error: 'Invalid response' }
	}
	const o = json as Record<string, unknown>
	const cardsRaw = o.cards
	const cards = Array.isArray(cardsRaw)
		? cardsRaw
				.map((row) => {
					if (!row || typeof row !== 'object') return null
					const c = row as Record<string, unknown>
					const nftsRaw = c.nfts
					const nfts = Array.isArray(nftsRaw)
						? nftsRaw
								.map((n) => {
									if (!n || typeof n !== 'object') return null
									const x = n as Record<string, unknown>
									return {
										tokenId: String(x.tokenId ?? ''),
										attribute: String(x.attribute ?? ''),
										tier: String(x.tier ?? ''),
									}
								})
								.filter(Boolean)
						: []
					return {
						cardAddress: String(c.cardAddress ?? ''),
						cardName: String(c.cardName ?? ''),
						points: String(c.points ?? '0'),
						points6: String(c.points6 ?? '0'),
						cardCurrency: String(c.cardCurrency ?? ''),
						cardBackground: c.cardBackground != null ? String(c.cardBackground) : undefined,
						cardImage: c.cardImage != null ? String(c.cardImage) : undefined,
						tierName: c.tierName != null ? String(c.tierName) : undefined,
						tierDescription:
							c.tierDescription != null ? String(c.tierDescription) : undefined,
						tierDiscountPercent:
							c.tierDiscountPercent != null ? Number(c.tierDiscountPercent) : undefined,
						chargeRewardPoints6:
							c.chargeRewardPoints6 != null ? String(c.chargeRewardPoints6) : undefined,
						primaryMemberTokenId:
							c.primaryMemberTokenId != null ? String(c.primaryMemberTokenId) : undefined,
						nfts: nfts as ReadBalanceCardItem['nfts'],
					} satisfies ReadBalanceCardItem
				})
				.filter(Boolean) as ReadBalanceCardItem[]
		: undefined

	const parseCouponBalanceRow = (row: unknown): MerchantCouponBalanceItem | null => {
		if (!row || typeof row !== 'object') return null
		const r = row as Record<string, unknown>
		const cardAddress = String(r.cardAddress ?? '').trim()
		const couponId = String(r.couponId ?? '').trim()
		const tokenId = String(r.tokenId ?? '').trim()
		if (!cardAddress || !tokenId) return null
		return {
			cardAddress,
			couponId,
			tokenId,
			title: String(r.title ?? 'Coupon').trim() || 'Coupon',
			balance: String(r.balance ?? '0'),
			requiresRedeemCode: Boolean(r.requiresRedeemCode),
		}
	}

	const parseClaimableRow = (row: unknown): MerchantClaimableCouponItem | null => {
		if (!row || typeof row !== 'object') return null
		const r = row as Record<string, unknown>
		const cardAddress = String(r.cardAddress ?? '').trim()
		const couponId = String(r.couponId ?? '').trim()
		const tokenId = String(r.tokenId ?? '').trim()
		if (!cardAddress || !tokenId) return null
		return {
			cardAddress,
			couponId,
			tokenId,
			title: String(r.title ?? 'Coupon').trim() || 'Coupon',
			requiresRedeemCode: Boolean(r.requiresRedeemCode),
		}
	}

	const merchantCouponBalances = Array.isArray(o.merchantCouponBalances)
		? o.merchantCouponBalances.map(parseCouponBalanceRow).filter(Boolean)
		: undefined
	const merchantClaimableCoupons = Array.isArray(o.merchantClaimableCoupons)
		? o.merchantClaimableCoupons.map(parseClaimableRow).filter(Boolean)
		: undefined

	return {
		ok: Boolean(o.ok ?? true),
		error: o.error != null ? String(o.error) : undefined,
		address: o.address != null ? String(o.address) : undefined,
		aaAddress: o.aaAddress != null ? String(o.aaAddress) : undefined,
		beamioTag: o.beamioTag != null ? String(o.beamioTag) : undefined,
		uid: o.uid != null ? String(o.uid) : undefined,
		tagIdHex: o.tagIdHex != null ? String(o.tagIdHex) : undefined,
		cardAddress: o.cardAddress != null ? String(o.cardAddress) : undefined,
		points: o.points != null ? String(o.points) : undefined,
		points6: o.points6 != null ? String(o.points6) : undefined,
		usdcBalance: o.usdcBalance != null ? String(o.usdcBalance) : undefined,
		caddBalance: o.caddBalance != null ? String(o.caddBalance) : undefined,
		cardCurrency: o.cardCurrency != null ? String(o.cardCurrency) : undefined,
		primaryMemberTokenId:
			o.primaryMemberTokenId != null ? String(o.primaryMemberTokenId) : undefined,
		chargeRewardPoints6:
			o.chargeRewardPoints6 != null ? String(o.chargeRewardPoints6) : undefined,
		posLastTopupAt: o.posLastTopupAt != null ? String(o.posLastTopupAt) : undefined,
		posLastTopupUsdcE6:
			o.posLastTopupUsdcE6 != null ? String(o.posLastTopupUsdcE6) : undefined,
		posLastTopupPointsE6:
			o.posLastTopupPointsE6 != null ? String(o.posLastTopupPointsE6) : undefined,
		cards,
		nfts: Array.isArray(o.nfts)
			? (o.nfts as unknown[])
					.map((n) => {
						if (!n || typeof n !== 'object') return null
						const x = n as Record<string, unknown>
						return {
							tokenId: String(x.tokenId ?? ''),
							attribute: x.attribute != null ? String(x.attribute) : undefined,
							tier: x.tier != null ? String(x.tier) : undefined,
						}
					})
					.filter(Boolean) as ReadBalanceNftItem[]
			: undefined,
		merchantCouponBalances: merchantCouponBalances?.length
			? (merchantCouponBalances as MerchantCouponBalanceItem[])
			: undefined,
		merchantClaimableCoupons: merchantClaimableCoupons?.length
			? (merchantClaimableCoupons as MerchantClaimableCouponItem[])
			: undefined,
	}
}
