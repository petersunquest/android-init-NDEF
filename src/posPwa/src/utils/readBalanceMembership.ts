import type { UIDAssetsResult } from '@/types/pos'
import {
	membershipFeeE6ToHuman,
	metadataTierMembershipFeeE6,
	metadataTierOnChainIndex,
	type MetadataTierRow,
} from '@/utils/beamioPaymentRouting'
import { readBalancePrimaryCard } from '@/utils/readBalanceAssets'

export type ReadBalanceMembershipTierChoice = {
	tierIndex: number
	feeFiat6: string
	name: string
	durationKind?: number
}

/** Same membership validity heuristic as `executeNfcTopup` / Cluster fee staging. */
export function readBalanceCustomerHasValidMembership(
	assets: UIDAssetsResult,
	merchantInfraCard: string,
): boolean {
	const primary = String(assets.primaryMemberTokenId ?? '').trim()
	if (primary && primary !== '0') return true
	const infra = merchantInfraCard.trim().toLowerCase()
	const cardRow =
		assets.cards?.find((row) => row.cardAddress?.trim().toLowerCase() === infra) ??
		readBalancePrimaryCard(assets, merchantInfraCard)
	const primaryOnCard = String(cardRow?.primaryMemberTokenId ?? '').trim()
	if (primaryOnCard && primaryOnCard !== '0') return true
	const nfts = cardRow?.nfts ?? assets.nfts ?? []
	return nfts.some((n) => Number(n.tokenId) > 0)
}

export function readBalanceMembershipFeeTiers(
	rows: MetadataTierRow[],
): ReadBalanceMembershipTierChoice[] {
	const out: ReadBalanceMembershipTierChoice[] = []
	rows.forEach((row, i) => {
		const feeFiat6 = metadataTierMembershipFeeE6(row)
		if (BigInt(feeFiat6) <= 0n) return
		out.push({
			tierIndex: metadataTierOnChainIndex(row, i),
			feeFiat6,
			name: (row.name ?? `Tier ${i + 1}`).trim() || `Tier ${i + 1}`,
			durationKind: row.membershipDurationKind,
		})
	})
	return out
}

/**
 * Cluster requires points credit after fee: amountCurrency6 must strictly exceed feeFiat6.
 * Bump by 1 whole unit when fee is whole, else +0.01.
 */
export function membershipPurchaseApiAmountHuman(feeFiat6: string): string {
	try {
		const fee = BigInt(String(feeFiat6).replace(/,/g, '').trim() || '0')
		if (fee <= 0n) return '0'
		const bump = fee % 1_000_000n === 0n ? 1_000_000n : 10_000n
		return membershipFeeE6ToHuman((fee + bump).toString()) || '0'
	} catch {
		return '0'
	}
}

export function membershipPurchaseBalanceCreditHuman(feeFiat6: string): string {
	try {
		const fee = BigInt(String(feeFiat6).replace(/,/g, '').trim() || '0')
		if (fee <= 0n) return '0'
		const bump = fee % 1_000_000n === 0n ? 1_000_000n : 10_000n
		return membershipFeeE6ToHuman(bump.toString()) || '0'
	} catch {
		return '0'
	}
}
