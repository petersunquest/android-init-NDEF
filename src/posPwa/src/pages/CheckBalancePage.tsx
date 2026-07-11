import { useCallback, useEffect, useRef, useState } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { cancelCheckBalanceFlow } from '@/utils/checkBalanceFlow'
import { BeamioCircularBackButton } from '@/components/BeamioCircularBackButton'
import { DeductPointsAmountPadPage } from '@/components/DeductPointsAmountPadPage'
import { DeductPointsSuccessView } from '@/components/DeductPointsSuccessView'
import { PosFlowLoadingShell } from '@/components/PosFlowLoadingShell'
import { PosScanExecutingShell } from '@/components/PosScanExecutingShell'
import { PosTopupExecutingCard } from '@/components/PosTopupExecutingCard'
import { ReadBalanceCouponsSection } from '@/components/ReadBalanceCouponsSection'
import { ReadBalancePassHeroCard } from '@/components/ReadBalancePassHeroCard'
import { ReadBalanceStatsCard } from '@/components/ReadBalanceStatsCard'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { usePosSession } from '@/providers/PosSessionProvider'
import type { MerchantClaimableCouponItem, MerchantCouponBalanceItem, UIDAssetsResult } from '@/types/pos'
import { runCheckBalanceFlow } from '@/utils/checkBalanceFlow'
import type { CheckBalanceNfcScanContext } from '@/utils/checkBalanceFlow'
import {
	deductChargeRewardPoints6,
	deductCustomerTargetFromAssets,
	executeDeductPoints,
	type DeductExecuteProgressPhase,
	type DeductExecuteSuccess,
} from '@/utils/deductPointsExecute'
import { POS_HOME_ROUTES } from '@/utils/posHomeActionRoutes'
import type { PosHomeLocationState } from '@/utils/posHomeLocationState'
import { readBalanceResultViewModel } from '@/utils/readBalanceDisplay'
import {
	claimMerchantCouponFromRead,
	merchantCouponRowId,
	readBalanceClaimUserEoa,
	readBalanceHasCouponClaimContext,
} from '@/utils/readBalanceCouponClaim'
import {
	completeCouponSurrenderViaOpenContainer,
	consumeMerchantCouponFromRead,
} from '@/utils/readBalanceCouponConsume'
import { runPosChargeScanFlow } from '@/utils/posScanFlow'
import { isPlausibleEvmAddress } from '@/utils/evmAddress'
import { resolvePosTerminalSignerEoa } from '@/utils/resolvePosTerminalSignerEoa'

export interface CheckBalanceLocationState {
	assets?: UIDAssetsResult
	nfcScan?: CheckBalanceNfcScanContext
}

type Phase = 'loading' | 'result' | 'deduct-amount' | 'deduct-executing' | 'deduct-success'

/**
 * Entry from Home → loading until NFC/QR flow finishes, then result or return Home.
 * Home is never visible while Check Balance is in progress.
 */
