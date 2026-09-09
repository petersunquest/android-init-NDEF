import { AlertTriangle, Check, Loader2 } from 'lucide-react'
import { BeamioCircularBackButton, BEAMIO_CIRCULAR_BACK_ROW_CLASS } from '@/components/BeamioCircularBackButton'
import { PosScreenFooter, PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import type { ChargeAdminCardBalanceRow } from '@/utils/chargeAdminCardBalances'
import { sameChargeCurrency } from '@/utils/chargeAdminCardBalances'
import { displayFiatPrefixFromCode, formatAmount, shortAddress } from '@/utils/display'

const CHARGE_BLUE = '#1562f0'

function formatRewardPts(amount: number): string {
	return amount.toLocaleString('en-US', {
		minimumFractionDigits: 2,
		maximumFractionDigits: 2,
	})
}

function cardSelectable(row: ChargeAdminCardBalanceRow, billCurrency: string): boolean {
	return row.trusted && sameChargeCurrency(row.cardCurrency, billCurrency)
}

export function ChargeSelectProgramCardPage({
	billAmount,
	billCurrency,
	rows,
	loading,
	selectedAddress,
	confirming,
	onSelect,
	onConfirm,
	onRetry,
	onBack,
}: {
	billAmount: string
	billCurrency: string
	rows: ChargeAdminCardBalanceRow[]
	loading: boolean
	selectedAddress: string
	confirming: boolean
	onSelect: (cardAddress: string) => void
	onConfirm: () => void
	onRetry: () => void
	onBack: () => void
}) {
	const bill = Number(billAmount) || 0
	const prefix = displayFiatPrefixFromCode(billCurrency, 'CAD')
	const selected = rows.find(
		(row) => row.cardAddress.trim().toLowerCase() === selectedAddress.trim().toLowerCase(),
	)
	const canConfirm =
		!loading &&
		!confirming &&
		Boolean(selected) &&
		cardSelectable(selected!, billCurrency)
	const anyTrusted = rows.some((row) => row.trusted)
	const allUntrusted = !loading && rows.length > 0 && !anyTrusted

	return (
		<PosScreenShell bg="bg-[#f2f2f7]">
			<div className="relative flex min-h-0 flex-1 flex-col">
				<div className={`${BEAMIO_CIRCULAR_BACK_ROW_CLASS} px-4 pt-[max(0.75rem,env(safe-area-inset-top))]`}>
					<BeamioCircularBackButton
						variant="onLight"
						onClick={onBack}
						disabled={confirming}
						className="absolute left-4 top-[max(0.75rem,env(safe-area-inset-top))]"
					/>
				</div>
				<PosScreenMain className="px-4 pb-3">
					<header className="pb-4 pt-2">
						<p className="text-[11px] font-semibold uppercase tracking-[0.14em] text-slate-500">
							Charge
						</p>
						<h1 className="mt-1 text-2xl font-semibold text-slate-900">Choose program card</h1>
						<p className="mt-1 text-sm text-slate-500">
							This terminal is admin on more than one program. Pick which balance to charge.
						</p>
						<p className="mt-3 text-lg font-semibold tabular-nums text-slate-900">
							Bill {prefix}
							{formatAmount(bill)}
						</p>
					</header>

					{allUntrusted ? (
						<div
							role="alert"
							className="mb-3 flex items-start gap-2 rounded-xl border border-amber-200 bg-amber-50 px-3 py-3 text-sm text-amber-900"
						>
							<AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
							<div className="min-w-0">
								<p>Could not load customer balances. Try again.</p>
								<button
									type="button"
									onClick={onRetry}
									className="mt-2 text-sm font-semibold text-amber-950 underline"
								>
									Retry
								</button>
							</div>
						</div>
					) : null}

					{selected && !cardSelectable(selected, billCurrency) && selected.trusted ? (
						<div
							role="alert"
							className="mb-3 flex items-start gap-2 rounded-xl border border-amber-200 bg-amber-50 px-3 py-3 text-sm text-amber-900"
						>
							<AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
							<p>
								Uses {selected.cardCurrency.trim().toUpperCase() || 'a different currency'} — enter
								the bill in that currency to use this card.
							</p>
						</div>
					) : null}

					<div className="min-h-0 flex-1 space-y-3 overflow-y-auto pb-2">
						{loading && rows.length === 0
							? [0, 1].map((i) => (
									<div
										key={i}
										className="h-24 animate-pulse rounded-2xl border border-slate-200 bg-white"
									/>
								))
							: rows.map((row) => {
									const selectable = cardSelectable(row, billCurrency)
									const isOn =
										row.cardAddress.trim().toLowerCase() === selectedAddress.trim().toLowerCase()
									const storePrefix = displayFiatPrefixFromCode(
										row.cardCurrency || billCurrency,
										billCurrency,
									)
									return (
										<button
											key={row.cardAddress}
											type="button"
											disabled={confirming || loading || !selectable}
											onClick={() => onSelect(row.cardAddress)}
											aria-pressed={isOn}
											className={`w-full rounded-2xl border bg-white p-4 text-left shadow-sm transition ${
												isOn
													? 'border-[#1562f0] ring-2 ring-[#1562f0]/20'
													: 'border-slate-200'
											} ${selectable ? '' : 'opacity-50'}`}
										>
											<div className="flex items-start justify-between gap-3">
												<div className="min-w-0">
													<p className="truncate text-base font-semibold text-slate-900">
														{row.cardName}
													</p>
													<p className="mt-0.5 font-mono text-xs text-slate-500">
														{shortAddress(row.cardAddress)}
													</p>
												</div>
												{isOn ? (
													<span
														className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-white"
														style={{ backgroundColor: CHARGE_BLUE }}
													>
														<Check className="h-3.5 w-3.5" aria-hidden />
													</span>
												) : null}
											</div>
											{row.trusted ? (
												<div className="mt-3 flex flex-wrap items-baseline gap-x-4 gap-y-1 text-sm text-slate-600">
													<p>
														<span className="text-slate-500">Store credit </span>
														<span className="font-semibold tabular-nums text-slate-900">
															{storePrefix}
															{formatAmount(row.storeCredit ?? 0)}
														</span>
													</p>
													<p>
														<span className="text-slate-500">Reward PT </span>
														<span className="font-semibold tabular-nums text-slate-900">
															{formatRewardPts(row.rewardPts ?? 0)}
														</span>
													</p>
													{row.memberNo ? (
														<p className="text-slate-500">{row.memberNo}</p>
													) : null}
												</div>
											) : (
												<p className="mt-3 text-sm text-amber-800">Balance unavailable</p>
											)}
											{row.trusted && !sameChargeCurrency(row.cardCurrency, billCurrency) ? (
												<p className="mt-2 text-xs text-slate-500">
													Card currency {row.cardCurrency.trim().toUpperCase()}
												</p>
											) : null}
										</button>
									)
								})}
					</div>
				</PosScreenMain>
				<PosScreenFooter>
					<button
						type="button"
						onClick={onConfirm}
						disabled={!canConfirm}
						aria-busy={confirming}
						aria-label="Continue"
						className="flex h-12 w-full items-center justify-center rounded-full text-base font-semibold text-white disabled:cursor-not-allowed disabled:opacity-50"
						style={{ backgroundColor: CHARGE_BLUE }}
					>
						{confirming ? <Loader2 className="h-5 w-5 animate-spin" aria-hidden /> : 'Continue'}
					</button>
				</PosScreenFooter>
			</div>
		</PosScreenShell>
	)
}
