import type { UIDAssetsResult } from '@/types/pos'
import {
	metadataTierMembershipFeeE6,
	metadataTierOnChainIndex,
	type MetadataTierRow,
} from '@/utils/beamioPaymentRouting'
import { isMembershipNftTokenId } from '@/utils/membershipNft'
import { readBalancePrimaryCard } from '@/utils/readBalanceAssets'

export type ReadBalanceMembershipTierChoice = {
	tierIndex: number
	feeFiat6: string
	/** On-chain tier minUsdc6 (points6 units); membership-fee mode uses 1, 2, 3… */
	minUsdc6?: string
	name: string
	durationKind?: number
}

/** Same hint as x402sdk `MEMBERSHIP_FEE_CHECK_BALANCE_HINT` — purchase membership on Check Balance, not generic Top-up. */
export const MEMBERSHIP_FEE_CHECK_BALANCE_HINT =
	'Active membership required. Purchase membership from Check Balance before top-up.'

export function readBalanceCustomerHasValidMembership(
	assets: UIDAssetsResult,
	merchantInfraCard: string,
): boolean {
	const primary = String(assets.primaryMemberTokenId ?? '').trim()
	if (primary && isMembershipNftTokenId(primary)) return true
	const infra = merchantInfraCard.trim().toLowerCase()
	const cardRow =
		assets.cards?.find((row) => row.cardAddress?.trim().toLowerCase() === infra) ??
		readBalancePrimaryCard(assets, merchantInfraCard)
	const primaryOnCard = String(cardRow?.primaryMemberTokenId ?? '').trim()
	if (primaryOnCard && isMembershipNftTokenId(primaryOnCard)) return true
	const nfts = cardRow?.nfts ?? assets.nfts ?? []
	return nfts.some((n) => !n.isExpired && isMembershipNftTokenId(n.tokenId))
}

export function readBalanceMembershipFeeTiers(
	rows: MetadataTierRow[],
): ReadBalanceMembershipTierChoice[] {
	const out: ReadBalanceMembershipTierChoice[] = []
	rows.forEach((row, i) => {
		const feeFiat6 = metadataTierMembershipFeeE6(row)
		if (BigInt(feeFiat6) <= 0n) return
		const tierIndex = metadataTierOnChainIndex(row, i)
		const defaultName = tierIndex === 0 ? 'Membership' : `Tier ${tierIndex}`
		out.push({
			tierIndex,
			feeFiat6,
			minUsdc6: row.minUsdc6,
			name: (row.name ?? defaultName).trim() || defaultName,
			durationKind: row.membershipDurationKind,
		})
	})
	return out
}

function parseMembershipNftChainTierIndex(tier: string | undefined): number | null {
	const raw = (tier ?? '').trim()
	if (!raw || raw === 'Default/Max') return null
	const n = Number(raw)
	if (Number.isFinite(n) && n >= 0 && n < Number.MAX_SAFE_INTEGER) return Math.trunc(n)
	const m = raw.match(/chain-tier-(\d+)/i)
	if (!m) return null
	const idx = Number(m[1])
	return Number.isFinite(idx) && idx >= 0 ? Math.trunc(idx) : null
}

function membershipFeeChoiceE6(tier: ReadBalanceMembershipTierChoice): bigint {
	try {
		const n = BigInt(String(tier.feeFiat6).replace(/,/g, '').trim() || '0')
		return n > 0n ? n : 0n
	} catch {
		return 0n
	}
}

function lowestMembershipFeeE6(feeTiers: ReadBalanceMembershipTierChoice[]): bigint | null {
	let min: bigint | null = null
	for (const t of feeTiers) {
		const fee = membershipFeeChoiceE6(t)
		if (fee <= 0n) continue
		if (min == null || fee < min) min = fee
	}
	return min
}

/**
 * Highest paid membership the customer already holds (NFT chain index / fee),
 * used to hide the current option and only offer strictly higher upgrades.
 */
