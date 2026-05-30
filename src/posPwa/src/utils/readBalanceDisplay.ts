import type { ReadBalanceCardItem, UIDAssetsResult } from '@/types/pos'
import { displayFiatPrefixFromCode, formatAmount, shortAddress } from '@/utils/display'
import { memberNoFromCard, readBalancePrimaryCard } from '@/utils/readBalanceAssets'

export interface ReadBalanceMoneyParts {
	prefix: string
	mid: string
	suffix: string
}

/** iOS `readBalanceFormatMoney` */
export function readBalanceFormatMoney(amount: number, currency: string): ReadBalanceMoneyParts {
	const mid = formatAmount(amount)
	const c = currency.trim().toUpperCase()
	const prefix = displayFiatPrefixFromCode(c, '')
	const suffix = c === 'USDC' ? ' USDC' : ''
	return { prefix: prefix.trim(), mid, suffix }
}

export function readBalanceFormatUsdcThousands(amount: number): string {
	return formatAmount(amount)
}

/** iOS `readBalancePassHeroMemberDisplayName` */
export function readBalancePassHeroMemberDisplayName(
	assets: UIDAssetsResult,
	primary: ReadBalanceCardItem | undefined,
): string {
	let tag = assets.beamioTag?.trim() ?? ''
	if (tag.startsWith('@')) tag = tag.slice(1)
	if (tag) return tag
	const addr = assets.address?.trim() ?? ''
	if (addr.startsWith('0x') && addr.length >= 10) return shortAddress(addr)
	const rawName = primary?.cardName?.trim()
	if (rawName) {
		const n = rawName.replace(/\s+CARD$/i, '').replace(/\s+Card$/i, '').trim()
		if (
			n &&
			n.toLowerCase() !== 'infrastructure card' &&
			n.toLowerCase() !== 'asset card'
		) {
			return n
		}
	}
	return 'Member'
}

function discountPercentFromDescription(text: string | undefined): number | null {
	const t = text?.trim()
	if (!t) return null
	const m = t.match(/(\d+(?:\.\d+)?)\s*%/i)
	if (!m) return null
	const v = Number(m[1])
	if (!Number.isFinite(v)) return null
	return Math.min(100, Math.max(0, Math.round(v * 100) / 100))
}

/** iOS `readBalanceTierDiscountPercent` */
export function readBalanceTierDiscountPercent(card: ReadBalanceCardItem | undefined): number | null {
	if (!card) return null
	if (card.tierDiscountPercent != null && card.tierDiscountPercent > 0) {
		return card.tierDiscountPercent
	}
	return discountPercentFromDescription(card.tierDescription)
}

export function beamioTierDiscountPercentLabel(percent: number): string {
	const r = Math.min(100, Math.max(0, Math.round(percent * 100) / 100))
	return r.toFixed(2)
}

/** iOS `readBalanceHeroCardBackgroundHex` */
export function readBalanceHeroCardBackgroundHex(
	assets: UIDAssetsResult,
	primary: ReadBalanceCardItem | undefined,
	merchantInfraCard: string,
): string | undefined {
	const bg = primary?.cardBackground?.trim()
	if (bg) return bg
	const infra = merchantInfraCard.trim().toLowerCase()
	if (infra && assets.cards?.length) {
		for (const c of assets.cards) {
			if (c.cardAddress.trim().toLowerCase() === infra) {
				const rowBg = c.cardBackground?.trim()
				if (rowBg) return rowBg
				break
			}
		}
	}
	if (assets.cards?.length === 1) {
		return assets.cards[0]?.cardBackground?.trim() || undefined
	}
	return undefined
}

export function readBalanceLastTopUpFallbackLine(assets: UIDAssetsResult): string {
	const iso = assets.posLastTopupAt?.trim() ?? ''
	if (iso) {
		const t = iso.replace('T', ' ').trim()
		return t.slice(0, 16).trim() || '—'
	}
	return '—'
}

/** NFT #2 charge-reward pts amount (Check Balance hero / success). */
export function readBalancePointRewardPtsAmount(
	primary: ReadBalanceCardItem | undefined,
	assets: UIDAssetsResult,
	pointSystemEnabled: boolean,
): string | null {
	if (!pointSystemEnabled) return null
	const raw =
		primary?.chargeRewardPoints6?.trim() ??
		assets.chargeRewardPoints6?.trim() ??
		'0'
	const reward6 = Number(raw)
	const amount = Number.isFinite(reward6) ? reward6 / 1_000_000 : 0
	return readBalanceFormatUsdcThousands(amount)
}

/** @deprecated Prefer `readBalancePointRewardPtsAmount` + pts row UI. */
export function readBalancePointRewardSubtitle(
	primary: ReadBalanceCardItem | undefined,
	assets: UIDAssetsResult,
	pointSystemEnabled: boolean,
): string | null {
	const pts = readBalancePointRewardPtsAmount(primary, assets, pointSystemEnabled)
	return pts != null ? `${pts} pts` : null
}

export function parseHexColor(raw: string | undefined | null): string | null {
	let s = raw?.trim() ?? ''
	if (!s) return null
	if (s.startsWith('#')) s = s.slice(1)
	if (s.length !== 6 && s.length !== 8) return null
	if (!/^[0-9a-fA-F]+$/.test(s)) return null
	return `#${s.slice(0, 6).toUpperCase()}`
}

