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
import { fetchMerchantCardCouponBurnSupported } from '@/api/beamioApi'
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
	completeCouponSurrenderViaNfcHostedKey,
	completeCouponSurrenderViaOpenContainer,
	consumeMerchantCouponFromRead,
} from '@/utils/readBalanceCouponConsume'
import {
	assetsForCheckBalanceCouponDisplay,
	checkBalanceUsesNfcCouponWorkflow,
	checkBalanceHasStoredValidOfflineContainer,
	type CheckBalanceQrContext,
} from '@/utils/readBalanceCouponDisplay'
import { runPosChargeScanFlow } from '@/utils/posScanFlow'
import { isPlausibleEvmAddress } from '@/utils/evmAddress'
import { resolvePosTerminalSignerEoa } from '@/utils/resolvePosTerminalSignerEoa'
import { formatCouponConsumeErrorMessage } from '@/utils/formatCouponConsumeErrorMessage'
import { formatCouponClaimErrorMessage } from '@/utils/formatCouponClaimErrorMessage'

export interface CheckBalanceLocationState {
	assets?: UIDAssetsResult
	nfcScan?: CheckBalanceNfcScanContext
	qrClassification?: CheckBalanceQrContext
	merchantSupportsBurn?: boolean | null
}

type Phase =
	| 'loading'
	| 'result'
	| 'deduct-amount'
	| 'deduct-executing'
	| 'deduct-success'
	| 'consume-executing'

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
	const [qrClassification, setQrClassification] = useState<CheckBalanceQrContext>(
		navState?.qrClassification ?? null,
	)
	const [merchantSupportsBurn, setMerchantSupportsBurn] = useState<boolean | null>(
		navState?.merchantSupportsBurn ?? null,
	)
	const [claimInFlightId, setClaimInFlightId] = useState<string | null>(null)
	const [claimSucceededId, setClaimSucceededId] = useState<string | null>(null)
	const [consumeInFlightId, setConsumeInFlightId] = useState<string | null>(null)
	const [consumeSucceededId, setConsumeSucceededId] = useState<string | null>(null)
	const [deductProgress, setDeductProgress] = useState<DeductExecuteProgressPhase>('preparing')
	const [deductKeypadAmount, setDeductKeypadAmount] = useState('')
	const [deductSuccess, setDeductSuccess] = useState<DeductExecuteSuccess | null>(null)
	const [couponToast, setCouponToast] = useState<{ kind: 'success' | 'error'; text: string } | null>(
		null,
	)
	const flowStartedRef = useRef(false)

	useEffect(() => {
		if (!couponToast) return
		const ms = couponToast.kind === 'error' ? 6000 : 3500
		const t = setTimeout(() => setCouponToast(null), ms)
		return () => clearTimeout(t)
	}, [couponToast])

	useEffect(() => {
		if (!assets?.ok || !infraCard || merchantSupportsBurn !== null) return
		let cancelled = false
		void fetchMerchantCardCouponBurnSupported(infraCard).then((supported) => {
			if (!cancelled && supported !== null) setMerchantSupportsBurn(supported)
		})
		return () => {
			cancelled = true
		}
	}, [assets?.ok, infraCard, merchantSupportsBurn])

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
				setQrClassification(outcome.qrClassification ?? null)
				setMerchantSupportsBurn(outcome.merchantSupportsBurn)
				setPhase('result')
				navigate(POS_HOME_ROUTES.checkBalance, {
					replace: true,
					state: {
						assets: outcome.assets,
						nfcScan: outcome.nfcScan,
						qrClassification: outcome.qrClassification ?? null,
						merchantSupportsBurn: outcome.merchantSupportsBurn,
					},
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
				state: {
					assets: next,
					nfcScan,
					qrClassification,
					merchantSupportsBurn,
				},
			})
		},
		[navigate, nfcScan, qrClassification, merchantSupportsBurn],
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
				setCouponToast({ kind: 'error', text: formatCouponClaimErrorMessage(result.message) })
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
			setConsumeSucceededId(null)
			setPhase('consume-executing')

			const finishConsume = (result: {
				status: 'success' | 'error'
				message?: string
				nextAssets?: UIDAssetsResult
				clearClaim?: boolean
			}) => {
				setConsumeInFlightId(null)
				setPhase('result')
				if (result.status === 'error') {
					setCouponToast({
						kind: 'error',
						text: formatCouponConsumeErrorMessage(result.message),
					})
					return
				}
				if (result.nextAssets) syncAssets(result.nextAssets)
				if (result.clearClaim) setClaimSucceededId(null)
				setConsumeSucceededId(rowId)
			}

			try {
				const signerEOA = await resolvePosTerminalSignerEoa(walletAddress)
				const posOp = signerEOA ?? walletAddress?.trim() ?? ''
				const storedOfflinePayload = checkBalanceHasStoredValidOfflineContainer(qrClassification)
					? qrClassification.offlineContainerPayload
					: null
				const result = await consumeMerchantCouponFromRead({
					assets,
					coupon,
					signerEOA,
					claimSucceededId,
					storedOfflineContainerPayload: storedOfflinePayload,
					posOperator: posOp || null,
					merchantInfraCard: infraCard || coupon.cardAddress,
					nfcScan,
				})

				if (result.status === 'needs_pay_qr') {
					setPhase('result')
					setCouponToast({
						kind: 'success',
						text: 'Scan the customer Pay QR to complete coupon redeem.',
					})
					const scan = await runPosChargeScanFlow()
					if (scan.status === 'nfc') {
						if (!posOp) {
							finishConsume({ status: 'error', message: 'Terminal wallet not configured.' })
							return
						}
						const nfcUid =
							scan.detail.queryUid?.trim() ||
							scan.detail.tagUidHex?.trim() ||
							assets.uid?.trim() ||
							''
						setPhase('consume-executing')
						const nfcSurrender = await completeCouponSurrenderViaNfcHostedKey({
							assets,
							coupon,
							surrender: result.surrender,
							posOperator: posOp,
							merchantInfraCard: infraCard || coupon.cardAddress,
							signerEOA,
							uid: nfcUid || null,
							tagIdHex: assets.tagIdHex,
							claimSucceededId,
						})
						if (nfcSurrender.status === 'error') {
							finishConsume({ status: 'error', message: nfcSurrender.message })
							return
						}
						if (nfcSurrender.status === 'needs_pay_qr') {
							finishConsume({ status: 'error', message: 'Unexpected surrender state.' })
							return
						}
						finishConsume({
							status: 'success',
							nextAssets: nfcSurrender.assets,
							clearClaim: nfcSurrender.clearClaimSucceededId,
						})
						return
					}
					if (scan.status === 'aborted') {
						setConsumeInFlightId(null)
						setPhase('result')
						return
					}
					if (scan.status === 'error') {
						finishConsume({ status: 'error', message: scan.message })
						return
					}
					if (!posOp) {
						finishConsume({ status: 'error', message: 'Terminal wallet not configured.' })
						return
					}
					setPhase('consume-executing')
					const surrenderResult = await completeCouponSurrenderViaOpenContainer({
						assets,
						coupon,
						surrender: result.surrender,
						openContainerPayload: scan.payload,
						posOperator: posOp,
						merchantInfraCard: infraCard || coupon.cardAddress,
						claimSucceededId,
					})
					if (surrenderResult.status === 'error') {
						finishConsume({ status: 'error', message: surrenderResult.message })
						return
					}
					if (surrenderResult.status === 'needs_pay_qr') {
						finishConsume({ status: 'error', message: 'Unexpected surrender state.' })
						return
					}
					finishConsume({
						status: 'success',
						nextAssets: surrenderResult.assets,
						clearClaim: surrenderResult.clearClaimSucceededId,
					})
					return
				}

				if (result.status === 'error') {
					finishConsume({ status: 'error', message: result.message })
					return
				}

				finishConsume({
					status: 'success',
					nextAssets: result.assets,
					clearClaim: result.clearClaimSucceededId,
				})
			} catch (err) {
				const message = err instanceof Error ? err.message : String(err)
				finishConsume({ status: 'error', message })
			}
		},
		[assets, claimInFlightId, claimSucceededId, consumeInFlightId, infraCard, nfcScan, qrClassification, syncAssets, walletAddress],
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

	if (phase === 'consume-executing') {
		return (
			<PosScanExecutingShell
				title="Consume Coupon"
				center={<PosTopupExecutingCard signingInProgress={false} />}
			/>
		)
	}

	const vm = readBalanceResultViewModel(assets, infraCard, pointSystemEnabled)
	const entryViaNfc = checkBalanceUsesNfcCouponWorkflow({ nfcScan, assets })
	const couponDisplayAssets = assetsForCheckBalanceCouponDisplay(assets, {
		merchantSupportsBurn,
		qrContext: qrClassification,
		entryViaNfc,
		consumeSucceededId,
	})
	const deductBusy =
		claimInFlightId != null || consumeInFlightId != null || phase !== 'result'

	function onBack() {
		navigate(POS_HOME_ROUTES.home, { replace: true })
	}

	return (
		<PosScreenShell bg="bg-[#F9F9FE]">
			<div className="relative flex min-h-0 flex-1 flex-col">
				{couponToast ? (
					<div
						className={`fixed left-4 right-4 z-30 rounded-2xl border px-4 py-3 text-sm font-semibold shadow-md ${
							couponToast.kind === 'success'
								? 'border-emerald-200 bg-emerald-50 text-emerald-900'
								: 'border-red-200 bg-red-50 text-red-900'
						}`}
						style={{ top: 'max(3.25rem, calc(env(safe-area-inset-top, 0px) + 2.5rem))' }}
						role="alert"
						aria-live="assertive"
					>
						{couponToast.text}
					</div>
				) : null}
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
							assets={couponDisplayAssets}
							activeCoupons={activeCoupons}
							claimInFlightId={claimInFlightId}
							claimSucceededId={claimSucceededId}
							consumeInFlightId={consumeInFlightId}
							consumeSucceededId={consumeSucceededId}
							onClaimCoupon={(coupon) => void handleClaimCoupon(coupon)}
							onConsumeCoupon={(coupon) => void handleConsumeCoupon(coupon)}
						/>
					</div>
				</PosScreenMain>
			</div>
		</PosScreenShell>
	)
}
