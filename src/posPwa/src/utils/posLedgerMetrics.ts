/** Cluster `/api/posLedger` row — aligned with iOS `PosLedgerItem`. */
export type PosLedgerItemKind = 'charge' | 'topUp' | 'tip' | 'couponClaim' | 'couponRedeem'

export interface PosLedgerItem {
	id: string
	originalPaymentHash?: string
	type: PosLedgerItemKind
	txCategory: string
	timestamp: number
	payer: string
	payee: string
	amountUSDC6: string
	amountFiat6: string
	currencyFiat: number
	displayJson: string
	topAdmin?: string
	subordinate?: string
	note?: string
	/** Cluster-enriched payer `@beamioTag` without `@`. */
	payerBeamioTag?: string
	/** `USDC` / `Card` / `Cash` / `Bonus` for top-up/charge rows. */
	paymentMethodLabel?: string
}

export interface PosLedgerTerminalResetMarker {
	txId: string
	timestamp: number
	payer: string
}

export interface PosLedgerSnapshot {
	topUpFromClear6: string
	chargeFromClear6: string
	items: PosLedgerItem[]
	lastTerminalReset: PosLedgerTerminalResetMarker | null
}

export interface PosHomeLedgerStats {
	/** Gross charge + tips (Total Due on home). */
	charge: number
	topUp: number
	tips: number
	chargeUsdc: number
	tipsUsdc: number
}

const HIDDEN_INTERNAL_CATEGORIES = new Set([
	'0x02d119b2041653c3b6f7aef339e2560da8ba867b022a04aaa150d062e5212bb7',
	'0x7067fa2b19fb81129d35576ad5fe635356a1405044d1c080a5ab341df6445776',
])

function coerceAtomicString(v: unknown): string {
	if (typeof v === 'string') return v.trim() || '0'
	if (typeof v === 'number' && Number.isFinite(v)) return String(Math.trunc(v))
	return '0'
}

function coerceInt64(v: unknown): number {
	if (typeof v === 'number' && Number.isFinite(v)) return Math.trunc(v)
	if (typeof v === 'string') {
		const n = Number(v.trim())
		return Number.isFinite(n) ? Math.trunc(n) : 0
	}
	return 0
}

function atomic6ToNumber(raw: string): number {
	const n = Number(raw.trim())
	if (!Number.isFinite(n)) return 0
	return n / 1_000_000
}

export function isHiddenInternalLedgerCategory(cat: string): boolean {
	return HIDDEN_INTERNAL_CATEGORIES.has(cat.trim().toLowerCase())
}

/** BeamioCurrencyType int → ISO code (iOS `beamioCurrencyCodeForCurrencyFiat`). */
export function beamioCurrencyCodeForCurrencyFiat(id: number): string {
	switch (id) {
		case 1:
			return 'USD'
		case 2:
			return 'JPY'
		case 3:
			return 'CNY'
		case 4:
			return 'USDC'
		case 5:
			return 'HKD'
		case 6:
			return 'EUR'
		case 7:
			return 'SGD'
		case 8:
			return 'TWD'
		default:
			return 'CAD'
	}
}

export interface LedgerDisplayAmount {
	value: number
	currencyCode: string
}

export function preferredLedgerDisplayAmount(tx: PosLedgerItem): LedgerDisplayAmount {
	if (tx.type === 'couponClaim' || tx.type === 'couponRedeem') {
		return { value: 0, currencyCode: beamioCurrencyCodeForCurrencyFiat(tx.currencyFiat) }
	}
	const fiat6 = Number(tx.amountFiat6)
	const usdc6 = Number(tx.amountUSDC6)
	if (Number.isFinite(fiat6) && fiat6 > 0) {
		return {
			value: fiat6 / 1_000_000,
			currencyCode: beamioCurrencyCodeForCurrencyFiat(tx.currencyFiat),
		}
	}
	return {
		value: Number.isFinite(usdc6) ? usdc6 / 1_000_000 : 0,
		currencyCode: 'USDC',
	}
}

function isHiddenCategory(cat: string): boolean {
	return isHiddenInternalLedgerCategory(cat)
}

function normalizeBytes32HexLower(raw: string | undefined): string | null {
	if (!raw) return null
	let s = raw.trim()
	if (!s) return null
	if (!s.startsWith('0x') && /^[0-9a-fA-F]{64}$/.test(s)) s = `0x${s}`
	if (!/^0x[0-9a-fA-F]{64}$/.test(s)) return null
	const lower = s.toLowerCase()
	return lower === `0x${'0'.repeat(64)}` ? null : lower
}

function displayJsonHashes(displayJson: string, keys: string[]): string[] {
	try {
		const obj = JSON.parse(displayJson) as Record<string, unknown>
		return keys
			.map((k) => obj[k])
			.filter((v): v is string => typeof v === 'string' && v.trim().length > 0)
	} catch {
		return []
	}
}

