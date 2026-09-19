/** Discover Gift brand chrome (copied from SilentPassUI GiftSheet L709–759). */

export const GIFT_BRAND_FALLBACK = '#2c2416'

export type GiftBrandCssVars = Record<string, string>

function shareMetadataRoot(meta: Record<string, unknown>): Record<string, unknown> | null {
	const share = meta.shareTokenMetadata
	if (share && typeof share === 'object') return share as Record<string, unknown>
	return null
}

function discoverSafeCssColor(raw: string | null | undefined): string | null {
	if (raw == null || typeof raw !== 'string') return null
	const t = raw.trim()
	if (!t) return null
	if (/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(t)) return t
	if (/^rgba?\(/i.test(t)) return t
	return null
}

function discoverParseCssRgb(color: string): { r: number; g: number; b: number } | null {
	const t = color.trim()
	const hex = t.match(/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i)
	if (hex) {
		let h = hex[1]
		if (h.length === 3) h = h.split('').map((c) => c + c).join('')
		if (h.length === 8) h = h.slice(0, 6)
		return {
			r: parseInt(h.slice(0, 2), 16),
			g: parseInt(h.slice(2, 4), 16),
			b: parseInt(h.slice(4, 6), 16),
		}
	}
	const rgb = t.match(/^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/i)
	if (rgb) {
		return { r: Number(rgb[1]), g: Number(rgb[2]), b: Number(rgb[3]) }
	}
	return null
}

function discoverMixCssColorWithWhite(color: string, whiteAmount: number): string | null {
	const rgb = discoverParseCssRgb(color)
	if (!rgb) return null
	const t = Math.min(1, Math.max(0, whiteAmount))
	const r = Math.round(rgb.r + (255 - rgb.r) * t)
	const g = Math.round(rgb.g + (255 - rgb.g) * t)
	const b = Math.round(rgb.b + (255 - rgb.b) * t)
	return `rgb(${r}, ${g}, ${b})`
}

function discoverMixCssColorWithBlack(color: string, blackAmount: number): string | null {
	const rgb = discoverParseCssRgb(color)
	if (!rgb) return null
	const t = Math.min(1, Math.max(0, blackAmount))
	const r = Math.round(rgb.r * (1 - t))
	const g = Math.round(rgb.g * (1 - t))
	const b = Math.round(rgb.b * (1 - t))
	return `rgb(${r}, ${g}, ${b})`
}

function discoverContrastTextOnBrand(color: string): '#ffffff' | '#111827' {
	const rgb = discoverParseCssRgb(color)
	if (!rgb) return '#ffffff'
	const L = (0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b) / 255
	return L > 0.62 ? '#111827' : '#ffffff'
}

function parseDiscoverCardBrandColor(meta: Record<string, unknown> | null | undefined): string | null {
	if (meta == null) return null
	const share = shareMetadataRoot(meta)
	const raw =
		meta.backgroundColor ??
		meta.background_color ??
		share?.backgroundColor ??
		share?.background_color
	return typeof raw === 'string' && raw.trim() ? discoverSafeCssColor(raw) : null
}

function parseDiscoverTierBackgroundColor(tier: unknown): string | null {
	if (tier == null || typeof tier !== 'object') return null
	const o = tier as Record<string, unknown>
	const nested =
		o.properties != null && typeof o.properties === 'object'
			? (o.properties as Record<string, unknown>)
			: null
	const bgRaw =
		o.backgroundColor ?? o.background_color ?? nested?.backgroundColor ?? nested?.background_color
	return typeof bgRaw === 'string' && bgRaw.trim() ? discoverSafeCssColor(bgRaw) : null
}

function discoverMetadataTiers(meta: Record<string, unknown> | null | undefined): unknown[] | null {
	if (!meta) return null
	if (Array.isArray(meta.tiers) && meta.tiers.length > 0) return meta.tiers
	const share = shareMetadataRoot(meta)
	if (share && Array.isArray(share.tiers) && share.tiers.length > 0) return share.tiers
	return null
}

function parseDiscoverHighestTierBackground(
	meta: Record<string, unknown> | null | undefined,
): string | null {
	const raw = discoverMetadataTiers(meta)
	if (!raw) return null
	let bestMin = -1n
	let bestBg: string | null = null
	for (const item of raw) {
		if (item == null || typeof item !== 'object') continue
		const o = item as Record<string, unknown>
		const minRaw = o.minUsdc6 ?? o.min_usdc6
		let minUsdc6 = 0n
		try {
			if (typeof minRaw === 'bigint') minUsdc6 = minRaw
			else if (typeof minRaw === 'number' && Number.isFinite(minRaw)) minUsdc6 = BigInt(Math.trunc(minRaw))
			else if (typeof minRaw === 'string' && minRaw.trim()) minUsdc6 = BigInt(minRaw.trim())
		} catch {
			minUsdc6 = 0n
		}
		const bg = parseDiscoverTierBackgroundColor(item)
		if (minUsdc6 > bestMin) {
			bestMin = minUsdc6
			bestBg = bg
		} else if (minUsdc6 === bestMin && bg) {
			bestBg = bg
		}
	}
	return bestBg
}

/** Card-level backgroundColor, then tiers[0], then highest minUsdc6 tier. */
export function parseGiftMerchantBrandColor(
	meta: Record<string, unknown> | null | undefined,
): string | null {
	const cardLevel = parseDiscoverCardBrandColor(meta)
	if (cardLevel) return cardLevel
	const tiers = discoverMetadataTiers(meta)
	const first = tiers?.length ? parseDiscoverTierBackgroundColor(tiers[0]) : null
	if (first) return first
	return parseDiscoverHighestTierBackground(meta)
}

export function resolveGiftBrandColor(
	meta: Record<string, unknown> | null | undefined,
	primaryOverride?: string | null,
): string {
	const safeOverride = primaryOverride ? discoverSafeCssColor(primaryOverride) : null
	if (safeOverride) return safeOverride
	return parseGiftMerchantBrandColor(meta) ?? GIFT_BRAND_FALLBACK
}

/** CSS custom properties for gift shell (maps GiftSheet inline brand tokens). */
export function buildGiftBrandCssVars(primaryColor: string): GiftBrandCssVars {
	const brandColor = discoverSafeCssColor(primaryColor) ?? GIFT_BRAND_FALLBACK
	const brandControl = discoverMixCssColorWithBlack(brandColor, 0.14) ?? brandColor
	const onBrandText = discoverContrastTextOnBrand(brandColor)
	const onBrandMuted =
		onBrandText === '#ffffff' ? 'rgba(255,255,255,0.75)' : 'rgba(17,24,39,0.72)'

	const brandRgb = discoverParseCssRgb(brandColor)
	const brandShadow = brandRgb
		? `0 8px 28px rgba(${brandRgb.r}, ${brandRgb.g}, ${brandRgb.b}, 0.28)`
		: '0 8px 28px rgba(15, 23, 42, 0.18)'

	const controlRgb = discoverParseCssRgb(brandControl)
	const brandControlShadow = controlRgb
		? `0 4px 16px rgba(${controlRgb.r}, ${controlRgb.g}, ${controlRgb.b}, 0.22)`
		: '0 4px 16px rgba(15, 23, 42, 0.16)'

	const brandTint = discoverMixCssColorWithWhite(brandControl, 0.82) ?? '#eeedf3'
	const brandSoftTint = discoverMixCssColorWithWhite(brandColor, 0.93) ?? brandTint
	const brandMuted = discoverMixCssColorWithWhite(brandControl, 0.42) ?? '#9aa3b2'
	const brandSaved = discoverMixCssColorWithBlack(brandControl, 0.18) ?? brandControl
	const brandPointsTrack = discoverMixCssColorWithBlack(brandControl, 0.28) ?? brandControl
	const brandSwitchOff = discoverMixCssColorWithWhite(brandControl, 0.55) ?? '#cbd5e1'
	const brandSelectedRing = `${brandControlShadow}, 0 0 0 2px ${brandControl}`

	return {
		'--brand-color': brandColor,
		'--brand-control': brandControl,
		'--brand-on-text': onBrandText,
		'--brand-on-muted': onBrandMuted,
		'--brand-shadow': brandShadow,
		'--brand-control-shadow': brandControlShadow,
		'--brand-tint': brandTint,
		'--brand-soft-tint': brandSoftTint,
		'--brand-muted': brandMuted,
		'--brand-saved': brandSaved,
		'--brand-points-track': brandPointsTrack,
		'--brand-switch-off': brandSwitchOff,
		'--brand-selected-ring': brandSelectedRing,
	}
}
