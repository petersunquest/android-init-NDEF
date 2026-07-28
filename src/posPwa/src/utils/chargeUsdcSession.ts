import {
	fetchUsdcChargePreCheck,
	fetchUsdcChargeSession,
	submitUsdcChargeTopupAuth,
	type UsdcChargeSessionResult,
} from '@/api/beamioApi'
import {
	chargeTipFromRequestAndBps,
	chargeTotalInCurrency,
} from '@/utils/beamioPaymentRouting'
import { fetchChargeTierRoutingDetails } from '@/utils/chargeTierRouting'
import type { ChargePaymentMethodRaw } from '@/utils/chargePaymentMethod'
import { getPosPrivateKeyHex } from '@/wallet/getPosPrivateKeyHex'
import { signExecuteForAdmin } from '@/wallet/signExecuteForAdmin'
import {
	paymentTokenQueryValue,
	stablecoinSymbolForMethod,
} from '@/utils/topupPaymentMethod'

const POLL_INTERVAL_MS = 2500
const MAX_TICKS = 600

export function newChargeUsdcSessionId(): string {
	if (typeof crypto !== 'undefined' && crypto.randomUUID) {
		return crypto.randomUUID().toLowerCase()
	}
	return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
		const r = (Math.random() * 16) | 0
		const v = c === 'x' ? r : (r & 0x3) | 0x8
		return v.toString(16)
	})
}

/** iOS `buildUsdcChargeQrUrlNoNfc` — raw HTTPS for external wallet charge. */
export function buildUsdcChargeQrUrlNoNfc(params: {
	cardAddress: string
	pos: string
	sid: string
	subtotal: number
	discountBps?: number
	taxBps?: number
	tipBps?: number
	paymentMethodRaw: ChargePaymentMethodRaw
}): string {
	const fmt = (n: number) => Math.max(0, n).toFixed(2)
	const url = new URL('https://verra.network/usdc-charge')
	url.searchParams.set('card', params.cardAddress)
	url.searchParams.set('pos', params.pos)
	url.searchParams.set('sid', params.sid)
	url.searchParams.set('subtotal', fmt(params.subtotal))
	if (params.tipBps && params.tipBps > 0) {
		url.searchParams.set('tipBps', String(params.tipBps))
	}
	if (params.taxBps && params.taxBps > 0) {
		url.searchParams.set('taxBps', String(params.taxBps))
	}
	if (params.discountBps && params.discountBps > 0) {
		url.searchParams.set('discountBps', String(params.discountBps))
	}
	const token = paymentTokenQueryValue(params.paymentMethodRaw)
	if (token) url.searchParams.set('paymentToken', token)
	return url.toString()
}

export function usdcChargeCustomerHint(methodRaw: ChargePaymentMethodRaw): string {
	const token = stablecoinSymbolForMethod(methodRaw)
	return `Customer scans this QR to pay with ${token}.`
}

export async function prepareUsdcChargeQr(params: {
	subtotal: number
	tipBps: number
	merchantInfraCard: string
	posWallet: string
	paymentMethodRaw: ChargePaymentMethodRaw
}): Promise<
	| { ok: true; deepLink: string; sid: string; total: number; currency: string; taxBps: number }
	| { ok: false; message: string }
> {
	const infra = params.merchantInfraCard.trim()
	const payee = params.posWallet.trim()
	if (!infra || !payee) {
		return { ok: false, message: 'Terminal not configured.' }
	}
	if (!(params.subtotal > 0)) {
		return { ok: false, message: 'Invalid amount.' }
	}

	const routing = (await fetchChargeTierRoutingDetails(payee, infra)) ?? {
		taxPercent: 0,
		discountByTierKey: {},
	}
	const taxBps = Math.max(0, Math.round(routing.taxPercent * 100))
	const tipAmt = chargeTipFromRequestAndBps(params.subtotal, params.tipBps)
	const total = chargeTotalInCurrency(params.subtotal, routing.taxPercent, 0, tipAmt)
	const subtotalStr = params.subtotal.toFixed(2)

	const pre = await fetchUsdcChargePreCheck({
		cardAddress: infra,
		pos: payee,
		subtotal: subtotalStr,
		tipBps: params.tipBps,
		taxBps,
		discountBps: 0,
	})
	if (pre && !pre.ok) {
		return {
			ok: false,
			message:
				pre.error ??
				'Pre-check failed: card owner B-Unit balance or POS admin quota is insufficient.',
		}
	}

	const sid = newChargeUsdcSessionId()
	const deepLink = buildUsdcChargeQrUrlNoNfc({
		cardAddress: infra,
		pos: payee,
		sid,
		subtotal: params.subtotal,
		taxBps,
		tipBps: params.tipBps,
		paymentMethodRaw: params.paymentMethodRaw,
	})
	return { ok: true, deepLink, sid, total, currency: pre?.cardCurrency ?? 'CAD', taxBps }
}

function progressLabelForState(state: string): string {
	switch (state) {
		case 'verifying':
			return 'Verifying payment…'
		case 'settling':
			return 'Settling USDC…'
		case 'awaiting_topup_auth':
			return 'Authorizing top-up…'
		case 'topup_pending':
		case 'topup_confirmed':
		case 'charge_pending':
			return 'Finalizing charge…'
		default:
			return ''
	}
}

export type UsdcChargePollOutcome =
	| { status: 'success'; txHash?: string; total?: string }
	| { status: 'error'; message: string }
	| { status: 'timeout' }

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
	if (submit?.ok) submittedAuth.add(sid)
}

export async function pollUsdcChargeSession(params: {
	sid: string
	onProgress?: (label: string) => void
	signal?: AbortSignal
}): Promise<UsdcChargePollOutcome> {
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
			return {
				status: 'success',
				txHash: result.chargeTxHash ?? result.topupTxHash,
				total: result.total,
			}
		}
		if (result.state === 'error') {
			return { status: 'error', message: result.error ?? 'USDC charge failed' }
		}
		await sleep(POLL_INTERVAL_MS)
	}
	return { status: 'timeout' }
}
