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

const peerCardInterface = new ethers.Interface([
	'function balanceOf(address,uint256) view returns (uint256)',
	'function pointsUnitPriceInCurrencyE6() view returns (uint256)',
	'function convertReward13ToPointsRatioE6() view returns (uint256)',
	'function quoteUsdcWithdrawForFiat6(uint256) view returns (uint256)',
	'function quoteUsdcDepositForFiat6(uint256) view returns (uint256)',
	'function rewardEscrowUsdc6() view returns (uint256)',
])
const usdcBalanceInterface = new ethers.Interface([
	'function balanceOf(address) view returns (uint256)',
])

/** USDC the destination card charges for `fiat6` of its own currency, including deposit spread. */
async function quoteMerchantDepositUsdc6(merchantCard: string, fiat6: bigint): Promise<bigint> {
	if (fiat6 <= 0n || !ethers.isAddress(merchantCard)) return 0n
	const card = new ethers.Contract(merchantCard, peerCardInterface, conetProvider)
	const quoted = (await card.quoteUsdcDepositForFiat6(fiat6)) as bigint
	return quoted > 0n ? quoted : 0n
}

/**
 * Largest source PT burn whose withdraw quote fits the card's escrow and USDC.
 * Quote is linear, so one proportional step is enough after the full-balance quote.
 */
