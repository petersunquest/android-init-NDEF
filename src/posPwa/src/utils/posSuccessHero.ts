import type { ReadBalanceCardItem, UIDAssetsResult } from '@/types/pos'
import type { ReadBalanceMoneyParts } from '@/utils/readBalanceDisplay'
import {
	readBalanceFormatMoney,
	readBalancePassHeroMemberDisplayName,
	readBalancePointRewardSubtitle,
	readBalanceTierDiscountPercent,
} from '@/utils/readBalanceDisplay'
import { memberNoFromCard, readBalancePrimaryCard } from '@/utils/readBalanceAssets'
import { paymentSuccessMemberTitle, programCardDisplayLine, shortWalletAddr } from '@/utils/posReceiptUtils'

export interface PosSuccessPassHeroProps {
	memberDisplayName: string
	memberNo: string
	tierDisplayName: string | null
	tierDiscountPercent: number | null
	programCardDisplayName: string
	tierCardBackgroundHex?: string
	cardMetadataImageUrl: string | null
	balanceParts: ReadBalanceMoneyParts
	balanceSubtitle: string | null
}

export function buildSuccessPassHeroProps(params: {
	assets: UIDAssetsResult
	merchantInfraCard: string
	pointSystemEnabled: boolean
	customerBeamioTag?: string
	customerWalletAddress?: string
	balanceAmount?: number
	balanceCurrency?: string
	chargeTierDiscountPercent?: number
}): PosSuccessPassHeroProps {
	const primary = readBalancePrimaryCard(params.assets, params.merchantInfraCard)
	const memberDisplayName = paymentSuccessMemberTitle({
		customerBeamioTag: params.customerBeamioTag ?? params.assets.beamioTag,
		customerWalletAddress: params.customerWalletAddress ?? params.assets.address,
		cardName: primary?.cardName,
	})
	const memberNo =
		memberNoFromCard(primary) ||
		shortWalletAddr(params.customerWalletAddress ?? params.assets.address) ||
		'—'
	const tierDisplayName = primary?.tierName?.trim() || null
	const tierDiscountPercent =
		params.chargeTierDiscountPercent != null && params.chargeTierDiscountPercent > 0
			? params.chargeTierDiscountPercent
			: readBalanceTierDiscountPercent(primary)
	const programCardDisplayName = programCardDisplayLine(primary?.cardName)
	const tierCardBackgroundHex = primary?.cardBackground?.trim() || undefined
	const cardMetadataImageUrl = primary?.cardImage?.trim() || null
	const currency =
		params.balanceCurrency ?? primary?.cardCurrency ?? params.assets.cardCurrency ?? 'CAD'
	let balanceAmount = params.balanceAmount
	if (balanceAmount == null) {
		const p6 = Number(primary?.points6 ?? params.assets.points6 ?? '0')
		if (p6 > 0) balanceAmount = p6 / 1_000_000
		else balanceAmount = Number(primary?.points ?? params.assets.points ?? '0') || 0
	}
	const balanceParts = readBalanceFormatMoney(balanceAmount, currency)
	const balanceSubtitle = readBalancePointRewardSubtitle(
		primary,
		params.assets,
		params.pointSystemEnabled,
	)
	return {
		memberDisplayName,
		memberNo,
		tierDisplayName,
		tierDiscountPercent,
		programCardDisplayName,
		tierCardBackgroundHex,
		cardMetadataImageUrl,
		balanceParts,
		balanceSubtitle,
	}
}

export function buildFallbackPassHero(params: {
	currency: string
	balanceAmount?: number
	memberNo?: string
	customerBeamioTag?: string
	customerWalletAddress?: string
	cardName?: string
	tierName?: string
	tierDiscountPercent?: number | null
}): PosSuccessPassHeroProps {
	const memberDisplayName = paymentSuccessMemberTitle({
		customerBeamioTag: params.customerBeamioTag,
		customerWalletAddress: params.customerWalletAddress,
		cardName: params.cardName,
	})
	const memberNo =
		params.memberNo?.trim() ||
		shortWalletAddr(params.customerWalletAddress) ||
		'—'
	return {
		memberDisplayName,
		memberNo,
		tierDisplayName: params.tierName?.trim() || null,
		tierDiscountPercent:
			params.tierDiscountPercent != null && params.tierDiscountPercent > 0
				? params.tierDiscountPercent
				: null,
		programCardDisplayName: programCardDisplayLine(params.cardName),
		tierCardBackgroundHex: undefined,
		cardMetadataImageUrl: null,
		balanceParts: readBalanceFormatMoney(params.balanceAmount ?? 0, params.currency),
		balanceSubtitle: null,
	}
}

export function pickPaymentCard(
	assets: UIDAssetsResult,
	merchantInfraCard: string,
): ReadBalanceCardItem | undefined {
	return readBalancePrimaryCard(assets, merchantInfraCard) ?? assets.cards?.[0]
}

export function buildTopupSuccessPassHero(params: {
	assets: UIDAssetsResult
	cardAddr: string
	merchantInfraCard: string
	pointSystemEnabled: boolean
	postBalance: string
	cardCurrency: string
	customerBeamioTag?: string
	customerAddress?: string
}): PosSuccessPassHeroProps {
	const card =
		params.assets.cards?.find(
			(c) => c.cardAddress.trim().toLowerCase() === params.cardAddr.trim().toLowerCase(),
		) ?? pickPaymentCard(params.assets, params.merchantInfraCard)
	const postNum = Number(params.postBalance)
	const balanceAmount = Number.isFinite(postNum) ? postNum : undefined
	const memberDisplayName =
		params.customerBeamioTag?.replace(/^@/, '') ||
		readBalancePassHeroMemberDisplayName(params.assets, card)
	const memberNo =
		memberNoFromCard(card) || shortWalletAddr(params.customerAddress ?? params.assets.address) || '—'
	return {
		memberDisplayName,
		memberNo,
		tierDisplayName: card?.tierName?.trim() || null,
		tierDiscountPercent: readBalanceTierDiscountPercent(card),
		programCardDisplayName: programCardDisplayLine(card?.cardName),
		tierCardBackgroundHex: card?.cardBackground?.trim() || undefined,
		cardMetadataImageUrl: card?.cardImage?.trim() || null,
		balanceParts: readBalanceFormatMoney(balanceAmount ?? 0, params.cardCurrency),
		balanceSubtitle: readBalancePointRewardSubtitle(
			card,
			params.assets,
			params.pointSystemEnabled,
		),
	}
}
