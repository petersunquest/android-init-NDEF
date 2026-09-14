import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { ethers, JsonRpcProvider } from 'ethers'
import {
	DeductPointsAmountPadPage,
} from '@/components/DeductPointsAmountPadPage'
import { DeductPointsSuccessView } from '@/components/DeductPointsSuccessView'
import { PosFlowLoadingShell } from '@/components/PosFlowLoadingShell'
import { PosScanExecutingShell } from '@/components/PosScanExecutingShell'
import { PosTopupExecutingCard } from '@/components/PosTopupExecutingCard'
import { TopupUsdcQrPanel } from '@/components/TopupUsdcQrPanel'
import { usePosSession } from '@/providers/PosSessionProvider'
import {
	executeDeductPoints,
	loadCustomerAssets,
	type DeductCustomerTarget,
	type DeductExecuteProgressPhase,
	type DeductExecuteSuccess,
} from '@/utils/deductPointsExecute'
import { fetchCardCurrencyCode, fetchCardOwner, fetchOracle } from '@/api/beamioApi'
import { cancelPosCustomerScan, runPosCustomerScanFlow } from '@/utils/posScanFlow'
import { POS_HOME_ROUTES } from '@/utils/posHomeActionRoutes'
import type { PosHomeLocationState } from '@/utils/posHomeLocationState'
import { executeNfcTopup } from '@/utils/topupExecute'
import { nfcTopupCurrencySplitFromPosKeypad } from '@/utils/topupCurrencySplit'
import {
	buildUsdcTopupQrUrlPhase1,
	buildUsdcTopupQrUrlWithNfc,
	newTopupUsdcSessionId,
	pollUsdcTopupSession,
	usdcTopupCustomerHint,
} from '@/utils/topupUsdcSession'
import type { UIDAssetsResult } from '@/types/pos'
import {
	DEFAULT_ORACLE,
	getRateForCurrency,
	type OracleRates,
} from '@/utils/beamioPaymentRouting'
import { CONET_RPC } from '@/constants'

const conetProvider = new JsonRpcProvider(CONET_RPC, 224422, { staticNetwork: true })
const CONET_USDC =
	'0x5209865D404aA5646eDe5B91CD4218909eA72eDA'

type DeductPhase = 'amount' | 'scan-customer' | 'executing' | 'usdc-qr' | 'success'