async function cappedPeerRewardPt(
	cardAddress: string,
	pt6: bigint,
): Promise<{ burn13: bigint; usdc6: bigint }> {
	if (pt6 <= 0n) return { burn13: 0n, usdc6: 0n }
	const card = new ethers.Contract(cardAddress, peerCardInterface, conetProvider)
	const quoted = (await card.quoteUsdcWithdrawForFiat6(pt6)) as bigint
	const escrow = (await card.rewardEscrowUsdc6()) as bigint
	const available = (await new ethers.Contract(
		CONET_USDC,
		usdcBalanceInterface,
		conetProvider,
	).balanceOf(cardAddress)) as bigint
	const cap = quoted < escrow ? (quoted < available ? quoted : available) : escrow < available ? escrow : available
	if (cap <= 0n || quoted <= 0n) return { burn13: 0n, usdc6: 0n }
	if (quoted <= cap) return { burn13: pt6, usdc6: quoted }
	let burn = (pt6 * cap) / quoted
	if (burn <= 0n) return { burn13: 0n, usdc6: 0n }
	let usdc = (await card.quoteUsdcWithdrawForFiat6(burn)) as bigint
	if (usdc > cap && usdc > 0n) {
		burn = (burn * cap) / usdc
		if (burn <= 0n) return { burn13: 0n, usdc6: 0n }
		usdc = (await card.quoteUsdcWithdrawForFiat6(burn)) as bigint
	}
	if (usdc <= 0n || usdc > cap) return { burn13: 0n, usdc6: 0n }
	return { burn13: burn, usdc6: usdc }
}

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
	let usdcPerFiatUnit = 0n
	try {
		usdcPerFiatUnit = await quoteMerchantDepositUsdc6(merchantCard, 1_000_000n)
	} catch {
		usdcPerFiatUnit = 0n
	}
	if (usdcPerFiatUnit <= 0n && targetRate <= 0) return 0
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
			const contract = new ethers.Contract(cardAddress, peerCardInterface, conetProvider)
			rewardPt6 = (await contract.balanceOf(aaAddress, 13n)) as bigint
		} catch {
			continue
		}
		if (rewardPt6 <= 0n) continue

		const contract = new ethers.Contract(cardAddress, peerCardInterface, conetProvider)
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

		// Cross-store #13: quote to USDC, cap by escrow and the card's USDC,
		// then convert with the destination deposit quote (same as Smart Checkout).
		try {
			const { usdc6 } = await cappedPeerRewardPt(cardAddress, rewardPt6)
			if (usdc6 <= 0n) continue
			if (usdcPerFiatUnit > 0n) {
				targetFiat6 += (usdc6 * 1_000_000n) / usdcPerFiatUnit
			} else if (targetRate > 0) {
				targetFiat6 += BigInt(Math.floor(Number(usdc6) * targetRate))
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
		const oracle = (await fetchOracle()) ?? DEFAULT_ORACLE
		const targetRate = getRateForCurrency(targetCurrency, oracle)
		const target = new ethers.Contract(infra, peerCardInterface, conetProvider)
		const targetPrice = BigInt(await target.pointsUnitPriceInCurrencyE6())
		const orderFiat6 = ethers.parseUnits(amount, 6)
		const targetPoints = (orderFiat6 * 1_000_000n + targetPrice - 1n) / targetPrice
		const targetPt = BigInt(await target.balanceOf(ptHolder, 13n))
		const sameRatio = BigInt(await target.convertReward13ToPointsRatioE6())
		const sameStoreBurn13 =
			sameRatio > 0n
				? (targetPoints * 1_000_000n + sameRatio - 1n) / sameRatio > targetPt
					? targetPt
					: (targetPoints * 1_000_000n + sameRatio - 1n) / sameRatio
				: 0n
		const sameStorePointsOut = (sameStoreBurn13 * sameRatio) / 1_000_000n
		const sameStoreFiat6 =
			targetPrice > 0n ? (sameStorePointsOut * targetPrice) / 1_000_000n : 0n
		const remainingFiat6 = orderFiat6 > sameStoreFiat6 ? orderFiat6 - sameStoreFiat6 : 0n
		let needUsdc = 0n
		try {
			needUsdc = await quoteMerchantDepositUsdc6(infra, remainingFiat6)
		} catch {
			needUsdc = 0n
		}
		if (needUsdc <= 0n && remainingFiat6 > 0n && targetRate > 0) {
			needUsdc = BigInt(Math.ceil(Number(remainingFiat6) / targetRate))
		}
		const peers: Array<{ cardAddress: string; burn13: string; usdcOut6: string }> = []
		let peerUsdc = 0n
		for (const card of assets.cards ?? []) {
			const cardAddress = card.cardAddress?.trim() ?? ''
			if (
				!ethers.isAddress(cardAddress) ||
				cardAddress.toLowerCase() === infra.toLowerCase() ||
				needUsdc <= 0n
			) {
				continue
			}
			try {
				const source = new ethers.Contract(cardAddress, peerCardInterface, conetProvider)
				const balance = BigInt(await source.balanceOf(ptHolder, 13n))
				const capped = await cappedPeerRewardPt(cardAddress, balance)
				if (capped.usdc6 <= 0n || capped.burn13 <= 0n) continue
				let useBurn = capped.burn13
				let useUsdc = capped.usdc6
				if (useUsdc > needUsdc) {
					useBurn = (capped.burn13 * needUsdc) / capped.usdc6
					if (useBurn <= 0n) continue
					useUsdc = BigInt(await source.quoteUsdcWithdrawForFiat6(useBurn))
					if (useUsdc > needUsdc && useUsdc > 0n) {
						useBurn = (useBurn * needUsdc) / useUsdc
						if (useBurn <= 0n) continue
						useUsdc = BigInt(await source.quoteUsdcWithdrawForFiat6(useBurn))
					}
				}
				if (useBurn <= 0n || useUsdc <= 0n) continue
				peers.push({
					cardAddress,
					burn13: useBurn.toString(),
					usdcOut6: useUsdc.toString(),
				})
				peerUsdc += useUsdc
				needUsdc = useUsdc >= needUsdc ? 0n : needUsdc - useUsdc
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
			const currentCard = assets.cards?.find(
				(card) => card.cardAddress.trim().toLowerCase() === infra.toLowerCase(),
			)
			const resolvedCurrency =
				currency ?? currentCard?.cardCurrency?.trim() ?? 'CAD'
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
