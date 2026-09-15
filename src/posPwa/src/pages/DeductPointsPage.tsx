import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { ethers, JsonRpcProvider } from 'ethers'
import {
	DeductPointsAmountPadPage,
} from '@/components/DeductPointsAmountPadPage'
import { DeductPointsSuccessView } from '@/components/DeductPointsSuccessView'
import { TopupSuccessView } from '@/components/TopupSuccessView'
import { PosFlowLoadingShell } from '@/components/PosFlowLoadingShell'
import { PosScanExecutingShell } from '@/components/PosScanExecutingShell'
import { PosTopupExecutingCard } from '@/components/PosTopupExecutingCard'
import { usePosSession } from '@/providers/PosSessionProvider'
import {
	executeDeductPoints,
	loadCustomerAssets,
	type DeductCustomerTarget,
	type DeductExecuteProgressPhase,
	type DeductExecuteSuccess,
} from '@/utils/deductPointsExecute'
import type { TopupExecuteSuccess } from '@/utils/topupExecute'
import {
	fetchCardCurrencyCode,
	fetchOracle,
	relayPosRewardPtTopup,
} from '@/api/beamioApi'
import { cancelPosCustomerScan, runPosCustomerScanFlow } from '@/utils/posScanFlow'
import { POS_HOME_ROUTES } from '@/utils/posHomeActionRoutes'
import type { PosHomeLocationState } from '@/utils/posHomeLocationState'
import type { UIDAssetsResult } from '@/types/pos'
import {
	DEFAULT_ORACLE,
	getRateForCurrency,
	type OracleRates,
} from '@/utils/beamioPaymentRouting'
import { CONET_RPC } from '@/constants'
import { buildTopupSuccessPassHero } from '@/utils/posSuccessHero'
import { memberNoFromCard } from '@/utils/readBalanceAssets'

const conetProvider = new JsonRpcProvider(CONET_RPC, 224422, { staticNetwork: true })
const CONET_USDC =
	'0x5209865D404aA5646eDe5B91CD4218909eA72eDA'

