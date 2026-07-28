import {
	cardCouponPosClaim,
	cardCouponPosClaimPrepare,
	cardCouponPosClaimSubmit,
} from '@/api/beamioApi'
import type {
	MerchantClaimableCouponItem,
	MerchantCouponBalanceItem,
	UIDAssetsResult,
} from '@/types/pos'
import { getPosPrivateKeyHex } from '@/wallet/getPosPrivateKeyHex'
import { signExecuteForAdmin } from '@/wallet/signExecuteForAdmin'
import { isPlausibleEvmAddress } from '@/utils/evmAddress'

export function merchantCouponRowId(cardAddress: string, tokenId: string): string {
	return `${cardAddress.trim().toLowerCase()}:${tokenId.trim()}`
}

/** iOS ContentView `readBalanceHasCouponClaimContext` — NFC uid/tag or member EOA. */
export function readBalanceHasCouponClaimContext(assets: UIDAssetsResult): boolean {
	if (assets.uid?.trim()) return true
	if (assets.tagIdHex?.trim()) return true
	return isPlausibleEvmAddress(assets.address)
}

export function readBalanceClaimUserEoa(assets: UIDAssetsResult): string {
	return assets.address?.trim() ?? ''
}

/** Mirror iOS `POSViewModel._claimMerchantCouponFromLastRead` local assets patch. */
export function applyClaimSuccessToAssets(
	assets: UIDAssetsResult,
	coupon: MerchantClaimableCouponItem,
): UIDAssetsResult {
	const next: UIDAssetsResult = { ...assets }
	const rowId = merchantCouponRowId(coupon.cardAddress, coupon.tokenId)

	if (next.merchantClaimableCoupons) {
		const claimable = next.merchantClaimableCoupons.filter(
			(row) => merchantCouponRowId(row.cardAddress, row.tokenId) !== rowId,
		)
		next.merchantClaimableCoupons = claimable.length ? claimable : undefined
	}

	const balances = [...(next.merchantCouponBalances ?? [])]
	const idx = balances.findIndex((row) => merchantCouponRowId(row.cardAddress, row.tokenId) === rowId)
	if (idx >= 0) {
		const old = Number.parseInt(balances[idx].balance.trim(), 10) || 0
		balances[idx] = {
			...balances[idx],
			balance: String(Math.max(0, old) + 1),
		}
	} else {
		balances.push({
			cardAddress: coupon.cardAddress,
			couponId: coupon.couponId,
			tokenId: coupon.tokenId,
			title: coupon.title,
			balance: '1',
			requiresRedeemCode: coupon.requiresRedeemCode,
		} satisfies MerchantCouponBalanceItem)
	}
	next.merchantCouponBalances = balances
	return next
}

export type ClaimMerchantCouponResult =
	| { status: 'success'; assets: UIDAssetsResult }
	| { status: 'error'; message: string }

/** Full POS claim flow: NFC → server openClaim; QR/wallet → prepare → sign → submit. */
export async function claimMerchantCouponFromRead(params: {
	assets: UIDAssetsResult
	coupon: MerchantClaimableCouponItem
	signerEOA?: string | null
}): Promise<ClaimMerchantCouponResult> {
	const { assets, coupon, signerEOA } = params
	const user = readBalanceClaimUserEoa(assets)
	if (!isPlausibleEvmAddress(user)) {
		return { status: 'error', message: 'Invalid user account for claim.' }
	}

	const hasNfc = Boolean(assets.uid?.trim() || assets.tagIdHex?.trim())
	if (hasNfc) {
		const result = await cardCouponPosClaim({
			cardAddress: coupon.cardAddress,
			couponId: coupon.couponId,
			userEOA: user,
			uid: assets.uid,
			tagIdHex: assets.tagIdHex,
			tokenId: coupon.tokenId,
			signerEOA: signerEOA ?? undefined,
		})
		if (!result) {
			return { status: 'error', message: 'Coupon claim failed.' }
		}
		if (!result.success) {
			return { status: 'error', message: result.error ?? 'Coupon claim failed.' }
		}
		return { status: 'success', assets: applyClaimSuccessToAssets(assets, coupon) }
	}

	if (!isPlausibleEvmAddress(signerEOA)) {
		return { status: 'error', message: 'Terminal wallet not initialized. POS admin is required for QR claim.' }
	}

	const pk = await getPosPrivateKeyHex()
	if (!pk) {
		return { status: 'error', message: 'Merchant signature wallet is unavailable.' }
	}

	const prep = await cardCouponPosClaimPrepare({
		cardAddress: coupon.cardAddress,
		couponId: coupon.couponId,
		userEOA: user,
		signerEOA: signerEOA ?? undefined,
		tokenId: coupon.tokenId,
	})
	if (!prep) {
		return { status: 'error', message: 'Claim prepare failed.' }
	}
	if (!prep.success || !prep.cardAddress || !prep.data || !prep.deadline || !prep.nonce) {
		return { status: 'error', message: prep.error ?? 'Claim prepare failed.' }
	}

	let adminSignature: string
	try {
		adminSignature = await signExecuteForAdmin({
			privateKeyHex: pk,
			cardAddress: prep.cardAddress,
			dataHex: prep.data,
			deadline: prep.deadline,
			nonceHex: prep.nonce,
			factoryGateway: prep.factoryGateway,
		})
	} catch {
		return { status: 'error', message: 'Merchant signature failed.' }
	}

	const submit = await cardCouponPosClaimSubmit({
		cardAddress: prep.cardAddress,
		data: prep.data,
		deadline: prep.deadline,
		nonce: prep.nonce,
		adminSignature,
		signerEOA: signerEOA ?? undefined,
	})
	if (!submit) {
		return { status: 'error', message: 'Coupon claim failed.' }
	}
	if (!submit.success) {
		return { status: 'error', message: submit.error ?? 'Coupon claim failed.' }
	}

	return { status: 'success', assets: applyClaimSuccessToAssets(assets, coupon) }
}