function chargeParentKeys(tx: PosLedgerItem): Set<string> {
	const out = new Set<string>()
	for (const k of [tx.id, tx.originalPaymentHash, ...displayJsonHashes(tx.displayJson, [
		'finishedHash',
		'baseRelayTxHash',
		'requestHash',
		'originalPaymentHash',
	])]) {
		const n = normalizeBytes32HexLower(k)
		if (n) out.add(n)
	}
	return out
}

function tipParentLinkKeys(tx: PosLedgerItem): Set<string> {
	const out = new Set<string>()
	for (const k of [tx.originalPaymentHash, ...displayJsonHashes(tx.displayJson, [
		'finishedHash',
		'originalPaymentHash',
		'baseRelayTxHash',
	])]) {
		const n = normalizeBytes32HexLower(k)
		if (n) out.add(n)
	}
	return out
}

export function tipRowMatchesChargeParent(tip: PosLedgerItem, charge: PosLedgerItem): boolean {
	const tipKeys = tipParentLinkKeys(tip)
	if (tipKeys.size === 0) return false
	const chargeKeys = chargeParentKeys(charge)
	for (const k of tipKeys) {
		if (chargeKeys.has(k)) return true
	}
	return false
}

function preferredLedgerDisplay(tx: PosLedgerItem): number {
	return preferredLedgerDisplayAmount(tx).value
}

function usdcAmount(tx: PosLedgerItem): number {
	const usdc6 = Number(tx.amountUSDC6)
	return Number.isFinite(usdc6) ? usdc6 / 1_000_000 : 0
}

function isExplicitUsdcAccountingCurrency(tx: PosLedgerItem): boolean {
	return tx.currencyFiat === 4
}

function parseEmbeddedTipDisplayAmount(tx: PosLedgerItem): number | null {
	try {
		const obj = JSON.parse(tx.displayJson) as Record<string, unknown>
		const breakdown = obj.chargeBreakdown as Record<string, unknown> | undefined
		if (!breakdown) return null
		const rawTip = String(breakdown.tipCurrencyAmount ?? '')
			.replace(/,/g, '')
			.trim()
		const tip = Number(rawTip)
		return Number.isFinite(tip) && tip > 0 ? tip : null
	} catch {
		return null
	}
}

function grossChargeRowDisplayTotal(charge: PosLedgerItem, matchedTips: PosLedgerItem[]): number {
	const base = preferredLedgerDisplay(charge)
	let tipSum = 0
	if (matchedTips.length === 0) {
		tipSum = parseEmbeddedTipDisplayAmount(charge) ?? 0
	} else {
		for (const t of matchedTips) tipSum += preferredLedgerDisplay(t)
	}
	return base + tipSum
}

export function itemsInTerminalStatsPeriod(snapshot: PosLedgerSnapshot): PosLedgerItem[] {
	const marker = snapshot.lastTerminalReset
	if (!marker) return snapshot.items
	return snapshot.items.filter((it) => it.timestamp > marker.timestamp)
}

function tipsDisplayTotal(items: PosLedgerItem[]): number {
	const visible = items.filter((it) => !isHiddenCategory(it.txCategory))
	const charges = visible.filter((it) => it.type === 'charge')
	const tips = visible.filter((it) => it.type === 'tip')
	const absorbed = new Set<string>()
	let total = 0

	for (const charge of charges) {
		const matched = tips.filter((tip) => tipRowMatchesChargeParent(tip, charge))
		if (matched.length === 0) {
			total += parseEmbeddedTipDisplayAmount(charge) ?? 0
		} else {
			for (const tip of matched) {
				absorbed.add(tip.id.toLowerCase())
				total += preferredLedgerDisplay(tip)
			}
		}
	}
	for (const tip of tips) {
		if (!absorbed.has(tip.id.toLowerCase())) total += preferredLedgerDisplay(tip)
	}
	return total
}

function chargeAndTipGrossDisplayTotal(items: PosLedgerItem[]): number {
	const visible = items.filter((it) => !isHiddenCategory(it.txCategory))
	const charges = visible.filter((it) => it.type === 'charge')
	const tips = visible.filter((it) => it.type === 'tip')
	const absorbed = new Set<string>()
	let gross = 0
	for (const charge of charges) {
		const matched = tips.filter((tip) => tipRowMatchesChargeParent(tip, charge))
		for (const t of matched) absorbed.add(t.id.toLowerCase())
		gross += grossChargeRowDisplayTotal(charge, matched)
	}
	for (const tip of tips) {
		if (!absorbed.has(tip.id.toLowerCase())) gross += preferredLedgerDisplay(tip)
	}
	return gross
}

function topUpDisplayTotal(items: PosLedgerItem[]): number {
	let sum = 0
	for (const tx of items) {
		if (tx.type !== 'topUp') continue
		if (isHiddenCategory(tx.txCategory)) continue
		sum += preferredLedgerDisplay(tx)
	}
	return sum
}

