import {
	ClipboardList,
	Gift,
	Link2,
	MinusCircle,
	Nfc,
	Plus,
	Search,
	Wallet,
} from 'lucide-react'
import type { LucideIcon } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { BeamioCapsuleCompact } from '@/components/BeamioCapsule'
import { PosScreenHeader, PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { usePosSession } from '@/providers/PosSessionProvider'
import { POS_HOME_ROUTES } from '@/utils/posHomeActionRoutes'
import type { PosHomeLocationState } from '@/utils/posHomeLocationState'
import { pickHomeAdminCapsuleProfile } from '@/utils/posHomeAdminProfile'
import {
	formatBUnitDisplay,
	formatDashboardCurrency,
	profileBeamioTag,
	walletShortLine,
} from '@/utils/display'

const BRAND_BLUE = '#1562f0'
const LINK_PURPLE = '#7c3aed'
const DEDUCT_ORANGE = '#ea580c'

/** iOS `homeButtonAreaHeights`: charge = 1.5× each action row; rows share remaining height. */
function useHomeButtonAreaHeights(actionRowCount: number) {
	const containerRef = useRef<HTMLDivElement>(null)
	const [heights, setHeights] = useState({ charge: 132, actionRow: 88 })

	useEffect(() => {
		const el = containerRef.current
		if (!el) return

		const compute = () => {
			const usable = el.clientHeight
			if (usable <= 0) return
			const chargeToActionGap = 16
			const actionRowGap = 12
			const rows = Math.max(1, actionRowCount)
			const interRowGaps = Math.max(0, rows - 1) * actionRowGap
			const rowH = Math.max(64, (usable - chargeToActionGap - interRowGaps) / (1.5 + rows))
			setHeights({ charge: rowH * 1.5, actionRow: rowH })
		}

		compute()
		const ro = new ResizeObserver(compute)
		ro.observe(el)
		return () => ro.disconnect()
	}, [actionRowCount])

	return { containerRef, heights }
}

export function HomePage() {
	const navigate = useNavigate()
	const location = useLocation()
	const {
		terminalProfile,
		adminProfile,
		parentProfile,
		parentBeamioTag,
		registeredBeamioTag,
		walletAddress,
		currency,
		chargeAmount,
		topUpAmount,
		tipsAmount,
		bUnitBalance,
		hasAAAccount,
		homeStatsLoaded,
		pointSystemEnabled,
		activeCoupons,
	} = usePosSession()

	const [homeActionError, setHomeActionError] = useState<string | null>(null)

	useEffect(() => {
		const err = (location.state as PosHomeLocationState | null)?.homeActionError
		if (!err) return
		setHomeActionError(err)
		navigate(POS_HOME_ROUTES.home, { replace: true, state: {} })
	}, [location.key, location.state, navigate])

	useEffect(() => {
		if (!homeActionError) return
		const t = setTimeout(() => setHomeActionError(null), 5000)
		return () => clearTimeout(t)
	}, [homeActionError])

	const actionRowCount = pointSystemEnabled ? 3 : 2
	const { containerRef, heights } = useHomeButtonAreaHeights(actionRowCount)

	const totalDue = chargeAmount
	const subtotalDue =
		chargeAmount != null ? Math.max(0, chargeAmount - (tipsAmount ?? 0)) : null

	const headerLine = (() => {
		const tag = profileBeamioTag(terminalProfile ?? {}) || registeredBeamioTag
		if (tag) return `@${tag}`
		if (walletAddress) return walletShortLine(walletAddress)
		return 'Terminal'
	})()

	const homeAdminCapsule = pickHomeAdminCapsuleProfile(
		adminProfile,
		parentProfile,
		parentBeamioTag,
	)

	return (
		<PosScreenShell>
			<PosScreenHeader className="border-b border-slate-200/60 bg-white/95 px-5 pb-3">
				<div className="flex items-center gap-3">
					<div className="flex h-10 w-10 shrink-0 items-center justify-center overflow-hidden rounded-full bg-brand-blue text-sm font-black text-white">
						P
					</div>
					<div className="min-w-0 flex-1">
						<p className="truncate text-[15px] font-semibold text-slate-500">{headerLine}</p>
					</div>
					{homeAdminCapsule ? (
						<button
							type="button"
							onClick={() => navigate(POS_HOME_ROUTES.workspace)}
							className="shrink-0 rounded-full transition active:scale-[0.97]"
							aria-label="Manage merchant workspaces"
						>
							<BeamioCapsuleCompact profile={homeAdminCapsule} />
						</button>
					) : (
						<button
							type="button"
							onClick={() => navigate(POS_HOME_ROUTES.workspace)}
							className="shrink-0 rounded-full bg-black/[0.06] px-3 py-2 text-[12px] font-semibold text-slate-600"
							aria-label="Manage merchant workspaces"
						>
							Workspaces
						</button>
					)}
				</div>
			</PosScreenHeader>

			<PosScreenMain className="px-5 pb-[max(1rem,env(safe-area-inset-bottom))] pt-5">
				<section className="shrink-0 text-center">
					<p className="text-[11px] font-black uppercase tracking-[0.28em] text-slate-500">
						Total Due
					</p>
					<div className="mt-2 flex items-center justify-center gap-3">
						<p className="text-5xl font-black tracking-tight text-slate-900 sm:text-6xl">
							{formatDashboardCurrency(totalDue, currency, homeStatsLoaded)}
						</p>
						{activeCoupons && activeCoupons.length > 0 ? (
							<button
								type="button"
								onClick={() => navigate(POS_HOME_ROUTES.activeCoupons)}
								className="flex h-11 w-11 items-center justify-center rounded-full bg-gradient-to-br from-orange-400 to-rose-500 text-white shadow-[0_2px_8px_rgba(249,115,22,0.28)]"
								aria-label="Bonus coupons"
							>
								<Gift className="h-5 w-5" />
							</button>
						) : null}
					</div>
					<div className="mt-2 flex justify-center gap-3 text-sm font-medium text-slate-500">
						<span>
							Subtotal{' '}
							<strong className="text-slate-800">
								{formatDashboardCurrency(subtotalDue, currency, homeStatsLoaded)}
							</strong>
						</span>
						<span className="text-slate-300">|</span>
						<span>
							Tip{' '}
							<strong className="text-slate-800">
								{formatDashboardCurrency(tipsAmount, currency, homeStatsLoaded)}
							</strong>
						</span>
					</div>
				</section>

				<div className="mt-4 grid shrink-0 grid-cols-2 gap-3 sm:gap-3.5">
					<HomeDataCard
						title="Period Top-Ups"
						value={formatDashboardCurrency(topUpAmount, currency, homeStatsLoaded)}
						titleClassName="text-slate-500"
					/>
					<HomeDataCard
						title="B-Units"
						value={formatBUnitDisplay(bUnitBalance, homeStatsLoaded)}
						titleClassName="text-[#d97706]"
					/>
				</div>

				{hasAAAccount === false ? (
					<div className="mt-4 shrink-0 rounded-[22px] bg-brand-blue p-4 text-white shadow-md">
						<div className="flex items-start gap-3">
							<Wallet className="mt-0.5 h-5 w-5 shrink-0 opacity-90" />
							<div>
								<p className="font-bold">EOA ready · AA pending</p>
								<p className="mt-1 text-sm text-white/85">
									Your terminal wallet can operate on EOA. Smart Account unlock may still be
									queued.
								</p>
							</div>
						</div>
					</div>
				) : null}

				{homeActionError ? (
					<div
						className="mt-4 shrink-0 rounded-2xl border border-red-200 bg-red-50 px-4 py-3 text-sm font-medium text-red-800"
						role="alert"
					>
						{homeActionError}
					</div>
				) : null}

				{/* iOS HomeRootView: GeometryReader flex button stack */}
				<div ref={containerRef} className="mt-4 flex min-h-0 flex-1 flex-col gap-4">
					<button
						type="button"
						onClick={() => navigate(POS_HOME_ROUTES.charge)}
						style={{ height: heights.charge, minHeight: heights.charge }}
						className="relative flex w-full shrink-0 flex-col items-center justify-center overflow-hidden rounded-[22px] bg-brand-blue shadow-[0_8px_18px_rgba(21,98,240,0.26)] active:scale-[0.99]"
					>
						<div
							className="pointer-events-none absolute inset-0 bg-gradient-to-b from-white/16 to-transparent"
							aria-hidden
						/>
						<p className="relative text-3xl font-semibold tracking-tight text-white sm:text-4xl">
							CHARGE
						</p>
						<div className="relative mt-2 flex items-center gap-2 text-xs font-semibold uppercase tracking-wider text-white/85 sm:text-sm">
							<Nfc className="h-4 w-4 sm:h-5 sm:w-5" aria-hidden />
							<span>Tap to Pay or Scan</span>
						</div>
					</button>

					<div className="flex min-h-0 flex-1 flex-col gap-3">
						<div
							className="grid grid-cols-2 gap-3"
							style={{ height: heights.actionRow, minHeight: heights.actionRow }}
						>
							<HomeActionGridButton
								title="Check Balance"
								icon={Search}
								iconTint={BRAND_BLUE}
								onClick={() => navigate(POS_HOME_ROUTES.checkBalance)}
							/>
							<HomeActionGridButton
								title="Top-up"
								icon={Plus}
								iconTint={LINK_PURPLE}
								onClick={() => navigate(POS_HOME_ROUTES.topUp)}
							/>
						</div>

						<div
							className="grid grid-cols-2 gap-3"
							style={{ height: heights.actionRow, minHeight: heights.actionRow }}
						>
							{pointSystemEnabled ? (
								<HomeActionGridButton
									title="Deduct Points"
									icon={MinusCircle}
									iconTint={DEDUCT_ORANGE}
									onClick={() => navigate(POS_HOME_ROUTES.deductPoints)}
								/>
							) : null}
							<HomeActionGridButton
								title="History"
								icon={ClipboardList}
								iconTint={BRAND_BLUE}
								onClick={() => navigate(POS_HOME_ROUTES.transactions)}
							/>
							{!pointSystemEnabled ? (
								<HomeActionGridButton
									title="Link App"
									icon={Link2}
									iconTint={BRAND_BLUE}
									onClick={() => navigate(POS_HOME_ROUTES.nativeAction('linkApp'))}
								/>
							) : null}
						</div>

						{pointSystemEnabled ? (
							<div
								className="grid grid-cols-2 gap-3"
								style={{ height: heights.actionRow, minHeight: heights.actionRow }}
							>
								<HomeActionGridButton
									title="Link App"
									icon={Link2}
									iconTint={BRAND_BLUE}
									onClick={() => navigate(POS_HOME_ROUTES.nativeAction('linkApp'))}
								/>
								<div aria-hidden />
							</div>
						) : null}
					</div>
				</div>
			</PosScreenMain>
		</PosScreenShell>
	)
}

function HomeDataCard({
	title,
	value,
	titleClassName,
}: {
	title: string
	value: string
	titleClassName: string
}) {
	return (
		<div className="flex h-[86px] flex-col items-center justify-center gap-1.5 rounded-3xl border border-slate-200/70 bg-white px-3 shadow-[0_2px_8px_rgba(0,0,0,0.06)] sm:h-[96px]">
			<p
				className={`text-[10px] font-black uppercase tracking-[0.16em] ${titleClassName}`}
			>
				{title}
			</p>
			<p className="max-w-full truncate text-xl font-bold tabular-nums text-slate-900 sm:text-2xl">
				{value}
			</p>
		</div>
	)
}

/** iOS `homeActionGridButton`: centered icon in tinted circle + title. */
function HomeActionGridButton({
	title,
	icon: Icon,
	iconTint,
	onClick,
	disabled = false,
}: {
	title: string
	icon: LucideIcon
	iconTint: string
	onClick: () => void
	disabled?: boolean
}) {
	return (
		<button
			type="button"
			onClick={onClick}
			disabled={disabled}
			className="flex h-full min-h-0 flex-col items-center justify-center gap-2 rounded-3xl border border-slate-200/70 bg-white px-2 py-2 shadow-[0_2px_8px_rgba(0,0,0,0.06)] active:scale-[0.99] disabled:cursor-not-allowed disabled:opacity-50 sm:gap-3 sm:px-3 sm:py-3"
		>
			<span
				className="flex h-10 w-10 items-center justify-center rounded-full sm:h-12 sm:w-12"
				style={{ backgroundColor: `${iconTint}1f` }}
			>
				<Icon className="h-5 w-5 sm:h-[22px] sm:w-[22px]" style={{ color: iconTint }} aria-hidden />
			</span>
			<span className="text-center text-xs font-bold leading-tight text-slate-900 sm:text-sm">
				{title}
			</span>
		</button>
	)
}