type DeductPhase = 'amount' | 'scan-customer' | 'executing' | 'success'

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
	const [success, setSuccess] = useState<DeductExecuteSuccess | TopupExecuteSuccess | null>(null)
	const [relayTopupSuccess, setRelayTopupSuccess] = useState(false)
	const [deductProgress, setDeductProgress] = useState<DeductExecuteProgressPhase>('preparing')
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
				setRelayTopupSuccess(false)
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
		const assets = customerAssets
		if (!assets) {
			goHome('Customer assets are unavailable. Please retry.')
			return
		}
		const operator = walletAddress?.trim() ?? ''
		const userEOA = assets.address?.trim() ?? ''
		const ptHolder = assets.aaAddress?.trim() ?? ''
		if (!ethers.isAddress(operator) || !ethers.isAddress(userEOA)) {
			goHome('Customer or terminal wallet is unavailable. Please retry.')
			return
		}
		if (!ethers.isAddress(ptHolder)) {
			goHome('Smart Wallet is required for Reward PT top-up.')
			return
		}
		const targetCurrency = (await fetchCardCurrencyCode(infra)) ?? 'CAD'
		const oracle = await fetchOracle()
		if (!oracle) {
			goHome('Exchange rates are unavailable. Please retry.')
			return
		}
		const targetRate = getRateForCurrency(targetCurrency, oracle)
		const target = new ethers.Contract(
			infra,
			new ethers.Interface([
				'function pointsUnitPriceInCurrencyE6() view returns (uint256)',
				'function convertReward13ToPointsRatioE6() view returns (uint256)',
				'function balanceOf(address,uint256) view returns (uint256)',
			]),
			conetProvider,
		)
		const targetPrice = BigInt(await target.pointsUnitPriceInCurrencyE6())
		const targetPoints = (ethers.parseUnits(amount, 6) * 1_000_000n + targetPrice - 1n) / targetPrice
		const targetPt = BigInt(await target.balanceOf(ptHolder, 13n))
		const sameRatio = BigInt(await target.convertReward13ToPointsRatioE6())
		const sameStoreBurn13 =
			sameRatio > 0n
				? (targetPoints * 1_000_000n + sameRatio - 1n) / sameRatio > targetPt
					? targetPt
					: (targetPoints * 1_000_000n + sameRatio - 1n) / sameRatio
				: 0n
		let remainingPoints = targetPoints - (sameStoreBurn13 * sameRatio) / 1_000_000n
		const peers: Array<{ cardAddress: string; burn13: string; usdcOut6: string }> = []
		let peerUsdc = 0n
		for (const card of assets.cards ?? []) {
			const cardAddress = card.cardAddress?.trim() ?? ''
			if (!ethers.isAddress(cardAddress) || cardAddress.toLowerCase() === infra.toLowerCase() || remainingPoints <= 0n) continue
			try {
				const source = new ethers.Contract(
					cardAddress,
					new ethers.Interface([
						'function balanceOf(address,uint256) view returns (uint256)',
						'function quoteUsdcWithdrawForFiat6(uint256) view returns (uint256)',
					]),
					conetProvider,
				)
				const balance = BigInt(await source.balanceOf(ptHolder, 13n))
				const burn = balance > remainingPoints ? remainingPoints : balance
				if (burn <= 0n) continue
				const usdcOut = BigInt(await source.quoteUsdcWithdrawForFiat6(burn))
				if (usdcOut <= 0n) continue
				peers.push({ cardAddress, burn13: burn.toString(), usdcOut6: usdcOut.toString() })
				peerUsdc += usdcOut
				// The target card's oracle is applied again by the server/contract.
				const estimatedPoints = BigInt(Math.max(1, Math.floor(Number(usdcOut) * targetRate)))
				remainingPoints = estimatedPoints >= remainingPoints ? 0n : remainingPoints - estimatedPoints
			} catch {
				// Ignore an untrusted source-card read; the server performs final checks.
			}
		}
		if (sameStoreBurn13 <= 0n && peers.length === 0) {
			goHome('Insufficient Reward PT for this top-up.')
			return
		}
		setPhase('executing')
		const deadline = Math.floor(Date.now() / 1000) + 300
		const nonce = ethers.hexlify(ethers.randomBytes(32))
		const relayResult = await relayPosRewardPtTopup({
			targetCard: infra,
			userEOA,
			terminalOperator: operator,
			terminalCard: infra,
			sameStoreBurn13: sameStoreBurn13.toString(),
			peerUsdcCredited6: peerUsdc.toString(),
			pointsFromPeerUsdc6: '0',
			minTotalPointsOut0: targetPoints.toString(),
			deadline,
			nonce,
			peers,
		})
		await refreshHome()
		const postAssets = await loadCustomerAssets(customer, infra)
		const postCard = postAssets?.cards?.find(
			(card) => card.cardAddress.trim().toLowerCase() === infra.toLowerCase(),
		)
		const preCard = assets.cards?.find(
			(card) => card.cardAddress.trim().toLowerCase() === infra.toLowerCase(),
		)
		const preBalance = preCard?.points ?? assets.points ?? '—'
		const postBalance = postAssets?.ok
			? postCard?.points ?? postAssets.points ?? '—'
			: '—'
		const cardCurrency = postCard?.cardCurrency ?? assets.cardCurrency ?? targetCurrency
		const relaySuccess: TopupExecuteSuccess = {
			amount,
			txHash: relayResult.hash,
			preBalance,
			postBalance,
			cardCurrency,
			memberNo: memberNoFromCard(postCard ?? preCard),
			customerBeamioTag: customer.beamioTag ?? postAssets?.beamioTag,
			address: postAssets?.address ?? assets.address ?? userEOA,
			passHero: postAssets?.ok
				? buildTopupSuccessPassHero({
						assets: postAssets,
						cardAddr: infra,
						merchantInfraCard: infra,
						pointSystemEnabled,
						postBalance,
						cardCurrency,
						customerBeamioTag: customer.beamioTag ?? postAssets.beamioTag,
						customerAddress: postAssets.address ?? userEOA,
					})
				: undefined,
		}
		setRelayTopupSuccess(true)
		setSuccess(relaySuccess)
		setPhase('success')
	}, [customer, customerAssets, goHome, merchantInfraCard, refreshHome, walletAddress])

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
		return () => cancelPosCustomerScan()
	}, [])

	if (phase === 'amount') {
		return (
			<DeductPointsAmountPadPage
				assets={customerAssets}
				merchantInfraCard={merchantInfraCard}
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
		if (relayTopupSuccess) {
			return (
				<TopupSuccessView
					result={success as TopupExecuteSuccess}
					pointSystemEnabled={pointSystemEnabled}
					onDone={() => navigate(POS_HOME_ROUTES.home, { replace: true })}
				/>
			)
		}
		return (
			<DeductPointsSuccessView
				result={success as DeductExecuteSuccess}
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