async function maxPtConvertibleTopupAmount(
	assets: UIDAssetsResult,
	merchantCard: string,
	merchantCurrency: string,
	includeMerchantRewardPt: boolean,
	oracle: OracleRates,
): Promise<number> {
	const merchantKey = merchantCard.trim().toLowerCase()
	const targetRate = getRateForCurrency(merchantCurrency, oracle)
	if (targetRate <= 0) return 0

	const cardInterface = new ethers.Interface([
		'function balanceOf(address,uint256) view returns (uint256)',
		'function currency() view returns (uint8)',
		'function pointsUnitPriceInCurrencyE6() view returns (uint256)',
		'function convertReward13ToPointsRatioE6() view returns (uint256)',
		'function quoteUsdcWithdrawForFiat6(uint256) view returns (uint256)',
		'function rewardEscrowUsdc6() view returns (uint256)',
	])
	const erc20Interface = new ethers.Interface([
		'function balanceOf(address) view returns (uint256)',
	])
	const cards = assets.cards?.length
		? assets.cards
		: ethers.isAddress(assets.cardAddress ?? merchantCard)
			? [{
					cardAddress: assets.cardAddress ?? merchantCard,
					cardName: '',
					points: '0',
					points6: '0',
					cardCurrency: merchantCurrency,
					chargeRewardPoints6: assets.chargeRewardPoints6,
				}]
			: []
	const aaAddress = assets.aaAddress?.trim() || ''
	if (!ethers.isAddress(aaAddress)) return 0
	let targetFiat6 = 0n

	for (const card of cards) {
		const cardAddress = card.cardAddress.trim()
		if (!ethers.isAddress(cardAddress)) continue
		const cardKey = cardAddress.toLowerCase()
		let rewardPt6 = 0n
		try {
			const contract = new ethers.Contract(cardAddress, cardInterface, conetProvider)
			rewardPt6 = (await contract.balanceOf(aaAddress, 13n)) as bigint
		} catch {
			continue
		}
		if (rewardPt6 <= 0n) continue

		const contract = new ethers.Contract(cardAddress, cardInterface, conetProvider)
		if (cardKey === merchantKey) {
			if (!includeMerchantRewardPt) continue
			try {
				const price = (await contract.pointsUnitPriceInCurrencyE6()) as bigint
				const ratio = (await contract.convertReward13ToPointsRatioE6()) as bigint
				if (ratio > 0n && price > 0n) {
					targetFiat6 += (rewardPt6 * price) / 1_000_000n
				}
			} catch {
				// Untrusted same-store read: do not count this PT.
			}
			continue
		}

		// Cross-store #13: mirror the client plan. PT first quotes to USDC,
		// then is capped by the source card's escrow and actual USDC balance.
		try {
			const quotedUsdc6 = (await contract.quoteUsdcWithdrawForFiat6(rewardPt6)) as bigint
			const escrowUsdc6 = (await contract.rewardEscrowUsdc6()) as bigint
			const availableUsdc6 = await new ethers.Contract(
				CONET_USDC,
				erc20Interface,
				conetProvider,
			).balanceOf(cardAddress) as bigint
			const redeemableUsdc6 = [quotedUsdc6, escrowUsdc6, availableUsdc6]
				.reduce((min, value) => (value < min ? value : min))
			if (redeemableUsdc6 > 0n) {
				targetFiat6 += BigInt(Math.floor(Number(redeemableUsdc6) * targetRate))
			}
		} catch {
			// Untrusted peer read: preserve the trusted zero contribution.
		}
	}

	return Number(targetFiat6) / 1_000_000
}

