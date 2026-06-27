/**
 * Beamio profile locale + display currency — single source of truth (Consumer PWA).
 * Mirror in bizSite / posPwa; do not cross-import between subprojects.
 * See `.cursor/rules/beamio-profile-locale-currency-protocol.mdc`
 */

export type BeamioUiLocale = 'en' | 'zh-CN'

export type BeamioDisplayCurrency =
	| 'CAD'
	| 'USD'
	| 'JPY'
	| 'CNY'
	| 'USDC'
	| 'HKD'
	| 'EUR'
	| 'SGD'
	| 'TWD'

export type BeamioProfileLocaleSetup = {
	language: BeamioUiLocale
	currency: BeamioDisplayCurrency
	tax: string
	/** Set true when persisted to chain via lastName JSON block */
	localeConfigured?: boolean
}

const DISPLAY_CURRENCIES: readonly BeamioDisplayCurrency[] = [
	'CAD',
	'USD',
	'JPY',
	'CNY',
	'USDC',
	'HKD',
	'EUR',
	'SGD',
	'TWD',
]

const EURO_REGIONS = new Set([
	'AT',
	'BE',
	'CY',
	'DE',
	'EE',
	'ES',
	'FI',
	'FR',
	'GR',
	'IE',
	'IT',
	'LT',
	'LU',
	'LV',
	'MT',
	'NL',
	'PT',
	'SI',
	'SK',
])

export function normalizeBeamioUiLocale(raw: unknown): BeamioUiLocale {
	if (raw === 'en' || raw === 'zh-CN') return raw
	return 'en'
}

export function normalizeBeamioDisplayCurrency(raw: unknown): BeamioDisplayCurrency {
	const code = String(raw ?? '')
		.trim()
		.toUpperCase()
	if ((DISPLAY_CURRENCIES as readonly string[]).includes(code)) {
		return code as BeamioDisplayCurrency
	}
	return 'USD'
}

export function detectBrowserBeamioLocale(): BeamioUiLocale {
	if (typeof navigator === 'undefined') return 'en'
	const tag = (navigator.language || navigator.languages?.[0] || 'en').toLowerCase()
	if (tag.startsWith('zh')) return 'zh-CN'
	return 'en'
}

export function detectBrowserDefaultCurrency(language?: BeamioUiLocale): BeamioDisplayCurrency {
	if (typeof navigator === 'undefined') return 'USD'
	const tag = (navigator.language || 'en-US').trim()
	const lower = tag.toLowerCase()
	const region = tag.split('-')[1]?.toUpperCase()

	if (region) {
		if (region === 'CA') return 'CAD'
		if (region === 'US') return 'USD'
		if (region === 'JP') return 'JPY'
		if (region === 'CN') return 'CNY'
		if (region === 'HK') return 'HKD'
		if (region === 'SG') return 'SGD'
		if (region === 'TW') return 'TWD'
		if (EURO_REGIONS.has(region)) return 'EUR'
	}

	if (lower.startsWith('ja')) return 'JPY'
	if (lower.startsWith('zh-hk')) return 'HKD'
	if (lower.startsWith('zh-tw') || lower.startsWith('zh-hant-tw')) return 'TWD'
	if (lower.startsWith('zh')) return 'CNY'
	if (lower.startsWith('en-ca')) return 'CAD'

	if (language === 'zh-CN') return 'CNY'
	return 'USD'
}

export function buildBrowserLocaleCurrencyDefaults(): BeamioProfileLocaleSetup {
	const language = detectBrowserBeamioLocale()
	return {
		language,
		currency: detectBrowserDefaultCurrency(language),
		tax: '0',
		localeConfigured: true,
	}
}

export function parseBeamioAddedSetupFromRegistryLastName(registryLastName: string): {
	displayLastName: string
	setup: BeamioProfileLocaleSetup | null
} {
	const raw = registryLastName || ''
	const parts = raw.split('\r\n')
	if (parts.length < 2) {
		return { displayLastName: raw, setup: null }
	}
	try {
		const parsed = JSON.parse(parts[parts.length - 1]) as Partial<BeamioProfileLocaleSetup>
		if (!parsed || typeof parsed !== 'object') {
			return { displayLastName: parts[0] ?? raw, setup: null }
		}
		const setup: BeamioProfileLocaleSetup = {
			language: normalizeBeamioUiLocale(parsed.language),
			currency: normalizeBeamioDisplayCurrency(parsed.currency),
			tax: String(parsed.tax ?? '0'),
			localeConfigured: parsed.localeConfigured !== false,
		}
		return {
			displayLastName: parts.slice(0, -1).join('\r\n') || parts[0] || '',
			setup,
		}
	} catch {
		return { displayLastName: parts[0] ?? raw, setup: null }
	}
}

export function hasProfileLocaleCurrencyOnChain(registryLastName: string | undefined): boolean {
	return parseBeamioAddedSetupFromRegistryLastName(registryLastName || '').setup !== null
}

export function buildLocaleCurrencySetupPayload(beamio: {
	language: unknown
	currency: unknown
	tax?: string
}): BeamioProfileLocaleSetup {
	return {
		language: normalizeBeamioUiLocale(beamio.language),
		currency: normalizeBeamioDisplayCurrency(beamio.currency),
		tax: String(beamio.tax ?? '0'),
		localeConfigured: true,
	}
}

/** Registry `lastName` wire format: display segment + CRLF + JSON setup block */
export function encodeRegistryLastNameWithLocaleSetup(
	displayLastName: string,
	setup: BeamioProfileLocaleSetup,
): string {
	const payload = buildLocaleCurrencySetupPayload(setup)
	return `${displayLastName}\r\n${JSON.stringify(payload)}`
}
