import { ArrowDown, ArrowUp, Gift, Heart } from 'lucide-react'
import type { PosLedgerDisplayItem } from '@/utils/posLedgerDisplay'
import {
	posTransactionRelativeTime,
	posTransactionSecondaryLine,
	preferredLedgerDisplayAmount,
} from '@/utils/posLedgerDisplay'
import { readBalanceFormatMoney } from '@/utils/readBalanceDisplay'

const BRAND_BLUE = '#1562f0'
const MINT_GREEN = '#34c759'
const TIP_PINK = '#f43f5e'

function tipTotalsByCurrency(item: PosLedgerDisplayItem): Record<string, number> {
	const totals: Record<string, number> = {}
	for (const tip of item.tips) {
		const amt = preferredLedgerDisplayAmount(tip)
		totals[amt.currencyCode] = (totals[amt.currencyCode] ?? 0) + amt.value
	}
	if (item.embeddedTip) {
		totals[item.embeddedTip.currencyCode] =
			(totals[item.embeddedTip.currencyCode] ?? 0) + item.embeddedTip.value
	}
	return totals
}

function tipTotalInCurrency(item: PosLedgerDisplayItem, currencyCode: string): number {
	return tipTotalsByCurrency(item)[currencyCode] ?? 0
}

export function PosTransactionRow({
	item,
	onPress,
}: {
	item: PosLedgerDisplayItem
	onPress?: () => void
}) {
	const { tx } = item
	const base = item.topupMergedTotal ?? preferredLedgerDisplayAmount(tx)
	const tipExtra = tx.type === 'charge' ? tipTotalInCurrency(item, base.currencyCode) : 0
	const total = base.value + tipExtra
	const parts = readBalanceFormatMoney(total, base.currencyCode)
	const sign = tx.type === 'topUp' ? '+' : '−'
	const amountLine = `${sign}${parts.prefix}${parts.mid}${parts.suffix}`

	let topupBonusLine: string | null = null
	if (tx.type === 'topUp' && item.topupBonus && item.topupBonus.value > 0.000_001) {
		const b = readBalanceFormatMoney(item.topupBonus.value, item.topupBonus.currencyCode)
		topupBonusLine = `+${b.prefix}${b.mid}${b.suffix}`
	}

	let tipLine: string | null = null
	if (tx.type === 'charge') {
		const grouped = tipTotalsByCurrency(item)
		const preferred = grouped[base.currencyCode] ?? Object.values(grouped)[0] ?? 0
		const code =
			grouped[base.currencyCode] != null
				? base.currencyCode
				: (Object.keys(grouped)[0] ?? base.currencyCode)
		if (preferred > 0.000_001) {
			const t = readBalanceFormatMoney(preferred, code)
			tipLine = `incl. ${t.prefix}${t.mid}${t.suffix} tip`
		}
	}

	const typeTitle = tx.type === 'topUp' ? 'Top-Up' : tx.type === 'tip' ? 'Tip' : 'Charge'
	const secondaryLine = posTransactionSecondaryLine(tx)
	const timeLine = posTransactionRelativeTime(item.topupLatestTimestamp ?? tx.timestamp)

	const tint =
		tx.type === 'topUp' ? MINT_GREEN : tx.type === 'tip' ? TIP_PINK : BRAND_BLUE
	const amountTint = tx.type === 'topUp' ? MINT_GREEN : undefined

	const Icon = tx.type === 'topUp' ? ArrowUp : tx.type === 'tip' ? Heart : ArrowDown

	return (
		<button
			type="button"
			onClick={onPress}
			className="flex w-full items-center gap-3 rounded-[14px] bg-white px-3 py-2.5 text-left active:bg-slate-50"
		>
			<div
				className="flex h-9 w-9 shrink-0 items-center justify-center rounded-[10px]"
				style={{ backgroundColor: `${tint}1f` }}
			>
				<Icon className="h-4 w-4" style={{ color: tint }} strokeWidth={2.5} />
			</div>

			<div className="min-w-0 flex-1">
				<p className="text-sm font-semibold text-mkt-onSurface">{typeTitle}</p>
				<p className="truncate text-[11px] text-mkt-onSurfaceVariant">{secondaryLine}</p>
			</div>

			<div className="shrink-0 text-right">
				<p
					className="text-sm font-semibold tabular-nums"
					style={amountTint ? { color: amountTint } : undefined}
				>
					{amountLine}
				</p>
				{topupBonusLine ? (
					<p className="flex items-center justify-end gap-0.5 text-[10px] font-bold text-orange-500">
						<span>Incl</span>
						<Gift className="h-2.5 w-2.5" strokeWidth={2.5} />
						<span>{topupBonusLine}</span>
					</p>
				) : null}
				{tipLine ? (
					<p className="text-[10px] italic text-mkt-onSurfaceVariant">{tipLine}</p>
				) : null}
				<p className="text-[10px] text-mkt-onSurfaceVariant">{timeLine}</p>
			</div>
		</button>
	)
}
