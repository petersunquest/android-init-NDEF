import { DEPRECATED_INFRA_CARD, USDC_BASE } from '@/constants'
import type { ReadBalanceCardItem, UIDAssetsResult } from '@/types/pos'

export interface OracleRates {
	usdcad: number
	usdeur: number
	usdjpy: number
	usdcny: number
	usdhkd: number
	usdsgd: number
	usdtwd: number
}

export const DEFAULT_ORACLE: OracleRates = {
	usdcad: 1.35,
	usdeur: 0.92,
	usdjpy: 150,
	usdcny: 7.2,
	usdhkd: 7.8,
	usdsgd: 1.35,
	usdtwd: 31,
}

export function getRateForCurrency(currency: string, oracle: OracleRates): number {
	switch (currency.toUpperCase()) {
		case 'CAD':
			return oracle.usdcad
		case 'USD':
		case 'USDC':
			return 1.0
		case 'EUR':
			return oracle.usdeur
		case 'JPY':
			return oracle.usdjpy
		case 'CNY':
			return oracle.usdcny
		case 'HKD':
			return oracle.usdhkd
		case 'SGD':
			return oracle.usdsgd
		case 'TWD':
			return oracle.usdtwd
		default:
			return oracle.usdcad
	}
}

export function points6ToUsdc6(
	points6: number,
	cardCurrency: string,
	oracle: OracleRates,
): number {
	if (points6 <= 0) return 0
	const rate = getRateForCurrency(cardCurrency, oracle)
	if (rate <= 0) return 0
	return Math.floor(points6 / rate)
}

export function normalizeTierDiscountPercent(v: number): number {
	const c = Math.min(100, Math.max(0, v))
	return Math.round(c * 100) / 100
}

export function tierDiscountBasisPoints(percent: number): number {
	const p = normalizeTierDiscountPercent(percent)
	return Math.min(10_000, Math.max(0, Math.round(p * 100)))
}

export function chargeTotalInCurrency(
	requestAmount: number,
	taxPercent: number,
	tierDiscountPercent: number,
	tipAmount: number,
): number {
	const tax = requestAmount * (taxPercent / 100)
	const p = normalizeTierDiscountPercent(tierDiscountPercent)
	const disc = requestAmount * (p / 100)
	return requestAmount + tax - disc + tipAmount
}

export function chargeTipFromRequestAndBps(requestAmount: number, tipRateBps: number): number {
	const bps = Math.max(0, Math.min(10_000, tipRateBps))
	return requestAmount * (bps / 10_000)
}

export interface ChargeableSplit {
	ccsaPointsWei: number
	infraPointsWei: number
	usdcWei: number
}

function isDeprecatedCardRow(c: ReadBalanceCardItem): boolean {
	const t = (c.cardType ?? '').trim().toLowerCase()
	if (t === 'ccsa') return true
	return c.cardAddress.trim().toLowerCase() === DEPRECATED_INFRA_CARD.toLowerCase()
}

export function chargeableCards(from: UIDAssetsResult, _infraCard: string): ReadBalanceCardItem[] {
	let base: ReadBalanceCardItem[]
	if (from.cards?.length) {
		base = from.cards
	} else if (from.cardAddress?.trim()) {
		base = [
			{
				cardAddress: from.cardAddress,
				cardName: 'Asset Card',
				points: from.points ?? '0',
				points6: from.points6 ?? '0',
				cardCurrency: from.cardCurrency ?? 'CAD',
				nfts: from.nfts ?? [],
				primaryMemberTokenId: from.primaryMemberTokenId,
			},
		]
	} else {
		return []
	}
	return base.filter((c) => !isDeprecatedCardRow(c))
}

export function partitionPointsForMerchantCharge(
	cards: ReadBalanceCardItem[],
	merchantInfraCard: string,
): { unitPricePoints6: number; oracleInfraCards: ReadBalanceCardItem[] } {
	let unitSum = 0
	const oracle: ReadBalanceCardItem[] = []
	const infraKey = merchantInfraCard.trim()
	for (const c of cards) {
		const p = Number(c.points6) || 0
		if (p <= 0) continue
		const t = (c.cardType ?? '').trim().toLowerCase()
		const sameTerminalInfra =
			infraKey &&
			c.cardAddress.trim().toLowerCase() === merchantInfraCard.trim().toLowerCase()
		if (t === 'infrastructure' && !sameTerminalInfra) {
			oracle.push(c)
		} else {
			unitSum += p
		}
	}
	return { unitPricePoints6: unitSum, oracleInfraCards: oracle }
}