function tipsUsdcSettlementTotal(items: PosLedgerItem[]): number {
	const visible = items.filter((it) => !isHiddenCategory(it.txCategory))
	const charges = visible.filter((it) => it.type === 'charge')
	const tips = visible.filter((it) => it.type === 'tip')
	const absorbed = new Set<string>()
	let total = 0
	for (const charge of charges) {
		const matched = tips.filter((tip) => tipRowMatchesChargeParent(tip, charge))
		for (const tip of matched) {
			absorbed.add(tip.id.toLowerCase())
			if (isExplicitUsdcAccountingCurrency(tip)) total += usdcAmount(tip)
		}
	}
	for (const tip of tips) {
		if (!absorbed.has(tip.id.toLowerCase()) && isExplicitUsdcAccountingCurrency(tip)) {
			total += usdcAmount(tip)
		}
	}
	return total
}

function chargeUsdcSettlementTotal(items: PosLedgerItem[]): number {
	let usdcSum = 0
	for (const tx of items) {
		if (tx.type !== 'charge' || isHiddenCategory(tx.txCategory)) continue
		let title = ''
		try {
			const obj = JSON.parse(tx.displayJson) as Record<string, unknown>
			title = String(obj.title ?? '').trim().toLowerCase()
		} catch {
			/* ignore */
		}
		if (title.includes('terminal settlement') || title === 'aa to eoa') continue
		if (title === 'usdc merchant charge') {
			const usdc = usdcAmount(tx)
			if (usdc > 0) usdcSum += usdc
		}
	}
	return usdcSum
}

/** Parse trusted `/api/posLedger` JSON (iOS `fetchPosLedger`). */
export function parsePosLedgerResponse(body: unknown): PosLedgerSnapshot | null {
	if (!body || typeof body !== 'object') return null
	const root = body as Record<string, unknown>
	if (root.ok !== true) return null
	const fromClear = (root.fromClear as Record<string, unknown> | undefined) ?? {}
	const topUp6 = coerceAtomicString(fromClear.topUp6 ?? '0')
	const charge6 = coerceAtomicString(fromClear.charge6 ?? '0')
	const rawItems = Array.isArray(root.items) ? root.items : []
	const items: PosLedgerItem[] = []
	for (const raw of rawItems) {
		if (!raw || typeof raw !== 'object') continue
		const row = raw as Record<string, unknown>
		const id = String(row.id ?? '').trim()
		const typeRaw = String(row.type ?? '').trim()
		if (
			!id ||
			(typeRaw !== 'charge' &&
				typeRaw !== 'topUp' &&
				typeRaw !== 'tip' &&
				typeRaw !== 'couponClaim' &&
				typeRaw !== 'couponRedeem')
		) {
			continue
		}
		const noteRaw = String(row.note ?? '').trim()
		const tagRaw = String(row.payerBeamioTag ?? '').trim()
		const methodRaw = String(row.paymentMethodLabel ?? '').trim()
		items.push({
			id,
			originalPaymentHash: String(row.originalPaymentHash ?? '').trim() || undefined,
			type: typeRaw as PosLedgerItemKind,
			txCategory: String(row.txCategory ?? ''),
			timestamp: coerceInt64(row.timestamp),
			payer: String(row.payer ?? ''),
			payee: String(row.payee ?? ''),
			amountUSDC6: coerceAtomicString(row.amountUSDC6),
			amountFiat6: coerceAtomicString(row.amountFiat6),
			currencyFiat: coerceInt64(row.currencyFiat),
			displayJson: String(row.displayJson ?? ''),
			topAdmin: String(row.topAdmin ?? '').trim() || undefined,
			subordinate: String(row.subordinate ?? '').trim() || undefined,
			note: noteRaw || undefined,
			payerBeamioTag: tagRaw || undefined,
			paymentMethodLabel: methodRaw || undefined,
		})
	}
	items.sort((a, b) => b.timestamp - a.timestamp)
	let lastTerminalReset: PosLedgerTerminalResetMarker | null = null
	const rawReset = root.lastTerminalReset
	if (rawReset && typeof rawReset === 'object') {
		const r = rawReset as Record<string, unknown>
		const txId = String(r.txId ?? '').trim()
		const ts = coerceInt64(r.timestamp)
		if (txId && ts >= 0) {
			lastTerminalReset = {
				txId,
				timestamp: ts,
				payer: String(r.payer ?? ''),
			}
		}
	}
	return {
		topUpFromClear6: topUp6,
		chargeFromClear6: charge6,
		items,
		lastTerminalReset,
	}
}

/** Home dashboard KPIs — mirror iOS `POSViewModel.refreshHomeProfiles` ledger branch. */
export function computeHomeStatsFromPosLedger(snapshot: PosLedgerSnapshot): PosHomeLedgerStats {
	const window = itemsInTerminalStatsPeriod(snapshot)
	return {
		charge: chargeAndTipGrossDisplayTotal(window),
		topUp: topUpDisplayTotal(window),
		tips: tipsDisplayTotal(window),
		chargeUsdc: chargeUsdcSettlementTotal(window),
		tipsUsdc: tipsUsdcSettlementTotal(window),
	}
}

export { atomic6ToNumber }
