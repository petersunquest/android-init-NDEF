import {
	fetchCardCurrencyCode,
	fetchUIDAssets,
	fetchWalletAssetsForRead,
	nfcTopupPrepare,
	nfcTopupSubmit,
} from '@/api/beamioApi'
import type { NfcTopupCurrencySplit } from '@/utils/topupCurrencySplit'
import { memberNoFromCard } from '@/utils/readBalanceAssets'
import {
	buildTopupSuccessPassHero,
	type PosSuccessPassHeroProps,
} from '@/utils/posSuccessHero'
import { getPosPrivateKeyHex } from '@/wallet/getPosPrivateKeyHex'
import { signExecuteForAdmin } from '@/wallet/signExecuteForAdmin'

export type TopupExecuteProgressPhase = 'preparing' | 'signing' | 'refreshing'

export type TopupExecuteProgress = (phase: TopupExecuteProgressPhase) => void

export interface TopupExecuteSuccess {
	amount: string
	txHash?: string
	preBalance: string
	postBalance: string
	cardCurrency: string
	memberNo?: string
	customerBeamioTag?: string
	address?: string
	settlementViaQr?: boolean
	passHero?: PosSuccessPassHeroProps
}

export type TopupExecuteResult =
	| { status: 'success'; result: TopupExecuteSuccess }
	| { status: 'error'; message: string }

export interface TopupCustomerTarget {
	beamioTag?: string
	wallet?: string
	uid?: string
	sun?: { e: string; c: string; m: string }
}

async function sleepMs(ms: number): Promise<void> {
	await new Promise((r) => setTimeout(r, ms))
}

function cardFromAssets(
	assets: { cards?: Array<{ cardAddress?: string; points?: string; cardCurrency?: string; memberNo?: string }>; points?: string; cardCurrency?: string; beamioTag?: string },
	cardAddr: string,
) {
	const card = assets.cards?.find(
		(c) => c.cardAddress?.toLowerCase() === cardAddr.toLowerCase(),
	)
	return {
		points: card?.points ?? assets.points ?? '0',
		currency: card?.cardCurrency ?? assets.cardCurrency ?? 'CAD',
		memberNo: card?.memberNo,
		tag: assets.beamioTag,
	}
}

async function submitPreparedTopup(params: {
	target: TopupCustomerTarget
	cardAddr: string
	data: string
	deadline: number
	nonce: string
	factoryGateway?: string
	currencySplit: NfcTopupCurrencySplit | null
	infraCard: string
	currency: string
	preBalance: string
	preCurrency: string
	preMemberNo?: string
	preTag?: string
	usdcTopupSessionId?: string
	pointSystemEnabled?: boolean
	onProgress?: TopupExecuteProgress
}): Promise<TopupExecuteResult> {
	const onProgress = params.onProgress
	const pk = await getPosPrivateKeyHex()
	if (!pk) {
		return { status: 'error', message: 'Wallet not initialized' }
	}
	onProgress?.('signing')
	let signature: string
	try {
		signature = await signExecuteForAdmin({
			privateKeyHex: pk,
			cardAddress: params.cardAddr,
			dataHex: params.data,
			deadline: params.deadline,
			nonceHex: params.nonce,
			factoryGateway: params.factoryGateway,
		})
	} catch (e) {
		return {
			status: 'error',
			message: e instanceof Error ? e.message : 'Failed to sign top-up',
		}
	}
	const pay = await nfcTopupSubmit({
		uid: params.target.uid,
		wallet: params.target.wallet,
		cardAddr: params.cardAddr,
		data: params.data,
		deadline: params.deadline,
		nonce: params.nonce,
		adminSignature: signature,
		sun: params.target.sun,
		currencySplit: params.currencySplit ?? undefined,
		usdcTopupSessionId: params.usdcTopupSessionId,
	})
	if (!pay) {
		return { status: 'error', message: 'Top-up request failed. Check network and try again.' }
	}
	if (!pay.success) {
		return { status: 'error', message: pay.error ?? 'Top-up failed' }
	}

	onProgress?.('refreshing')
	await sleepMs(3000)

	let postBalance = '—'
	let postAssets: Awaited<ReturnType<typeof fetchUIDAssets>> | null = null
	if (params.target.beamioTag || params.target.wallet) {
		postAssets = params.target.beamioTag
			? await fetchUIDAssets({ uid: params.target.beamioTag, merchantInfraCard: params.infraCard })
			: await fetchWalletAssetsForRead({
					wallet: params.target.wallet!,
					merchantInfraCard: params.infraCard,
				})
	} else if (params.target.uid && params.target.sun) {
		postAssets = await fetchUIDAssets({
			uid: params.target.uid,
			merchantInfraCard: params.infraCard,
			sun: params.target.sun,
		})
	}
	if (postAssets?.ok) {
		const c = cardFromAssets(postAssets, params.cardAddr)
		postBalance = c.points
	}

	const passHero = postAssets?.ok
		? buildTopupSuccessPassHero({
				assets: postAssets,
				cardAddr: params.cardAddr,
				merchantInfraCard: params.infraCard,
				pointSystemEnabled: params.pointSystemEnabled ?? false,
				postBalance,
				cardCurrency: params.preCurrency,
				customerBeamioTag: params.preTag?.trim() || postAssets.beamioTag,
				customerAddress: postAssets.address,
			})
		: undefined

	return {
		status: 'success',
		result: {
			amount: params.currencySplit?.currencyAmount ?? '',
			txHash: pay.txHash,
			preBalance: params.preBalance,
			postBalance,
			cardCurrency: params.preCurrency,
			memberNo: params.preMemberNo ?? memberNoFromCard(
				postAssets?.cards?.find(
					(c) =>
						c.cardAddress.trim().toLowerCase() === params.cardAddr.trim().toLowerCase(),
				),
			),
			customerBeamioTag: params.preTag?.trim() || postAssets?.beamioTag || undefined,
			address: postAssets?.address,
			settlementViaQr: Boolean(params.usdcTopupSessionId),
			passHero,
		},
	}
}

