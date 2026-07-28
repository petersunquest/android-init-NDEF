import { useEffect, useState } from 'react'
import {
	ArrowRightLeft,
	ArrowUpFromLine,
	CheckCircle2,
	Download,
	ExternalLink,
	Heart,
	Nfc,
	RefreshCcw,
	Smartphone,
	Ticket,
	Wallet,
	X,
	Zap,
} from 'lucide-react'
import { AddressCapsule } from '@/components/AddressCapsule'
import { openExternalUrl } from '@/bridge/cashTreesScanBridge'
import type { PosLedgerDisplayItem } from '@/utils/posLedgerDisplay'
import { preferredLedgerDisplayAmount } from '@/utils/posLedgerDisplay'
import { displayFiatPrefixFromCode, formatAmount, shortAddress } from '@/utils/display'
import { baseScanTxUrl } from '@/utils/posReceiptUtils'
import {
	buildPosReceiptBreakdown,
	buildPosReceiptRouteLines,
	formatPosReceiptDateTime,
	posReceiptBadge,
	posReceiptLedgerTypeTitle,
	posReceiptPaymentChannelLabel,
	posReceiptStatusPill,
	posReceiptTotalLine,
	posReceiptTxIdShort,
	receiptTotalAmount,
	resolvePosLedgerBaseScanTxHash,
} from '@/utils/posSmartReceipt'