export function currencyToFiat6(amount: number): string {
	if (amount <= 0) return '0'
	return String(Math.round(amount * 1_000_000))
}

export function computeChargeContainerSplitFiat6(params: {
	amountFiat6: number
	payCurrency: string
	cardCurrency: string | null | undefined
	pointsUnitPriceInCurrencyE6: number
	ccsaPoints6: number
	infraPoints6: number
	infraCardCurrency: string | null | undefined
	usdcBalance6: number
	oracle: OracleRates
	unitPriceUSDC6Fallback: number
}): ChargeableSplit {
	const {
		payCurrency,
		cardCurrency,
		pointsUnitPriceInCurrencyE6,
		ccsaPoints6,
		infraPoints6,
		infraCardCurrency,
		usdcBalance6,
		oracle,
		unitPriceUSDC6Fallback,
	} = params
	let amountFiat6 = params.amountFiat6
	if (amountFiat6 <= 0) {
		return { ccsaPointsWei: 0, infraPointsWei: 0, usdcWei: 0 }
	}
	const payCur = payCurrency.trim().toUpperCase()
	const cardCur = (cardCurrency ?? '').trim().toUpperCase()
	const priceE6 =
		pointsUnitPriceInCurrencyE6 > 0 ? pointsUnitPriceInCurrencyE6 : unitPriceUSDC6Fallback

	let remainingFiat6 = amountFiat6
	let ccsaPointsWei = 0
	if (ccsaPoints6 > 0 && priceE6 > 0 && cardCur && payCur === cardCur) {
		const needCeil = Math.floor((remainingFiat6 * 1_000_000 + priceE6 - 1) / priceE6)
		ccsaPointsWei = Math.min(needCeil, ccsaPoints6)
		const consumedFiat6 = Math.floor((ccsaPointsWei * priceE6) / 1_000_000)
		remainingFiat6 = Math.max(0, remainingFiat6 - consumedFiat6)
	}

	let infraPointsWei = 0
	const infraCur = (infraCardCurrency ?? '').trim().toUpperCase()
	if (remainingFiat6 > 0 && infraPoints6 > 0 && infraCur) {
		if (infraCur === payCur && priceE6 > 0) {
			const needCeil = Math.floor((remainingFiat6 * 1_000_000 + priceE6 - 1) / priceE6)
			infraPointsWei = Math.min(needCeil, infraPoints6)
			const consumedFiat6 = Math.floor((infraPointsWei * priceE6) / 1_000_000)
			remainingFiat6 = Math.max(0, remainingFiat6 - consumedFiat6)
		} else {
			const payRate = getRateForCurrency(payCur, oracle)
			const infraRate = getRateForCurrency(infraCur, oracle)
			if (payRate > 0 && infraRate > 0) {
				const remainingUsdc6 = Math.floor(remainingFiat6 / payRate)
				const infraValueUsdc6 = points6ToUsdc6(infraPoints6, infraCur, oracle)
				const needUsdc6 = Math.min(remainingUsdc6, infraValueUsdc6)
				infraPointsWei = Math.ceil(needUsdc6 * infraRate)
				infraPointsWei = Math.max(0, Math.min(infraPointsWei, infraPoints6))
				const usedUsdc6 = points6ToUsdc6(infraPointsWei, infraCur, oracle)
				const usedFiat6 = Math.floor(usedUsdc6 * payRate)
				remainingFiat6 = Math.max(0, remainingFiat6 - usedFiat6)
			}
		}
	}

	let usdcWei = 0
	if (remainingFiat6 > 0) {
		const payRate = getRateForCurrency(payCur, oracle)
		if (payRate > 0) {
			usdcWei = Math.ceil(remainingFiat6 / payRate)
			usdcWei = Math.max(0, Math.min(usdcWei, Math.max(0, usdcBalance6)))
		}
	}

	return { ccsaPointsWei, infraPointsWei, usdcWei }
}

