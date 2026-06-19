import {
	fetchCardMetadataTiersBundle,
	fetchOracle,
	fetchUIDAssets,
	fetchWalletAssetsForRead,
	payByNfcUidPrepare,
	payByNfcUidSignContainer,
	postAAtoEOA,
} from '@/api/beamioApi'
import type { ReadBalanceCardItem, UIDAssetsResult } from '@/types/pos'
import {
	chargeTipFromRequestAndBps,
	chargeTotalInCurrency,
	chargeableCards,
	computeChargeContainerSplitFiat6,
	currencyToFiat6,
	DEFAULT_ORACLE,
	buildPayItemsFiat6,
	mergeInfraKind1Items,
	mergePrimaryTierStyleFromCardMetadata,
	normalizeTierDiscountPercent,
	partitionPointsForMerchantCharge,
	pickChargeTierDiscountPercent,
	points6ToUsdc6,
	postPaymentBalanceCad,
	tierDiscountBasisPoints,
} from '@/utils/beamioPaymentRouting'
import { fetchChargeTierRoutingDetails } from '@/utils/chargeTierRouting'
import type { PosTerminalChargePolicy } from '@/utils/chargePaymentMethod'
import {
	BASE_MAINNET_CHAIN_ID,
	fetchBeamioUserCardChainId,
	fetchCardCurrencyAndPointsPriceE6,
} from '@/utils/posProgramCardAccess'
import { memberNoPrimaryFromSortedCards } from '@/utils/readBalanceAssets'
import {
	buildSuccessPassHeroProps,
	type PosSuccessPassHeroProps,
} from '@/utils/posSuccessHero'
import type { PaymentRoutingStepPatch } from '@/utils/paymentRoutingSteps'

export interface ChargeCustomerTarget {
	uid: string
	sun?: { e: string; c: string; m: string }
}

export interface ChargeExecuteSuccess {
	amount: string
	subtotal: string
	tip?: string
	txHash?: string
	postBalance: string
	cardCurrency: string
	memberNo?: string
	customerBeamioTag?: string
	payee: string
	cardName?: string
	tierName?: string
	chargeTaxPercent: number
	chargeTierDiscountPercent: number
	settlementViaQr?: boolean
	customerWalletAddress?: string
	passHero?: PosSuccessPassHeroProps
}

export type ChargeExecuteResult =
	| { status: 'success'; result: ChargeExecuteSuccess }
	| {
			status: 'insufficient'
			message: string
			requiredLabel?: string
			availableLabel?: string
			/** iOS `qrRetryPayload` — re-run QR charge after top-up. */
			qrRetryPayload?: Record<string, unknown>
	  }
	| { status: 'error'; message: string }

function payerUsdcBalance6(assets: UIDAssetsResult, policy: PosTerminalChargePolicy): number {
	const raw = Math.round((Number(assets.usdcBalance ?? '0') || 0) * 1_000_000)
	return policy.allowPayerUsdcInCharge ? raw : 0
}

async function sleepMs(ms: number): Promise<void> {
	await new Promise((r) => setTimeout(r, ms))
}

const POST_CHARGE_BALANCE_RETRY_DELAYS_MS = [1500, 2000, 2500, 3000]

function points6ToDisplayAmount(points6: string): number {
	const n = Number(points6)
	return Number.isFinite(n) && n >= 0 ? n / 1_000_000 : 0
}

function findMerchantCard(
	assets: UIDAssetsResult,
	merchantInfraCard: string,
): ReadBalanceCardItem | undefined {
	const cardKey = merchantInfraCard.trim().toLowerCase()
	return (
		assets.cards?.find((c) => c.cardAddress.trim().toLowerCase() === cardKey) ??
		(assets.cardAddress?.trim().toLowerCase() === cardKey
			? ({
					cardAddress: assets.cardAddress,
					cardName: 'Asset Card',
					points: assets.points ?? '0',
					points6: assets.points6 ?? '0',
					cardCurrency: assets.cardCurrency ?? 'CAD',
					nfts: assets.nfts ?? [],
					primaryMemberTokenId: assets.primaryMemberTokenId,
				} satisfies ReadBalanceCardItem)
			: undefined)
	)
}

function merchantCardPoints6(assets: UIDAssetsResult | null | undefined, merchantInfraCard: string): bigint | null {
	if (!assets?.ok) return null
	const raw = findMerchantCard(assets, merchantInfraCard)?.points6
	if (raw == null) return null
	try {
		return BigInt(String(raw).trim())
	} catch {
		return null
	}
}

