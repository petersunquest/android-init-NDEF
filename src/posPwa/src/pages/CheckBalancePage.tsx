import { useEffect, useRef, useState } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { cancelCheckBalanceFlow } from '@/utils/checkBalanceFlow'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { PosFlowLoadingShell } from '@/components/PosFlowLoadingShell'
import { ReadBalanceCouponsSection } from '@/components/ReadBalanceCouponsSection'
import { ReadBalancePassHeroCard } from '@/components/ReadBalancePassHeroCard'
import { ReadBalanceStatsCard } from '@/components/ReadBalanceStatsCard'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { usePosSession } from '@/providers/PosSessionProvider'
import type { UIDAssetsResult } from '@/types/pos'
import { runCheckBalanceFlow } from '@/utils/checkBalanceFlow'
import { POS_HOME_ROUTES } from '@/utils/posHomeActionRoutes'
import type { PosHomeLocationState } from '@/utils/posHomeLocationState'
import { readBalanceResultViewModel } from '@/utils/readBalanceDisplay'

export interface CheckBalanceLocationState {
	assets?: UIDAssetsResult
}

type Phase = 'loading' | 'result'

/**
 * Entry from Home → loading until NFC/QR flow finishes, then result or return Home.
 * Home is never visible while Check Balance is in progress.
 */
export function CheckBalancePage() {
	const navigate = useNavigate()
	const location = useLocation()
	const { merchantInfraCard, pointSystemEnabled, activeCoupons } = usePosSession()
	const infraCard = merchantInfraCard?.trim() ?? ''

	const navAssets = (location.state as CheckBalanceLocationState | null)?.assets
	const initialAssets = navAssets?.ok ? navAssets : null

	const [phase, setPhase] = useState<Phase>(initialAssets ? 'result' : 'loading')
	const [assets, setAssets] = useState<UIDAssetsResult | null>(initialAssets)
	const flowStartedRef = useRef(false)

	useEffect(() => {
		if (phase !== 'loading' || assets?.ok || flowStartedRef.current) return
		flowStartedRef.current = true

		let cancelled = false

		void (async () => {
			const outcome = await runCheckBalanceFlow(infraCard)
			if (cancelled) return

			if (outcome.status === 'success') {
				setAssets(outcome.assets)
				setPhase('result')
				navigate(POS_HOME_ROUTES.checkBalance, {
					replace: true,
					state: { assets: outcome.assets },
				})
				return
			}

			const homeState: PosHomeLocationState =
				outcome.status === 'error' ? { homeActionError: outcome.message } : {}
			navigate(POS_HOME_ROUTES.home, { replace: true, state: homeState })
		})()

		return () => {
			cancelled = true
			cancelCheckBalanceFlow()
		}
	}, [assets?.ok, infraCard, navigate, phase])

	if (phase === 'loading' || !assets?.ok) {
		return (
			<PosFlowLoadingShell
				title="Check Balance"
				subtitle="Waiting for NFC or QR scan…"
			/>
		)
	}

	const vm = readBalanceResultViewModel(assets, infraCard, pointSystemEnabled)

	function onBack() {
		navigate(POS_HOME_ROUTES.home, { replace: true })
	}

	return (
		<PosScreenShell bg="bg-[#F9F9FE]">
			<div className="relative flex min-h-0 flex-1 flex-col">
				<BeamioCircularBackButton
					onClick={onBack}
					className="absolute left-2 top-[max(0.375rem,env(safe-area-inset-top))] z-10"
				/>
				<PosScreenMain className="overflow-y-auto px-5 pb-[max(1rem,env(safe-area-inset-bottom))] pt-14">
					<div className="space-y-3 pb-6">
						<ReadBalancePassHeroCard
							memberDisplayName={vm.memberDisplay}
							memberNo={vm.memberNo}
							tierDisplayName={vm.tierName}
							tierDiscountPercent={vm.tierDiscount}
							programCardDisplayName={vm.programLine}
							tierCardBackgroundHex={vm.bgHex}
							cardMetadataImageUrl={vm.cardImageUrl}
							balanceParts={vm.balanceParts}
							balanceSubtitle={vm.rewardSubtitle}
						/>
						<ReadBalanceStatsCard
							assets={assets}
							cardCurrency={vm.balCurrency}
							usdcBalance={vm.usdcBal}
							caddBalance={vm.caddBal}
						/>
						<ReadBalanceCouponsSection assets={assets} activeCoupons={activeCoupons} />
					</div>
				</PosScreenMain>
			</div>
		</PosScreenShell>
	)
}