export function buildPayItemsFiat6(split: ChargeableSplit, infraCard: string): Array<Record<string, string | number>> {
	const items: Array<Record<string, string | number>> = []
	if (split.usdcWei > 0) {
		items.push({
			kind: 0,
			asset: USDC_BASE,
			amount: String(split.usdcWei),
			tokenId: '0',
			data: '0x',
		})
	}
	if (split.ccsaPointsWei > 0) {
		items.push({
			kind: 1,
			asset: infraCard,
			amount: String(split.ccsaPointsWei),
			tokenId: '0',
			data: '0x',
		})
	}
	if (split.infraPointsWei > 0) {
		items.push({
			kind: 1,
			asset: infraCard,
			amount: String(split.infraPointsWei),
			tokenId: '0',
			data: '0x',
		})
	}
	return items
}

export function mergeInfraKind1Items(
	items: Array<Record<string, string | number>>,
	infraCard: string,
): Array<Record<string, string | number>> {
	let usdc: Record<string, string | number> | null = null
	let infraSum = 0
	const others: Array<Record<string, string | number>> = []
	const infraLower = infraCard.trim().toLowerCase()
	for (const it of items) {
		const kind = Number(it.kind) || 0
		const asset = String(it.asset ?? '')
		if (kind === 0) {
			usdc = it
			continue
		}
		if (kind === 1 && asset.toLowerCase() === infraLower) {
			infraSum += Math.max(0, Number(it.amount) || 0)
		} else {
			others.push(it)
		}
	}
	const out: Array<Record<string, string | number>> = []
	if (usdc) out.push(usdc)
	if (infraSum > 0) {
		out.push({
			kind: 1,
			asset: infraCard,
			amount: String(infraSum),
			tokenId: '0',
			data: '0x',
		})
	}
	out.push(...others)
	return out.length ? out : items
}

export interface MetadataTierRow {
	chainTierIndex?: number
	/** Metadata `index` when present (on-chain tier index). */
	index?: number
	name?: string
	description?: string
	discountPercent?: number
	backgroundColor?: string
	image?: string
	/** On-chain tier floor (points6 units). Membership-fee mode: 1, 2, 3… */
	minUsdc6?: string
	membershipFeeE6?: string
	membershipFee?: string
	membershipDurationKind?: number
}

export function parseMetadataTierRows(metadataTiersArray: unknown[]): MetadataTierRow[] {
	const out: MetadataTierRow[] = []
	for (const rowAny of metadataTiersArray) {
		if (!rowAny || typeof rowAny !== 'object') continue
		const row = rowAny as Record<string, unknown>
		const chainTierIndex =
			typeof row.chainTierIndex === 'number'
				? row.chainTierIndex
				: Number(row.chainTierIndex) || undefined
		const indexRaw = row.index != null ? Number(row.index) : NaN
		const index = Number.isFinite(indexRaw) ? Math.trunc(indexRaw) : undefined
		const name = String(row.name ?? row.tierName ?? '').trim() || undefined
		const description = String(row.description ?? '').trim() || undefined
		let discountPercent: number | undefined
		if (row.discountPercent != null) {
			if (typeof row.discountPercent === 'number') {
				discountPercent = normalizeTierDiscountPercent(row.discountPercent)
			} else {
				discountPercent = normalizeTierDiscountPercent(Number(row.discountPercent) || 0)
			}
		}
		const backgroundColor = String(row.backgroundColor ?? row.backgroundColorHex ?? '').trim() || undefined
		const image = String(row.image ?? row.imageUrl ?? '').trim() || undefined
		let membershipFeeE6: string | undefined
		if (row.membershipFeeE6 != null && String(row.membershipFeeE6).trim() !== '') {
			try {
				membershipFeeE6 = BigInt(String(row.membershipFeeE6).replace(/,/g, '').trim()).toString()
			} catch {
				membershipFeeE6 = undefined
			}
		}
		const membershipFee =
			row.membershipFee != null && String(row.membershipFee).trim() !== ''
				? String(row.membershipFee).replace(/,/g, '').trim()
				: undefined
		let minUsdc6: string | undefined
		if (row.minUsdc6 != null && String(row.minUsdc6).trim() !== '') {
			try {
				const m = BigInt(String(row.minUsdc6).replace(/,/g, '').trim())
				if (m > 0n) minUsdc6 = m.toString()
			} catch {
				minUsdc6 = undefined
			}
		}
		const durationRaw =
			row.membershipDurationKind != null ? Number(row.membershipDurationKind) : NaN
		const membershipDurationKind =
			Number.isFinite(durationRaw) && durationRaw >= 1 && durationRaw <= 6
				? Math.trunc(durationRaw)
				: undefined
		out.push({
			chainTierIndex,
			index,
			name,
			description,
			discountPercent,
			backgroundColor,
			image,
			minUsdc6,
			membershipFeeE6,
			membershipFee,
			membershipDurationKind,
		})
	}
	return out
}

