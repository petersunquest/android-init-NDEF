import {
	cardCouponPosConsumeNfcSign,
	cardCouponPosConsumePrepare,
	cardCouponPosConsumeSubmit,
	postAAtoEOACouponSurrender,
} from '@/api/beamioApi'
import type { MerchantCouponBalanceItem, UIDAssetsResult } from '@/types/pos'
import { getPosPrivateKeyHex } from '@/wallet/getPosPrivateKeyHex'
import { signExecuteForAdmin } from '@/wallet/signExecuteForAdmin'
import { isPlausibleEvmAddress } from '@/utils/evmAddress'
import { merchantCouponRowId, readBalanceClaimUserEoa } from '@/utils/readBalanceCouponClaim'
import type { CheckBalanceNfcScanContext } from '@/utils/checkBalanceFlow'

export type ConsumeMerchantCouponResult =
	| { status: 'success'; assets: UIDAssetsResult; clearClaimSucceededId?: boolean }
	| { status: 'error'; message: string }

function optString(v: unknown): string {
	if (v == null) return ''
	if (typeof v === 'string') return v
	if (typeof v === 'number' && Number.isFinite(v)) return String(v)
	return String(v)
}

/** Build OpenContainer coupon transfer payload from a Scan-to-Pay open-relay signature. */
function buildSurrenderPayloadFromOpenRelay(params: {
	base: Record<string, unknown>
	to: string
	cardAddress: string
	tokenId: string
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
	return {
		payload: {
			account,
			to: params.to,
			items: [
				{
					kind: 1,
					asset: params.cardAddress,
					tokenId: params.tokenId,
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

/**
 * Full POS consume flow:
 * - New cards: prepare → sign ExecuteForAdmin burn → submit
 * - Legacy cards: OpenContainer transfer coupon to POS/admin/owner (NFC hosted key or Scan-to-Pay QR)
 */
export async function consumeMerchantCouponFromRead(params: {
	assets: UIDAssetsResult
	coupon: MerchantCouponBalanceItem
	signerEOA?: string | null
	claimSucceededId?: string | null
	nfcScan?: CheckBalanceNfcScanContext
	/** Scan-to-Pay open-relay payload retained from Check Balance QR. */
	openContainerPayload?: Record<string, unknown> | null
}): Promise<ConsumeMerchantCouponResult> {
	const { assets, coupon, signerEOA, claimSucceededId, nfcScan, openContainerPayload } = params
	const user = readBalanceClaimUserEoa(assets)
	if (!isPlausibleEvmAddress(user)) {
		return { status: 'error', message: 'Invalid user account for consume.' }
	}

	const posOperator = signerEOA?.trim()
	if (!isPlausibleEvmAddress(posOperator)) {
		return { status: 'error', message: 'Terminal wallet is required to redeem this coupon.' }
	}

	const prep = await cardCouponPosConsumePrepare({
		cardAddress: coupon.cardAddress,
		couponId: coupon.couponId,
		userEOA: user,
		signerEOA: posOperator,
		posOperator,
		tokenId: coupon.tokenId,
		amount: '1',
	})
	if (!prep) {
		return { status: 'error', message: 'Consume prepare failed.' }
	}
	if (!prep.success) {
		return {
			status: 'error',
			message: prep.error || prep.message || 'Consume prepare failed.',
		}
	}

	const isLegacyTransfer =
		prep.mode === 'transfer' || prep.useOpenContainerSurrender || prep.requiresCustomerAuth

	if (isLegacyTransfer) {
		const transferTo: string =
			(isPlausibleEvmAddress(prep.transferRecipient) ? prep.transferRecipient! : null) ||
			posOperator!
		const uid = (nfcScan?.uid || assets.uid || '').trim()
		const tagIdHex = (assets.tagIdHex || '').trim()
		let payload: Record<string, unknown> | null = null

		if (uid || tagIdHex) {
			const signed = await cardCouponPosConsumeNfcSign({
				cardAddress: coupon.cardAddress,
				couponId: coupon.couponId,
				userEOA: user,
				posOperator: transferTo,
				signerEOA: posOperator,
				uid: uid || undefined,
				tagIdHex: tagIdHex || undefined,
				tokenId: coupon.tokenId,
				amount: prep.amount || '1',
			})
			if (!signed?.success || !signed.openContainerPayload) {
				return {
					status: 'error',
					message:
						signed?.error ||
						'Could not sign coupon transfer with NFC session. Try Check Balance with NFC again.',
				}
			}
			payload = signed.openContainerPayload
		} else if (openContainerPayload) {
			const built = buildSurrenderPayloadFromOpenRelay({
				base: openContainerPayload,
				to: transferTo,
				cardAddress: coupon.cardAddress,
				tokenId: coupon.tokenId,
				amount: prep.amount || '1',
			})
			if ('error' in built) {
				return { status: 'error', message: built.error }
			}
			payload = built.payload
		} else {
			return {
				status: 'error',
				message:
					'This program card transfers coupons on redeem (no on-chain burn). Scan the customer NFC card, or a fresh Scan to Pay QR, then redeem again.',
			}
		}

		const relay = await postAAtoEOACouponSurrender({
			openContainerPayload: payload,
			merchantCardAddress: coupon.cardAddress,
			posOperator: transferTo,
			couponBurnUserEOA: user,
		})
		if (!relay) {
			return { status: 'error', message: 'Coupon transfer failed.' }
		}
		if (!relay.success) {
			return { status: 'error', message: relay.error ?? 'Coupon transfer failed.' }
		}

		const rowId = merchantCouponRowId(coupon.cardAddress, coupon.tokenId)
		return {
			status: 'success',
			assets: applyConsumeSuccessToAssets(assets, coupon),
			clearClaimSucceededId: claimSucceededId === rowId,
		}
	}

	if (
		!prep.cardAddress ||
		!prep.data ||
		!prep.deadline ||
		!prep.nonce
	) {
		return {
			status: 'error',
			message: prep.error || prep.message || 'Consume prepare failed.',
		}
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
		signerEOA: posOperator,
	})
	if (!submit) {
		return { status: 'error', message: 'Coupon consume failed.' }
	}
	if (!submit.success) {
		return { status: 'error', message: submit.error ?? 'Coupon consume failed.' }
	}

	const rowId = merchantCouponRowId(coupon.cardAddress, coupon.tokenId)
	return {
		status: 'success',
		assets: applyConsumeSuccessToAssets(assets, coupon),
		clearClaimSucceededId: claimSucceededId === rowId,
	}
}
