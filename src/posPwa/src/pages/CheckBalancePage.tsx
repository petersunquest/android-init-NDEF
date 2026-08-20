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
import { ReadBalanceMembershipSection } from '@/components/ReadBalanceMembershipSection'
import { TopupUsdcQrPanel } from '@/components/TopupUsdcQrPanel'
import { ReadBalancePassHeroCard } from '@/components/ReadBalancePassHeroCard'
import { ReadBalanceStatsCard } from '@/components/ReadBalanceStatsCard'
import { TopupSuccessView } from '@/components/TopupSuccessView'
import { PosScreenMain, PosScreenShell } from '@/components/PosScreenShell'
import { usePosSession } from '@/providers/PosSessionProvider'
import type { MerchantClaimableCouponItem, MerchantCouponBalanceItem, UIDAssetsResult } from '@/types/pos'
import {
	fetchCardCurrencyCode,
	fetchCardMetadataTiersBundle,
	fetchCardOwner,
	fetchUIDAssets,
	fetchWalletAssetsForRead,
} from '@/api/beamioApi'
import { runCheckBalanceFlow } from '@/utils/checkBalanceFlow'
import type { CheckBalanceNfcScanContext } from '@/utils/checkBalanceFlow'
import {
	deductChargeRewardPoints6,
	deductCustomerTargetFromAssets,
	executeDeductPoints,
	type DeductExecuteProgressPhase,
	type DeductExecuteSuccess,
} from '@/utils/deductPointsExecute'
import { displayFiatPrefixFromCode } from '@/utils/display'
import { POS_HOME_ROUTES } from '@/utils/posHomeActionRoutes'
import type { PosHomeLocationState } from '@/utils/posHomeLocationState'
import { cancelPosCustomerScan, runPosCustomerScanFlow } from '@/utils/posScanFlow'
import { readBalanceResultViewModel } from '@/utils/readBalanceDisplay'
import {
	claimMerchantCouponFromRead,
	merchantCouponRowId,
	readBalanceClaimUserEoa,
	readBalanceHasCouponClaimContext,
} from '@/utils/readBalanceCouponClaim'
import { consumeMerchantCouponFromRead } from '@/utils/readBalanceCouponConsume'
import {
	membershipPurchaseApiAmountHuman,
	readBalanceCustomerHasValidMembership,
	readBalanceMembershipFeeTiers,
	type ReadBalanceMembershipTierChoice,
} from '@/utils/readBalanceMembership'
import { isPlausibleEvmAddress } from '@/utils/evmAddress'
import { resolvePosTerminalSignerEoa } from '@/utils/resolvePosTerminalSignerEoa'
import { membershipFeeE6ToHuman } from '@/utils/beamioPaymentRouting'
import { nfcTopupCurrencySplitFromPosKeypad } from '@/utils/topupCurrencySplit'
import type { TopupPaymentMethodRaw } from '@/utils/topupPaymentMethod'
import {
	executeNfcTopup,
	type TopupCustomerTarget,
	type TopupExecuteProgressPhase,
	type TopupExecuteSuccess,
} from '@/utils/topupExecute'
import {
	buildUsdcTopupQrUrlPhase1,
	buildUsdcTopupQrUrlWithNfc,
	newTopupUsdcSessionId,
	pollUsdcTopupSession,
	usdcTopupCustomerHint,
} from '@/utils/topupUsdcSession'

export interface CheckBalanceLocationState {
	assets?: UIDAssetsResult
	nfcScan?: CheckBalanceNfcScanContext
	openContainerPayload?: Record<string, unknown>
}

type Phase =
	| 'loading'
	| 'result'
	| 'deduct-amount'
	| 'deduct-executing'
	| 'deduct-success'
	| 'membership-usdc-qr'
	| 'membership-scan-nfc-after-usdc'
	| 'membership-executing'
	| 'membership-success'

