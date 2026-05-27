import type { ReactNode } from 'react'
import { ArrowLeftRight, Banknote, CreditCard } from 'lucide-react'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosScreenHeader, PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import type { PosLedgerSnapshot } from '@/utils/posLedgerMetrics'
import { overviewSelectedPeriodLine, topUpOverviewBreakdown } from '@/utils/posLedgerOverview'
import { displayFiatPrefixFromCode, formatAmount } from '@/utils/display'

function fmtMoney(n: number): string {
	return formatAmount(n)
}

function BreakdownRow({
	icon,
	title,
	subtitle,
	amount,
	txnCount,
	currency,
}: {
	icon: ReactNode
	title: string
	subtitle: string
	amount: number
	txnCount: number
	currency: string
}) {
	const prefix = displayFiatPrefixFromCode(currency, 'CAD')
	return (
		<div className="flex items-center gap-3 rounded-2xl bg-white p-4 shadow-sm">
			<div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-[#1562f0]/10 text-[#1562f0]">
				{icon}
			</div>
			<div className="min-w-0 flex-1">
				<p className="text-sm font-semibold text-mkt-onSurface">{title}</p>
				<p className="text-xs text-mkt-onSurfaceVariant">{subtitle}</p>
			</div>
			<div className="shrink-0 text-right">
				<p className="text-sm font-bold tabular-nums text-mkt-onSurface">
					{prefix}
					{fmtMoney(amount)}
				</p>
				<p className="text-[10px] text-mkt-onSurfaceVariant">
					{txnCount} txn{txnCount === 1 ? '' : 's'}
				</p>
			</div>
		</div>
	)
}

/** iOS `POSTopUpOverviewScreen` — cash / card / USDC top-up breakdown. */
export function TransactionsTopUpOverview({
	snapshot,
	merchantCurrency,
	onClose,
}: {
	snapshot: PosLedgerSnapshot | null
	merchantCurrency: string
	onClose: () => void
}) {
	const breakdown = snapshot
		? topUpOverviewBreakdown(snapshot)
		: { cashTotal: 0, cardTotal: 0, usdcTotal: 0, cashCount: 0, cardCount: 0, usdcCount: 0 }
	const totalTopUps = breakdown.cashTotal + breakdown.cardTotal + breakdown.usdcTotal
	const periodLine = snapshot ? overviewSelectedPeriodLine(snapshot) : '—'
	const prefix = displayFiatPrefixFromCode(merchantCurrency, 'CAD')

	return (
		<PosScreenShell bg="bg-[#f5f6f8]">
			<PosScreenHeader className="border-b border-slate-200/80 bg-white/95">
				<div className="flex items-center gap-3 px-3 pb-2.5 pt-2">
					<BeamioCircularBackButton onClick={onClose} />
					<h1 className="flex-1 text-center text-lg font-extrabold text-[#0f2747] pr-10">
						Top-Up Overview
					</h1>
				</div>
			</PosScreenHeader>

			<PosScreenMain className="overflow-y-auto">
				<div className="space-y-4 px-4 py-4 pb-8">
					<div className="rounded-[20px] bg-[#1562f0] p-5 text-white shadow-md">
						<p className="text-[10px] font-extrabold tracking-wider opacity-80">TOTAL TOP-UPS</p>
						<p className="mt-2 text-[32px] font-extrabold tabular-nums leading-none">
							{prefix}
							{fmtMoney(totalTopUps)}
						</p>
						<p className="mt-3 font-mono text-xs opacity-90">{periodLine}</p>
					</div>

					<p className="pt-1 text-base font-semibold text-mkt-onSurface">Payment Breakdown</p>

					<BreakdownRow
						icon={<Banknote className="h-5 w-5" strokeWidth={2} />}
						title="Cash Top-Ups"
						subtitle="Retail locations"
						amount={breakdown.cashTotal}
						txnCount={breakdown.cashCount}
						currency={merchantCurrency}
					/>
					<BreakdownRow
						icon={<CreditCard className="h-5 w-5" strokeWidth={2} />}
						title="Card Top-Ups"
						subtitle="Debit & Credit"
						amount={breakdown.cardTotal}
						txnCount={breakdown.cardCount}
						currency={merchantCurrency}
					/>
					<BreakdownRow
						icon={<ArrowLeftRight className="h-5 w-5" strokeWidth={2} />}
						title="USDC Top-Ups"
						subtitle="Web3 Wallet"
						amount={breakdown.usdcTotal}
						txnCount={breakdown.usdcCount}
						currency="USDC"
					/>
				</div>
			</PosScreenMain>
		</PosScreenShell>
	)
}