function resolveHeldPaidMembership(
	feeTiers: ReadBalanceMembershipTierChoice[],
	assets: UIDAssetsResult,
	merchantInfraCard: string,
): { tierIndex: number | null; feeE6: bigint | null } {
	const feeByIndex = new Map<number, bigint>()
	for (const t of feeTiers) {
		const fee = membershipFeeChoiceE6(t)
		if (fee > 0n) feeByIndex.set(t.tierIndex, fee)
	}
	const primary = readBalancePrimaryCard(assets, merchantInfraCard)
	const nfts = [...(primary?.nfts ?? []), ...(assets.nfts ?? [])]
	let bestIndex: number | null = null
	let bestFee: bigint | null = null
	for (const nft of nfts) {
		if (!isMembershipNftTokenId(nft.tokenId)) continue
		if (nft.isExpired) continue
		const idx = parseMembershipNftChainTierIndex(nft.tier)
		if (idx == null || !feeByIndex.has(idx)) continue
		const fee = feeByIndex.get(idx) ?? 0n
		if (bestFee == null || fee > bestFee || (fee === bestFee && (bestIndex == null || idx > bestIndex))) {
			bestIndex = idx
			bestFee = fee
		}
	}
	if (bestIndex != null) return { tierIndex: bestIndex, feeE6: bestFee }
	const name = primary?.tierName?.trim().toLowerCase() ?? ''
	if (name && name !== 'default') {
		const byName = feeTiers.find((t) => t.name.trim().toLowerCase() === name)
		if (byName) {
			return { tierIndex: byName.tierIndex, feeE6: membershipFeeChoiceE6(byName) }
		}
	}
	return { tierIndex: null, feeE6: null }
}

/**
 * Paid membership choices the customer can still upgrade to.
 * Empty when they already hold a paid membership and no higher-fee paid tier exists.
 * Current (already issued) paid options are never included.
 */
export function readBalanceMembershipUpgradeTiers(
	feeTiers: ReadBalanceMembershipTierChoice[],
	assets: UIDAssetsResult,
	merchantInfraCard: string,
): ReadBalanceMembershipTierChoice[] {
	if (feeTiers.length === 0) return []
	if (!readBalanceCustomerHasValidMembership(assets, merchantInfraCard)) return []
	const held = resolveHeldPaidMembership(feeTiers, assets, merchantInfraCard)
	const floorFee =
		held.feeE6 != null && held.feeE6 > 0n ? held.feeE6 : lowestMembershipFeeE6(feeTiers)
	if (floorFee == null) return []
	return feeTiers.filter((t) => {
		if (held.tierIndex != null && t.tierIndex === held.tierIndex) return false
		return membershipFeeChoiceE6(t) > floorFee
	})
}

/**
 * Paid-membership issue must mint a non-zero `#0` top-up (card rejects mint 0).
 * API mints `MEMBERSHIP_FEE_ONLY_ISSUE_POINTS6 = 1` when client amount equals the locked fee.
 * Do not add this dust onto the POS payable amount / USDC QR.
 */
export const MEMBERSHIP_FEE_ISSUE_TOPUP_E6 = 1n

export function membershipPurchasePointsCreditE6(_minUsdc6?: string | number | bigint | null): bigint {
	return MEMBERSHIP_FEE_ISSUE_TOPUP_E6
}

/**
 * User-facing membership amounts use two decimal places (CA$0.50, not 0.500001).
 * Extra E6 dust is truncated toward zero — join pays the locked fee only.
 */
function membershipFeeE6ToHuman2dp(e6: string | number | undefined | null): string {
	if (e6 == null || e6 === '') return ''
	try {
		const bi = BigInt(String(e6).replace(/,/g, '').trim() || '0')
		if (bi <= 0n) return ''
		const whole = bi / 1_000_000n
		const cents = (bi % 1_000_000n) / 10_000n
		return `${whole}.${cents.toString().padStart(2, '0')}`
	} catch {
		return ''
	}
}

/** Full 6dp human string for E6 amounts (unlike 2dp fee formatting). */
function formatMembershipCurrencyE6Full(e6: bigint): string {
	if (e6 <= 0n) return '0'
	const whole = e6 / 1_000_000n
	const frac = (e6 % 1_000_000n).toString().padStart(6, '0').replace(/0+$/, '')
	return frac ? `${whole}.${frac}` : `${whole}`
}

/**
 * Charge / API amount = locked membership fee only (two decimals).
 * API adds `MEMBERSHIP_FEE_ONLY_ISSUE_POINTS6` when leftover after fee is 0.
 */
export function membershipPurchaseApiAmountHuman(
	feeFiat6: string,
	_minUsdc6?: string | number | bigint | null,
): string {
	try {
		const fee = BigInt(String(feeFiat6).replace(/,/g, '').trim() || '0')
		if (fee <= 0n) return '0'
		return membershipFeeE6ToHuman2dp(fee.toString()) || '0'
	} catch {
		return '0'
	}
}

export function membershipPurchaseBalanceCreditHuman(
	feeFiat6: string,
	minUsdc6?: string | number | bigint | null,
): string {
	try {
		const fee = BigInt(String(feeFiat6).replace(/,/g, '').trim() || '0')
		if (fee <= 0n) return '0'
		const credit = membershipPurchasePointsCreditE6(minUsdc6)
		return formatMembershipCurrencyE6Full(credit)
	} catch {
		return '0'
	}
}
