import {
	burnChargeRewardByAdminPrepare,
	fetchUIDAssets,
	fetchWalletAssetsForRead,
	formatNfcTopupAdminError,
	nfcTopupSubmit,
} from '@/api/beamioApi'
import type { UIDAssetsResult } from '@/types/pos'
import { currencyToFiat6 } from '@/utils/beamioPaymentRouting'
import { formatPosAssetsQueryError } from '@/utils/formatPosAssetsQueryError'
import { isNfcUid14Hex, normalizeNfcUid14 } from '@/utils/nfcUid'
import { readBalancePrimaryCard } from '@/utils/readBalanceAssets'
import { buildSuccessPassHeroProps, type PosSuccessPassHeroProps } from '@/utils/posSuccessHero'
import { getPosPrivateKeyHex, getPosSigningWalletAddress } from '@/wallet/getPosPrivateKeyHex'
import { signExecuteForAdmin } from '@/wallet/signExecuteForAdmin'

export type DeductExecuteProgressPhase = 'preparing' | 'signing'

export type DeductExecuteProgress = (phase: DeductExecuteProgressPhase) => void

export interface DeductCustomerTarget {
	beamioTag?: string
	wallet?: string
	uid?: string
	sun?: { e: string; c: string; m: string }
}

export interface DeductExecuteSuccess {
	amount: string
	txHash?: string
	postPointBalance6: string
	patchedAssets: UIDAssetsResult
	passHero: PosSuccessPassHeroProps
	customerBeamioTag?: string
	settlementViaQr?: boolean
}

export type DeductExecuteResult =
	| { status: 'success'; result: DeductExecuteSuccess }
	| { status: 'error'; message: string }

export function parseDeductKeypadAmount6(keypadAmount: string): string | null {
	const raw = keypadAmount.trim().replace(/,/g, '')
	const v = Number(raw)
	if (!Number.isFinite(v) || v <= 0) return null
	return currencyToFiat6(v)
}

/** Charge-reward pts (token #2) on merchant program card — same source as Check Balance hero. */
export function deductChargeRewardPoints6(
	assets: UIDAssetsResult,
	merchantInfraCard: string,
): bigint {
	return infraCardChargeRewardPoints6(assets, merchantInfraCard)
}

export function isDeductKeypadWithinBalance(
	keypadAmount: string,
	maxPoints6: bigint,
): boolean {
	const amt6 = parseDeductKeypadAmount6(keypadAmount)
	if (!amt6) return false
	try {
		return BigInt(amt6) <= maxPoints6
	} catch {
		return false
	}
}

function deductPointsAmount6(keypadAmount: string): string | null {
	return parseDeductKeypadAmount6(keypadAmount)
}

function infraCardChargeRewardPoints6(
	assets: UIDAssetsResult,
	merchantInfraCard: string,
): bigint {
	const infra = merchantInfraCard.trim().toLowerCase()
	if (!infra) return 0n
	const card = assets.cards?.find(
		(c) => c.cardAddress.trim().toLowerCase() === infra,
	)
	const raw = card?.chargeRewardPoints6?.trim() ?? assets.chargeRewardPoints6?.trim() ?? '0'
	try {
		return BigInt(raw)
	} catch {
		return 0n
	}
}

function assetsWithPostPointBalance(
	assets: UIDAssetsResult,
	merchantInfraCard: string,
	post6: bigint,
): UIDAssetsResult {
	const infra = merchantInfraCard.trim().toLowerCase()
	if (!infra) return assets
	const postStr = post6.toString()
	const cards = assets.cards?.map((c) => {
		if (c.cardAddress.trim().toLowerCase() !== infra) return c
		return {
			...c,
			chargeRewardPoints6: postStr,
		}
	})
	return {
		...assets,
		chargeRewardPoints6: postStr,
		cards,
	}
}

async function loadCustomerAssets(
	target: DeductCustomerTarget,
	merchantInfraCard: string,
): Promise<UIDAssetsResult | null> {
	if (target.beamioTag?.trim()) {
		return fetchUIDAssets({
			uid: target.beamioTag.trim(),
			merchantInfraCard,
		})
	}
	if (target.uid?.trim()) {
		return fetchUIDAssets({
			uid: target.uid.trim(),
			merchantInfraCard,
			sun: target.sun,
		})
	}
	if (target.wallet?.trim()) {
		return fetchWalletAssetsForRead({
			wallet: target.wallet.trim(),
			merchantInfraCard,
		})
	}
	return null
}

export type NfcScanContext = {
	uid: string
	sun: { e: string; c: string; m: string }
}

/** Build deduct target from Check Balance assets; never treat @beamioTag as NFC uid. */
export function deductCustomerTargetFromAssets(
	assets: UIDAssetsResult,
	nfcScan?: NfcScanContext,
): DeductCustomerTarget {
	const wallet = assets.address?.trim()
	const walletOk = wallet?.startsWith('0x') && wallet.length >= 10 ? wallet : undefined
	const tagRaw = assets.beamioTag?.trim() ?? ''
	const tag = tagRaw.startsWith('@') ? tagRaw.slice(1) : tagRaw
	const tagOk = tag && !tag.startsWith('0x') ? tag : undefined

	if (nfcScan?.uid && nfcScan.sun) {
		return {
			uid: normalizeNfcUid14(nfcScan.uid),
			sun: nfcScan.sun,
			wallet: walletOk,
			beamioTag: tagOk,
		}
	}

	const uidRaw = assets.uid?.trim() || assets.tagIdHex?.trim()
	const uid =
		uidRaw && isNfcUid14Hex(uidRaw) ? normalizeNfcUid14(uidRaw) : undefined

	if (tagOk) {
		return { beamioTag: tagOk, uid, wallet: walletOk }
	}
	if (uid) return { uid, wallet: walletOk }
	if (walletOk) return { wallet: walletOk }
	return {}
}