/** bizSite Smart Receipt drawer — adapted for POS `/api/posLedger` rows. */
export function PosSmartReceiptDrawer({
	item,
	merchantCurrency,
	payeeTag,
	payeeAddress,
	onClose,
}: {
	item: PosLedgerDisplayItem
	merchantCurrency: string
	payeeTag: string | null
	payeeAddress: string | null
	onClose: () => void
}) {
	const [open, setOpen] = useState(false)
	const { tx } = item
	const baseScanTxHash = resolvePosLedgerBaseScanTxHash(tx)
	const baseScanUrl = baseScanTxHash ? baseScanTxUrl(baseScanTxHash) : null
	const openBaseScan = () => {
		if (!baseScanUrl) return
		openExternalUrl(baseScanUrl)
	}
	const { dateStr, timeStr } = formatPosReceiptDateTime(item.topupLatestTimestamp ?? tx.timestamp)
	const statusPill = posReceiptStatusPill(tx)
	const typeTitle = posReceiptLedgerTypeTitle(item)
	const breakdownRows = buildPosReceiptBreakdown(item, merchantCurrency)
	const routeLines = buildPosReceiptRouteLines(item)
	const total = receiptTotalAmount(item)
	const totalPrefix = displayFiatPrefixFromCode(total.currencyCode, merchantCurrency)
	const payerTag = tx.payerBeamioTag?.trim()
		? `@${tx.payerBeamioTag.replace(/^@/, '')}`
		: ''
	const channel = posReceiptPaymentChannelLabel(tx)

	useEffect(() => {
		const t = window.requestAnimationFrame(() => setOpen(true))
		return () => window.cancelAnimationFrame(t)
	}, [])

	useEffect(() => {
		const onKey = (e: KeyboardEvent) => {
			if (e.key === 'Escape') onClose()
		}
		window.addEventListener('keydown', onKey)
		return () => window.removeEventListener('keydown', onKey)
	}, [onClose])

	const handleClose = () => {
		setOpen(false)
		window.setTimeout(onClose, 220)
	}

	const amountPreview = (() => {
		const base = item.topupMergedTotal ?? preferredLedgerDisplayAmount(tx)
		const prefix = displayFiatPrefixFromCode(base.currencyCode, merchantCurrency)
		return (
			<div className="flex items-start gap-2">
				{tx.type === 'tip' ? (
					<Heart className="mt-0.5 h-[15px] w-[15px] shrink-0 text-rose-500" strokeWidth={2} />
				) : (
					<Ticket className="mt-0.5 h-[15px] w-[15px] shrink-0 text-emerald-500" strokeWidth={2} />
				)}
				<div className="min-w-0">
					<div className="flex items-center gap-2 whitespace-nowrap text-sm font-semibold text-slate-900">
						{formatAmount(base.value)}
						<span className="text-xs font-medium text-slate-400">{base.currencyCode}</span>
					</div>
					{merchantCurrency !== base.currencyCode ? (
						<p className="mt-0.5 text-[11px] font-medium text-slate-400">
							≈ {prefix}
							{formatAmount(base.value)} {merchantCurrency}
						</p>
					) : null}
				</div>
			</div>
		)
	})()

	return (
		<>
			<button
				type="button"
				className={`fixed inset-0 z-[74] cursor-default bg-[#2c2f31]/20 backdrop-blur-sm transition-opacity duration-200 ${
					open ? 'opacity-100' : 'opacity-0'
				}`}
				aria-label="Close smart receipt"
				onClick={handleClose}
			/>
			<div
				role="dialog"
				aria-modal="true"
				aria-labelledby="pos-smart-receipt-title"
				className={`fixed right-0 top-0 z-[75] flex h-full w-full max-w-lg flex-col border-l border-[#abadaf]/33 bg-white text-[#2c2f31] shadow-2xl transition-transform duration-300 ease-out ${
					open ? 'translate-x-0' : 'translate-x-full'
				}`}
				onClick={(e) => e.stopPropagation()}
			>
				<div className="flex shrink-0 items-center justify-between border-b border-[#eef1f3] bg-white px-6 pb-5 pt-[max(2.5rem,env(safe-area-inset-top))] sm:px-8">
					<div>
						<span className="mb-2 inline-block rounded-full bg-[#0051d1]/10 px-3 py-1 text-[10px] font-black uppercase tracking-widest text-[#0051d1]">
							{posReceiptBadge(item)}
						</span>
						<h3 id="pos-smart-receipt-title" className="text-2xl font-black tracking-tighter">
							Smart Receipt
						</h3>
					</div>
					<button
						type="button"
						onClick={handleClose}
						className="flex h-12 w-12 items-center justify-center rounded-full bg-[#eef1f3] text-[#595c5e] shadow-sm transition-colors hover:bg-[#dfe3e6]"
						aria-label="Close"
					>
						<X size={22} strokeWidth={2} />
					</button>
				</div>

				<div className="min-h-0 flex-1 overflow-y-auto px-6 py-6 sm:px-8">
					<div className="mb-8 overflow-hidden rounded-[2rem] border border-[#abadaf]/15 bg-white shadow-sm">
						<div className="flex flex-col gap-4 border-b border-[#e5e9eb] bg-[#eef1f3]/50 px-6 py-6 sm:flex-row sm:items-start sm:justify-between">
							<div className="flex min-w-0 flex-1 items-start gap-4">
								<div
									className={`flex h-12 w-12 shrink-0 items-center justify-center rounded-full ${
										tx.type === 'topUp'
											? 'bg-emerald-50 text-emerald-600'
											: tx.type === 'tip'
												? 'bg-rose-50 text-rose-600'
												: 'bg-[#1562f0]/10 text-[#1562f0]'
									}`}
								>
									{tx.type === 'tip' ? (
										<Heart size={20} className="fill-rose-100" strokeWidth={2} />
									) : tx.type === 'topUp' ? (
										<ArrowUpFromLine size={20} strokeWidth={2} />
									) : (
										<Zap size={20} strokeWidth={2.25} />
									)}
								</div>
								<div className="min-w-0 flex-1 space-y-1">
									<div className="flex flex-wrap items-center gap-2">
										<span className="text-base font-extrabold tracking-tight text-slate-900">
											{typeTitle}
										</span>
										<span
											className={`rounded-full px-2 py-0.5 text-[10px] font-bold uppercase tracking-wider ${statusPill.cls}`}
										>
											{statusPill.label}
										</span>
									</div>
									<div className="flex flex-col gap-1.5">
										<div className="flex min-w-0 flex-wrap items-center gap-2">
											{payerTag ? (
												<span className="whitespace-nowrap text-[15px] font-semibold text-slate-900">
													{payerTag}
												</span>
											) : tx.payer ? (
												<AddressCapsule address={tx.payer} />
											) : (
												<span className="text-[15px] font-medium italic text-slate-500">
													{tx.type === 'topUp' ? 'Wallet' : 'Customer'}
												</span>
											)}
										</div>
										<div className="flex flex-wrap items-center gap-1.5 text-[13px] font-medium text-slate-500">
											{channel === 'NFC' ? (
												<Nfc size={14} className="shrink-0 text-slate-400" />
											) : (
												<Smartphone size={14} className="shrink-0 text-emerald-800" />
											)}
											<span className="whitespace-nowrap">{channel} •</span>
											{payeeTag ? (
												<span className="whitespace-nowrap">@{payeeTag.replace(/^@/, '')}</span>
											) : payeeAddress ? (
												<AddressCapsule
													address={payeeAddress}
													className="border-slate-200 bg-slate-50 text-[12px] text-slate-600"
												/>
											) : (
												<span className="text-slate-400">—</span>
											)}
											{tx.paymentMethodLabel ? (
												<span className="text-slate-400">· {tx.paymentMethodLabel}</span>
											) : null}
										</div>
									</div>
									<div className="mt-1.5 flex flex-wrap items-center gap-2 text-xs text-slate-500">
										{dateStr ? <span className="whitespace-nowrap">{dateStr}</span> : null}
										{dateStr && timeStr ? (
											<span className="h-1 w-1 shrink-0 rounded-full bg-slate-300" />
										) : null}
										<span className="whitespace-nowrap">{timeStr}</span>
										<span className="h-1 w-1 shrink-0 rounded-full bg-slate-300" />
										<span className="whitespace-nowrap font-mono text-[11px] text-slate-400">
											{shortAddress(tx.id)}
										</span>
									</div>
									<div className="mt-2 flex flex-col gap-3 sm:flex-row sm:items-start sm:gap-4">
										<div className="min-w-0 flex-1">{amountPreview}</div>
										<div className="flex shrink-0 flex-col items-start gap-2 sm:min-w-[140px]">
											{baseScanTxHash ? (
												<button
													type="button"
													onClick={openBaseScan}
													className="flex cursor-pointer items-center gap-1.5 rounded-md border border-slate-100 bg-slate-50 px-2 py-1 transition-colors hover:border-slate-200 hover:bg-slate-100"
													title="View transaction on BaseScan"
												>
													<CheckCircle2 size={12} className="shrink-0 text-emerald-500" />
													<span className="font-mono text-[12px] text-slate-500">
														{baseScanTxHash.slice(0, 6)}…{baseScanTxHash.slice(-4)}
													</span>
												</button>
											) : (
												<div className="flex items-center gap-1.5 rounded-md border border-slate-100 bg-slate-50 px-2 py-1">
													<CheckCircle2 size={12} className="shrink-0 text-emerald-500" />
													<span className="font-mono text-[12px] text-slate-500">
														{shortAddress(tx.id)}
													</span>
												</div>
											)}
											<div className="flex items-center gap-1.5 rounded-md border border-slate-200/50 bg-slate-100 px-2 py-1">
												<span className="text-[11px] font-bold text-slate-400">
													0.00 B-Units (Base Gas)
												</span>
											</div>
										</div>
									</div>
								</div>
							</div>
							<div className="hidden shrink-0 flex-col items-end gap-1 text-right sm:flex">
								<span className="whitespace-nowrap text-lg font-semibold tabular-nums text-slate-900">
									{posReceiptTotalLine(item, merchantCurrency)}
								</span>
							</div>
						</div>

						<div className="space-y-4 border-b border-[#e5e9eb] px-6 py-8 sm:px-8">
							<p className="text-[10px] font-black uppercase tracking-widest text-[#595c5e]">
								Transaction breakdown
							</p>
							<div className="space-y-3">
								{breakdownRows.map((row) => (
									<div key={row.label} className="flex items-center justify-between text-sm">
										<span
											className={
												row.discount ? 'font-bold text-[#0051d1]' : 'text-[#595c5e]'
											}
										>
											{row.label}
										</span>
										<span
											className={`font-medium ${row.discount ? 'font-bold text-[#0051d1]' : 'text-[#2c2f31]'}`}
										>
											{row.value}
										</span>
									</div>
								))}
								<div className="flex items-center justify-between border-t border-[#e5e9eb] pt-4">
									<span className="text-base font-bold text-[#2c2f31]">
										{tx.type === 'topUp' ? 'Net issued' : 'Total charged'}
									</span>
									<span
										className={`text-xl font-extrabold tabular-nums ${
											tx.type === 'topUp'
												? 'text-emerald-600'
												: tx.type === 'tip'
													? 'text-rose-600'
													: 'text-[#2c2f31]'
										}`}
									>
										{tx.type === 'topUp' ? '+' : ''}
										{totalPrefix}
										{formatAmount(total.value)}
									</span>
								</div>
							</div>
						</div>

						{tx.type === 'charge' ? (
							<div className="space-y-6 px-6 py-8 sm:px-8">
								{routeLines.length > 0 ? (
									<>
										<p className="text-[10px] font-black uppercase tracking-widest text-[#0051d1]">
											Payment routing strategy
										</p>
										<div className="space-y-4">
											{routeLines.map((ln, ri) => (
												<div key={`${ln.title}-${ri}`} className="flex items-center gap-4">
													<div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-[#eef1f3] text-[#0051d1]">
														{ln.title.includes('Stored') ? (
															<Wallet size={20} strokeWidth={2} />
														) : (
															<ArrowRightLeft size={20} strokeWidth={2} />
														)}
													</div>
													<div className="min-w-0 flex-1">
														<p className="text-sm font-bold text-[#2c2f31]">{ln.title}</p>
														<p className="text-[11px] text-[#747779]">{ln.sub}</p>
													</div>
													<span className="shrink-0 text-sm font-bold text-[#9f0519]">
														−{totalPrefix}
														{formatAmount(ln.amount)}
													</span>
												</div>
											))}
										</div>
									</>
								) : null}
								<div
									className={`flex items-center justify-between rounded-2xl bg-[#0051d1] px-6 py-6 text-white shadow-lg shadow-[#0051d1]/20 ${routeLines.length > 0 ? 'mt-8' : ''}`}
								>
									<div>
										<p className="text-[10px] font-black uppercase tracking-widest opacity-70">
											Total settled
										</p>
										<p className="mt-1 text-2xl font-black tracking-tight">
											{totalPrefix}
											{formatAmount(total.value)} {total.currencyCode}
										</p>
									</div>
									<CheckCircle2 className="size-10 shrink-0 opacity-40" strokeWidth={2} />
								</div>
							</div>
						) : null}
					</div>

					{baseScanUrl ? (
						<button
							type="button"
							onClick={openBaseScan}
							className="mb-6 flex w-full items-center justify-center gap-2 rounded-full border border-[#abadaf]/40 py-3 text-sm font-bold text-[#595c5e] transition-colors hover:bg-[#eef1f3]"
						>
							<ExternalLink size={16} aria-hidden />
							View on BaseScan
						</button>
					) : null}

					<div className="space-y-3">
						<button
							type="button"
							disabled
							title="Coming soon"
							className="flex w-full cursor-not-allowed items-center justify-center gap-3 rounded-full bg-[#0051d1] py-4 text-base font-extrabold text-white opacity-60 shadow-xl shadow-[#0051d1]/20"
						>
							Issue Refund
							<RefreshCcw size={18} aria-hidden />
						</button>
						<button
							type="button"
							disabled
							title="Coming soon"
							className="flex w-full cursor-not-allowed items-center justify-center gap-2 rounded-full border border-[#abadaf] py-3.5 text-sm font-bold text-[#595c5e] opacity-60"
						>
							<Download size={16} aria-hidden />
							Export PDF
						</button>
					</div>
				</div>

				<div className="shrink-0 border-t border-[#eef1f3] px-6 py-4 text-center text-[11px] font-medium text-[#747779] sm:px-8">
					Settled · TX-{posReceiptTxIdShort(tx.id)}
				</div>
			</div>
		</>
	)
}
