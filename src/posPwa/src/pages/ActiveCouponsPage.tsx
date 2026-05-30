import { useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Gift, Loader2, QrCode, Ticket } from 'lucide-react'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { CouponClaimShareSheet } from '@/components/CouponClaimShareSheet'
import { CouponPreviewTicket } from '@/components/CouponPreviewTicket'
import { PosScreenHeader, PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { usePosSession } from '@/providers/PosSessionProvider'
import { POS_HOME_ROUTES } from '@/utils/posHomeActionRoutes'
import {
	canShareCouponOpenClaim,
	couponOpenClaimUrl,
	couponSupplySummaryText,
} from '@/utils/couponOpenClaim'
import type { MerchantActiveIssuedCoupon } from '@/utils/couponMetadata'
import { couponTicketToneFromHex } from '@/utils/couponTone'

/**
 * iOS `POSActiveCouponsScreen` — in-PWA flow from /home gift icon.
 * Lists `/api/cardActiveIssuedCouponSeries` with claim QR share per row.
 */
export function ActiveCouponsPage() {
	const navigate = useNavigate()
	const { activeCoupons, activeCouponsLoaded, refreshHome } = usePosSession()
	const coupons = activeCoupons ?? []
	const [sharing, setSharing] = useState<MerchantActiveIssuedCoupon | null>(null)
	const [refreshing, setRefreshing] = useState(false)
	const [pullDistance, setPullDistance] = useState(0)
	const listRef = useRef<HTMLDivElement>(null)
	const touchStartY = useRef(0)
	const backgroundRefreshStarted = useRef(false)

	const shareUrl = sharing ? couponOpenClaimUrl(sharing) : null

	/** Local-first: show cached list immediately; refresh network in background. */
	useEffect(() => {
		if (backgroundRefreshStarted.current) return
		backgroundRefreshStarted.current = true
		void refreshHome()
	}, [refreshHome])

	useEffect(() => {
		const el = listRef.current
		if (!el) return

		const onTouchMove = (e: TouchEvent) => {
			if (el.scrollTop > 0) return
			const dy = (e.touches[0]?.clientY ?? 0) - touchStartY.current
			if (dy > 0) e.preventDefault()
		}

		el.addEventListener('touchmove', onTouchMove, { passive: false })
		return () => el.removeEventListener('touchmove', onTouchMove)
	}, [coupons.length])

	const handleRefresh = async () => {
		if (refreshing) return
		setRefreshing(true)
		try {
			await refreshHome()
		} finally {
			setRefreshing(false)
		}
	}

	return (
		<PosScreenShell bg="bg-[#f2f2f7]">
			<PosScreenHeader className="border-b border-black/[0.06] bg-white/95">
				<div className="flex items-center gap-3 px-4 pb-3 pt-[max(0.375rem,env(safe-area-inset-top))]">
					<BeamioCircularBackButton onClick={() => navigate(POS_HOME_ROUTES.home)} />
					<div className="min-w-0 flex-1">
						<h1 className="text-lg font-semibold text-slate-900">Active Vouchers</h1>
						<p className="text-[11px] text-slate-500">
							{coupons.length} vouchers ready to use
						</p>
					</div>
					{refreshing ? (
						<Loader2 className="h-4 w-4 shrink-0 animate-spin text-slate-500" aria-hidden />
					) : null}
				</div>
			</PosScreenHeader>

			<PosScreenMain className="min-w-0 overflow-x-hidden">
				{!activeCouponsLoaded && coupons.length === 0 ? (
					<div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-3 overflow-hidden px-8 text-center">
						<Loader2 className="h-8 w-8 animate-spin text-slate-400" aria-hidden />
						<p className="text-[17px] font-semibold text-slate-900">Loading vouchers</p>
						<p className="text-sm text-slate-500">Showing saved vouchers when available.</p>
					</div>
				) : coupons.length === 0 ? (
					<div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-3 overflow-hidden px-8 text-center">
						<Ticket className="h-11 w-11 text-[#1562f0]/55" strokeWidth={1.5} aria-hidden />
						<p className="text-[17px] font-semibold text-slate-900">No active coupons</p>
						<p className="text-sm text-slate-500">
							Pull to refresh after publishing a new offer.
						</p>
					</div>
				) : (
					<div
						ref={listRef}
						className="min-h-0 min-w-0 flex-1 touch-pan-y overflow-x-hidden overflow-y-auto overscroll-x-none overscroll-y-contain px-4 py-3.5"
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
						onTouchEnd={() => {
							if (pullDistance >= 56) void handleRefresh()
							setPullDistance(0)
						}}
					>
						{(pullDistance > 0 || refreshing) && (
							<div className="flex justify-center py-2">
								<Loader2
									className={`h-4 w-4 text-slate-500 ${refreshing ? 'animate-spin' : ''}`}
									aria-hidden
								/>
							</div>
						)}
						<div className="space-y-3">
							{coupons.map((row) => (
								<ActiveCouponRow
									key={row.id}
									row={row}
									onShare={() => setSharing(row)}
								/>
							))}
						</div>
					</div>
				)}
			</PosScreenMain>

			{sharing && shareUrl ? (
				<CouponClaimShareSheet
					couponTitle={sharing.displayTitle}
					claimUrl={shareUrl}
					onClose={() => setSharing(null)}
				/>
			) : sharing ? (
				<div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 p-0 sm:items-center sm:p-4">
					<div className="w-full max-w-sm rounded-t-[1.25rem] bg-white p-6 text-center sm:rounded-[1.25rem]">
						<Gift className="mx-auto h-8 w-8 text-amber-500" aria-hidden />
						<p className="mt-3 text-[17px] font-semibold text-slate-900">Claim link unavailable</p>
						<p className="mt-2 text-sm text-slate-500">
							This coupon does not expose a valid open-claim URL.
						</p>
						<button
							type="button"
							onClick={() => setSharing(null)}
							className="mt-4 w-full rounded-xl bg-slate-100 py-2.5 text-sm font-semibold text-slate-800"
						>
							Close
						</button>
					</div>
				</div>
			) : null}
		</PosScreenShell>
	)
}

function ActiveCouponRow({
	row,
	onShare,
}: {
	row: MerchantActiveIssuedCoupon
	onShare: () => void
}) {
	const tone = couponTicketToneFromHex(
		row.backgroundColorHex,
		row.couponId ?? row.tokenId,
	)
	const rawSub = row.subtitle?.trim() ?? ''
	const subtitle = rawSub || 'Add coupon details for members'
	const supply = couponSupplySummaryText(row)
	const showShare = canShareCouponOpenClaim(row)

	return (
		<div className="min-w-0 max-w-full space-y-1.5 overflow-x-hidden">
			<CouponPreviewTicket
				title={row.displayTitle}
				subtitle={subtitle}
				iconUrl={row.iconUrl}
				backgroundImageUrl={row.backgroundImageUrl}
				tone={tone}
				validBeforeSec={row.issuedNftValidBeforeSec}
				punchBgClassName="bg-[#f2f2f7]"
				trailing={
					showShare ? (
						<button
							type="button"
							onClick={onShare}
							className="flex h-[34px] w-[34px] items-center justify-center rounded-full"
							style={{ backgroundColor: tone.iconBackdrop }}
							aria-label="Show coupon claim QR and URL"
						>
							<QrCode className="h-[18px] w-[18px]" style={{ color: tone.primaryText }} />
						</button>
					) : undefined
				}
			/>
			{supply ? (
				<p className="truncate text-[11px] font-semibold text-slate-500">{supply}</p>
			) : null}
		</div>
	)
}