function expectedPostMerchantCardPoints6(
	preAssets: UIDAssetsResult,
	merchantInfraCard: string,
	debitPoints6: number,
): string | undefined {
	if (!(debitPoints6 > 0)) return undefined
	const pre = merchantCardPoints6(preAssets, merchantInfraCard)
	if (pre == null) return undefined
	const debit = BigInt(Math.max(0, Math.trunc(debitPoints6)))
	const post = pre > debit ? pre - debit : 0n
	return post.toString()
}

function merchantCardBalanceIsFresh(
	assets: UIDAssetsResult | null | undefined,
	merchantInfraCard: string,
	expectedPoints6?: string,
): boolean {
	if (!expectedPoints6) return Boolean(assets?.ok)
	const actual = merchantCardPoints6(assets, merchantInfraCard)
	if (actual == null) return false
	try {
		return actual <= BigInt(expectedPoints6)
	} catch {
		return false
	}
}

function patchMerchantCardPoints6ForReceipt(
	assets: UIDAssetsResult,
	preAssets: UIDAssetsResult,
	merchantInfraCard: string,
	points6: string,
): UIDAssetsResult {
	const cardKey = merchantInfraCard.trim().toLowerCase()
	const base = findMerchantCard(assets, merchantInfraCard) ?? findMerchantCard(preAssets, merchantInfraCard)
	if (!base) return assets
	const patchedCard: ReadBalanceCardItem = {
		...base,
		points6,
		points: points6ToDisplayAmount(points6).toFixed(6),
	}
	const nextCards = assets.cards?.length
		? assets.cards.map((c) => (c.cardAddress.trim().toLowerCase() === cardKey ? patchedCard : c))
		: [patchedCard]
	if (!nextCards.some((c) => c.cardAddress.trim().toLowerCase() === cardKey)) {
		nextCards.unshift(patchedCard)
	}
	return {
		...assets,
		cards: nextCards,
		...(assets.cardAddress?.trim().toLowerCase() === cardKey
			? { points6, points: patchedCard.points, cardCurrency: patchedCard.cardCurrency }
			: {}),
	}
}

function replacePassCardInAssets(
	assets: UIDAssetsResult,
	passCard: ReadBalanceCardItem | undefined,
	merged: ReadBalanceCardItem,
): UIDAssetsResult {
	const target = passCard?.cardAddress?.trim().toLowerCase()
	if (!target) {
		const rest = assets.cards?.slice(1) ?? []
		return { ...assets, cards: [merged, ...rest] }
	}
	const cards = (assets.cards ?? []).map((c) =>
		c.cardAddress.trim().toLowerCase() === target ? merged : c,
	)
	return { ...assets, cards }
}

function cardPointBalanceDisplay(
	assets: UIDAssetsResult,
	merchantInfraCard: string,
): { amount: number; display: string; currency: string; card?: ReadBalanceCardItem } | null {
	const card = findMerchantCard(assets, merchantInfraCard)
	if (!card) return null
	const p6 = Number(card.points6)
	const amount =
		Number.isFinite(p6) && p6 >= 0
			? p6 / 1_000_000
			: Number(card.points ?? '0')
	if (!Number.isFinite(amount)) return null
	return {
		amount,
		display: amount.toFixed(2),
		currency: card.cardCurrency || assets.cardCurrency || 'CAD',
		card,
	}
}

