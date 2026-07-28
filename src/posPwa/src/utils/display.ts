const CODE_PREFIX: Record<string, string> = {
	CAD: 'CA$',
	USD: '$',
	USDC: '$',
	EUR: '€',
	JPY: 'JP¥',
	TWD: 'NT$',
	CNY: 'CN¥',
	HKD: 'HK$',
	SGD: 'SG$',
}

export function displayFiatPrefixFromCode(raw: string | undefined | null, fallback = 'CAD'): string {
	const c = (raw ?? fallback).trim().toUpperCase()
	return CODE_PREFIX[c] ?? `${c} `
}

export function formatAmount(n: number, decimals = 2): string {
	if (!Number.isFinite(n)) return '—'
	return n.toLocaleString(undefined, {
		minimumFractionDigits: decimals,
		maximumFractionDigits: decimals,
	})
}

export function formatDashboardCurrency(amount: number | null, currency: string, loaded: boolean): string {
	if (!loaded && amount == null) return '—'
	if (amount == null) return '—'
	return `${displayFiatPrefixFromCode(currency)}${formatAmount(amount)}`
}

export function formatBUnitDisplay(value: number | null, loaded: boolean): string {
	if (!loaded && value == null) return '—'
	if (value == null) return '—'
	return Number(value).toFixed(2)
}

export function shortAddress(addr: string): string {
	const t = addr.trim()
	if (t.length < 10) return t
	return `${t.slice(0, 6)}…${t.slice(-4)}`
}

export function walletShortLine(addr: string): string {
	return shortAddress(addr)
}

export function dicebearAvatarUrl(seed: string): string {
	const enc = encodeURIComponent(seed || 'Beamio')
	return `https://api.dicebear.com/8.x/fun-emoji/png?seed=${enc}`
}

export function profileDisplayName(p: {
	first_name?: string
	last_name?: string
	firstName?: string
	lastName?: string
	accountName?: string
	username?: string
}): string {
	const f = (p.first_name ?? p.firstName ?? '').trim()
	let lastRaw = (p.last_name ?? p.lastName ?? '').trim()
	const lastLine = lastRaw.split(/\r?\n/)[0]?.trim() ?? ''
	const l = lastLine.startsWith('{') ? '' : lastLine.trim()
	const both = `${f} ${l}`.trim()
	if (both) return both
	return (p.accountName ?? p.username ?? '').trim()
}

export function profileBeamioTag(p: {
	accountName?: string
	username?: string
}): string {
	return (p.accountName ?? p.username ?? '').trim()
}
