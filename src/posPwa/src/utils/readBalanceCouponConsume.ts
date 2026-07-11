import {
	cardCouponPosConsumePrepare,
	cardCouponPosConsumeSubmit,
	postAAtoEOA,
} from '@/api/beamioApi'
import type { MerchantCouponBalanceItem, UIDAssetsResult } from '@/types/pos'
import { getPosPrivateKeyHex } from '@/wallet/getPosPrivateKeyHex'
import { signExecuteForAdmin } from '@/wallet/signExecuteForAdmin'
import { isPlausibleEvmAddress } from '@/utils/evmAddress'
import { merchantCouponRowId, readBalanceClaimUserEoa } from '@/utils/readBalanceCouponClaim'
import { selectOpenContainerPayloadForMerchantCard } from '@/utils/chargeExecute'

export type OpenContainerSurrenderPrep = {
	cardAddress: string
	couponId: string
	userEOA: string
	userAccount: string
	tokenId: string
	amount: string
}

export type ConsumeMerchantCouponResult =
	| { status: 'success'; assets: UIDAssetsResult; clearClaimSucceededId?: boolean }
	| { status: 'needs_pay_qr'; surrender: OpenContainerSurrenderPrep }
	| { status: 'error'; message: string }

function optPayloadString(v: unknown): string {
	if (v == null) return ''
	if (typeof v === 'string') return v
	if (typeof v === 'number' && Number.isFinite(v)) return String(v)
	return String(v)
}

function normalizeAddress(v: string): string {
	return v.trim().toLowerCase()
}

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

/** Legacy card: OpenContainer transfer coupon from customer AA → merchant owner AA. */
export async function completeCouponSurrenderViaOpenContainer(params: {
	assets: UIDAssetsResult
	coupon: MerchantCouponBalanceItem
	surrender: OpenContainerSurrenderPrep
	openContainerPayload: Record<string, unknown>
	posOperator: string
	merchantInfraCard: string
	claimSucceededId?: string | null
}): Promise<ConsumeMerchantCouponResult> {
	const { assets, coupon, surrender, openContainerPayload, posOperator, merchantInfraCard, claimSucceededId } =
		params
	const cardAddress = surrender.cardAddress.trim()
	const selected = await selectOpenContainerPayloadForMerchantCard(openContainerPayload, cardAddress)
	if (selected.error) {
		return { status: 'error', message: selected.error }
	}
	const payload: Record<string, unknown> = { ...selected.payload }
	const account = optPayloadString(payload.account).trim()
	if (!account) {
		return { status: 'error', message: 'Invalid payment code.' }
	}
	if (normalizeAddress(account) !== normalizeAddress(surrender.userAccount)) {
		return {
			status: 'error',
			message: 'Pay QR wallet does not match the coupon holder. Ask the customer to open Pay on the same wallet.',
		}
	}

	payload.items = [
		{
			kind: 1,
			asset: cardAddress,
			tokenId: surrender.tokenId,
			amount: surrender.amount,
			data: '0x',
		},
	]
	payload.maxAmount = '0'
	if (payload.deadline == null && payload.validBefore != null) {
		payload.deadline = payload.validBefore
	}
	payload.to = posOperator.trim()

	const cardCurrency =
		assets.cards?.find((c) => normalizeAddress(c.cardAddress ?? '') === normalizeAddress(cardAddress))?.cardCurrency?.trim() ||
		'USD'

	const pay = await postAAtoEOA({
		openContainerPayload: payload,
		currency: cardCurrency,
		currencyAmount: '0.00',
		merchantInfraCard: merchantInfraCard.trim() || cardAddress,
		posOperator,
		forText: 'POS coupon surrender',
		couponOpenContainerSurrender: true,
		couponBurnUserEOA: surrender.userEOA,
	})
	if (!pay?.success) {
		return { status: 'error', message: pay?.error ?? 'Coupon surrender failed.' }
	}

	const rowId = merchantCouponRowId(coupon.cardAddress, coupon.tokenId)
	const nextAssets = applyConsumeSuccessToAssets(assets, coupon)
	return {
		status: 'success',
		assets: nextAssets,
		clearClaimSucceededId: claimSucceededId === rowId,
	}
}

/** Full POS consume flow: prepare → burn OR openContainer surrender (reuse entry offline QR when present). */
export async function consumeMerchantCouponFromRead(params: {
	assets: UIDAssetsResult
	coupon: MerchantCouponBalanceItem
	signerEOA?: string | null
	claimSucceededId?: string | null
	storedOfflineContainerPayload?: Record<string, unknown> | null
	posOperator?: string | null
	merchantInfraCard?: string | null
}): Promise<ConsumeMerchantCouponResult> {
	const {
		assets,
		coupon,
		signerEOA,
		claimSucceededId,
		storedOfflineContainerPayload,
		posOperator,
		merchantInfraCard,
	} = params
	const user = readBalanceClaimUserEoa(assets)
	if (!isPlausibleEvmAddress(user)) {
		return { status: 'error', message: 'Invalid user account for consume.' }
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
	if (!prep.success) {
		return { status: 'error', message: prep.error ?? 'Consume prepare failed.' }
	}

	if (prep.useOpenContainerSurrender) {
		const userAccount = prep.userAccount?.trim()
		const tokenId = prep.tokenId?.trim()
		const amount = prep.amount?.trim() || '1'
		const cardAddress = prep.cardAddress?.trim() || coupon.cardAddress
		if (!userAccount || !tokenId) {
			return { status: 'error', message: 'Consume prepare missing surrender fields.' }
		}
		const surrender: OpenContainerSurrenderPrep = {
			cardAddress,
			couponId: coupon.couponId,
			userEOA: user,
			userAccount,
			tokenId,
			amount,
		}
		if (storedOfflineContainerPayload && posOperator?.trim()) {
			return completeCouponSurrenderViaOpenContainer({
				assets,
				coupon,
				surrender,
				openContainerPayload: storedOfflineContainerPayload,
				posOperator: posOperator.trim(),
				merchantInfraCard: merchantInfraCard?.trim() || cardAddress,
				claimSucceededId,
			})
		}
		return {
			status: 'needs_pay_qr',
			surrender,
		}
	}

	if (!prep.cardAddress || !prep.data || !prep.deadline || !prep.nonce) {
		return { status: 'error', message: prep.error ?? 'Consume prepare failed.' }
	}

	const pk = await getPosPrivateKeyHex()
	if (!pk) {
		return { status: 'error', message: 'Merchant signature wallet is unavailable.' }
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