/** iOS `completePaymentSuccessUi` — NFC 3s / QR 5s, tier metadata merge on pass card. */
async function completeChargeSuccessUi(params: {
	passCard: ReadBalanceCardItem | undefined
	settlementViaQr: boolean
	useInfraPost: boolean
	merchantInfraCard: string
	pointSystemEnabled: boolean
	chargeTierDiscountPercent: number
	payCurrency: string
	preAssets: UIDAssetsResult
	fetchPostAssets: () => Promise<UIDAssetsResult | null>
	expectedMerchantCardPoints6?: string
}): Promise<{
	postBalStr: string
	passHero?: PosSuccessPassHeroProps
	customerBeamioTag?: string
	customerWalletAddress?: string
}> {
	const delayMs = params.settlementViaQr ? 5000 : 3000
	await sleepMs(delayMs)
	const oracleRes = (await fetchOracle()) ?? DEFAULT_ORACLE
	let postAssets = await params.fetchPostAssets()
	let retryIndex = 0
	while (
		!merchantCardBalanceIsFresh(
			postAssets,
			params.merchantInfraCard,
			params.expectedMerchantCardPoints6,
		) &&
		retryIndex < POST_CHARGE_BALANCE_RETRY_DELAYS_MS.length
	) {
		await sleepMs(POST_CHARGE_BALANCE_RETRY_DELAYS_MS[retryIndex]!)
		postAssets = await params.fetchPostAssets()
		retryIndex += 1
	}
	let postBalStr = '—'
	let postBalanceAmount: number | undefined
	let postBalanceCurrency = params.payCurrency
	let postCardBalance: ReturnType<typeof cardPointBalanceDisplay> = null
	let displayAssets = postAssets
	if (
		postAssets?.ok &&
		params.expectedMerchantCardPoints6 &&
		!merchantCardBalanceIsFresh(
			postAssets,
			params.merchantInfraCard,
			params.expectedMerchantCardPoints6,
		)
	) {
		// The relay succeeded but RPC still returned the pre-charge card row; use the
		// transaction-derived post-state for this receipt without writing any cache.
		displayAssets = patchMerchantCardPoints6ForReceipt(
			postAssets,
			params.preAssets,
			params.merchantInfraCard,
			params.expectedMerchantCardPoints6,
		)
	}
	if (displayAssets?.ok) {
		postCardBalance = cardPointBalanceDisplay(displayAssets, params.merchantInfraCard)
		if (postCardBalance) {
			postBalStr = postCardBalance.display
			postBalanceAmount = postCardBalance.amount
			postBalanceCurrency = postCardBalance.currency
		} else {
			const cad = postPaymentBalanceCad(
				displayAssets,
				oracleRes,
				params.merchantInfraCard,
				params.useInfraPost,
			)
			if (cad != null) {
				postBalStr = cad.toFixed(2)
				postBalanceAmount = cad
				postBalanceCurrency = params.payCurrency
			}
		}
	}
	if (!displayAssets?.ok) return { postBalStr }
	let refreshedPass = postCardBalance?.card ?? params.passCard
	const passAddr = params.passCard?.cardAddress?.trim()
	if (!postCardBalance && passAddr) {
		const pc = displayAssets.cards?.find(
			(c) => c.cardAddress.trim().toLowerCase() === passAddr.toLowerCase(),
		)
		if (pc) refreshedPass = pc
	}
	if (refreshedPass?.cardAddress?.trim()) {
		const bundle = await fetchCardMetadataTiersBundle(refreshedPass.cardAddress)
		refreshedPass = mergePrimaryTierStyleFromCardMetadata(refreshedPass, bundle.rows)
	}
	const heroAssets = refreshedPass
		? replacePassCardInAssets(displayAssets, params.passCard, refreshedPass)
		: displayAssets
	const passHero = buildSuccessPassHeroProps({
		assets: heroAssets,
		merchantInfraCard: params.merchantInfraCard,
		pointSystemEnabled: params.pointSystemEnabled,
		customerBeamioTag: displayAssets.beamioTag ?? params.preAssets.beamioTag,
		customerWalletAddress: displayAssets.address ?? params.preAssets.address,
		balanceAmount: postBalanceAmount,
		balanceCurrency: postBalanceCurrency,
		chargeTierDiscountPercent: params.chargeTierDiscountPercent,
	})
	return {
		postBalStr,
		passHero,
		customerBeamioTag: displayAssets.beamioTag?.trim() || undefined,
		customerWalletAddress: displayAssets.address?.trim() || undefined,
	}
}

