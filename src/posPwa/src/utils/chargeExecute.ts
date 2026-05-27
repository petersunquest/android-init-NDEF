import {
	fetchCardMetadataRoot,
	fetchOracle,
	fetchUIDAssets,
	payByNfcUidPrepare,
	payByNfcUidSignContainer,
} from '@/api/beamioApi'
import type { UIDAssetsResult } from '@/types/pos'
import {
	chargeTipFromRequestAndBps,
	chargeTotalInCurrency,
	chargeableCards,
	computeChargeContainerSplitFiat6,
	currencyToFiat6,
	DEFAULT_ORACLE,
	buildPayItemsFiat6,
	mergeInfraKind1Items,
	normalizeTierDiscountPercent,
	parseMetadataTierRows,
	partitionPointsForMerchantCharge,
	pickChargeTierDiscountPercent,
	points6ToUsdc6,
	postPaymentBalanceCad,
	tierDiscountBasisPoints,
} from '@/utils/beamioPaymentRouting'
import { fetchChargeTierRoutingDetails } from '@/utils/chargeTierRouting'
import type { PosTerminalChargePolicy } from '@/utils/chargePaymentMethod'
import {
	buildSuccessPassHeroProps,
	type PosSuccessPassHeroProps,
} from '@/utils/posSuccessHero'

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
	| { status: 'insufficient'; message: string; requiredLabel?: string; availableLabel?: string }
	| { status: 'error'; message: string }

function payerUsdcBalance6(assets: UIDAssetsResult, policy: PosTerminalChargePolicy): number {
	const raw = Math.round((Number(assets.usdcBalance ?? '0') || 0) * 1_000_000)
	return policy.allowPayerUsdcInCharge ? raw : 0
}

async function sleepMs(ms: number): Promise<void> {
	await new Promise((r) => setTimeout(r, ms))
}

export async function executeNfcCharge(params: {
	target: ChargeCustomerTarget
	subtotal: number
	tipBps: number
	merchantInfraCard: string
	posWallet: string
	chargePolicy: PosTerminalChargePolicy
	pointSystemEnabled?: boolean
}): Promise<ChargeExecuteResult> {
	const infra = params.merchantInfraCard.trim()
	const payee = params.posWallet.trim()
	if (!infra || !payee) {
		return { status: 'error', message: 'Terminal not configured.' }
	}
	const subtotal = params.subtotal
	if (!(subtotal > 0)) {
		return { status: 'error', message: 'Invalid amount.' }
	}

	const assets = await fetchUIDAssets({
		uid: params.target.uid,
		merchantInfraCard: infra,
		sun: params.target.sun,
	})
	if (!assets?.ok) {
		return { status: 'error', message: assets?.error ?? 'Card not registered' }
	}

	const oracleRes = (await fetchOracle()) ?? DEFAULT_ORACLE
	const payCard = assets.cards?.[0]
	const payCurrency = payCard?.cardCurrency ?? assets.cardCurrency ?? 'CAD'
	const routing = (await fetchChargeTierRoutingDetails(payee, infra)) ?? {
		taxPercent: 0,
		discountByTierKey: {},
	}
	const metaRoot = await fetchCardMetadataRoot(payCard?.cardAddress ?? infra)
	const tiersArr = (metaRoot?.metadata as { tiers?: unknown[] } | undefined)?.tiers
	const metadataTiers = Array.isArray(tiersArr) ? parseMetadataTierRows(tiersArr) : []
	const disc = pickChargeTierDiscountPercent({
		paymentCard: payCard,
		assets,
		discountByTierKey: routing.discountByTierKey,
		metadataTiers,
		metadataTiersFromApi: metadataTiers.length > 0,
	})
	const tip = chargeTipFromRequestAndBps(subtotal, params.tipBps)
	const total = chargeTotalInCurrency(subtotal, routing.taxPercent, disc, tip)
	const amountFiat6Str = currencyToFiat6(total)
	const amountFiat6 = Number(amountFiat6Str)
	if (!(amountFiat6 > 0)) {
		return { status: 'error', message: 'Amount conversion failed' }
	}

	const prep = await payByNfcUidPrepare({
		uid: params.target.uid,
		payee,
		amountFiat6: amountFiat6Str,
		currency: payCurrency,
		sun: params.target.sun,
	})
	if (!prep?.ok) {
		return { status: 'error', message: prep?.error ?? 'Prepare failed' }
	}
	const account = prep.account
	const nonce = prep.nonce
	const deadline = prep.deadline
	const payeeAA = prep.payeeAA
	const unitPrice = Number(prep.unitPriceUSDC6) || 0
	if (!account || !nonce || !deadline || !payeeAA || unitPrice <= 0) {
		return { status: 'error', message: prep.error ?? 'Prepare failed' }
	}

	const cardCurrencyOnChain = prep.cardCurrency?.toUpperCase()
	const pointsPriceCurE6 = Number(prep.pointsUnitPriceInCurrencyE6) || 0
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

	const pay = await payByNfcUidSignContainer({
		uid: params.target.uid,
		containerPayload: container,
		amountFiat6: amountFiat6Str,
		currency: payCurrency,
		sun: params.target.sun,
		nfcBill: bill,
	})
	if (!pay?.success) {
		return { status: 'error', message: pay?.error ?? 'Payment failed' }
	}

	await sleepMs(3000)
	const postAssets = await fetchUIDAssets({
		uid: params.target.uid,
		merchantInfraCard: infra,
		sun: params.target.sun,
	})
	const useInfraPost = split.ccsaPointsWei + split.infraPointsWei > 0
	let postBalStr = '—'
	if (postAssets?.ok) {
		const cad = postPaymentBalanceCad(postAssets, oracleRes, infra, useInfraPost)
		if (cad != null) postBalStr = cad.toFixed(2)
	}

	const memberNo = payCard?.primaryMemberTokenId
		? `M-${payCard.primaryMemberTokenId}`
		: undefined

	const passHero = postAssets?.ok
		? buildSuccessPassHeroProps({
				assets: postAssets,
				merchantInfraCard: infra,
				pointSystemEnabled: params.pointSystemEnabled ?? false,
				customerBeamioTag: postAssets.beamioTag ?? assets.beamioTag,
				customerWalletAddress: postAssets.address ?? assets.address,
				balanceAmount:
					postBalStr !== '—' && Number.isFinite(Number(postBalStr))
						? Number(postBalStr)
						: undefined,
				balanceCurrency: payCurrency,
				chargeTierDiscountPercent: disc,
			})
		: undefined

	return {
		status: 'success',
		result: {
			amount: total.toFixed(2),
			subtotal: subtotal.toFixed(2),
			tip: tip > 0 ? tip.toFixed(2) : undefined,
			txHash: pay.txHash,
			postBalance: postBalStr,
			cardCurrency: payCurrency,
			memberNo,
			customerBeamioTag: postAssets?.beamioTag ?? assets.beamioTag,
			payee: payeeAA,
			cardName: payCard?.cardName,
			tierName: payCard?.tierName,
			chargeTaxPercent: routing.taxPercent,
			chargeTierDiscountPercent: disc,
			settlementViaQr: false,
			customerWalletAddress: postAssets?.address ?? assets.address,
			passHero,
		},
	}
}