export function CheckBalancePage() {
	const navigate = useNavigate()
	const location = useLocation()
	const { merchantInfraCard, pointSystemEnabled, activeCoupons, walletAddress } = usePosSession()
	const infraCard = merchantInfraCard?.trim() ?? ''

	const navState = location.state as CheckBalanceLocationState | null
	const navAssets = navState?.assets
	const initialAssets = navAssets?.ok ? navAssets : null

	const [phase, setPhase] = useState<Phase>(initialAssets ? 'result' : 'loading')
	const [assets, setAssets] = useState<UIDAssetsResult | null>(initialAssets)
	const [nfcScan, setNfcScan] = useState<CheckBalanceNfcScanContext | undefined>(
		navState?.nfcScan,
	)
	const [claimInFlightId, setClaimInFlightId] = useState<string | null>(null)
	const [claimSucceededId, setClaimSucceededId] = useState<string | null>(null)
	const [consumeInFlightId, setConsumeInFlightId] = useState<string | null>(null)
	const [deductProgress, setDeductProgress] = useState<DeductExecuteProgressPhase>('preparing')
	const [deductKeypadAmount, setDeductKeypadAmount] = useState('')
	const [deductSuccess, setDeductSuccess] = useState<DeductExecuteSuccess | null>(null)
	const [couponToast, setCouponToast] = useState<{ kind: 'success' | 'error'; text: string } | null>(
		null,
	)
	const flowStartedRef = useRef(false)

	useEffect(() => {
		if (!couponToast) return
		const t = setTimeout(() => setCouponToast(null), 3500)
		return () => clearTimeout(t)
	}, [couponToast])

	useEffect(() => {
		if (phase !== 'loading' || assets?.ok || flowStartedRef.current) return
		flowStartedRef.current = true

		let cancelled = false

		void (async () => {
			const outcome = await runCheckBalanceFlow(infraCard)
			if (cancelled) return

			if (outcome.status === 'success') {
				setAssets(outcome.assets)
				setNfcScan(outcome.nfcScan)
				setPhase('result')
				navigate(POS_HOME_ROUTES.checkBalance, {
					replace: true,
					state: { assets: outcome.assets, nfcScan: outcome.nfcScan },
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

	const syncAssets = useCallback(
		(next: UIDAssetsResult) => {
			setAssets(next)
			navigate(POS_HOME_ROUTES.checkBalance, {
				replace: true,
				state: { assets: next, nfcScan },
			})
		},
		[navigate, nfcScan],
	)

	const handleClaimCoupon = useCallback(
		async (coupon: MerchantClaimableCouponItem) => {
			if (claimInFlightId) return
			if (!assets?.ok) {
				setCouponToast({ kind: 'error', text: 'No loaded balance context.' })
				return
			}
			if (!readBalanceHasCouponClaimContext(assets)) {
				setCouponToast({ kind: 'error', text: 'Claim requires member wallet or NFC card.' })
				return
			}
			const user = readBalanceClaimUserEoa(assets)
			if (!isPlausibleEvmAddress(user)) {
				setCouponToast({ kind: 'error', text: 'Invalid user account for claim.' })
				return
			}
			const signerEOA = await resolvePosTerminalSignerEoa(walletAddress)
			const needsPosAdmin =
				!assets.uid?.trim() && !assets.tagIdHex?.trim()
			if (needsPosAdmin && !signerEOA) {
				setCouponToast({
					kind: 'error',
					text: 'Terminal wallet not initialized. POS admin is required for QR claim.',
				})
				return
			}
			const rowId = merchantCouponRowId(coupon.cardAddress, coupon.tokenId)
			setClaimInFlightId(rowId)
			setClaimSucceededId(null)

			const result = await claimMerchantCouponFromRead({
				assets,
				coupon,
				signerEOA,
			})

			setClaimInFlightId(null)

			if (result.status === 'error') {
				setCouponToast({ kind: 'error', text: result.message })
				return
			}

			syncAssets(result.assets)
			setClaimSucceededId(rowId)
			setCouponToast({ kind: 'success', text: 'Coupon claimed.' })
		},
		[assets, claimInFlightId, syncAssets, walletAddress],
	)

	const handleConsumeCoupon = useCallback(
		async (coupon: MerchantCouponBalanceItem) => {
			if (consumeInFlightId || claimInFlightId) return
			if (!assets?.ok) {
				setCouponToast({ kind: 'error', text: 'No loaded balance context.' })
				return
			}
			const rowId = merchantCouponRowId(coupon.cardAddress, coupon.tokenId)
			setConsumeInFlightId(rowId)

			const signerEOA = await resolvePosTerminalSignerEoa(walletAddress)
			const result = await consumeMerchantCouponFromRead({
				assets,
				coupon,
				signerEOA,
				claimSucceededId,
			})

			if (result.status === 'needs_pay_qr') {
				setCouponToast({
					kind: 'success',
					text: 'Scan the customer Pay QR to complete coupon redeem.',
				})
				const scan = await runPosChargeScanFlow()
				if (scan.status === 'nfc') {
					setConsumeInFlightId(null)
					setCouponToast({
						kind: 'error',
						text: 'Coupon redeem requires Scan to Pay QR, not NFC.',
					})
					return
				}
				if (scan.status === 'aborted') {
					setConsumeInFlightId(null)
					return
				}
				if (scan.status === 'error') {
					setConsumeInFlightId(null)
					setCouponToast({ kind: 'error', text: scan.message })
					return
				}
				const posOp = signerEOA ?? walletAddress?.trim() ?? ''
				if (!posOp) {
					setConsumeInFlightId(null)
					setCouponToast({ kind: 'error', text: 'Terminal wallet not configured.' })
					return
				}
				const surrenderResult = await completeCouponSurrenderViaOpenContainer({
					assets,
					coupon,
					surrender: result.surrender,
					openContainerPayload: scan.payload,
					posOperator: posOp,
					merchantInfraCard: infraCard || coupon.cardAddress,
					claimSucceededId,
				})
				setConsumeInFlightId(null)
				if (surrenderResult.status === 'error') {
					setCouponToast({ kind: 'error', text: surrenderResult.message })
					return
				}
				if (surrenderResult.status === 'needs_pay_qr') {
					setCouponToast({ kind: 'error', text: 'Unexpected surrender state.' })
					return
				}
				syncAssets(surrenderResult.assets)
				if (surrenderResult.clearClaimSucceededId) setClaimSucceededId(null)
				setCouponToast({ kind: 'success', text: 'Coupon consumed.' })
				return
			}

			setConsumeInFlightId(null)

			if (result.status === 'error') {
				setCouponToast({ kind: 'error', text: result.message })
				return
			}

			syncAssets(result.assets)
			if (result.clearClaimSucceededId) setClaimSucceededId(null)
			setCouponToast({ kind: 'success', text: 'Coupon consumed.' })
		},
		[assets, claimInFlightId, claimSucceededId, consumeInFlightId, infraCard, syncAssets, walletAddress],
	)

	const runDeductFromReadBalance = useCallback(
		async (keypadAmount: string) => {
			if (!assets?.ok) {
				setCouponToast({ kind: 'error', text: 'No loaded balance context.' })
				setPhase('result')
				return
			}
			setPhase('deduct-executing')
			setDeductKeypadAmount(keypadAmount)
			setDeductProgress('preparing')

			const outcome = await executeDeductPoints({
				target: deductCustomerTargetFromAssets(assets, nfcScan),
				keypadAmount,
				merchantInfraCard: infraCard,
				pointSystemEnabled,
				preloadedAssets: assets,
				onProgress: setDeductProgress,
			})

			if (outcome.status === 'error') {
				setCouponToast({ kind: 'error', text: outcome.message })
				setPhase('result')
				return
			}

			syncAssets(outcome.result.patchedAssets)
			setDeductSuccess(outcome.result)
			setPhase('deduct-success')
		},
		[assets, infraCard, nfcScan, pointSystemEnabled, syncAssets],
	)

	if (phase === 'deduct-success' && deductSuccess) {
		return (
			<DeductPointsSuccessView
				result={deductSuccess}
				pointSystemEnabled={pointSystemEnabled}
				onDone={() => {
					setDeductSuccess(null)
					setPhase('result')
				}}
			/>
		)
	}

	if (phase === 'loading' || !assets?.ok) {
		return (
			<PosFlowLoadingShell
				title="Check Balance"
				subtitle="Waiting for NFC or QR scan…"
			/>
		)
	}

	if (phase === 'deduct-amount' && assets?.ok) {
		const maxPoints6 = deductChargeRewardPoints6(assets, infraCard)
		return (
			<DeductPointsAmountPadPage
				maxPoints6={maxPoints6}
				onCancel={() => setPhase('result')}
				onContinue={(amount) => void runDeductFromReadBalance(amount)}
			/>
		)
	}

	if (phase === 'deduct-executing') {
		const pts = Number(deductKeypadAmount.replace(/,/g, '')) || 0
		return (
			<PosScanExecutingShell
				title="Deduct Points"
				center={
					<PosTopupExecutingCard signingInProgress={deductProgress === 'signing'} />
				}
				bottomAmount={pts > 0 ? pts : undefined}
				bottomTone="deduct"
			/>
		)
	}

	const vm = readBalanceResultViewModel(assets, infraCard, pointSystemEnabled)
	const deductBusy =
		claimInFlightId != null || consumeInFlightId != null || phase !== 'result'

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
							pointRewardPts={vm.rewardPtsAmount}
							onDeductPoints={
								pointSystemEnabled ? () => setPhase('deduct-amount') : undefined
							}
							deductPointsDisabled={deductBusy}
						/>
						<ReadBalanceStatsCard
							assets={assets}
							cardCurrency={vm.balCurrency}
							usdcBalance={vm.usdcBal}
							caddBalance={vm.caddBal}
						/>
						<ReadBalanceCouponsSection
							assets={assets}
							activeCoupons={activeCoupons}
							claimInFlightId={claimInFlightId}
							claimSucceededId={claimSucceededId}
							consumeInFlightId={consumeInFlightId}
							onClaimCoupon={(coupon) => void handleClaimCoupon(coupon)}
							onConsumeCoupon={(coupon) => void handleConsumeCoupon(coupon)}
						/>
						{couponToast ? (
							<div
								className={`rounded-2xl border px-4 py-3 text-sm font-medium ${
									couponToast.kind === 'success'
										? 'border-emerald-200 bg-emerald-50 text-emerald-800'
										: 'border-red-200 bg-red-50 text-red-800'
								}`}
								role="status"
							>
								{couponToast.text}
							</div>
						) : null}
					</div>
				</PosScreenMain>
			</div>
		</PosScreenShell>
	)
}
