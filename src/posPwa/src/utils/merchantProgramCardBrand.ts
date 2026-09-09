import { parseHexColor } from '@/utils/readBalanceDisplay'

/** Factory / Start Kit swirl hashes — not merchant branding. */
const FACTORY_DEFAULT_IMAGE_HASHES = [
	'44e7a175e57a337bf5d0a98deb19a0a545e362d504092a7af1aecd58798eab',
	'6022e4efb44990767d1faa1642f570ed8a49ab0417b370aaae35f84884061c97',
	'3e94721678833790ab22c27fd80d2206c90847094c7a7331513aff361f0c83e5',
] as const

export function isFactoryDefaultMerchantAssetUrl(url: string | undefined): boolean {
	const raw = (url ?? '').trim().toLowerCase()
	if (!raw) return false
	const hexOnly = raw.replace(/[^0-9a-f]/g, '')
	return FACTORY_DEFAULT_IMAGE_HASHES.some((hash) => raw.includes(hash) || hexOnly.includes(hash))
}

function asRecord(raw: unknown): Record<string, unknown> | null {
	if (raw && typeof raw === 'object' && !Array.isArray(raw)) return raw as Record<string, unknown>
	return null
}

function readTrimmed(raw: unknown): string {
	return typeof raw === 'string' ? raw.trim() : ''
}

function firstNonFactoryUrl(...candidates: Array<string | undefined>): string | undefined {
	for (const raw of candidates) {
		const url = (raw ?? '').trim()
		if (url && !isFactoryDefaultMerchantAssetUrl(url)) return url
	}
	return undefined
}

function firstTierBackgroundColor(meta: Record<string, unknown>): string | undefined {
	const tiers = meta.tiers
	if (!Array.isArray(tiers)) return undefined
	for (const item of tiers) {
		const row = asRecord(item)
		const hex =
			parseHexColor(readTrimmed(row?.backgroundColor) || readTrimmed(row?.background_color))
		if (hex) return hex
	}
	return undefined
}

export type MerchantProgramCardBrand = {
	brandColor?: string
	logoUrl?: string
	cardName?: string
}

/** Card-level brand chrome. Prefer metadata icon; never Discover merchantImage. */
export function pickMerchantProgramCardBrand(params: {
	assetBackground?: string
	assetImage?: string
	metadata?: Record<string, unknown> | null
}): MerchantProgramCardBrand {
	const meta = params.metadata ?? null
	const share = asRecord(meta?.shareTokenMetadata)
	const brandColor =
		parseHexColor(params.assetBackground) ??
		parseHexColor(readTrimmed(meta?.backgroundColor) || readTrimmed(meta?.background_color)) ??
		parseHexColor(readTrimmed(share?.backgroundColor) || readTrimmed(share?.background_color)) ??
		(meta ? firstTierBackgroundColor(meta) : undefined)

	const logoUrl = firstNonFactoryUrl(
		readTrimmed(meta?.icon),
		readTrimmed(share?.icon),
		readTrimmed(share?.logoUrl),
		readTrimmed(share?.logo),
		params.assetImage,
	)

	const cardName = readTrimmed(meta?.name) || readTrimmed(share?.name) || undefined

	return {
		...(brandColor ? { brandColor } : {}),
		...(logoUrl ? { logoUrl } : {}),
		...(cardName ? { cardName } : {}),
	}
}

function hexToRgb(hex: string): { r: number; g: number; b: number } {
	const h = hex.replace('#', '')
	return {
		r: Number.parseInt(h.slice(0, 2), 16),
		g: Number.parseInt(h.slice(2, 4), 16),
		b: Number.parseInt(h.slice(4, 6), 16),
	}
}

function mixWithWhite(hex: string, brandRatio: number): string {
	const { r, g, b } = hexToRgb(hex)
	const mix = (c: number) => Math.round(c * brandRatio + 255 * (1 - brandRatio))
	const toHex = (n: number) => n.toString(16).padStart(2, '0')
	return `#${toHex(mix(r))}${toHex(mix(g))}${toHex(mix(b))}`
}

function relativeLuminance(hex: string): number {
	const { r, g, b } = hexToRgb(hex)
	const lin = (c: number) => {
		const n = c / 255
		return n <= 0.03928 ? n / 12.92 : ((n + 0.055) / 1.055) ** 2.4
	}
	return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}

export type MerchantProgramCardRowChrome = {
	background: string
	border: string
	selectedBorder: string
	selectedRing: string
	name: string
	muted: string
	amount: string
	logoBackdrop: string
	letter: string
}

const NEUTRAL_CHROME: MerchantProgramCardRowChrome = {
	background: '#ffffff',
	border: '#e2e8f0',
	selectedBorder: '#1562f0',
	selectedRing: 'rgba(21, 98, 240, 0.20)',
	name: '#0f172a',
	muted: '#64748b',
	amount: '#0f172a',
	logoBackdrop: '#e2e8f0',
	letter: '#1562f0',
}

export function merchantProgramCardRowChrome(brandHex?: string): MerchantProgramCardRowChrome {
	const hex = parseHexColor(brandHex)
	if (!hex) return NEUTRAL_CHROME
	const { r, g, b } = hexToRgb(hex)
	return {
		background: mixWithWhite(hex, 0.18),
		border: mixWithWhite(hex, 0.42),
		selectedBorder: hex,
		selectedRing: `rgba(${r}, ${g}, ${b}, 0.22)`,
		name: '#0f172a',
		muted: '#475569',
		amount: '#0f172a',
		logoBackdrop: hex,
		letter: relativeLuminance(hex) > 0.55 ? '#0f172a' : '#ffffff',
	}
}

export function merchantProgramCardLetter(cardName: string): string {
	const letter = cardName.replace(/[^A-Za-z0-9\u4e00-\u9fff]/g, '').charAt(0)
	return (letter || '?').toUpperCase()
}