function hexToRgb(hex: string): { r: number; g: number; b: number } {
	const h = hex.replace('#', '')
	return {
		r: parseInt(h.slice(0, 2), 16) / 255,
		g: parseInt(h.slice(2, 4), 16) / 255,
		b: parseInt(h.slice(4, 6), 16) / 255,
	}
}

function relativeLuminance(r: number, g: number, b: number): number {
	const lin = (c: number) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4)
	return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}

function darkerShade(hex: string): string {
	const { r, g, b } = hexToRgb(hex)
	const max = Math.max(r, g, b)
	const min = Math.min(r, g, b)
	const l = (max + min) / 2
	const target = Math.max(0.12, l * 0.76)
	const scale = l > 0 ? target / l : 0.76
	const nr = Math.min(1, Math.max(0, r * scale))
	const ng = Math.min(1, Math.max(0, g * scale))
	const nb = Math.min(1, Math.max(0, b * scale))
	const toHex = (v: number) => Math.round(v * 255).toString(16).padStart(2, '0')
	return `#${toHex(nr)}${toHex(ng)}${toHex(nb)}`.toUpperCase()
}

export interface ReadBalancePassHeroPalette {
	gradientStart: string
	gradientEnd: string
	primaryText: string
	secondaryText: string
	tertiaryText: string
	decorativeCircle: string
	avatarBorder: string
	avatarBackdrop: string
	walletIconTint: string
}

const DEFAULT_START = '#1562F0'

export function readBalancePassHeroPalette(tierCardBackgroundHex: string | undefined): ReadBalancePassHeroPalette {
	const startHex = parseHexColor(tierCardBackgroundHex) ?? DEFAULT_START
	const endHex = darkerShade(startHex)
	const { r, g, b } = hexToRgb(startHex)
	const lum = relativeLuminance(r, g, b)
	const darkForeground = lum > 0.55
	return {
		gradientStart: startHex,
		gradientEnd: endHex,
		primaryText: darkForeground ? 'rgba(0,0,0,0.84)' : '#ffffff',
		secondaryText: darkForeground ? 'rgba(0,0,0,0.72)' : 'rgba(255,255,255,0.9)',
		tertiaryText: darkForeground ? 'rgba(0,0,0,0.62)' : 'rgba(255,255,255,0.78)',
		decorativeCircle: darkForeground ? 'rgba(0,0,0,0.06)' : 'rgba(255,255,255,0.12)',
		avatarBorder: darkForeground ? 'rgba(0,0,0,0.12)' : 'rgba(255,255,255,0.35)',
		avatarBackdrop: darkForeground ? 'rgba(255,255,255,0.35)' : 'rgba(0,0,0,0.25)',
		walletIconTint: darkForeground ? 'rgba(0,0,0,0.45)' : 'rgba(255,255,255,0.85)',
	}
}

export function readBalanceResultViewModel(
	assets: UIDAssetsResult,
	merchantInfraCard: string,
	pointSystemEnabled: boolean,
) {
	const primary = readBalancePrimaryCard(assets, merchantInfraCard)
	const memberDisplay = readBalancePassHeroMemberDisplayName(assets, primary)
	const tierName = primary?.tierName?.trim() || null
	const tierDiscount = readBalanceTierDiscountPercent(primary)
	const programLine = primary?.cardName
		? primary.cardName.replace(/\s+CARD$/i, '').replace(/\s+Card$/i, '').trim() || '—'
		: '—'
	const bgHex = readBalanceHeroCardBackgroundHex(assets, primary, merchantInfraCard)
	const balCurrency = primary?.cardCurrency || assets.cardCurrency || 'CAD'
	const balNum =
		primary?.points6 && Number(primary.points6) > 0
			? Number(primary.points6) / 1_000_000
			: primary?.points && Number(primary.points) !== 0
				? Number(primary.points)
				: assets.points6 && Number(assets.points6) > 0
					? Number(assets.points6) / 1_000_000
					: Number(assets.points ?? 0)
	const balanceParts = readBalanceFormatMoney(balNum, balCurrency)
	const rewardPtsAmount = readBalancePointRewardPtsAmount(primary, assets, pointSystemEnabled)
	const rewardSubtitle = rewardPtsAmount != null ? `${rewardPtsAmount} pts` : null
	const usdcBal = Number(assets.usdcBalance ?? '0')
	const caddBalRaw = assets.caddBalance?.trim()
	const caddBal = caddBalRaw != null && caddBalRaw !== '' ? Number(caddBalRaw) : null
	return {
		primary,
		memberDisplay,
		memberNo: memberNoFromCard(primary) || (() => {
			const p = assets.primaryMemberTokenId?.trim() ?? ''
			if (p && Number(p) > 0) return `M-${p.padStart(6, '0')}`
			return ''
		})(),
		tierName,
		tierDiscount,
		programLine,
		bgHex,
		balanceParts,
		rewardPtsAmount,
		rewardSubtitle,
		balCurrency,
		usdcBal: Number.isFinite(usdcBal) ? usdcBal : 0,
		caddBal: caddBal != null && Number.isFinite(caddBal) ? caddBal : null,
		cardImageUrl: primary?.cardImage?.trim() || null,
	}
}