export async function executeNfcCharge(params: {
	target: ChargeCustomerTarget
	subtotal: number
	tipBps: number
	merchantInfraCard: string
	posWallet: string
	chargePolicy: PosTerminalChargePolicy
	pointSystemEnabled?: boolean
	onRoutingStep?: PaymentRoutingStepPatch
}): Promise<ChargeExecuteResult> {
	const patch = params.onRoutingStep
	const infra = params.merchantInfraCard.trim()
	const payee = params.posWallet.trim()
	if (!infra || !payee) {
		return { status: 'error', message: 'Terminal not configured.' }
	}
	const subtotal = params.subtotal
	if (!(subtotal > 0)) {
		return { status: 'error', message: 'Invalid amount.' }
	}

	patch?.('detectingUser', 'loading')
	patch?.('membership', 'loading')
	patch?.('analyzingAssets', 'loading')

	const assets = await fetchUIDAssets({
		uid: params.target.uid,
		merchantInfraCard: infra,
		sun: params.target.sun,
	})
	if (!assets?.ok) {
		patch?.('detectingUser', 'error')
		return { status: 'error', message: assets?.error ?? 'Card not registered' }
	}
	patch?.('detectingUser', 'success', 'NFC card detected')
	patch?.('membership', 'success', 'NFC card payment')

	const oracleRes = (await fetchOracle()) ?? DEFAULT_ORACLE
	const payCard = assets.cards?.[0]
	const chargeCardInfo = await fetchCardCurrencyAndPointsPriceE6(infra)
	if (!chargeCardInfo) {
		patch?.('analyzingAssets', 'error', 'Program card price unavailable')
		return {
			status: 'error',
			message: 'Program card price unavailable. Please refresh and try again.',
		}
	}
	const payCurrency = chargeCardInfo.code.toUpperCase()
	const routing = (await fetchChargeTierRoutingDetails(payee, infra)) ?? {
		taxPercent: 0,
		discountByTierKey: {},
	}
	const metaBundle = await fetchCardMetadataTiersBundle(payCard?.cardAddress ?? infra)
	const disc = pickChargeTierDiscountPercent({
		paymentCard: payCard,
		assets,
		discountByTierKey: routing.discountByTierKey,
		metadataTiers: metaBundle.rows,
		metadataTiersFromApi: metaBundle.fromApi,
	})
	const tip = chargeTipFromRequestAndBps(subtotal, params.tipBps)
	const total = chargeTotalInCurrency(subtotal, routing.taxPercent, disc, tip)
	const amountFiat6Str = currencyToFiat6(total)
	const amountFiat6 = Number(amountFiat6Str)
	if (!(amountFiat6 > 0)) {
		patch?.('analyzingAssets', 'error', 'Amount conversion failed')
		return { status: 'error', message: 'Amount conversion failed' }
	}
	patch?.('analyzingAssets', 'success', 'Card + USDC balance')

	patch?.('optimizingRoute', 'loading')
	const prep = await payByNfcUidPrepare({
		uid: params.target.uid,
		payee,
		amountFiat6: amountFiat6Str,
		currency: payCurrency,
		merchantInfraCard: infra,
		sun: params.target.sun,
	})
	if (!prep?.ok) {
		patch?.('optimizingRoute', 'error', prep?.error ?? 'Prepare failed')
		return { status: 'error', message: prep?.error ?? 'Prepare failed' }
	}
	const account = prep.account
	const nonce = prep.nonce
	const deadline = prep.deadline
	const payeeAA = prep.payeeAA
	const unitPrice = Number(prep.unitPriceUSDC6) || 0
	if (!account || !nonce || !deadline || !payeeAA || unitPrice <= 0) {
		patch?.('optimizingRoute', 'error', prep.error ?? 'Prepare failed')
		return { status: 'error', message: prep.error ?? 'Prepare failed' }
	}
	patch?.('optimizingRoute', 'success', 'Direct: NFC → Merchant')

	const cardCurrencyOnChain = prep.cardCurrency?.toUpperCase() || chargeCardInfo.code.toUpperCase()
	const pointsPriceCurE6 = Number(prep.pointsUnitPriceInCurrencyE6) || chargeCardInfo.priceE6
	const amountBig = Math.floor((amountFiat6 * unitPrice + 999_999) / 1_000_000)
	const usdcBal = payerUsdcBalance6(assets, params.chargePolicy)
	const cards = chargeableCards(assets, infra)
	const part = partitionPointsForMerchantCharge(cards, infra)
	const unitPointsStr = part.unitPricePoints6
	const oracleInfraCards = part.oracleInfraCards
	const infraPointsStr = oracleInfraCards.reduce((s, c) => s + (Number(c.points6) || 0), 0)
	const unitBucketUsdc6 =
		unitPointsStr > 0 && unitPrice > 0 ? Math.floor((unitPointsStr * unitPrice) / 1_000_000) : 0
	const infraValue = oracleInfraCards.reduce(
		(partial, c) =>
			partial + points6ToUsdc6(Number(c.points6) || 0, c.cardCurrency, oracleRes),
		0,
	)
	const totalBal = unitBucketUsdc6 + infraValue + usdcBal
	if (totalBal < amountBig) {
		patch?.('optimizingRoute', 'error', 'Insufficient balance')
		return {
			status: 'insufficient',
			message: 'Insufficient balance for this charge.',
			requiredLabel: `$${total.toFixed(2)} ${payCurrency}`,
			availableLabel: `$${((totalBal * oracleRes.usdcad) / 1_000_000).toFixed(2)} CAD equiv.`,
		}
	}

	const split = computeChargeContainerSplitFiat6({
		amountFiat6,
		payCurrency,
		cardCurrency: cardCurrencyOnChain,
		pointsUnitPriceInCurrencyE6: pointsPriceCurE6,
		ccsaPoints6: unitPointsStr,
		infraPoints6: infraPointsStr,
		infraCardCurrency: oracleInfraCards[0]?.cardCurrency,
		usdcBalance6: usdcBal,
		oracle: oracleRes,
		unitPriceUSDC6Fallback: unitPrice,
	})
	let items = buildPayItemsFiat6(split, infra)
	items = mergeInfraKind1Items(items, infra)
	const merchantPointDebit6 = split.ccsaPointsWei + split.infraPointsWei
	const expectedMerchantCardPoints6 = expectedPostMerchantCardPoints6(
		assets,
		infra,
		merchantPointDebit6,
	)
	const container = {
		account,
		to: payeeAA,
		items,
		nonce,
		deadline,
	}
	const taxFiat6 = Math.round(subtotal * (routing.taxPercent / 100) * 1_000_000)
	const discNorm = normalizeTierDiscountPercent(disc)
	const discFiat6 = Math.round(subtotal * (discNorm / 100) * 1_000_000)
	const bill: Record<string, string | number> = {
		nfcSubtotalCurrencyAmount: subtotal.toFixed(2),
		nfcRequestCurrency: payCurrency,
		nfcTaxAmountFiat6: String(taxFiat6),
		nfcTaxRateBps: Math.round(routing.taxPercent * 100),
		nfcDiscountAmountFiat6: String(discFiat6),
		nfcDiscountRateBps: tierDiscountBasisPoints(disc),
	}
	if (tip > 0) {
		bill.nfcTipCurrencyAmount = tip.toFixed(2)
		if (params.tipBps > 0) bill.nfcTipRateBps = params.tipBps
	}

	patch?.('sendTx', 'loading')
	const pay = await payByNfcUidSignContainer({
		uid: params.target.uid,
		containerPayload: container,
		amountFiat6: amountFiat6Str,
		currency: payCurrency,
		merchantInfraCard: infra,
		sun: params.target.sun,
		nfcBill: bill,
	})
	if (!pay?.success) {
		patch?.('sendTx', 'error', pay?.error ?? 'Payment failed')
		patch?.('waitTx', 'error')
		return { status: 'error', message: pay?.error ?? 'Payment failed' }
	}
	patch?.('sendTx', 'success', 'Sent')
	patch?.('waitTx', 'success', 'Transaction complete')
	patch?.('refreshBalance', 'loading', 'Fetching latest balance')

	const useInfraPost = split.ccsaPointsWei + split.infraPointsWei > 0
	const memberNo = memberNoPrimaryFromSortedCards(assets)
	const { postBalStr, passHero, customerBeamioTag, customerWalletAddress } =
		await completeChargeSuccessUi({
		passCard: payCard,
		settlementViaQr: false,
		useInfraPost,
		merchantInfraCard: infra,
		pointSystemEnabled: params.pointSystemEnabled ?? false,
		chargeTierDiscountPercent: disc,
		payCurrency,
		preAssets: assets,
		fetchPostAssets: () =>
			fetchUIDAssets({
				uid: params.target.uid,
				merchantInfraCard: infra,
				sun: params.target.sun,
			}),
		expectedMerchantCardPoints6,
	})

	patch?.('refreshBalance', 'success', postBalStr !== '—' ? postBalStr : 'Updated')

	return {
		status: 'success',
		result: {
			amount: total.toFixed(2),
			subtotal: subtotal.toFixed(2),
			tip: tip > 0 ? tip.toFixed(2) : undefined,
			txHash: pay.txHash,
			postBalance: postBalStr,
			cardCurrency: payCurrency,
			memberNo: memberNo || undefined,
			customerBeamioTag: customerBeamioTag ?? assets.beamioTag,
			payee: payeeAA,
			cardName: payCard?.cardName,
			tierName: payCard?.tierName,
			chargeTaxPercent: routing.taxPercent,
			chargeTierDiscountPercent: disc,
			settlementViaQr: false,
			customerWalletAddress: customerWalletAddress ?? assets.address,
			passHero,
		},
	}
}

