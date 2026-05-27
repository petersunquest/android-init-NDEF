import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosScreenHeader, PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { usePosSession } from '@/providers/PosSessionProvider'
import type { PosLedgerSnapshot } from '@/utils/posLedgerMetrics'
import {
	chargeBaseDisplayTotal,
	chargeTransactionCount,
	chargeUsdcSettlementTotal,
	overviewSelectedPeriodLine,
	salesOverviewApproxCurrencySubtitle,
	tipsDisplayTotalInPeriod,
} from '@/utils/posLedgerOverview'
import { formatAmount } from '@/utils/display'

function fmtMoney(n: number): string {
	return formatAmount(n)
}

/** iOS `POSSalesOverviewScreen` — settlement-window sales KPIs. */
export function TransactionsSalesOverview({
	snapshot,
	merchantCurrency,
	onClose,
}: {
	snapshot: PosLedgerSnapshot | null
	merchantCurrency: string
	onClose: () => void
}) {
	const { terminalProfile, adminProfile } = usePosSession()
	const grossSales = snapshot ? chargeBaseDisplayTotal(snapshot) : 0
	const refunds = 0
	const refundCount = 0
	const netSales = Math.max(0, grossSales - refunds)
	const tips = snapshot ? tipsDisplayTotalInPeriod(snapshot) : 0
	const amountCollected = netSales + tips
	const transactionCount = snapshot ? chargeTransactionCount(snapshot) : 0
	const usdcSettlement = snapshot ? chargeUsdcSettlementTotal(snapshot) : 0
	const periodLine = snapshot
		? overviewSelectedPeriodLine(snapshot)
		: '—'

	const tag = adminProfile?.accountName ?? terminalProfile?.accountName ?? '?'

	return (
		<PosScreenShell bg="bg-[#f5f6f8]">
			<PosScreenHeader className="border-b border-slate-200/80 bg-white/95">
				<div className="flex items-center gap-3 px-3 pb-2.5 pt-2">
					<BeamioCircularBackButton onClick={onClose} />
					<h1 className="flex-1 text-center text-lg font-extrabold text-[#1562f0] pr-10">
						Sales Overview
					</h1>
				</div>
			</PosScreenHeader>

			<PosScreenMain className="overflow-y-auto">
				<div className="space-y-5 px-4 py-4 pb-8">
					<div>
						<p className="text-[10px] font-extrabold tracking-wider text-mkt-onSurfaceVariant">
							SELECTED PERIOD
						</p>
						<p className="mt-1.5 font-mono text-[13px] font-medium leading-snug text-mkt-onSurface">
							{periodLine}
						</p>
					</div>

					<div className="rounded-[20px] bg-white p-4 shadow-sm">
						<div className="flex items-baseline justify-between">
							<span className="text-[15px] font-semibold">Gross Sales</span>
							<span className="text-lg font-bold tabular-nums">${fmtMoney(grossSales)}</span>
						</div>
						<div className="mt-3.5 flex items-center justify-between">
							<div className="flex items-center gap-2">
								<span className="text-[15px] font-semibold">Refunds</span>
								<span className="rounded-full bg-slate-100 px-2 py-0.5 text-[10px] font-bold text-mkt-onSurfaceVariant">
									{refundCount}
								</span>
							</div>
							<span className="text-lg font-bold tabular-nums text-red-600">
								(${fmtMoney(refunds)})
							</span>
						</div>
						<hr className="my-4 border-slate-100" />
						<div className="flex items-baseline justify-between">
							<span className="text-[17px] font-bold">Net Sales</span>
							<span className="text-[22px] font-extrabold tabular-nums text-[#1562f0]">
								${fmtMoney(netSales)}
							</span>
						</div>
						<hr className="my-4 border-slate-100" />
						<div className="space-y-2.5 text-sm">
							<div className="flex justify-between">
								<span className="text-mkt-onSurfaceVariant">Taxes &amp; Fees</span>
								<span className="tabular-nums">$0.00</span>
							</div>
							<div className="flex justify-between">
								<span className="text-mkt-onSurfaceVariant">Tips</span>
								<span className="tabular-nums">${fmtMoney(tips)}</span>
							</div>
						</div>
						<hr className="my-4 border-slate-100" />
						<div className="flex items-baseline justify-between">
							<span className="text-[17px] font-bold">Amount Collected</span>
							<span className="text-[22px] font-extrabold tabular-nums">
								${fmtMoney(amountCollected)}
							</span>
						</div>
					</div>

					<div className="grid grid-cols-2 gap-3">
						<div className="rounded-[20px] bg-white p-3 shadow-sm">
							<p className="text-[9px] font-extrabold tracking-wider text-mkt-onSurfaceVariant">
								TRANSACTIONS
							</p>
							<p className="mt-2 text-[22px] font-extrabold tabular-nums">{transactionCount}</p>
						</div>
						<div className="rounded-[20px] bg-white p-3 shadow-sm">
							<p className="text-[9px] font-extrabold tracking-wider text-mkt-onSurfaceVariant">
								USDC SETTLEMENT
							</p>
							<div className="mt-2 flex items-baseline gap-2">
								<span className="text-[22px] font-extrabold tabular-nums">
									{fmtMoney(usdcSettlement)}
								</span>
								<span className="text-xs text-mkt-onSurfaceVariant">USDC</span>
							</div>
							<p className="mt-1 text-[11px] font-medium text-mkt-onSurfaceVariant">
								{salesOverviewApproxCurrencySubtitle(netSales, merchantCurrency)}
							</p>
						</div>
					</div>

					<div className="flex items-center gap-2 text-xs text-mkt-onSurfaceVariant">
						<div className="flex h-8 w-8 items-center justify-center rounded-full bg-gradient-to-br from-[#1562f0] to-violet-600 text-sm font-bold text-white">
							{tag.slice(0, 1).toUpperCase()}
						</div>
						<span>Terminal settlement window</span>
					</div>
				</div>
			</PosScreenMain>
		</PosScreenShell>
	)
}