function customerTargetFromScan(
	scan:
		| { status: 'nfc'; detail: { queryUid?: string; tagUidHex?: string; sun?: { e: string; c: string; m: string } } }
		| { status: 'qr'; identity: { beamioTag?: string; wallet?: string } },
): DeductCustomerTarget | null {
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
 * Points: scan NFC/QR → read balances → choose Reward PT burn or USDC store-credit top-up.
 */
export function DeductPointsPage() {
	const navigate = useNavigate()
	const { merchantInfraCard, walletAddress, pointSystemEnabled, refreshHome } = usePosSession()

	const [phase, setPhase] = useState<DeductPhase>('scan-customer')
	const [keypadAmount, setKeypadAmount] = useState('')
	const [customer, setCustomer] = useState<DeductCustomerTarget | null>(null)
	const [customerAssets, setCustomerAssets] = useState<UIDAssetsResult | null>(null)
	const [maxConvertibleTopupAmount, setMaxConvertibleTopupAmount] = useState<number | null>(null)
	const [success, setSuccess] = useState<DeductExecuteSuccess | null>(null)
	const [deductProgress, setDeductProgress] = useState<DeductExecuteProgressPhase>('preparing')
	const [usdcDeepLink, setUsdcDeepLink] = useState('')
	const [usdcHint, setUsdcHint] = useState('')
	const [usdcProgress, setUsdcProgress] = useState('')
	const [usdcSid, setUsdcSid] = useState('')
	const pollAbortRef = useRef<AbortController | null>(null)
	const scanStartedRef = useRef(false)

	const goHome = useCallback(
		(error?: string) => {
			const state: PosHomeLocationState = error ? { homeActionError: error } : {}
			navigate(POS_HOME_ROUTES.home, { replace: true, state })
		},
		[navigate],
	)

	const runDeduct = useCallback(
		async (
			target: DeductCustomerTarget,
			viaQr: boolean,
			assets: UIDAssetsResult,
			amount: string,
		) => {
			const infra = merchantInfraCard?.trim() ?? ''
			if (!infra) {
				goHome('Merchant program card is unavailable.')
				return
			}
			setDeductProgress('preparing')
			setPhase('executing')
			const outcome = await executeDeductPoints({
				target,
				keypadAmount: amount,
				merchantInfraCard: infra,
				pointSystemEnabled,
				viaQr,
				preloadedAssets: assets,
				onProgress: setDeductProgress,
			})
			if (outcome.status === 'success') {
				setSuccess(outcome.result)
				setPhase('success')
				void refreshHome()
				return
			}
			goHome(outcome.message)
		},
		[merchantInfraCard, pointSystemEnabled, goHome, refreshHome],
	)

	const startUsdcTopup = useCallback(async (amount: string) => {
		const infra = merchantInfraCard?.trim() ?? ''
		if (!customer || !amount || !infra) {
			goHome('Customer or merchant card is unavailable.')
			return
		}
		const owner = await fetchCardOwner(infra, walletAddress ?? '')
		if (!owner) {
			goHome('Cannot resolve merchant card owner. Please retry.')
			return
		}
		const currency = (await fetchCardCurrencyCode(infra)) ?? 'CAD'
		const sid = newTopupUsdcSessionId()
		const split = nfcTopupCurrencySplitFromPosKeypad(amount, 'usdc', false, 0)
		if (!split) {
			goHome('Enter a valid USDC amount.')
			return
		}
		setUsdcSid(sid)
		setUsdcHint(usdcTopupCustomerHint('usdc', Boolean(customer.beamioTag || customer.wallet)))
		setUsdcProgress('')
		setUsdcDeepLink(
			customer.uid && customer.sun
				? buildUsdcTopupQrUrlWithNfc({
						cardAddress: infra,
						cardOwner: owner,
						uid: customer.uid,
						sun: customer.sun,
						amount: split.currencyAmount,
						currency,
						sid,
						pos: walletAddress ?? '',
						paymentMethodRaw: 'usdc',
					})
				: buildUsdcTopupQrUrlPhase1({
						cardAddress: infra,
						cardOwner: owner,
						amount: split.currencyAmount,
						currency,
						sid,
						pos: walletAddress ?? '',
						paymentMethodRaw: 'usdc',
					}),
		)
		setPhase('usdc-qr')
	}, [customer, goHome, merchantInfraCard, walletAddress])

	useEffect(() => {
		if (phase !== 'scan-customer') return
		if (scanStartedRef.current) return
		scanStartedRef.current = true

		let cancelled = false
		void (async () => {
			const scan = await runPosCustomerScanFlow()
			if (cancelled) return

			if (scan.status === 'aborted') {
				goHome()
				return
			}
			if (scan.status === 'error') {
				goHome(scan.message)
				return
			}

			const target = customerTargetFromScan(scan)
			if (!target) {
				goHome(
					scan.status === 'nfc'
						? 'Card does not support SUN. Cannot deduct points.'
						: 'Cannot parse customer identity.',
				)
				return
			}
			const infra = merchantInfraCard?.trim() ?? ''
			const [assets, currency, oracleResponse] = await Promise.all([
				loadCustomerAssets(target, infra),
				fetchCardCurrencyCode(infra),
				fetchOracle(),
			])
			if (cancelled) return
			if (!assets?.ok) {
				goHome(assets?.error || 'Balance query failed. Please retry.')
				return
			}
			setCustomer(target)
			setCustomerAssets(assets)
			const resolvedCurrency = currency ?? assets.cardCurrency ?? 'CAD'
			const oracle = oracleResponse ?? DEFAULT_ORACLE
			setMaxConvertibleTopupAmount(
				await maxPtConvertibleTopupAmount(
					assets,
					infra,
					resolvedCurrency,
					pointSystemEnabled,
					oracle,
				),
			)
			setPhase('amount')
		})()

		return () => {
			cancelled = true
			cancelPosCustomerScan()
		}
	}, [phase, goHome, merchantInfraCard, pointSystemEnabled])

	useEffect(() => {
		if (phase !== 'usdc-qr' || !usdcSid) return
		pollAbortRef.current?.abort()
		const controller = new AbortController()
		pollAbortRef.current = controller
		void (async () => {
			const outcome = await pollUsdcTopupSession({
				sid: usdcSid,
				signal: controller.signal,
				onProgress: setUsdcProgress,
			})
			if (controller.signal.aborted) return
			if (outcome.status === 'success') {
				void refreshHome()
				goHome()
			} else if (outcome.status === 'timeout' || outcome.status === 'error') {
				goHome(outcome.status === 'timeout' ? 'USDC top-up timed out.' : outcome.message)
			} else if (outcome.status === 'awaiting_beneficiary' && customer) {
				const split = nfcTopupCurrencySplitFromPosKeypad(keypadAmount, 'usdc', false, 0)
				if (!split) return
				setDeductProgress('preparing')
				setPhase('executing')
				const result = await executeNfcTopup({
					target: customer,
					apiAmount: split.currencyAmount,
					currencySplit: split,
					merchantInfraCard: merchantInfraCard?.trim() ?? '',
					posWallet: walletAddress ?? '',
					usdcTopupSessionId: usdcSid,
					onProgress: (progress) =>
						setDeductProgress(progress === 'refreshing' ? 'preparing' : progress),
				})
				if (result.status === 'error') goHome(result.message)
				else {
					void refreshHome()
					goHome()
				}
			}
		})()
		return () => controller.abort()
	}, [customer, goHome, keypadAmount, merchantInfraCard, phase, refreshHome, usdcSid, walletAddress])

	useEffect(() => {
		return () => cancelPosCustomerScan()
	}, [])

	if (phase === 'amount') {
		return (
			<DeductPointsAmountPadPage
				assets={customerAssets}
				convertibleTopupAmount={maxConvertibleTopupAmount}
				onCancel={() => goHome()}
				onContinue={({ mode, keypadAmount: nextAmount }) => {
					setKeypadAmount(nextAmount)
					if (mode === 'usdc-topup') {
						void startUsdcTopup(nextAmount)
						return
					}
					if (customer && customerAssets) {
						void runDeduct(customer, Boolean(customer.uid), customerAssets, nextAmount)
					}
				}}
			/>
		)
	}

	if (phase === 'success' && success) {
		return (
			<DeductPointsSuccessView
				result={success}
				pointSystemEnabled={pointSystemEnabled}
				onDone={() => navigate(POS_HOME_ROUTES.home, { replace: true })}
			/>
		)
	}

	if (phase === 'executing') {
		const pts = Number(keypadAmount.replace(/,/g, '')) || 0
		return (
			<PosScanExecutingShell
				title="Points"
				center={
					<PosTopupExecutingCard signingInProgress={deductProgress === 'signing'} />
				}
				bottomAmount={pts > 0 ? pts : undefined}
				bottomTone="deduct"
			/>
		)
	}

	if (phase === 'usdc-qr' && usdcDeepLink) {
		return (
			<TopupUsdcQrPanel
				deepLink={usdcDeepLink}
				hint={usdcHint}
				progressLabel={usdcProgress}
				onCancel={() => goHome()}
			/>
		)
	}

	if (phase === 'scan-customer') {
		return (
			<PosFlowLoadingShell
				title="Points"
				subtitle="Waiting for NFC or QR scan…"
				bg="bg-[#f2f2f7]"
			/>
		)
	}

	return (
		<PosFlowLoadingShell title="Points" subtitle="Loading…" bg="bg-[#f2f2f7]" />
	)
}
