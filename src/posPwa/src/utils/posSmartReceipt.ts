import type { PosLedgerDisplayItem } from '@/utils/posLedgerDisplay'
import {
	beamioCurrencyCodeForCurrencyFiat,
	preferredLedgerDisplayAmount,
} from '@/utils/posLedgerDisplay'
import type { PosLedgerItem } from '@/utils/posLedgerMetrics'
import { displayFiatPrefixFromCode, formatAmount } from '@/utils/display'

const ZERO_HASH = `0x${'0'.repeat(64)}`

export interface PosReceiptBreakdownRow {
	label: string
	value: string
	discount?: boolean
}

export interface PosReceiptRouteLine {
	title: string
	sub: string
	amount: number
}

function normalizeBytes32HexLower(raw: string | undefined | null): string | null {
	if (!raw) return null
	let s = raw.trim()
	if (!s) return null
	if (!s.startsWith('0x') && /^[0-9a-fA-F]{64}$/.test(s)) s = `0x${s}`
	if (!/^0x[0-9a-fA-F]{64}$/.test(s)) return null
	const lower = s.toLowerCase()
	return lower === ZERO_HASH ? null : lower
}

export function parsePosLedgerDisplayJson(displayJson: string): Record<string, unknown> | null {
	try {
		if (!displayJson.trim()) return null
		return JSON.parse(displayJson) as Record<string, unknown>
	} catch {
		return null
	}
}

/** biz `resolveTxDisplayRowBaseScanTxHash` — POS ledger row. */
export function resolvePosLedgerBaseScanTxHash(tx: PosLedgerItem): string {
	const obj = parsePosLedgerDisplayJson(tx.displayJson)
	const fromDisplay = [
		obj?.finishedHash,
		obj?.baseRelayTxHash,
		obj?.requestHash,
	]
		.map((v) => (typeof v === 'string' ? normalizeBytes32HexLower(v) : null))
		.find(Boolean)
	if (fromDisplay) return fromDisplay
	const oph = normalizeBytes32HexLower(tx.originalPaymentHash)
	if (oph) return oph
	return normalizeBytes32HexLower(tx.id) ?? ''
}

export function formatPosReceiptDateTime(timestamp: number): { dateStr: string; timeStr: string } {
	if (timestamp <= 0) return { dateStr: '—', timeStr: '' }
	const d = new Date(timestamp * 1000)
	const dateStr = d.toLocaleString('en-US', {
		month: 'short',
		day: 'numeric',
		year: 'numeric',
	})
	const timeStr = d
		.toLocaleString('en-US', { hour: 'numeric', minute: '2-digit', hour12: true })
		.toLowerCase()
	return { dateStr, timeStr }
}

export function posReceiptBadge(item: PosLedgerDisplayItem): string {
	const { tx } = item
	if (tx.type === 'charge') return 'Charge'
	if (tx.type === 'topUp') return 'Top-up'
	return 'Tip'
}

export function posReceiptLedgerTypeTitle(item: PosLedgerDisplayItem): string {
	const { tx } = item
	if (tx.type === 'topUp') return 'Top-Up'
	if (tx.type === 'tip') return 'Tip'
	const obj = parsePosLedgerDisplayJson(tx.displayJson)
	const title = String(obj?.title ?? '').trim().toLowerCase()
	if (title.includes('auto') || title.includes('routing')) return 'Charge (Auto)'
	return 'Charge'
}

export function posReceiptStatusPill(tx: PosLedgerItem): { label: string; cls: string } {
	if (tx.type === 'topUp') return { label: 'Confirmed', cls: 'bg-emerald-50 text-emerald-600' }
	return { label: 'Settled', cls: 'bg-blue-50 text-blue-600' }
}

function parseHumanAmount(raw: unknown): number {
	const n = Number(String(raw ?? '').replace(/,/g, '').trim())
	return Number.isFinite(n) && n > 0 ? n : 0
}

function receiptTotalAmount(item: PosLedgerDisplayItem): { value: number; currencyCode: string } {
	const { tx } = item
	const base = item.topupMergedTotal ?? preferredLedgerDisplayAmount(tx)
	let total = base.value
	if (tx.type === 'charge') {
		for (const tip of item.tips) total += preferredLedgerDisplayAmount(tip).value
		if (item.embeddedTip) total += item.embeddedTip.value
	}
	return { value: total, currencyCode: base.currencyCode }
}

