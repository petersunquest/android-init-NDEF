import { useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Banknote, BarChart3, ClipboardList, Loader2 } from 'lucide-react'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosSmartReceiptDrawer } from '@/components/PosSmartReceiptDrawer'
import { PosTransactionRow } from '@/components/PosTransactionRow'
import { PosScreenHeader, PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { TransactionsSalesOverview } from '@/components/TransactionsSalesOverview'
import { TransactionsTopUpOverview } from '@/components/TransactionsTopUpOverview'
import { usePosLedger } from '@/hooks/usePosLedger'
import { usePosSession } from '@/providers/PosSessionProvider'
import { POS_HOME_ROUTES } from '@/utils/posHomeActionRoutes'
import { mergePosLedgerDisplayItems } from '@/utils/posLedgerDisplay'
import type { PosLedgerDisplayItem } from '@/utils/posLedgerDisplay'
import { itemsInTerminalStatsPeriod } from '@/utils/posLedgerMetrics'

/**
 * iOS `POSTransactionsScreen`: local-first ledger list since last clear; no filter UI.
 */
export function TransactionsPage() {
	const navigate = useNavigate()
	const { currency, registeredBeamioTag, terminalProfile, walletAddress } = usePosSession()
	const { snapshot, loading, refreshing, lastError, refreshTrustedOnly } = usePosLedger()
	const [showSalesOverview, setShowSalesOverview] = useState(false)
	const [showTopUpOverview, setShowTopUpOverview] = useState(false)
	const [smartReceiptItem, setSmartReceiptItem] = useState<PosLedgerDisplayItem | null>(null)
	const [pullRefreshing, setPullRefreshing] = useState(false)
	const [pullDistance, setPullDistance] = useState(0)
	const listRef = useRef<HTMLDivElement>(null)
	const touchStartY = useRef(0)

	const payeeTag =
		registeredBeamioTag?.trim() ||
		terminalProfile?.accountName?.trim() ||
		terminalProfile?.username?.trim() ||
		null
	const payeeAddress = walletAddress?.trim() || null

	useEffect(() => {
		if (!smartReceiptItem) return
		const prev = document.body.style.overflow
		document.body.style.overflow = 'hidden'
		return () => {
			document.body.style.overflow = prev
		}
	}, [smartReceiptItem])

	const items = useMemo(() => {
		if (!snapshot) return []
		return mergePosLedgerDisplayItems(itemsInTerminalStatsPeriod(snapshot))
	}, [snapshot])

	const handlePullRefresh = async () => {
		if (pullRefreshing || refreshing) return
		setPullRefreshing(true)
		try {
			await refreshTrustedOnly()
		} finally {
			setPullRefreshing(false)
		}
	}

	if (showSalesOverview) {
		return (
			<TransactionsSalesOverview
				snapshot={snapshot}
				merchantCurrency={currency}
				onClose={() => setShowSalesOverview(false)}
			/>
		)
	}

	if (showTopUpOverview) {
		return (
			<TransactionsTopUpOverview
				snapshot={snapshot}
				merchantCurrency={currency}
				onClose={() => setShowTopUpOverview(false)}
			/>
		)
	}

	return (
		<PosScreenShell bg="bg-[#f2f2f7]">
			<PosScreenHeader>
				<div className="flex items-center gap-3 px-4 pb-2.5 pt-3">
					<BeamioCircularBackButton onClick={() => navigate(POS_HOME_ROUTES.home)} />
					<div className="min-w-0 flex-1">
						<h1 className="text-lg font-semibold text-mkt-onSurface">Transactions</h1>
						<p className="text-[11px] text-mkt-onSurfaceVariant">
							Top-Ups, charges &amp; coupons since last clear
						</p>
					</div>
					<div className="flex shrink-0 items-center gap-2">
						<button
							type="button"
							className="flex h-9 w-9 items-center justify-center rounded-full bg-[#1562f0]/12"
							aria-label="Sales overview"
							onClick={() => {
								setShowTopUpOverview(false)
								setShowSalesOverview(true)
							}}
						>
							<BarChart3 className="h-4 w-4 text-[#1562f0]" strokeWidth={2.5} />
						</button>
						<button
							type="button"
							className="flex h-9 w-9 items-center justify-center rounded-full bg-[#1562f0]/12"
							aria-label="Top-up overview"
							onClick={() => {
								setShowSalesOverview(false)
								setShowTopUpOverview(true)
							}}
						>
							<Banknote className="h-4 w-4 text-[#1562f0]" strokeWidth={2.5} />
						</button>
						{(loading || refreshing || pullRefreshing) && (
							<Loader2 className="h-4 w-4 animate-spin text-mkt-onSurfaceVariant" />
						)}
					</div>
				</div>
			</PosScreenHeader>

			<PosScreenMain>
				{items.length === 0 ? (
					<div className="flex flex-1 flex-col items-center justify-center gap-2 px-8 text-center">
						<ClipboardList className="h-9 w-9 text-mkt-onSurfaceVariant/40" strokeWidth={1.5} />
						<p className="text-sm font-medium text-mkt-onSurfaceVariant">
							No transactions since last clear
						</p>
						{lastError ? (
							<p className="pt-1 text-[11px] text-amber-600">{lastError}</p>
						) : null}
					</div>
				) : (
					<div
						ref={listRef}
						className="min-h-0 flex-1 overflow-y-auto overscroll-y-contain px-4 pb-6 pt-1"
						onTouchStart={(e) => {
							touchStartY.current = e.touches[0]?.clientY ?? 0
						}}
						onTouchMove={(e) => {
							const el = listRef.current
							if (!el || el.scrollTop > 0) {
								setPullDistance(0)
								return
							}
							const dy = (e.touches[0]?.clientY ?? 0) - touchStartY.current
							if (dy > 0) setPullDistance(Math.min(dy, 72))
						}}
						onTouchEnd={async () => {
							if (pullDistance >= 56) await handlePullRefresh()
							setPullDistance(0)
						}}
					>
						{(pullDistance > 0 || pullRefreshing) && (
							<div className="flex justify-center py-2">
								<Loader2
									className={`h-4 w-4 text-mkt-onSurfaceVariant ${pullRefreshing ? 'animate-spin' : ''}`}
									style={{ opacity: Math.min(1, pullDistance / 56) }}
								/>
							</div>
						)}
						<div className="flex flex-col gap-2">
							{items.map((item) => (
								<PosTransactionRow
									key={item.tx.id}
									item={item}
									onPress={() => setSmartReceiptItem(item)}
								/>
							))}
						</div>
						{lastError ? (
							<p className="mt-4 text-center text-[11px] text-amber-600">{lastError}</p>
						) : null}
					</div>
				)}
			</PosScreenMain>
			{smartReceiptItem ? (
				<PosSmartReceiptDrawer
					item={smartReceiptItem}
					merchantCurrency={currency}
					payeeTag={payeeTag}
					payeeAddress={payeeAddress}
					onClose={() => setSmartReceiptItem(null)}
				/>
			) : null}
		</PosScreenShell>
	)
}