function optPayloadString(v: unknown): string {
	if (v == null) return ''
	if (typeof v === 'string') return v
	if (typeof v === 'number' && Number.isFinite(v)) return String(v)
	return String(v)
}

function looksLikeAddress(v: string): boolean {
	return /^0x[0-9a-fA-F]{40}$/.test(v.trim())
}

function isOpenContainerPayload(v: unknown): v is Record<string, unknown> {
	if (!v || typeof v !== 'object' || Array.isArray(v)) return false
	const o = v as Record<string, unknown>
	return Boolean(optPayloadString(o.account).trim() && optPayloadString(o.signature).trim())
}

async function selectOpenContainerPayloadForMerchantCard(
	rawPayload: Record<string, unknown>,
	merchantInfraCard: string,
): Promise<{ payload: Record<string, unknown>; error?: string }> {
	const payloads = rawPayload.openContainerPayloads
	if (!payloads || typeof payloads !== 'object' || Array.isArray(payloads)) {
		return { payload: rawPayload }
	}
	const byChain = payloads as Record<string, unknown>
	const chainId = await fetchBeamioUserCardChainId(merchantInfraCard)
	const chainKey = chainId === BASE_MAINNET_CHAIN_ID ? 'base' : chainId ? 'conet' : ''
	const selected = chainKey ? byChain[chainKey] : undefined
	if (isOpenContainerPayload(selected)) {
		return { payload: selected }
	}
	if (chainId) {
		return {
			payload: rawPayload,
			error: 'This payment code was generated before multi-chain Scan to Pay support. Ask the customer to close Pay and open a fresh QR code.',
		}
	}
	const fallback = [byChain.conet, byChain.base].find(isOpenContainerPayload)
	return fallback ? { payload: fallback } : { payload: rawPayload, error: 'Invalid payment code.' }
}