export function buildPosReceiptBreakdown(
	item: PosLedgerDisplayItem,
	merchantCurrency: string,
): PosReceiptBreakdownRow[] {
	const { tx } = item
	const total = receiptTotalAmount(item)
	const prefix = displayFiatPrefixFromCode(total.currencyCode, merchantCurrency)

	if (tx.type === 'charge') {
		const rows: PosReceiptBreakdownRow[] = []
		const obj = parsePosLedgerDisplayJson(tx.displayJson)
		const breakdown = obj?.chargeBreakdown as Record<string, unknown> | undefined
		if (breakdown) {
			const ccy = String(breakdown.requestCurrency ?? total.currencyCode).toUpperCase()
			const sym = displayFiatPrefixFromCode(ccy, merchantCurrency).trim() || '$'
			const sub = parseHumanAmount(breakdown.subtotalCurrencyAmount)
			const tax = parseHumanAmount(breakdown.taxAmountCurrencyAmount)
			const tip = parseHumanAmount(breakdown.tipCurrencyAmount)
			if (sub > 0) rows.push({ label: 'Original price', value: `${sym}${formatAmount(sub)}` })
			if (tax > 0) rows.push({ label: 'Tax', value: `${sym}${formatAmount(tax)}` })
			if (tip > 0) rows.push({ label: 'Staff tip', value: `${sym}${formatAmount(tip)}` })
		}
		if (rows.length === 0) {
			rows.push({
				label: 'Amount settled',
				value: `${prefix}${formatAmount(total.value)}`,
			})
		}
		for (const tip of item.tips) {
			const t = preferredLedgerDisplayAmount(tip)
			const p = displayFiatPrefixFromCode(t.currencyCode, merchantCurrency)
			rows.push({ label: 'Tip', value: `${p}${formatAmount(t.value)}` })
		}
		if (item.embeddedTip && item.tips.length === 0) {
			const p = displayFiatPrefixFromCode(item.embeddedTip.currencyCode, merchantCurrency)
			rows.push({ label: 'Staff tip', value: `${p}${formatAmount(item.embeddedTip.value)}` })
		}
		return rows
	}

	if (tx.type === 'topUp') {
		const rows: PosReceiptBreakdownRow[] = [
			{
				label: 'Amount issued',
				value: `${prefix}${formatAmount(total.value)}`,
			},
		]
		const usdc6 = Number(tx.amountUSDC6)
		if (Number.isFinite(usdc6) && usdc6 > 0) {
			rows.push({
				label: 'USDC on-chain',
				value: `${formatAmount(usdc6 / 1_000_000)} USDC`,
			})
		}
		if (item.topupBonus && item.topupBonus.value > 0.000_001) {
			const p = displayFiatPrefixFromCode(item.topupBonus.currencyCode, merchantCurrency)
			rows.push({
				label: 'Recharge bonus',
				value: `+${p}${formatAmount(item.topupBonus.value)}`,
			})
		}
		return rows
	}

	const usdc = preferredLedgerDisplayAmount(tx)
	return [
		{
			label: 'Tip (USDC)',
			value: `${formatAmount(usdc.value)} USDC`,
		},
	]
}

export function buildPosReceiptRouteLines(item: PosLedgerDisplayItem): PosReceiptRouteLine[] {
	if (item.tx.type !== 'charge') return []
	const obj = parsePosLedgerDisplayJson(item.tx.displayJson)
	const route = obj?.route
	if (!Array.isArray(route) || route.length === 0) return []
	const out: PosReceiptRouteLine[] = []
	for (const entry of route) {
		if (!entry || typeof entry !== 'object') continue
		const row = entry as Record<string, unknown>
		const assetType = Number(row.assetType ?? 255)
		const amtUsdc6 = Number(String(row.amountE6 ?? '0'))
		const offset6 = Number(String(row.offsetInRequestCurrencyE6 ?? row.amountE6 ?? '0'))
		const amt = offset6 > 0 ? offset6 / 1_000_000 : amtUsdc6 / 1_000_000
		if (assetType === 1) {
			out.push({
				title: 'Stored value deducted',
				sub: 'Program balance',
				amount: amt,
			})
		} else {
			out.push({
				title: 'Auto settlement via USDC',
				sub: amtUsdc6 > 0 ? `≈ ${formatAmount(amtUsdc6 / 1_000_000)} USDC` : 'On-chain',
				amount: amt,
			})
		}
	}
	if (item.embeddedTip && item.tips.length === 0) {
		out.push({
			title: 'Tip',
			sub: `${formatAmount(item.embeddedTip.value)} ${item.embeddedTip.currencyCode}`,
			amount: item.embeddedTip.value,
		})
	}
	return out
}

export function posReceiptTotalLine(
	item: PosLedgerDisplayItem,
	merchantCurrency: string,
): string {
	const { value, currencyCode } = receiptTotalAmount(item)
	const prefix = displayFiatPrefixFromCode(currencyCode, merchantCurrency)
	const sign = item.tx.type === 'topUp' ? '+' : item.tx.type === 'tip' ? '' : ''
	return `${sign}${prefix}${formatAmount(value)}`
}

export function posReceiptTxIdShort(id: string): string {
	const n = normalizeBytes32HexLower(id) ?? id.trim()
	if (n.length >= 10) return n.slice(2, 8)
	return n.slice(0, 6)
}

export function posReceiptPaymentChannelLabel(tx: PosLedgerItem): 'NFC' | 'App' {
	const method = (tx.paymentMethodLabel ?? '').trim().toLowerCase()
	if (method === 'card' || method === 'cash' || method === 'bonus') return 'NFC'
	return 'App'
}

export { beamioCurrencyCodeForCurrencyFiat, receiptTotalAmount }