/** Human fee → E6 string; empty/invalid → "0". */
export function membershipFeeHumanToE6(raw: string | number | undefined | null): string {
	if (raw == null || raw === '') return '0'
	const s = String(raw).replace(/,/g, '').trim()
	if (!s) return '0'
	const n = Number(s)
	if (!Number.isFinite(n) || n <= 0) return '0'
	return String(Math.round(n * 1e6))
}

export function membershipFeeE6ToHuman(e6: string | number | undefined | null): string {
	if (e6 == null || e6 === '') return ''
	try {
		const bi = BigInt(String(e6).replace(/,/g, '').trim() || '0')
		if (bi <= 0n) return ''
		const whole = bi / 1000000n
		const frac = bi % 1000000n
		if (frac === 0n) return whole.toString()
		const fracStr = frac.toString().padStart(6, '0').replace(/0+$/, '')
		return `${whole}.${fracStr}`
	} catch {
		return ''
	}
}

export function metadataTierMembershipFeeE6(row: MetadataTierRow): string {
	if (row.membershipFeeE6 && BigInt(row.membershipFeeE6) > 0n) return row.membershipFeeE6
	return membershipFeeHumanToE6(row.membershipFee)
}

export function metadataTiersHaveMembershipFee(tiers: MetadataTierRow[]): boolean {
	return tiers.some((t) => BigInt(metadataTierMembershipFeeE6(t)) > 0n)
}

export function membershipDurationLabel(kind: number | undefined): string {
	switch (kind) {
		case 1:
			return 'Day'
		case 2:
			return 'Week'
		case 3:
			return 'Month'
		case 4:
			return 'Quarter'
		case 5:
			return 'Year'
		case 6:
			return 'Forever'
		default:
			return ''
	}
}

/** Prefer metadata `index`, then `chainTierIndex`, else array position. */
export function metadataTierOnChainIndex(row: MetadataTierRow, fallbackIndex: number): number {
	if (typeof row.index === 'number' && Number.isFinite(row.index)) return Math.trunc(row.index)
	if (typeof row.chainTierIndex === 'number' && Number.isFinite(row.chainTierIndex)) {
		return Math.trunc(row.chainTierIndex)
	}
	return fallbackIndex
}

function chainTierIndexCandidates(nft: { tier?: string; tokenId: string }): number[] {
	const out: number[] = []
	const tier = (nft.tier ?? '').trim()
	if (tier) {
		const n = Number(tier)
		if (Number.isFinite(n)) out.push(n)
		const m = tier.match(/chain-tier-(\d+)/i)
		if (m) out.push(Number(m[1]))
	}
	return [...new Set(out)]
}

function firstPercentInDescription(text?: string): number | null {
	const t = (text ?? '').trim()
	if (!t) return null
	const m = t.match(/(\d+(?:\.\d+)?)\s*%/)
	if (!m) return null
	return normalizeTierDiscountPercent(Number(m[1]) || 0)
}

function discountPercentFromMetadataRow(row: MetadataTierRow): number {
	if (row.discountPercent != null) return normalizeTierDiscountPercent(row.discountPercent)
	return firstPercentInDescription(row.description) ?? 0
}

export function selectMetadataTierForPrimaryMembership(
	card: ReadBalanceCardItem,
	tiers: MetadataTierRow[],
): MetadataTierRow | null {
	if (!tiers.length) return null
	let primaryTid: string | undefined
	const p = (card.primaryMemberTokenId ?? '').trim()
	if (p && (Number(p) || 0) > 0) {
		primaryTid = p
	} else {
		const best = [...(card.nfts ?? [])]
			.filter((n) => (Number(n.tokenId) || 0) > 0)
			.sort((a, b) => (Number(b.tokenId) || 0) - (Number(a.tokenId) || 0))[0]
		if (best && (Number(best.tokenId) || 0) > 0) primaryTid = best.tokenId
	}
	if (!primaryTid) return null
	const primaryNft = (card.nfts ?? []).find(
		(n) => n.tokenId === primaryTid || n.tokenId.toLowerCase() === primaryTid!.toLowerCase(),
	)
	if (!primaryNft) return null
	for (const idx of chainTierIndexCandidates(primaryNft)) {
		const row = tiers.find((t) => t.chainTierIndex === idx)
		if (row) return row
	}
	const tierLabel = (primaryNft.tier ?? '').trim()
	if (tierLabel && !/chain-tier-\d+/i.test(tierLabel) && Number.isNaN(Number(tierLabel))) {
		const row = tiers.find((t) => (t.name ?? '').toLowerCase() === tierLabel.toLowerCase())
		if (row) return row
	}
	return null
}

