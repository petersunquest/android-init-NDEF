import {
	cardCouponPosConsumePrepare,
	cardCouponPosConsumeSubmit,
} from '@/api/beamioApi'
import type { MerchantCouponBalanceItem, UIDAssetsResult } from '@/types/pos'
import { getPosPrivateKeyHex } from '@/wallet/getPosPrivateKeyHex'
import { signExecuteForAdmin } from '@/wallet/signExecuteForAdmin'
import { isPlausibleEvmAddress } from '@/utils/evmAddress'
import { merchantCouponRowId, readBalanceClaimUserEoa } from '@/utils/readBalanceCouponClaim'

export type ConsumeMerchantCouponResult =
	| { status: 'success'; assets: UIDAssetsResult; clearClaimSucceededId?: boolean }
	| { status: 'error'; message: string }

/** Mirror iOS `POSViewModel._consumeMerchantCouponFromLastRead` local assets patch. */
export function applyConsumeSuccessToAssets(
	assets: UIDAssetsResult,
	coupon: MerchantCouponBalanceItem,
): UIDAssetsResult {
	const next: UIDAssetsResult = { ...assets }
	const rowId = merchantCouponRowId(coupon.cardAddress, coupon.tokenId)
	const balances = [...(next.merchantCouponBalances ?? [])]
	const idx = balances.findIndex((row) => merchantCouponRowId(row.cardAddress, row.tokenId) === rowId)
	if (idx >= 0) {
		const old = Number.parseInt(balances[idx].balance.trim(), 10) || 0
		const nextBal = Math.max(0, old - 1)
		if (nextBal === 0) {
			balances.splice(idx, 1)
		} else {
			balances[idx] = { ...balances[idx], balance: String(nextBal) }
		}
	}
	next.merchantCouponBalances = balances.length ? balances : undefined
	return next
}

/** Full POS consume flow: prepare → sign ExecuteForAdmin → submit. */
export async function consumeMerchantCouponFromRead(params: {
	assets: UIDAssetsResult
	coupon: MerchantCouponBalanceItem
	signerEOA?: string | null
	claimSucceededId?: string | null
}): Promise<ConsumeMerchantCouponResult> {
	const { assets, coupon, signerEOA, claimSucceededId } = params
	const user = readBalanceClaimUserEoa(assets)
	if (!isPlausibleEvmAddress(user)) {
		return { status: 'error', message: 'Invalid user account for consume.' }
	}

	const pk = await getPosPrivateKeyHex()
	if (!pk) {
		return { status: 'error', message: 'Merchant signature wallet is unavailable.' }
	}

	const prep = await cardCouponPosConsumePrepare({
		cardAddress: coupon.cardAddress,
		couponId: coupon.couponId,
		userEOA: user,
		signerEOA: signerEOA ?? undefined,
		tokenId: coupon.tokenId,
		amount: '1',
	})
	if (!prep) {
		return { status: 'error', message: 'Consume prepare failed.' }
	}
	if (
		!prep.success ||
		!prep.cardAddress ||
		!prep.data ||
		!prep.deadline ||
		!prep.nonce
	) {
		return { status: 'error', message: prep.error ?? 'Consume prepare failed.' }
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

	const submit = await cardCouponPosConsumeSubmit({
		cardAddress: prep.cardAddress,
		data: prep.data,
		deadline: prep.deadline,
		nonce: prep.nonce,
		adminSignature,
		signerEOA: signerEOA ?? undefined,
		userEOA: user,
	})
	if (!submit) {
		return { status: 'error', message: 'Coupon consume failed.' }
	}
	if (!submit.success) {
		return { status: 'error', message: submit.error ?? 'Coupon consume failed.' }
	}

	const rowId = merchantCouponRowId(coupon.cardAddress, coupon.tokenId)
	const nextAssets = applyConsumeSuccessToAssets(assets, coupon)
	return {
		status: 'success',
		assets: nextAssets,
		clearClaimSucceededId: claimSucceededId === rowId,
	}
}
