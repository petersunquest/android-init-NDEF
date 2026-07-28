import { parseHexColor, readBalancePassHeroPalette } from '@/utils/readBalanceDisplay'

export interface CouponTicketTone {
	gradientStart: string
	gradientEnd: string
	primaryText: string
	secondaryText: string
	borderColor: string
	iconBackdrop: string
	overlayTopOpacity: number
	overlayBottomOpacity: number
}

function hashSeed(seed: string): number {
	let hash = 5381
	for (let i = 0; i < seed.length; i++) {
		hash = ((hash << 5) + hash + seed.charCodeAt(i)) | 0
	}
	return Math.abs(hash)
}

function hsvToHex(h: number, s: number, v: number): string {
	const i = Math.floor(h * 6)
	const f = h * 6 - i
	const p = v * (1 - s)
	const q = v * (1 - f * s)
	const t = v * (1 - (1 - f) * s)
	let r = 0
	let g = 0
	let b = 0
	switch (i % 6) {
		case 0:
			r = v
			g = t
			b = p
			break
		case 1:
			r = q
			g = v
			b = p
			break
		case 2:
			r = p
			g = v
			b = t
			break
		case 3:
			r = p
			g = q
			b = v
			break
		case 4:
			r = t
			g = p
			b = v
			break
		default:
			r = v
			g = p
			b = q
	}
	const toHex = (n: number) =>
		Math.round(n * 255)
			.toString(16)
			.padStart(2, '0')
	return `#${toHex(r)}${toHex(g)}${toHex(b)}`.toUpperCase()
}

/** iOS `readBalanceBizCouponTicketTonePack` / `readBalanceCouponTone` */
export function couponTicketToneFromHex(
	backgroundColorHex: string | undefined,
	seed: string,
): CouponTicketTone {
	const startHex =
		parseHexColor(backgroundColorHex) ?? hsvToHex((hashSeed(seed) % 360) / 360, 0.58, 0.62)
	const palette = readBalancePassHeroPalette(startHex)
	const dark = palette.primaryText.includes('0,0,0')
	return {
		gradientStart: palette.gradientStart,
		gradientEnd: palette.gradientEnd,
		primaryText: palette.primaryText,
		secondaryText: palette.secondaryText,
		borderColor: dark ? 'rgba(0,0,0,0.12)' : 'rgba(255,255,255,0.14)',
		iconBackdrop: dark ? 'rgba(255,255,255,0.35)' : 'rgba(0,0,0,0.25)',
		overlayTopOpacity: dark ? 0.06 : 0.18,
		overlayBottomOpacity: dark ? 0.1 : 0.3,
	}
}