function customerTargetFromScan(
	scan:
		| { status: 'nfc'; detail: { queryUid?: string; tagUidHex?: string; sun?: { e: string; c: string; m: string } } }
		| { status: 'qr'; identity: { beamioTag?: string; wallet?: string } },
): TopupCustomerTarget | null {
	if (scan.status === 'nfc') {
		const uid = (scan.detail.queryUid ?? scan.detail.tagUidHex ?? '').trim()
		if (!uid || !scan.detail.sun) return null
		return { uid, sun: scan.detail.sun }
	}
	if (scan.identity.beamioTag?.trim()) {
		return { beamioTag: scan.identity.beamioTag.trim() }
	}
	if (scan.identity.wallet) {
		return { wallet: scan.identity.wallet }
	}
	return null
}

/**
 * Entry from Home → loading until NFC/QR flow finishes, then result or return Home.
 * Home is never visible while Check Balance is in progress.
 */
export function CheckBalancePage() {
	const navigate = useNavigate()
	const location = useLocation()
	const { merchantInfraCard, pointSystemEnabled, activeCoupons, walletAddress, refreshHome } =
		usePosSession()
	const infraCard = merchantInfraCard?.trim() ?? ''

	const navState = location.state as CheckBalanceLocationState | null
	const navAssets = navState?.assets
	const initialAssets = navAssets?.ok ? navAssets : null

	const [phase, setPhase] = useState<Phase>(initialAssets ? 'result' : 'loading')
	const [assets, setAssets] = useState<UIDAssetsResult | null>(initialAssets)
	const [nfcScan, setNfcScan] = useState<CheckBalanceNfcScanContext | undefined>(
		navState?.nfcScan,
	)
	const [openContainerPayload, setOpenContainerPayload] = useState<
		Record<string, unknown> | undefined
	>(navState?.openContainerPayload)
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

	const [membershipTiers, setMembershipTiers] = useState<ReadBalanceMembershipTierChoice[]>([])
	const [membershipCurrencyPrefix, setMembershipCurrencyPrefix] = useState('$')
	const [selectedMembershipTier, setSelectedMembershipTier] =
		useState<ReadBalanceMembershipTierChoice | null>(null)
	const [membershipProgress, setMembershipProgress] =
		useState<TopupExecuteProgressPhase>('preparing')
	const [membershipSuccess, setMembershipSuccess] = useState<TopupExecuteSuccess | null>(null)
	const [membershipUsdcTarget, setMembershipUsdcTarget] = useState<TopupCustomerTarget | null>(
		null,
	)
	const [usdcDeepLink, setUsdcDeepLink] = useState('')
	const [usdcHint, setUsdcHint] = useState('')
	const [usdcProgress, setUsdcProgress] = useState('')
	const [usdcSid, setUsdcSid] = useState('')
	const membershipScanStartedRef = useRef(false)
	const pollAbortRef = useRef<AbortController | null>(null)

	useEffect(() => {
		if (!couponToast) return
		const ms = couponToast.kind === 'error' ? 8000 : 3500
		const t = setTimeout(() => setCouponToast(null), ms)
		return () => clearTimeout(t)
	}, [couponToast])

	useEffect(() => {
		if (!infraCard) {
			setMembershipTiers([])
			return
		}
		let cancelled = false
		void (async () => {
			const [tiersBundle, currency] = await Promise.all([
				fetchCardMetadataTiersBundle(infraCard),
				fetchCardCurrencyCode(infraCard),
			])
			if (cancelled) return
			setMembershipTiers(readBalanceMembershipFeeTiers(tiersBundle.rows))
			setMembershipCurrencyPrefix(displayFiatPrefixFromCode(currency ?? 'CAD', 'CAD'))
		})()
		return () => {
			cancelled = true
		}
	}, [infraCard])

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
				setOpenContainerPayload(outcome.openContainerPayload)
				setPhase('result')
				navigate(POS_HOME_ROUTES.checkBalance, {
					replace: true,
					state: {
						assets: outcome.assets,
						nfcScan: outcome.nfcScan,
						openContainerPayload: outcome.openContainerPayload,
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
				state: { assets: next, nfcScan, openContainerPayload },
			})
		},
		[navigate, nfcScan, openContainerPayload],
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
				nfcScan,
				openContainerPayload,
			})

			setConsumeInFlightId(null)

			if (result.status === 'error') {
				setCouponToast({ kind: 'error', text: result.message })
				return
			}

			syncAssets(result.assets)
			if (result.clearClaimSucceededId) setClaimSucceededId(null)
			setCouponToast({ kind: 'success', text: 'Coupon consumed.' })
		},
		[
			assets,
			claimInFlightId,
			claimSucceededId,
			consumeInFlightId,
			nfcScan,
			openContainerPayload,
			syncAssets,
			walletAddress,
		],
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

	const runMembershipTopup = useCallback(
		async (
			target: TopupCustomerTarget,
			tier: ReadBalanceMembershipTierChoice,
			method: TopupPaymentMethodRaw,
			usdcSessionId?: string,
		) => {
			if (!walletAddress) {
				setCouponToast({ kind: 'error', text: 'Wallet not initialized' })
				setPhase('result')
				return
			}
			const chargeHuman = membershipPurchaseApiAmountHuman(tier.feeFiat6, tier.minUsdc6)
			const posMethod = method === 'usdc' ? 'usdc' : 'cash'
			const split = nfcTopupCurrencySplitFromPosKeypad(chargeHuman, posMethod, false, 20)
			if (!split) {
				setCouponToast({ kind: 'error', text: 'Invalid membership fee amount.' })
				setPhase('result')
				return
			}
			setMembershipProgress('preparing')
			setPhase('membership-executing')
			const outcome = await executeNfcTopup({
				target,
				apiAmount: chargeHuman,
				currencySplit: split,
				merchantInfraCard: infraCard,
				posWallet: walletAddress,
				pointSystemEnabled,
				membershipTierIndex: tier.tierIndex,
				membershipFeeFiat6: tier.feeFiat6,
				usdcTopupSessionId: usdcSessionId,
				onProgress: setMembershipProgress,
			})
			if (outcome.status === 'error') {
				setCouponToast({ kind: 'error', text: outcome.message })
				setSelectedMembershipTier(null)
				setMembershipUsdcTarget(null)
				setPhase('result')
				return
			}

			let refreshed: UIDAssetsResult | null = null
			if (target.beamioTag) {
				refreshed = await fetchUIDAssets({
					uid: target.beamioTag,
					merchantInfraCard: infraCard,
				})
			} else if (target.wallet) {
				refreshed = await fetchWalletAssetsForRead({
					wallet: target.wallet,
					merchantInfraCard: infraCard,
				})
			} else if (target.uid && target.sun) {
				refreshed = await fetchUIDAssets({
					uid: target.uid,
					merchantInfraCard: infraCard,
					sun: target.sun,
				})
			}
			if (refreshed?.ok) {
				syncAssets(refreshed)
			}
			setMembershipSuccess(outcome.result)
			setSelectedMembershipTier(null)
			setMembershipUsdcTarget(null)
			setUsdcSid('')
			setPhase('membership-success')
			void refreshHome()
		},
		[infraCard, pointSystemEnabled, refreshHome, syncAssets, walletAddress],
	)

	const startMembershipUsdcQrFlow = useCallback(
		async (target: TopupCustomerTarget, tier: ReadBalanceMembershipTierChoice) => {
			if (!walletAddress) {
				setCouponToast({ kind: 'error', text: 'Wallet not initialized' })
				return
			}
			const infra = infraCard?.trim() ?? ''
			const owner = await fetchCardOwner(infra, walletAddress)
			if (!owner) {
				setCouponToast({ kind: 'error', text: 'Cannot resolve card owner. Please retry.' })
				return
			}
			const chargeHuman = membershipPurchaseApiAmountHuman(tier.feeFiat6, tier.minUsdc6)
			const currency = (await fetchCardCurrencyCode(infra)) ?? 'CAD'
			const sid = newTopupUsdcSessionId()
			setUsdcSid(sid)
			let link = ''
			if (target.uid && target.sun) {
				link = buildUsdcTopupQrUrlWithNfc({
					cardAddress: infra,
					cardOwner: owner,
					uid: target.uid,
					sun: target.sun,
					amount: chargeHuman,
					currency,
					sid,
					pos: walletAddress,
					paymentMethodRaw: 'usdc',
				})
			} else {
				link = buildUsdcTopupQrUrlPhase1({
					cardAddress: infra,
					cardOwner: owner,
					amount: chargeHuman,
					currency,
					sid,
					pos: walletAddress,
					paymentMethodRaw: 'usdc',
				})
			}
			setUsdcDeepLink(link)
			setUsdcHint(
				usdcTopupCustomerHint('usdc', Boolean(target.beamioTag || target.wallet)),
			)
			setUsdcProgress('')
			setMembershipUsdcTarget(target)
			setPhase('membership-usdc-qr')
		},
		[infraCard, walletAddress],
	)

	const onPurchaseMembershipTier = useCallback(
		(tier: ReadBalanceMembershipTierChoice, method: TopupPaymentMethodRaw) => {
			if (!assets?.ok) {
				setCouponToast({ kind: 'error', text: 'Customer not loaded.' })
				return
			}
			if (!walletAddress) {
				setCouponToast({ kind: 'error', text: 'Wallet not initialized' })
				return
			}
			setSelectedMembershipTier(tier)
			const target = deductCustomerTargetFromAssets(assets, nfcScan)
			if (method === 'cash') {
				void runMembershipTopup(target, tier, 'cash')
				return
			}
			void startMembershipUsdcQrFlow(target, tier)
		},
		[assets, nfcScan, runMembershipTopup, startMembershipUsdcQrFlow, walletAddress],
	)

	useEffect(() => {
		if (phase !== 'membership-scan-nfc-after-usdc') return
		if (membershipScanStartedRef.current) return
		membershipScanStartedRef.current = true

		let cancelled = false
		void (async () => {
			const scan = await runPosCustomerScanFlow()
			if (cancelled) return

			if (scan.status === 'aborted') {
				setSelectedMembershipTier(null)
				setMembershipUsdcTarget(null)
				setPhase('result')
				return
			}
			if (scan.status === 'error') {
				setCouponToast({ kind: 'error', text: scan.message })
				setSelectedMembershipTier(null)
				setMembershipUsdcTarget(null)
				setPhase('result')
				return
			}

			const target = customerTargetFromScan(scan)
			if (!target || !selectedMembershipTier) {
				setCouponToast({
					kind: 'error',
					text:
						scan.status === 'nfc'
							? 'Card does not support SUN. Cannot issue membership.'
							: 'Cannot parse customer identity.',
				})
				setSelectedMembershipTier(null)
				setMembershipUsdcTarget(null)
				setPhase('result')
				return
			}
			await runMembershipTopup(target, selectedMembershipTier, 'usdc', usdcSid)
		})()

		return () => {
			cancelled = true
			cancelPosCustomerScan()
		}
	}, [phase, runMembershipTopup, selectedMembershipTier, usdcSid])

	useEffect(() => {
		if (phase !== 'membership-usdc-qr' || !usdcSid || !selectedMembershipTier) return
		pollAbortRef.current?.abort()
		const ac = new AbortController()
		pollAbortRef.current = ac

		void (async () => {
			const outcome = await pollUsdcTopupSession({
				sid: usdcSid,
				signal: ac.signal,
				onProgress: setUsdcProgress,
			})
			if (ac.signal.aborted) return

			const tier = selectedMembershipTier
			const target = membershipUsdcTarget

			if (outcome.status === 'timeout') {
				setCouponToast({ kind: 'error', text: 'USDC payment timed out.' })
				setSelectedMembershipTier(null)
				setMembershipUsdcTarget(null)
				setPhase('result')
				return
			}
			if (outcome.status === 'error') {
				setCouponToast({ kind: 'error', text: outcome.message })
				setSelectedMembershipTier(null)
				setMembershipUsdcTarget(null)
				setPhase('result')
				return
			}
			if (outcome.status === 'success') {
				if (target && (target.beamioTag || target.wallet)) {
					await runMembershipTopup(target, tier, 'usdc', usdcSid)
					return
				}
				membershipScanStartedRef.current = false
				setPhase('membership-scan-nfc-after-usdc')
				return
			}
			if (outcome.status === 'awaiting_beneficiary') {
				if (target?.beamioTag || target?.wallet) {
					await runMembershipTopup(target, tier, 'usdc', usdcSid)
					return
				}
				membershipScanStartedRef.current = false
				setPhase('membership-scan-nfc-after-usdc')
			}
		})()

		return () => {
			ac.abort()
		}
	}, [phase, usdcSid, selectedMembershipTier, membershipUsdcTarget, runMembershipTopup])

	useEffect(() => {
		return () => {
			pollAbortRef.current?.abort()
			cancelPosCustomerScan()
		}
	}, [])

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

	if (phase === 'membership-success' && membershipSuccess) {
		return (
			<TopupSuccessView
				result={membershipSuccess}
				pointSystemEnabled={pointSystemEnabled}
				onDone={() => {
					setMembershipSuccess(null)
					setSelectedMembershipTier(null)
					setMembershipUsdcTarget(null)
					setPhase('result')
				}}
			/>
		)
	}

	if (phase === 'membership-usdc-qr' && usdcDeepLink) {
		return (
			<TopupUsdcQrPanel
				deepLink={usdcDeepLink}
				hint={usdcHint}
				progressLabel={usdcProgress}
				onCancel={() => {
					pollAbortRef.current?.abort()
					setUsdcDeepLink('')
					setUsdcSid('')
					setSelectedMembershipTier(null)
					setMembershipUsdcTarget(null)
					setPhase('result')
				}}
			/>
		)
	}

	if (phase === 'membership-scan-nfc-after-usdc') {
		return (
			<PosFlowLoadingShell
				title="Membership"
				subtitle="USDC paid. Tap customer NFC card…"
			/>
		)
	}

	if (phase === 'membership-executing') {
		const feeHuman = selectedMembershipTier
			? membershipFeeE6ToHuman(selectedMembershipTier.feeFiat6)
			: ''
		const amt = Number(feeHuman.replace(/,/g, '')) || 0
		return (
			<PosScanExecutingShell
				title="Membership"
				center={
					<PosTopupExecutingCard signingInProgress={membershipProgress === 'signing'} />
				}
				bottomAmount={amt > 0 ? amt : undefined}
				bottomTone="topup"
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
		claimInFlightId != null ||
		consumeInFlightId != null ||
		phase !== 'result'
	const hasValidMembership = readBalanceCustomerHasValidMembership(assets, infraCard)
	const showMembershipJoin = membershipTiers.length > 0 && !hasValidMembership

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
						{couponToast ? (
							<div
								className={`sticky top-0 z-20 rounded-2xl border px-4 py-3 text-sm font-medium shadow-sm ${
									couponToast.kind === 'success'
										? 'border-emerald-200 bg-emerald-50 text-emerald-800'
										: 'border-red-200 bg-red-50 text-red-800'
								}`}
								role="alert"
								aria-live="assertive"
							>
								{couponToast.text}
							</div>
						) : null}
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
						{showMembershipJoin ? (
							<ReadBalanceMembershipSection
								mode="join"
								tiers={membershipTiers}
								currencyPrefix={membershipCurrencyPrefix}
								disabled={deductBusy}
								onPurchaseTier={onPurchaseMembershipTier}
							/>
						) : null}
						{membershipTiers.length > 0 && hasValidMembership ? (
							<ReadBalanceMembershipSection
								mode="upgrade"
								tiers={membershipTiers}
								currencyPrefix={membershipCurrencyPrefix}
								disabled={deductBusy}
								onPurchaseTier={onPurchaseMembershipTier}
							/>
						) : null}
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
					</div>
				</PosScreenMain>
			</div>
		</PosScreenShell>
	)
}