export function pickTierDiscountPercentFromAssets(
	assets: UIDAssetsResult,
	tierKeyToDiscount: Record<string, number>,
): number {
	if (!Object.keys(tierKeyToDiscount).length) return 0
	const keys = new Set<string>()
	for (const c of assets.cards ?? []) {
		for (const n of c.nfts ?? []) {
			const t = (n.tier ?? '').trim()
			if (t) {
				keys.add(t)
				keys.add(t.toLowerCase())
			}
		}
	}
	for (const n of assets.nfts ?? []) {
		const t = (n.tier ?? '').trim()
		if (t) {
			keys.add(t)
			keys.add(t.toLowerCase())
		}
	}
	let best = 0
	for (const k of keys) {
		if (tierKeyToDiscount[k] != null) best = Math.max(best, tierKeyToDiscount[k]!)
		if (tierKeyToDiscount[k.toLowerCase()] != null) {
			best = Math.max(best, tierKeyToDiscount[k.toLowerCase()]!)
		}
	}
	for (const k of keys) {
		const idx = Number(k)
		if (Number.isFinite(idx)) {
			const v = tierKeyToDiscount[`chain-tier-${idx}`.toLowerCase()]
			if (v != null) best = Math.max(best, v)
		}
	}
	return normalizeTierDiscountPercent(best)
}

function normalizeMetadataBackgroundHex(raw?: string): string | undefined {
	const t = (raw ?? '').trim()
	if (!t) return undefined
	return t.startsWith('#') ? t : `#${t.replace(/^#/, '')}`
}

/** iOS `BeamioPaymentRouting.mergePrimaryTierStyleFromCardMetadata`. */
export function mergePrimaryTierStyleFromCardMetadata(
	card: ReadBalanceCardItem,
	tiers: MetadataTierRow[],
): ReadBalanceCardItem {
	if (!tiers.length) return card
	const row = selectMetadataTierForPrimaryMembership(card, tiers)
	if (!row) return card
	const bg = normalizeMetadataBackgroundHex(row.backgroundColor)
	const img = row.image?.trim() || undefined
	let bgOut = card.cardBackground
	let imgOut = card.cardImage
	if (bg) bgOut = bg
	if (img) imgOut = img
	if (bgOut === card.cardBackground && imgOut === card.cardImage) return card
	return { ...card, cardBackground: bgOut, cardImage: imgOut }
}

export function pickChargeTierDiscountPercent(params: {
	paymentCard: ReadBalanceCardItem | undefined
	assets: UIDAssetsResult
	discountByTierKey: Record<string, number>
	metadataTiers: MetadataTierRow[]
	metadataTiersFromApi: boolean
}): number {
	const addr = params.paymentCard?.cardAddress.trim() ?? ''
	if (addr && params.paymentCard && params.metadataTiersFromApi) {
		const row = selectMetadataTierForPrimaryMembership(params.paymentCard, params.metadataTiers)
		if (row) return discountPercentFromMetadataRow(row)
	}
	return pickTierDiscountPercentFromAssets(params.assets, params.discountByTierKey)
}

export function postPaymentBalanceCad(
	assets: UIDAssetsResult,
	oracle: OracleRates,
	_infraCard: string,
	_useInfraCardRow: boolean,
): number | null {
	if (!assets.ok) return null
	const usdcBalance6 = Math.round((Number(assets.usdcBalance ?? '0') || 0) * 1_000_000)
	let cardsValueUsdc6 = 0
	if (assets.cards?.length) {
		for (const card of assets.cards) {
			cardsValueUsdc6 += points6ToUsdc6(Number(card.points6) || 0, card.cardCurrency, oracle)
		}
	} else {
		cardsValueUsdc6 += points6ToUsdc6(Number(assets.points6) || 0, assets.cardCurrency ?? 'CAD', oracle)
	}
	const totalUsdc6 = usdcBalance6 + cardsValueUsdc6
	const cad = (totalUsdc6 / 1_000_000) * oracle.usdcad
	return Number.isFinite(cad) ? cad : null
}
