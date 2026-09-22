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

function optString(v: unknown): string {
	if (v == null) return ''
	if (typeof v === 'string') return v
	if (typeof v === 'number' && Number.isFinite(v)) return String(v)
	return String(v)
}

/** Rebuild the already-signed Scan to Pay container with a single Reward PT item. Signature fields stay. */
function buildRewardPtClaimPayloadFromOpenRelay(params: {
	base: Record<string, unknown>
	to: string
	cardAddress: string
	amount: string
}): { payload: Record<string, unknown> } | { error: string } {
	const account = optString(params.base.account).trim()
	const signature = optString(params.base.signature).trim()
	const nonce = optString(params.base.nonce).trim()
	const deadline = optString(params.base.deadline ?? params.base.validBefore).trim()
	if (!isPlausibleEvmAddress(account) || !signature || !nonce || !deadline) {
		return { error: 'Scan to Pay signature is incomplete. Ask the customer to show a fresh payment QR.' }
	}
	const deadlineSec = Number(deadline)
	if (!Number.isFinite(deadlineSec) || deadlineSec <= Math.floor(Date.now() / 1000)) {
		return { error: 'Scan to Pay signature expired. Ask the customer to show a fresh payment QR.' }
	}
	const currencyTypeRaw = params.base.currencyType
	const currencyType =
		typeof currencyTypeRaw === 'number' && Number.isFinite(currencyTypeRaw)
			? currencyTypeRaw
			: Number(optString(currencyTypeRaw)) || 4
	const maxAmount = optString(params.base.maxAmount).trim() || '0'
	try {
		if (BigInt(maxAmount) !== 0n) {
			return { error: 'This payment QR cannot authorize Reward PT. Ask the customer to show a Scan to Pay QR.' }
		}
	} catch {
		return { error: 'This payment QR cannot authorize Reward PT. Ask the customer to show a Scan to Pay QR.' }
	}
	return {
		payload: {
			account,
			to: params.to,
			items: [
				{
					kind: 1,
					asset: params.cardAddress,
					tokenId: '13',
					amount: params.amount,
					data: '0x',
				},
			],
			currencyType,
			maxAmount,
			nonce,
			deadline,
			signature,
		},
	}
}

function applyRewardPtDebitToAssets(
	assets: UIDAssetsResult,
	cardAddress: string,
	amountRaw: string | undefined,
): UIDAssetsResult {
	const raw = amountRaw?.trim()
	if (!raw) return assets
	let amount: bigint
	try {
		amount = BigInt(raw)
	} catch {
		return assets
	}
	if (amount <= 0n || !assets.cards?.length) return assets
	const cardLower = cardAddress.trim().toLowerCase()
	const cards = assets.cards.map((card) => {
		if (card.cardAddress.trim().toLowerCase() !== cardLower) return card
		const balanceRaw = card.chargeRewardPoints6?.trim()
		if (!balanceRaw) return card
		let balance: bigint
		try {
			balance = BigInt(balanceRaw)
		} catch {
			return card
		}
		const next = balance > amount ? balance - amount : 0n
		return { ...card, chargeRewardPoints6: next.toString() }
	})
	return { ...assets, cards }
}

export type ClaimMerchantCouponResult =
	| { status: 'success'; assets: UIDAssetsResult }
	| { status: 'error'; message: string }

/** Full POS claim flow: NFC → server; QR/wallet → prepare → sign → submit. */
export async function claimMerchantCouponFromRead(params: {
	assets: UIDAssetsResult
	coupon: MerchantClaimableCouponItem
	signerEOA?: string | null
	openContainerPayload?: Record<string, unknown>
}): Promise<ClaimMerchantCouponResult> {
	const { assets, coupon, signerEOA, openContainerPayload } = params
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
		const patched = applyRewardPtDebitToAssets(
			applyClaimSuccessToAssets(assets, coupon),
			coupon.cardAddress,
			result.rewardPtAmount,
		)
		return { status: 'success', assets: patched }
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

	let rewardPtOpenContainer: Record<string, unknown> | undefined
	if (prep.rewardPtAmount?.trim()) {
		if (!openContainerPayload) {
			return {
				status: 'error',
				message: 'Scan to Pay signature is required to claim this Reward PT coupon.',
			}
		}
		const built = buildRewardPtClaimPayloadFromOpenRelay({
			base: openContainerPayload,
			to: signerEOA!,
			cardAddress: prep.cardAddress,
			amount: prep.rewardPtAmount.trim(),
		})
		if ('error' in built) return { status: 'error', message: built.error }
		rewardPtOpenContainer = built.payload
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
		couponId: prep.couponId ?? coupon.couponId,
		data: prep.data,
		deadline: prep.deadline,
		nonce: prep.nonce,
		adminSignature,
		signerEOA: signerEOA ?? undefined,
		rewardPtOpenContainer,
	})
	if (!submit) {
		return { status: 'error', message: 'Coupon claim failed.' }
	}
	if (!submit.success) {
		return { status: 'error', message: submit.error ?? 'Coupon claim failed.' }
	}

	const patched = applyRewardPtDebitToAssets(
		applyClaimSuccessToAssets(assets, coupon),
		coupon.cardAddress,
		prep.rewardPtAmount,
	)
	return { status: 'success', assets: patched }
}
