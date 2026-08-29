import {
	burnPointsByAdminPrepare,
	fetchCardMetadataTiersBundle,
	fetchOracle,
	fetchUIDAssets,
	fetchWalletAssetsForRead,
	formatNfcTopupAdminError,
	nfcTopupSubmit,
	payByNfcUidPrepare,
	payByNfcUidSignContainer,
	postAAtoEOA,
} from '@/api/beamioApi'
import type { ReadBalanceCardItem, UIDAssetsResult } from '@/types/pos'
import { formatPosAssetsQueryError } from '@/utils/formatPosAssetsQueryError'
import {
	chargeProgramPointsBurnAmount6,
	chargeProgramPointsBurnFiat6,
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
import { resolveNfcTopupSubmitIdentity } from '@/utils/deductPointsExecute'
import { fetchCardCurrencyAndPointsPriceE6 } from '@/utils/posProgramCardAccess'
import { memberNoPrimaryFromSortedCards } from '@/utils/readBalanceAssets'
import {
	buildSuccessPassHeroProps,
	type PosSuccessPassHeroProps,
} from '@/utils/posSuccessHero'
import type { PaymentRoutingStepPatch } from '@/utils/paymentRoutingSteps'
import { getPosPrivateKeyHex, getPosSigningWalletAddress } from '@/wallet/getPosPrivateKeyHex'
import { signExecuteForAdmin } from '@/wallet/signExecuteForAdmin'

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

/**
 * Charge points leg: burn customer AA #0 via executeForAdmin (not Container transfer).
 * Hybrid leg sets skipBunitFee after USDC Container already paid the fixed Charge B-Unit fee.
 */
async function submitChargeCustomerProgramPointsBurn(params: {
	merchantInfraCard: string
	customerAa: string
	customerEoa?: string
	burnPoints6: number
	burnFiat6?: number
	burnCurrency?: string
	skipBunitFee: boolean
	submitIdentity: { uid?: string; wallet?: string; sun?: ChargeCustomerTarget['sun'] }
}): Promise<{ ok: true; txHash?: string } | { ok: false; error: string }> {
	const amount = String(Math.floor(params.burnPoints6))
	if (!(params.burnPoints6 > 0) || !params.customerAa.startsWith('0x')) {
		return { ok: false, error: 'Invalid program points burn amount.' }
	}
	if (!params.submitIdentity.uid && !params.submitIdentity.wallet) {
		return { ok: false, error: 'Customer account is unavailable.' }
	}
	const pk = await getPosPrivateKeyHex()
	if (!pk) {
		return { ok: false, error: 'Wallet not initialized.' }
	}
	const prep = await burnPointsByAdminPrepare({
		cardAddress: params.merchantInfraCard,
		target: params.customerAa,
		amount,
		purpose: 'chargeCustomerProgramPoints',
	})
	if (!prep?.success || !prep.cardAddr || !prep.data || !prep.deadline || !prep.nonce) {
		return { ok: false, error: prep?.error ?? 'Charge points prepare failed.' }
	}
	let adminSignature: string
	try {
		adminSignature = await signExecuteForAdmin({
			privateKeyHex: pk,
			cardAddress: prep.cardAddr,
			dataHex: prep.data,
			deadline: prep.deadline,
			nonceHex: prep.nonce,
			factoryGateway: prep.factoryGateway,
		})
	} catch (e) {
		return {
			ok: false,
			error: e instanceof Error ? e.message : 'Merchant signature failed.',
		}
	}
	const signerEOA = (await getPosSigningWalletAddress()) ?? undefined
	const pay = await nfcTopupSubmit({
		uid: params.submitIdentity.uid,
		wallet: params.submitIdentity.wallet,
		cardAddr: prep.cardAddr,
		data: prep.data,
		deadline: prep.deadline,
		nonce: prep.nonce,
		adminSignature,
		signerEOA,
		sun: params.submitIdentity.sun,
		chargeBurnProgramPoints: true,
		chargeBurnCustomerEOA: params.customerEoa,
		chargeBurnAmountFiat6:
			params.burnFiat6 != null && params.burnFiat6 > 0
				? String(Math.floor(params.burnFiat6))
				: undefined,
		chargeBurnCurrency: params.burnCurrency,
		chargeBurnSkipBunitFee: params.skipBunitFee,
		purpose: 'chargeCustomerProgramPoints',
	})
	if (!pay) {
		return { ok: false, error: 'Charge points burn failed.' }
	}
	if (!pay.success) {
		return { ok: false, error: formatNfcTopupAdminError(pay) }
	}
	return { ok: true, txHash: pay.txHash }
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
}): Promise<{
	postBalStr: string
	passHero?: PosSuccessPassHeroProps
	customerBeamioTag?: string
	customerWalletAddress?: string
}> {
	const delayMs = params.settlementViaQr ? 5000 : 3000
	await sleepMs(delayMs)
	const oracleRes = (await fetchOracle()) ?? DEFAULT_ORACLE
	const postAssets = await params.fetchPostAssets()
	let postBalStr = '—'
	if (postAssets?.ok) {
		const cad = postPaymentBalanceCad(
			postAssets,
			oracleRes,
			params.merchantInfraCard,
			params.useInfraPost,
		)
		if (cad != null) postBalStr = cad.toFixed(2)
	}
	if (!postAssets?.ok) return { postBalStr }
	let refreshedPass = params.passCard
	const passAddr = params.passCard?.cardAddress?.trim()
	if (passAddr) {
		const pc = postAssets.cards?.find(
			(c) => c.cardAddress.trim().toLowerCase() === passAddr.toLowerCase(),
		)
		if (pc) refreshedPass = pc
	}
	if (refreshedPass?.cardAddress?.trim()) {
		const bundle = await fetchCardMetadataTiersBundle(refreshedPass.cardAddress)
		refreshedPass = mergePrimaryTierStyleFromCardMetadata(refreshedPass, bundle.rows)
	}
	const heroAssets = refreshedPass
		? replacePassCardInAssets(postAssets, params.passCard, refreshedPass)
		: postAssets
	const passHero = buildSuccessPassHeroProps({
		assets: heroAssets,
		merchantInfraCard: params.merchantInfraCard,
		pointSystemEnabled: params.pointSystemEnabled,
		customerBeamioTag: postAssets.beamioTag ?? params.preAssets.beamioTag,
		customerWalletAddress: postAssets.address ?? params.preAssets.address,
		balanceAmount:
			postBalStr !== '—' && Number.isFinite(Number(postBalStr))
				? Number(postBalStr)
				: undefined,
		balanceCurrency: params.payCurrency,
		chargeTierDiscountPercent: params.chargeTierDiscountPercent,
	})
	return {
		postBalStr,
		passHero,
		customerBeamioTag: postAssets.beamioTag?.trim() || undefined,
		customerWalletAddress: postAssets.address?.trim() || undefined,
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
		return {
			status: 'error',
			message: formatPosAssetsQueryError(assets?.error) || 'Card not registered',
		}
	}
	patch?.('detectingUser', 'success', 'NFC card detected')
	patch?.('membership', 'success', 'NFC card payment')

	const oracleRes = (await fetchOracle()) ?? DEFAULT_ORACLE
	const payCard = assets.cards?.[0]
	/*
	 * fiat6-only: amount currency MUST be the merchant program card on-chain currency,
	 * not the customer pay-card / profile default (often CAD while card is USDC).
	 */
	const merchantChain = await fetchCardCurrencyAndPointsPriceE6(infra)
	const payCurrency = (
		merchantChain?.code ||
		payCard?.cardCurrency ||
		assets.cardCurrency ||
		'CAD'
	)
		.trim()
		.toUpperCase()
	if (!merchantChain?.code) {
		patch?.('analyzingAssets', 'error', 'Merchant card currency unavailable')
		return {
			status: 'error',
			message: 'Merchant card currency unavailable. Please refresh Home and try again.',
		}
	}
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

	const cardCurrencyOnChain = (prep.cardCurrency ?? payCurrency).toUpperCase()
	const pointsPriceCurE6 =
		Number(prep.pointsUnitPriceInCurrencyE6) || merchantChain.priceE6 || 0
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
	const burnPoints6 = chargeProgramPointsBurnAmount6(split)
	const burnFiat6 = chargeProgramPointsBurnFiat6(burnPoints6, pointsPriceCurE6)
	const usdcWei = firstUsdcAmount6(items as Array<Record<string, unknown>>)
	const customerAa = assets.aaAddress?.trim() || account
	const customerEoa = assets.address?.trim() || undefined
	if (burnPoints6 > 0 && (!customerAa || !looksLikeAddress(customerAa))) {
		patch?.('optimizingRoute', 'error', 'Customer Smart Wallet unavailable')
		return {
			status: 'error',
			message: 'Customer Smart Wallet unavailable for points settlement.',
		}
	}
	let routeDetail: string
	if (burnPoints6 > 0 && usdcWei > 0) {
		routeDetail = 'Hybrid: points burn + USDC'
	} else if (burnPoints6 > 0) {
		routeDetail = 'Points burn only'
	} else {
		routeDetail = 'USDC only'
	}
	patch?.('optimizingRoute', 'success', routeDetail)

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
	let lastTxHash: string | undefined
	const submitIdentity = resolveNfcTopupSubmitIdentity({
		uid: params.target.uid,
		sun: params.target.sun,
		wallet: customerEoa,
	})

	if (usdcWei > 0) {
		const container = {
			account,
			to: payeeAA,
			items,
			nonce,
			deadline,
		}
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
		lastTxHash = pay.txHash
	}

	if (burnPoints6 > 0) {
		const burn = await submitChargeCustomerProgramPointsBurn({
			merchantInfraCard: infra,
			customerAa,
			customerEoa,
			burnPoints6,
			burnFiat6,
			burnCurrency: payCurrency,
			skipBunitFee: usdcWei > 0,
			submitIdentity,
		})
		if (!burn.ok) {
			patch?.('sendTx', 'error', burn.error)
			patch?.('waitTx', 'error')
			return { status: 'error', message: burn.error }
		}
		lastTxHash = burn.txHash || lastTxHash
	}

	if (!(usdcWei > 0) && !(burnPoints6 > 0)) {
		patch?.('sendTx', 'error', 'Nothing to settle')
		return { status: 'error', message: 'Nothing to settle for this charge.' }
	}

	patch?.('sendTx', 'success', 'Sent')
	patch?.('waitTx', 'success', 'Transaction complete')
	patch?.('refreshBalance', 'loading', 'Fetching latest balance')

	const useInfraPost = burnPoints6 > 0
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
	})

	patch?.('refreshBalance', 'success', postBalStr !== '—' ? postBalStr : 'Updated')

	return {
		status: 'success',
		result: {
			amount: total.toFixed(2),
			subtotal: subtotal.toFixed(2),
			tip: tip > 0 ? tip.toFixed(2) : undefined,
			txHash: lastTxHash,
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

function firstUsdcAmount6(items: Array<Record<string, unknown>>): number {
	for (const it of items) {
		if (Number(it.kind) !== 0) continue
		return Number(optPayloadString(it.amount)) || 0
	}
	return 0
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

	const account = optPayloadString(params.openContainerPayload.account).trim()
	if (!account) {
		return { status: 'error', message: 'Invalid payment code' }
	}

	patch?.('detectingUser', 'loading')
	patch?.('detectingUser', 'success', 'Dynamic QR detected')
	patch?.('membership', 'loading')

	const assets = await fetchWalletAssetsForRead({ wallet: account, merchantInfraCard: infra })
	if (!assets?.ok) {
		patch?.('membership', 'error')
		return {
			status: 'error',
			message: formatPosAssetsQueryError(assets?.error) || 'Unable to fetch customer assets',
		}
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
	const merchantChain = await fetchCardCurrencyAndPointsPriceE6(infra)
	const payCurrency = (
		merchantChain?.code ||
		payCard?.cardCurrency ||
		assets.cardCurrency ||
		'CAD'
	)
		.trim()
		.toUpperCase()
	if (!merchantChain?.code) {
		patch?.('analyzingAssets', 'error', 'Merchant card currency unavailable')
		return {
			status: 'error',
			message: 'Merchant card currency unavailable. Please refresh Home and try again.',
		}
	}
	const amountFiat6Str = currencyToFiat6(total)
	const amountFiat6 = Number(amountFiat6Str)
	if (!(amountFiat6 > 0)) {
		patch?.('analyzingAssets', 'error', 'Amount conversion failed')
		return { status: 'error', message: 'Amount conversion failed' }
	}

	const cardAddr = payCard?.cardAddress?.trim() || assets.cardAddress?.trim() || ''
	const cardChainInfo = cardAddr ? await fetchCardCurrencyAndPointsPriceE6(cardAddr) : null
	const unitPrice = Number(assets.unitPriceUSDC6 ?? '0') || 0
	const cards = chargeableCards(assets, infra)
	const part = partitionPointsForMerchantCharge(cards, infra)
	const unitPoints6 = part.unitPricePoints6
	if (unitPoints6 > 0 && !cardChainInfo && !merchantChain) {
		patch?.('analyzingAssets', 'error', 'Card price unavailable')
		return {
			status: 'error',
			message: 'Card price unavailable. Please refresh the customer balance and try again.',
		}
	}
	const cardCurrencyOnChain = (
		merchantChain.code ||
		cardChainInfo?.code ||
		payCurrency
	).toUpperCase()
	const pointsPriceCurE6 = merchantChain.priceE6 || cardChainInfo?.priceE6 || 0
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
			qrRetryPayload: { ...params.openContainerPayload },
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
	const burnPoints6 = chargeProgramPointsBurnAmount6(split)
	const burnFiat6 = chargeProgramPointsBurnFiat6(burnPoints6, pointsPriceCurE6)
	const usdcWei = firstUsdcAmount6(items)
	const customerAa = assets.aaAddress?.trim() || account
	const customerEoa = assets.address?.trim() || undefined
	if (burnPoints6 > 0 && (!customerAa || !looksLikeAddress(customerAa))) {
		patch?.('optimizingRoute', 'error', 'Customer Smart Wallet unavailable')
		return {
			status: 'error',
			message: 'Customer Smart Wallet unavailable for points settlement.',
		}
	}
	let routeDetail: string
	if (burnPoints6 > 0 && usdcWei > 0) {
		routeDetail = 'Hybrid: points burn + USDC'
	} else if (burnPoints6 > 0) {
		routeDetail = 'Points burn only'
	} else {
		routeDetail = 'USDC only'
	}
	patch?.('optimizingRoute', 'success', routeDetail)

	const payload: Record<string, unknown> = { ...params.openContainerPayload }
	payload.items = items
	if (payload.maxAmount == null) payload.maxAmount = '0'
	if (payload.deadline == null && payload.validBefore != null) {
		payload.deadline = payload.validBefore
	}

	const terminalAssets = await fetchWalletAssetsForRead({
		wallet: payeeWallet,
		merchantInfraCard: infra,
	})
	const toAA =
		terminalAssets?.aaAddress?.trim() ||
		optPayloadString(payload.to).trim()
	if (!toAA || !looksLikeAddress(toAA)) {
		patch?.('sendTx', 'error', 'Merchant AA not found')
		return {
			status: 'error',
			message: 'Merchant AA not found. Please ensure terminal is configured.',
		}
	}
	payload.to = toAA

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
	let lastTxHash: string | undefined
	const submitIdentity = resolveNfcTopupSubmitIdentity({
		wallet: customerEoa,
	})

	if (usdcWei > 0) {
		const pay = await postAAtoEOA({
			openContainerPayload: payload,
			currency: payCurrency,
			currencyAmount: total.toFixed(2),
			merchantInfraCard: infra,
			chargeBill: bill,
		})
		if (!pay?.success) {
			patch?.('sendTx', 'error', pay?.error ?? 'Payment failed')
			patch?.('waitTx', 'error')
			return { status: 'error', message: pay?.error ?? 'Payment failed' }
		}
		lastTxHash = pay.txHash
	}

	if (burnPoints6 > 0) {
		const burn = await submitChargeCustomerProgramPointsBurn({
			merchantInfraCard: infra,
			customerAa,
			customerEoa,
			burnPoints6,
			burnFiat6,
			burnCurrency: payCurrency,
			skipBunitFee: usdcWei > 0,
			submitIdentity,
		})
		if (!burn.ok) {
			patch?.('sendTx', 'error', burn.error)
			patch?.('waitTx', 'error')
			return { status: 'error', message: burn.error }
		}
		lastTxHash = burn.txHash || lastTxHash
	}

	if (!(usdcWei > 0) && !(burnPoints6 > 0)) {
		patch?.('sendTx', 'error', 'Nothing to settle')
		return { status: 'error', message: 'Nothing to settle for this charge.' }
	}

	patch?.('sendTx', 'success', 'Sent')
	patch?.('waitTx', 'success', 'Transaction complete')
	patch?.('refreshBalance', 'loading', 'Fetching latest balance')

	const useInfraPost = burnPoints6 > 0
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
	})

	patch?.('refreshBalance', 'success', postBalStr !== '—' ? postBalStr : 'Updated')

	return {
		status: 'success',
		result: {
			amount: total.toFixed(2),
			subtotal: subtotal.toFixed(2),
			tip: tip > 0 ? tip.toFixed(2) : undefined,
			txHash: lastTxHash,
			postBalance: postBalStr,
			cardCurrency: payCurrency,
			memberNo: memberNo || undefined,
			customerBeamioTag: customerBeamioTag ?? assets.beamioTag,
			payee: toAA,
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
