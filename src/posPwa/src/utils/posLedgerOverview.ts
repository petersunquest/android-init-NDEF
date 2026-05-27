import type { PosLedgerItem, PosLedgerSnapshot } from '@/utils/posLedgerMetrics'
import {
	isHiddenInternalLedgerCategory,
	itemsInTerminalStatsPeriod,
	preferredLedgerDisplayAmount,
	tipRowMatchesChargeParent,
} from '@/utils/posLedgerMetrics'

export interface PosTopUpOverviewBreakdown {
	cashTotal: number
	cardTotal: number
	usdcTotal: number
	cashCount: number
	cardCount: number
	usdcCount: number
}

function formatEpochSecondsForOverviewPeriod(epochSeconds: number): string {
	const d = new Date(epochSeconds * 1000)
	const datePart = d.toLocaleString('en-US', {
		month: 'short',
		day: 'numeric',
		year: 'numeric',
	})
	const timePart = d
		.toLocaleString('en-US', { hour: 'numeric', minute: '2-digit', hour12: true })
		.toLowerCase()
	return `${datePart} ${timePart}`
}

export function overviewSelectedPeriodLine(snapshot: PosLedgerSnapshot, nowSec = Date.now() / 1000): string {
	const endPart = formatEpochSecondsForOverviewPeriod(nowSec)
	const resetSec = snapshot.lastTerminalReset?.timestamp
	const periodItems = itemsInTerminalStatsPeriod(snapshot)
	const startSec = resetSec ?? (periodItems.length ? Math.min(...periodItems.map((it) => it.timestamp)) : null)
	if (startSec == null) return `— ${endPart}`
	return `${formatEpochSecondsForOverviewPeriod(startSec)} — ${endPart}`
}

function topUpPaymentLegFromDisplayJson(displayJson: string): string {
	try {
		const obj = JSON.parse(displayJson) as Record<string, unknown>
		return String(obj.topupPaymentLeg ?? '')
			.trim()
			.toLowerCase()
	} catch {
		return ''
	}
}

type TopUpBucket = 'cash' | 'card' | 'usdc'

function topUpOverviewBucket(tx: PosLedgerItem): TopUpBucket {
	const label = (tx.paymentMethodLabel ?? '').trim().toLowerCase()
	switch (label) {
		case 'cash':
			return 'cash'
		case 'usdc':
			return 'usdc'
		case 'card':
		case 'bonus':
			return 'card'
		default:
			break
	}
	if (label) return 'card'

	const leg = topUpPaymentLegFromDisplayJson(tx.displayJson)
	switch (leg) {
		case 'cash':
			return 'cash'
		case 'credit':
		case 'bonus':
			return 'card'
		default:
			break
	}

	const fiat6 = Number(tx.amountFiat6)
	const usdc6 = Number(tx.amountUSDC6)
	if ((!Number.isFinite(fiat6) || fiat6 <= 0) && Number.isFinite(usdc6) && usdc6 > 0) return 'usdc'
	return 'card'
}

export function topUpOverviewBreakdown(snapshot: PosLedgerSnapshot): PosTopUpOverviewBreakdown {
	let cashTotal = 0
	let cardTotal = 0
	let usdcTotal = 0
	let cashCount = 0
	let cardCount = 0
	let usdcCount = 0

	for (const tx of itemsInTerminalStatsPeriod(snapshot)) {
		if (tx.type !== 'topUp') continue
		if (isHiddenInternalLedgerCategory(tx.txCategory)) continue
		const amt = preferredLedgerDisplayAmount(tx).value
		switch (topUpOverviewBucket(tx)) {
			case 'cash':
				cashTotal += amt
				cashCount += 1
				break
			case 'card':
				cardTotal += amt
				cardCount += 1
				break
			case 'usdc':
				usdcTotal += amt
				usdcCount += 1
				break
		}
	}

	return { cashTotal, cardTotal, usdcTotal, cashCount, cardCount, usdcCount }
}

export function chargeBaseDisplayTotal(snapshot: PosLedgerSnapshot): number {
	return itemsInTerminalStatsPeriod(snapshot)
		.filter((it) => it.type === 'charge' && !isHiddenInternalLedgerCategory(it.txCategory))
		.reduce((sum, it) => sum + preferredLedgerDisplayAmount(it).value, 0)
}

export function chargeTransactionCount(snapshot: PosLedgerSnapshot): number {
	return itemsInTerminalStatsPeriod(snapshot).filter(
		(it) => it.type === 'charge' && !isHiddenInternalLedgerCategory(it.txCategory),
	).length
}

function tipsDisplayTotal(items: PosLedgerItem[]): number {
	const visible = items.filter((it) => !isHiddenInternalLedgerCategory(it.txCategory))
	const charges = visible.filter((it) => it.type === 'charge')
	const tips = visible.filter((it) => it.type === 'tip')
	const absorbed = new Set<string>()
	let total = 0

	for (const charge of charges) {
		const matched = tips.filter((tip) => tipRowMatchesChargeParent(tip, charge))
		if (matched.length === 0) {
			try {
				const obj = JSON.parse(charge.displayJson) as Record<string, unknown>
				const breakdown = obj.chargeBreakdown as Record<string, unknown> | undefined
				const rawTip = Number(String(breakdown?.tipCurrencyAmount ?? '0').replace(/,/g, ''))
				if (Number.isFinite(rawTip) && rawTip > 0) total += rawTip
			} catch {
				/* ignore */
			}
		} else {
			for (const tip of matched) {
				absorbed.add(tip.id.toLowerCase())
				total += preferredLedgerDisplayAmount(tip).value
			}
		}
	}
	for (const tip of tips) {
		if (!absorbed.has(tip.id.toLowerCase())) total += preferredLedgerDisplayAmount(tip).value
	}
	return total
}

export function tipsDisplayTotalInPeriod(snapshot: PosLedgerSnapshot): number {
	return tipsDisplayTotal(itemsInTerminalStatsPeriod(snapshot))
}

function usdcAmount(tx: PosLedgerItem): number {
	const usdc6 = Number(tx.amountUSDC6)
	return Number.isFinite(usdc6) ? usdc6 / 1_000_000 : 0
}

export function chargeUsdcSettlementTotal(snapshot: PosLedgerSnapshot): number {
	let usdcSum = 0
	for (const tx of itemsInTerminalStatsPeriod(snapshot)) {
		if (tx.type !== 'charge' || isHiddenInternalLedgerCategory(tx.txCategory)) continue
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

export function salesOverviewApproxCurrencySubtitle(amount: number, currencyCode: string): string {
	const amt = amount.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })
	switch (currencyCode.toUpperCase()) {
		case 'CAD':
			return `≈ CA$${amt}`
		case 'USD':
			return `≈ $${amt}`
		case 'EUR':
			return `≈ €${amt}`
		case 'JPY':
			return `≈ JP¥${amt}`
		case 'CNY':
			return `≈ CN¥${amt}`
		case 'HKD':
			return `≈ HK$${amt}`
		case 'SGD':
			return `≈ SG$${amt}`
		case 'TWD':
			return `≈ NT$${amt}`
		case 'USDC':
			return `≈ $${amt} USDC`
		default:
			return `≈ ${amt} ${currencyCode}`
	}
}
