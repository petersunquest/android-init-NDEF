import type { PosLedgerItem } from '@/utils/posLedgerMetrics'
import {
	beamioCurrencyCodeForCurrencyFiat,
	isHiddenInternalLedgerCategory,
	preferredLedgerDisplayAmount,
	tipRowMatchesChargeParent,
} from '@/utils/posLedgerMetrics'

export interface PosTransactionTipAmount {
	value: number
	currencyCode: string
}

/** Display row after tip nesting + top-up bonus merge (iOS `POSLedgerDisplayItem`). */
export interface PosLedgerDisplayItem {
	tx: PosLedgerItem
	tips: PosLedgerItem[]
	embeddedTip: PosTransactionTipAmount | null
	topupMergedTotal: PosTransactionTipAmount | null
	topupBonus: PosTransactionTipAmount | null
	topupLatestTimestamp: number | null
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

function topupFinishedHash(tx: PosLedgerItem): string | null {
	for (const h of displayJsonHashes(tx.displayJson, ['finishedHash', 'baseRelayTxHash'])) {
		const n = normalizeBytes32HexLower(h)
		if (n) return n
	}
	return null
}

function topupPaymentLeg(tx: PosLedgerItem): string {
	try {
		const obj = JSON.parse(tx.displayJson) as Record<string, unknown>
		return String(obj.topupPaymentLeg ?? '')
			.trim()
			.toLowerCase()
	} catch {
		return ''
	}
}

function parseTopupRechargeBonusNote(tx: PosLedgerItem): { actual: number; bonus: number } | null {
	const note = tx.note?.trim()
	if (!note) return null
	try {
		const obj = JSON.parse(note) as Record<string, unknown>
		const actual6 = Number(String(obj.actualPaymentCurrencyFiat6 ?? '0'))
		const bonus6 = Number(String(obj.rechargeBonusCurrencyFiat6 ?? '0'))
		if (!Number.isFinite(actual6) || !Number.isFinite(bonus6) || bonus6 <= 0) return null
		return { actual: actual6 / 1_000_000, bonus: bonus6 / 1_000_000 }
	} catch {
		return null
	}
}

function parseEmbeddedTip(from: PosLedgerItem): PosTransactionTipAmount | null {
	try {
		const obj = JSON.parse(from.displayJson) as Record<string, unknown>
		const breakdown = obj.chargeBreakdown as Record<string, unknown> | undefined
		if (!breakdown) return null
		const rawTip = String(breakdown.tipCurrencyAmount ?? '')
			.replace(/,/g, '')
			.trim()
		const tip = Number(rawTip)
		if (!Number.isFinite(tip) || tip <= 0) return null
		const currency = String(breakdown.requestCurrency ?? '')
			.trim()
			.toUpperCase()
		return { value: tip, currencyCode: currency || 'CAD' }
	} catch {
		return null
	}
}

function mergeTopupRechargeBonusRows(items: PosLedgerItem[]): PosLedgerDisplayItem[] {
	const topups = items.filter((it) => it.type === 'topUp')
	const groups = new Map<string, PosLedgerItem[]>()
	for (const tx of topups) {
		const key = topupFinishedHash(tx)
		if (!key || key === tx.id.toLowerCase()) continue
		const list = groups.get(key) ?? []
		list.push(tx)
		groups.set(key, list)
	}

	const replacement = new Map<string, PosLedgerDisplayItem>()
	const suppressed = new Set<string>()

	for (const group of groups.values()) {
		if (group.length < 2) continue
		const bonusRows = group.filter((tx) => topupPaymentLeg(tx) === 'bonus')
		if (bonusRows.length === 0) continue
		const primary = group.find((tx) => topupPaymentLeg(tx) !== 'bonus')
		if (!primary) continue
		const note = group.map(parseTopupRechargeBonusNote).find(Boolean)
		const currency = preferredLedgerDisplayAmount(primary).currencyCode
		const bonusValue =
			note?.bonus ??
			bonusRows.reduce((sum, row) => sum + preferredLedgerDisplayAmount(row).value, 0)
		if (bonusValue <= 0.000_001) continue
		const actualValue = note?.actual ?? preferredLedgerDisplayAmount(primary).value
		const total = actualValue + bonusValue
		replacement.set(primary.id.toLowerCase(), {
			tx: primary,
			tips: [],
			embeddedTip: null,
			topupMergedTotal: { value: total, currencyCode: currency },
			topupBonus: { value: bonusValue, currencyCode: currency },
			topupLatestTimestamp: Math.max(...group.map((g) => g.timestamp)),
		})
		for (const row of bonusRows) {
			if (row.id.toLowerCase() !== primary.id.toLowerCase()) {
				suppressed.add(row.id.toLowerCase())
			}
		}
	}

	if (replacement.size === 0 && suppressed.size === 0) {
		return items.map((tx) => ({
			tx,
			tips: [],
			embeddedTip: null,
			topupMergedTotal: null,
			topupBonus: null,
			topupLatestTimestamp: null,
		}))
	}

	return items.flatMap((tx) => {
		const key = tx.id.toLowerCase()
		if (suppressed.has(key)) return []
		return [
			replacement.get(key) ?? {
				tx,
				tips: [],
				embeddedTip: null,
				topupMergedTotal: null,
				topupBonus: null,
				topupLatestTimestamp: null,
			},
		]
	})
}

/** Merge tips under charges + top-up bonus rows (iOS `POSLedgerDisplayItem.merged`). */
export function mergePosLedgerDisplayItems(rawItems: PosLedgerItem[]): PosLedgerDisplayItem[] {
	const visibleItems = mergeTopupRechargeBonusRows(
		rawItems.filter((it) => !isHiddenInternalLedgerCategory(it.txCategory)),
	)
	const tips = visibleItems.map((it) => it.tx).filter((it) => it.type === 'tip')
	const absorbedTipIds = new Set<string>()
	const out: PosLedgerDisplayItem[] = []

	for (const base of visibleItems) {
		if (base.tx.type === 'tip') continue
		const tx = base.tx
		let matchedTips: PosLedgerItem[] = []
		if (tx.type === 'charge') {
			matchedTips = tips.filter((tip) => tipRowMatchesChargeParent(tip, tx))
			for (const tip of matchedTips) absorbedTipIds.add(tip.id.toLowerCase())
		}
		out.push({
			tx,
			tips: matchedTips,
			embeddedTip:
				tx.type === 'charge' && matchedTips.length === 0 ? parseEmbeddedTip(tx) : null,
			topupMergedTotal: base.topupMergedTotal,
			topupBonus: base.topupBonus,
			topupLatestTimestamp: base.topupLatestTimestamp,
		})
	}

	for (const tip of tips) {
		if (!absorbedTipIds.has(tip.id.toLowerCase())) {
			out.push({
				tx: tip,
				tips: [],
				embeddedTip: null,
				topupMergedTotal: null,
				topupBonus: null,
				topupLatestTimestamp: null,
			})
		}
	}

	out.sort((a, b) => {
		const ta = a.topupLatestTimestamp ?? a.tx.timestamp
		const tb = b.topupLatestTimestamp ?? b.tx.timestamp
		if (ta !== tb) return tb - ta
		return b.tx.id.localeCompare(a.tx.id)
	})
	return out
}

export function posTransactionRelativeTime(timestamp: number): string {
	if (timestamp <= 0) return '—'
	const nowSec = Date.now() / 1000
	const diff = nowSec - timestamp
	if (diff < 60 * 60) return `${Math.max(1, Math.floor(diff / 60))}m ago`
	if (diff < 24 * 60 * 60) return `${Math.floor(diff / 3600)}h ago`
	if (diff < 48 * 60 * 60) return 'Yesterday'
	const d = new Date(timestamp * 1000)
	const month = d.toLocaleString('en-US', { month: 'short' })
	const day = d.getDate()
	const hh = String(d.getHours()).padStart(2, '0')
	const mm = String(d.getMinutes()).padStart(2, '0')
	return `${month} ${day}, ${hh}:${mm}`
}

export function posTransactionSecondaryLine(tx: PosLedgerItem): string {
	if (tx.type === 'tip') {
		if (tx.note?.trim()) return tx.note.trim()
		const trimmed = tx.payer.trim()
		if (!trimmed || trimmed.toLowerCase() === '0x0000000000000000000000000000000000000000') {
			return 'Member'
		}
		return trimmed.length >= 10 ? `${trimmed.slice(0, 6)}…${trimmed.slice(-4)}` : trimmed
	}
	const method = (tx.paymentMethodLabel ?? '').trim()
	const tagRaw = (tx.payerBeamioTag ?? '').trim()
	let who: string
	if (tagRaw) {
		who = `@${tagRaw}`
	} else {
		const counterparty = tx.payer.trim()
		if (
			!counterparty ||
			counterparty.toLowerCase() === '0x0000000000000000000000000000000000000000'
		) {
			who = tx.type === 'topUp' ? 'Wallet' : 'Customer'
		} else {
			who =
				counterparty.length >= 10
					? `${counterparty.slice(0, 6)}…${counterparty.slice(-4)}`
					: counterparty
		}
	}
	if (!method) return who
	if (tx.type === 'couponClaim' || tx.type === 'couponRedeem') {
		return who
	}
	return `${who} · ${method}`
}

export { beamioCurrencyCodeForCurrencyFiat, preferredLedgerDisplayAmount }
