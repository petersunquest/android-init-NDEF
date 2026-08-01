import {
	fetchUsdcChargeSession,
	submitUsdcChargeTopupAuth,
	type UsdcChargeSessionResult,
} from '@/api/beamioApi'
import type { NfcTopupCurrencySplit } from '@/utils/topupCurrencySplit'
import { getPosPrivateKeyHex } from '@/wallet/getPosPrivateKeyHex'
import { signExecuteForAdmin } from '@/wallet/signExecuteForAdmin'
import {
	paymentTokenQueryValue,
	stablecoinSymbolForMethod,
	type TopupPaymentMethodRaw,
} from '@/utils/topupPaymentMethod'

const POLL_INTERVAL_MS = 2500
const MAX_TICKS = 600

export function buildUsdcTopupQrUrlPhase1(params: {
	cardAddress: string
	cardOwner: string
	amount: string
	currency: string
	sid: string
	pos: string
	paymentMethodRaw: TopupPaymentMethodRaw
}): string {
	const url = new URL('https://verra.network/usdc-topup')
	url.searchParams.set('card', params.cardAddress)
	url.searchParams.set('owner', params.cardOwner)
	url.searchParams.set('amount', params.amount)
	url.searchParams.set('currency', params.currency.toUpperCase())
	url.searchParams.set('sid', params.sid)
	url.searchParams.set('pos', params.pos)
	const token = paymentTokenQueryValue(params.paymentMethodRaw)
	if (token) url.searchParams.set('paymentToken', token)
	return url.toString()
}

export function buildUsdcTopupQrUrlWithNfc(params: {
	cardAddress: string
	cardOwner: string
	uid: string
	sun: { e: string; c: string; m: string }
	amount: string
	currency: string
	sid: string
	pos: string
	paymentMethodRaw: TopupPaymentMethodRaw
}): string {
	const url = new URL('https://verra.network/usdc-topup')
	url.searchParams.set('card', params.cardAddress)
	url.searchParams.set('owner', params.cardOwner)
	url.searchParams.set('uid', params.uid)
	url.searchParams.set('e', params.sun.e)
	url.searchParams.set('c', params.sun.c)
	url.searchParams.set('m', params.sun.m)
	url.searchParams.set('amount', params.amount)
	url.searchParams.set('currency', params.currency.toUpperCase())
	url.searchParams.set('sid', params.sid)
	url.searchParams.set('pos', params.pos)
	const token = paymentTokenQueryValue(params.paymentMethodRaw)
	if (token) url.searchParams.set('paymentToken', token)
	return url.toString()
}

function progressLabelForState(state: string): string {
	switch (state) {
		case 'verifying':
			return 'Verifying payment…'
		case 'settling':
			return 'Settling USDC…'
		case 'awaiting_topup_auth':
			return 'Authorizing top-up…'
		case 'awaiting_beneficiary':
			return 'USDC received — ask customer to tap card…'
		case 'topup_pending':
			return 'Crediting card…'
		case 'topup_confirmed':
		case 'charge_pending':
			return 'Finalizing…'
		default:
			return ''
	}
}

export type UsdcTopupPollOutcome =
	| { status: 'success'; txHash?: string }
	| { status: 'awaiting_beneficiary'; qrBeneficiary?: { beamioTag?: string; wallet?: string } }
	| { status: 'error'; message: string }
	| { status: 'timeout' }

export async function pollUsdcTopupSession(params: {
	sid: string
	onProgress?: (label: string) => void
	signal?: AbortSignal
}): Promise<UsdcTopupPollOutcome> {
	const submittedAuth = new Set<string>()
	let ticks = 0

	const sleep = (ms: number) =>
		new Promise<void>((resolve, reject) => {
			const t = setTimeout(resolve, ms)
			params.signal?.addEventListener('abort', () => {
				clearTimeout(t)
				reject(new DOMException('Aborted', 'AbortError'))
			})
		})

	try {
		await sleep(POLL_INTERVAL_MS)
	} catch {
		return { status: 'error', message: 'Cancelled' }
	}

	while (ticks < MAX_TICKS) {
		if (params.signal?.aborted) {
			return { status: 'error', message: 'Cancelled' }
		}
		ticks += 1
		const result = await fetchUsdcChargeSession(params.sid)
		if (!result) {
			await sleep(POLL_INTERVAL_MS)
			continue
		}
		await handleAwaitingTopupAuth(result, params.sid, submittedAuth)
		const label = progressLabelForState(result.state)
		if (label) params.onProgress?.(label)

		if (result.state === 'success') {
			return { status: 'success', txHash: result.topupTxHash }
		}
		if (result.state === 'error') {
			return { status: 'error', message: result.error ?? 'USDC top-up failed' }
		}
		if (result.state === 'awaiting_beneficiary') {
			return { status: 'awaiting_beneficiary' }
		}
		await sleep(POLL_INTERVAL_MS)
	}
	return { status: 'timeout' }
}

async function handleAwaitingTopupAuth(
	result: UsdcChargeSessionResult,
	sid: string,
	submittedAuth: Set<string>,
): Promise<void> {
	if (result.state !== 'awaiting_topup_auth') return
	if (submittedAuth.has(sid)) return
	if (
		!result.pendingTopupCardAddr ||
		!result.pendingTopupData ||
		!result.pendingTopupDeadline ||
		!result.pendingTopupNonce
	) {
		return
	}
	const pk = await getPosPrivateKeyHex()
	if (!pk) return
	let signature: string
	try {
		signature = await signExecuteForAdmin({
			privateKeyHex: pk,
			cardAddress: result.pendingTopupCardAddr,
			dataHex: result.pendingTopupData,
			deadline: result.pendingTopupDeadline,
			nonceHex: result.pendingTopupNonce,
			factoryGateway: result.pendingTopupVerifyingContract,
		})
	} catch {
		return
	}
	const submit = await submitUsdcChargeTopupAuth(sid, signature)
	if (submit?.ok) {
		submittedAuth.add(sid)
	}
}

export function usdcTopupCustomerHint(
	methodRaw: TopupPaymentMethodRaw,
	hasQrBeneficiary: boolean,
): string {
	const token = stablecoinSymbolForMethod(methodRaw)
	if (hasQrBeneficiary) {
		return `Customer scans this QR to pay with ${token}. Points credit automatically after payment.`
	}
	return `Customer scans this QR to pay with ${token}. If prompted after payment, ask them to tap their Beamio NFC card.`
}

export function newTopupUsdcSessionId(): string {
	if (typeof crypto !== 'undefined' && crypto.randomUUID) {
		return crypto.randomUUID().toLowerCase()
	}
	return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
		const r = (Math.random() * 16) | 0
		const v = c === 'x' ? r : (r & 0x3) | 0x8
		return v.toString(16)
	})
}

export type UsdcTopupSessionContext = {
	sid: string
	deepLink: string
	apiAmount: string
	currency: string
	currencySplit: NfcTopupCurrencySplit | null
	qrBeneficiaryBeamioTag?: string
	qrBeneficiaryWallet?: string
}