/**
 * `/api/nfcTopup` identity: valid NFC uid+SUN, or wallet-only (Check Balance / QR).
 * Must not pass beamioTag as uid (causes "NFC UID request" errors).
 */
export function resolveNfcTopupSubmitIdentity(target: DeductCustomerTarget): {
	uid?: string
	wallet?: string
	sun?: DeductCustomerTarget['sun']
} {
	const wallet =
		target.wallet?.trim().startsWith('0x') && target.wallet.trim().length >= 10
			? target.wallet.trim()
			: undefined
	const uid = isNfcUid14Hex(target.uid) ? normalizeNfcUid14(target.uid!) : undefined
	const sun = target.sun

	if (uid && sun) {
		return { uid, wallet, sun }
	}
	if (wallet) {
		return { wallet }
	}
	return {}
}

/** iOS `POSViewModel.runDeductPoints`. */
export async function executeDeductPoints(params: {
	target: DeductCustomerTarget
	keypadAmount: string
	merchantInfraCard: string
	pointSystemEnabled: boolean
	viaQr?: boolean
	preloadedAssets?: UIDAssetsResult
	onProgress?: DeductExecuteProgress
}): Promise<DeductExecuteResult> {
	const onProgress = params.onProgress
	const infra = params.merchantInfraCard.trim()
	if (!infra.startsWith('0x')) {
		return { status: 'error', message: 'Merchant program card is unavailable.' }
	}
	const points6Str = deductPointsAmount6(params.keypadAmount)
	if (!points6Str || BigInt(points6Str) <= 0n) {
		return { status: 'error', message: 'Enter a valid point amount.' }
	}
	const deduct6 = BigInt(points6Str)

	onProgress?.('preparing')
	const pk = await getPosPrivateKeyHex()
	if (!pk) {
		return { status: 'error', message: 'Wallet not initialized.' }
	}

	const assets =
		params.preloadedAssets?.ok === true
			? params.preloadedAssets
			: await loadCustomerAssets(params.target, infra)
	if (!assets?.ok) {
		return { status: 'error', message: formatPosAssetsQueryError(assets?.error) }
	}

	const balance6 = infraCardChargeRewardPoints6(assets, infra)
	if (balance6 <= 0n) {
		return { status: 'error', message: 'Customer has no point balance.' }
	}
	if (deduct6 > balance6) {
		return { status: 'error', message: 'Insufficient point balance.' }
	}

	const target =
		assets.aaAddress?.trim() ||
		assets.address?.trim() ||
		''
	if (!target.startsWith('0x') || target.length < 10) {
		return { status: 'error', message: 'Customer account is unavailable.' }
	}

	const prep = await burnChargeRewardByAdminPrepare({
		cardAddress: infra,
		target,
		amount: points6Str,
	})
	if (!prep?.success || !prep.cardAddr || !prep.data || !prep.deadline || !prep.nonce) {
		return { status: 'error', message: prep?.error ?? 'Deduct prepare failed.' }
	}

	onProgress?.('signing')
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
			status: 'error',
			message: e instanceof Error ? e.message : 'Merchant signature failed.',
		}
	}

	const submitIdentity = resolveNfcTopupSubmitIdentity(params.target)
	if (!submitIdentity.uid && !submitIdentity.wallet) {
		return { status: 'error', message: 'Customer account is unavailable.' }
	}

	const signerEOA = (await getPosSigningWalletAddress()) ?? undefined
	const pay = await nfcTopupSubmit({
		uid: submitIdentity.uid,
		wallet: submitIdentity.wallet,
		cardAddr: prep.cardAddr,
		data: prep.data,
		deadline: prep.deadline,
		nonce: prep.nonce,
		adminSignature,
		signerEOA,
		sun: submitIdentity.sun,
	})
	if (!pay) {
		return { status: 'error', message: 'Deduct points failed.' }
	}
	if (!pay.success) {
		return { status: 'error', message: formatNfcTopupAdminError(pay) }
	}

	const post6 = balance6 > deduct6 ? balance6 - deduct6 : 0n
	const patchedAssets = assetsWithPostPointBalance(assets, infra, post6)
	const primary = readBalancePrimaryCard(patchedAssets, infra)
	const passHero = buildSuccessPassHeroProps({
		assets: patchedAssets,
		merchantInfraCard: infra,
		pointSystemEnabled: params.pointSystemEnabled,
		customerBeamioTag: assets.beamioTag,
		customerWalletAddress: assets.address,
		balanceAmount: Number(primary?.points ?? assets.points ?? '0') || undefined,
		balanceCurrency: primary?.cardCurrency ?? assets.cardCurrency,
	})

	return {
		status: 'success',
		result: {
			amount: params.keypadAmount,
			txHash: pay.txHash,
			postPointBalance6: post6.toString(),
			patchedAssets,
			passHero,
			customerBeamioTag: assets.beamioTag?.trim() || undefined,
			settlementViaQr: params.viaQr,
		},
	}
}