function mergedInfraKind1Amount(
	items: Array<Record<string, unknown>>,
	infraCard: string,
): number {
	const infra = infraCard.trim().toLowerCase()
	let sum = 0
	for (const it of items) {
		if (Number(it.kind) !== 1) continue
		const asset = optPayloadString(it.asset).trim().toLowerCase()
		if (asset !== infra) continue
		sum += Number(optPayloadString(it.amount)) || 0
	}
	return sum
}

function firstUsdcAmount6(items: Array<Record<string, unknown>>): number {
	for (const it of items) {
		if (Number(it.kind) !== 0) continue
		return Number(optPayloadString(it.amount)) || 0
	}
	return 0
}

function qrChargePaymentErrorMessage(raw?: string): string {
	const msg = (raw ?? '').trim()
	if (!msg) return 'Payment failed'
	if (/nonce|already used|refresh(?:ed)? pay qr|payment code was already used/i.test(msg)) {
		return 'This Pay QR was already used. Ask the customer to refresh Pay QR, then scan the new code.'
	}
	return msg
}

/** iOS `handlePaymentQr` — dynamic Scan to Pay QR → `/api/AAtoEOA`. */
export async function executeQrCharge(params: {
	openContainerPayload: Record<string, unknown>
	subtotal: number
	tipBps: number
	merchantInfraCard: string
	posWallet: string
	chargePolicy: PosTerminalChargePolicy
	pointSystemEnabled?: boolean
	onRoutingStep?: PaymentRoutingStepPatch
}): Promise<ChargeExecuteResult> {
	const patch = params.onRoutingStep
	const infra = params.merchantInfraCard.trim()
	const payeeWallet = params.posWallet.trim()
	if (!infra || !payeeWallet) {
		return { status: 'error', message: 'Terminal not configured.' }
	}
	const subtotal = params.subtotal
	if (!(subtotal > 0)) {
		return { status: 'error', message: 'Invalid amount.' }
	}

	const selectedPayload = await selectOpenContainerPayloadForMerchantCard(params.openContainerPayload, infra)
	if (selectedPayload.error) {
		return { status: 'error', message: selectedPayload.error }
	}
	const openContainerPayload = selectedPayload.payload
	const account = optPayloadString(openContainerPayload.account).trim()
	if (!account) {
		return { status: 'error', message: 'Invalid payment code' }
	}

	patch?.('detectingUser', 'loading')
	patch?.('detectingUser', 'success', 'Dynamic QR detected')
	patch?.('membership', 'loading')

	const assets = await fetchWalletAssetsForRead({ wallet: account, merchantInfraCard: infra })
	if (!assets?.ok) {
		patch?.('membership', 'error')
		return { status: 'error', message: assets?.error ?? 'Unable to fetch customer assets' }
	}

	const hasCardholder =
		assets.cards?.some((c) => (Number(c.points6) || 0) > 0) ||
		(Number(assets.points6 ?? '0') || 0) > 0
	patch?.('membership', 'success', hasCardholder ? 'Cardholder' : 'No membership')
	patch?.('analyzingAssets', 'loading')

	const routing = (await fetchChargeTierRoutingDetails(payeeWallet, infra)) ?? {
		taxPercent: 0,
		discountByTierKey: {},
	}
	const payCard = assets.cards?.[0]
	const metaBundle = await fetchCardMetadataTiersBundle(payCard?.cardAddress ?? infra)
	const disc = pickChargeTierDiscountPercent({
		paymentCard: payCard,
		assets,
		discountByTierKey: routing.discountByTierKey,
		metadataTiers: metaBundle.rows,
		metadataTiersFromApi: metaBundle.fromApi,
	})
	const oracleRes = (await fetchOracle()) ?? DEFAULT_ORACLE
	const tip = chargeTipFromRequestAndBps(subtotal, params.tipBps)
	const total = chargeTotalInCurrency(subtotal, routing.taxPercent, disc, tip)
	const chargeCardInfo = await fetchCardCurrencyAndPointsPriceE6(infra)
	if (!chargeCardInfo) {
		patch?.('analyzingAssets', 'error', 'Program card price unavailable')
		return {
			status: 'error',
			message: 'Program card price unavailable. Please refresh the customer balance and try again.',
		}
	}
	const payCurrency = chargeCardInfo.code.toUpperCase()
	const amountFiat6Str = currencyToFiat6(total)
	const amountFiat6 = Number(amountFiat6Str)
	if (!(amountFiat6 > 0)) {
		patch?.('analyzingAssets', 'error', 'Amount conversion failed')
		return { status: 'error', message: 'Amount conversion failed' }
	}

	const unitPrice = Number(assets.unitPriceUSDC6 ?? '0') || 0
	const cards = chargeableCards(assets, infra)
	const part = partitionPointsForMerchantCharge(cards, infra)
	const unitPoints6 = part.unitPricePoints6
	const cardCurrencyOnChain = chargeCardInfo.code.toUpperCase()
	const pointsPriceCurE6 = chargeCardInfo.priceE6
	const oracleInfraCards = part.oracleInfraCards
	const infraPoints6 = oracleInfraCards.reduce((s, c) => s + (Number(c.points6) || 0), 0)
	const usdcBal = payerUsdcBalance6(assets, params.chargePolicy)
	const unitBucketUsdc6 =
		unitPoints6 > 0 && unitPrice > 0 ? Math.floor((unitPoints6 * unitPrice) / 1_000_000) : 0
	const infraValue = oracleInfraCards.reduce(
		(partial, c) =>
			partial + points6ToUsdc6(Number(c.points6) || 0, c.cardCurrency, oracleRes),
		0,
	)
	const totalBal = unitBucketUsdc6 + infraValue + usdcBal
	const amountBig =
		unitPrice > 0
			? Math.floor((amountFiat6 * unitPrice + 999_999) / 1_000_000)
			: Math.floor(total * oracleRes.usdcad * 1_000_000)

	let analyzingDetail: string
	if (unitBucketUsdc6 >= amountBig) {
		analyzingDetail = 'Program points (sufficient)'
	} else if (unitBucketUsdc6 > 0) {
		analyzingDetail = 'Program points (partial)'
	} else {
		analyzingDetail = 'USDC sufficient'
	}
	patch?.('analyzingAssets', 'success', analyzingDetail)
	patch?.('optimizingRoute', 'loading')

	if (totalBal < amountBig) {
		patch?.('optimizingRoute', 'error', 'Insufficient balance')
		return {
			status: 'insufficient',
			message: 'Insufficient balance for this charge.',
			requiredLabel: `$${total.toFixed(2)} ${payCurrency}`,
			availableLabel: `$${((totalBal * oracleRes.usdcad) / 1_000_000).toFixed(2)} CAD equiv.`,
			qrRetryPayload: { ...openContainerPayload },
		}
	}

	const split = computeChargeContainerSplitFiat6({
		amountFiat6,
		payCurrency,
		cardCurrency: cardCurrencyOnChain,
		pointsUnitPriceInCurrencyE6: pointsPriceCurE6,
		ccsaPoints6: unitPoints6,
		infraPoints6,
		infraCardCurrency: oracleInfraCards[0]?.cardCurrency,
		usdcBalance6: usdcBal,
		oracle: oracleRes,
		unitPriceUSDC6Fallback: unitPrice,
	})
	let items = buildPayItemsFiat6(split, infra)
	items = mergeInfraKind1Items(items, infra)
	const beamio1155Wei = mergedInfraKind1Amount(items, infra)
	const usdcWei = firstUsdcAmount6(items)
	const expectedMerchantCardPoints6 = expectedPostMerchantCardPoints6(
		assets,
		infra,
		beamio1155Wei,
	)
	let routeDetail: string
	if (beamio1155Wei > 0 && usdcWei > 0) {
		routeDetail = 'Hybrid: points + USDC'
	} else if (beamio1155Wei > 0) {
		routeDetail = 'Points only'
	} else {
		routeDetail = 'USDC only'
	}
	patch?.('optimizingRoute', 'success', routeDetail)

	const payload: Record<string, unknown> = { ...openContainerPayload }
	payload.items = items
	if (payload.maxAmount == null) payload.maxAmount = '0'
	if (payload.deadline == null && payload.validBefore != null) {
		payload.deadline = payload.validBefore
	}

	// The server resolves ERC1155 program-point charges to the merchant card owner's AA.
	// Keep the QR relay recipient in the merchant/POS context and avoid querying wallet assets for the terminal EOA.
	const relayPayee = looksLikeAddress(payeeWallet)
		? payeeWallet
		: optPayloadString(payload.to).trim()
	if (!relayPayee || !looksLikeAddress(relayPayee)) {
		patch?.('sendTx', 'error', 'Merchant recipient not found')
		return {
			status: 'error',
			message: 'Merchant recipient not found. Please ensure terminal is configured.',
		}
	}
	payload.to = relayPayee

	const taxFiat6 = Math.round(subtotal * (routing.taxPercent / 100) * 1_000_000)
	const discNorm = normalizeTierDiscountPercent(disc)
	const discFiat6 = Math.round(subtotal * (discNorm / 100) * 1_000_000)
	const bill: Record<string, string | number> = {
		nfcSubtotalCurrencyAmount: subtotal.toFixed(2),
		nfcRequestCurrency: payCurrency,
		nfcTaxAmountFiat6: String(taxFiat6),
		nfcTaxRateBps: Math.round(routing.taxPercent * 100),
		nfcDiscountAmountFiat6: String(discFiat6),
		nfcDiscountRateBps: tierDiscountBasisPoints(disc),
	}
	if (tip > 0) {
		bill.nfcTipCurrencyAmount = tip.toFixed(2)
		if (params.tipBps > 0) bill.nfcTipRateBps = params.tipBps
	}

	patch?.('sendTx', 'loading')
	const pay = await postAAtoEOA({
		openContainerPayload: payload,
		currency: payCurrency,
		currencyAmount: total.toFixed(2),
		merchantInfraCard: infra,
		posOperator: payeeWallet,
		chargeBill: bill,
	})
	if (!pay?.success) {
		const paymentError = qrChargePaymentErrorMessage(pay?.error)
		patch?.('sendTx', 'error', paymentError)
		patch?.('waitTx', 'error')
		return { status: 'error', message: paymentError }
	}
	patch?.('sendTx', 'success', 'Sent')
	patch?.('waitTx', 'success', 'Transaction complete')
	patch?.('refreshBalance', 'loading', 'Fetching latest balance')

	const useInfraPost = split.ccsaPointsWei + split.infraPointsWei > 0
	const memberNo = memberNoPrimaryFromSortedCards(assets)
	const { postBalStr, passHero, customerBeamioTag, customerWalletAddress } =
		await completeChargeSuccessUi({
		passCard: payCard,
		settlementViaQr: true,
		useInfraPost,
		merchantInfraCard: infra,
		pointSystemEnabled: params.pointSystemEnabled ?? false,
		chargeTierDiscountPercent: disc,
		payCurrency,
		preAssets: assets,
		fetchPostAssets: () =>
			fetchWalletAssetsForRead({
				wallet: account,
				merchantInfraCard: infra,
				forPostPayment: true,
			}),
		expectedMerchantCardPoints6,
	})

	patch?.('refreshBalance', 'success', postBalStr !== '—' ? postBalStr : 'Updated')

	return {
		status: 'success',
		result: {
			amount: total.toFixed(2),
			subtotal: subtotal.toFixed(2),
			tip: tip > 0 ? tip.toFixed(2) : undefined,
			txHash: pay.txHash,
			postBalance: postBalStr,
			cardCurrency: payCurrency,
			memberNo: memberNo || undefined,
			customerBeamioTag: customerBeamioTag ?? assets.beamioTag,
			payee: relayPayee,
			cardName: payCard?.cardName,
			tierName: payCard?.tierName,
			chargeTaxPercent: routing.taxPercent,
			chargeTierDiscountPercent: disc,
			settlementViaQr: true,
			customerWalletAddress: customerWalletAddress ?? assets.address,
			passHero,
		},
	}
}