/** Execute admin top-up after customer NFC/QR — mirrors iOS `runTopup` (card/cash/bonus path). */
export async function executeNfcTopup(params: {
	target: TopupCustomerTarget
	apiAmount: string
	currencySplit: NfcTopupCurrencySplit | null
	merchantInfraCard: string
	posWallet: string
	usdcTopupSessionId?: string
	pointSystemEnabled?: boolean
	onProgress?: TopupExecuteProgress
}): Promise<TopupExecuteResult> {
	const onProgress = params.onProgress
	const infra = params.merchantInfraCard.trim()
	if (!infra) {
		return { status: 'error', message: 'Terminal program card is not configured.' }
	}
	const currency =
		(await fetchCardCurrencyCode(infra)) ?? 'CAD'

	const prepBody = {
		amount: params.apiAmount,
		currency,
		cardAddress: infra,
		beamioTag: params.target.beamioTag,
		wallet: params.target.wallet,
		uid: params.target.uid,
		sun: params.target.sun,
	}

	onProgress?.('preparing')
	let prep = await nfcTopupPrepare(prepBody)
	if (prep?.error && params.target.wallet) {
		prep = await nfcTopupPrepare(prepBody)
	}
	if (!prep || prep.error) {
		return { status: 'error', message: prep?.error ?? 'Prepare failed' }
	}
	if (!prep.cardAddr || !prep.data || !prep.deadline || !prep.nonce) {
		return { status: 'error', message: 'Prepare failed' }
	}

	let preBalance = '0'
	let preCurrency = currency
	let preMemberNo: string | undefined
	let preTag: string | undefined
	let resolvedWallet = params.target.wallet

	if (params.target.beamioTag) {
		const assets = await fetchUIDAssets({ uid: params.target.beamioTag, merchantInfraCard: infra })
		if (!assets?.ok) {
			return { status: 'error', message: assets?.error ?? 'Query failed' }
		}
		const c = cardFromAssets(assets, prep.cardAddr)
		preBalance = c.points
		preCurrency = c.currency
		preMemberNo = c.memberNo
		preTag = c.tag
		resolvedWallet = prep.wallet ?? resolvedWallet
	} else if (params.target.wallet) {
		const assets = await fetchWalletAssetsForRead({
			wallet: params.target.wallet,
			merchantInfraCard: infra,
		})
		if (!assets?.ok) {
			return { status: 'error', message: assets?.error ?? 'Query failed' }
		}
		const c = cardFromAssets(assets, prep.cardAddr)
		preBalance = c.points
		preCurrency = c.currency
		preMemberNo = c.memberNo
		preTag = c.tag
	} else if (params.target.uid && params.target.sun) {
		const assets = await fetchUIDAssets({
			uid: params.target.uid,
			merchantInfraCard: infra,
			sun: params.target.sun,
		})
		if (!assets?.ok) {
			return { status: 'error', message: assets?.error ?? 'Query failed' }
		}
		const c = cardFromAssets(assets, prep.cardAddr)
		preBalance = c.points
		preCurrency = c.currency
		preMemberNo = c.memberNo
		preTag = c.tag
	} else {
		return { status: 'error', message: 'Cannot read customer identity.' }
	}

	return submitPreparedTopup({
		target: {
			beamioTag: params.target.beamioTag,
			wallet: resolvedWallet ?? params.target.wallet,
			uid: params.target.uid,
			sun: params.target.sun,
		},
		cardAddr: prep.cardAddr,
		data: prep.data,
		deadline: prep.deadline,
		nonce: prep.nonce,
		factoryGateway: prep.factoryGateway,
		currencySplit: params.currencySplit,
		infraCard: infra,
		currency,
		preBalance,
		preCurrency,
		preMemberNo,
		preTag,
		usdcTopupSessionId: params.usdcTopupSessionId,
		pointSystemEnabled: params.pointSystemEnabled,
		onProgress,
	})
}
