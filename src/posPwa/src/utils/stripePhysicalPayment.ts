import {
	createMerchantCardStripeTerminalPaymentIntent,
	pollMerchantCardStripePayment,
} from '@/api/beamioApi'
import {
	hasStripePhysicalPaymentBridge,
	listenStripePhysicalPayment,
	newCashTreesScanRequestId,
	startStripePhysicalPayment,
	cancelStripePhysicalPayment,
	type StripePhysicalReaderMode,
} from '@/bridge/cashTreesScanBridge'
import { getPosPrivateKeyHex, getPosSigningWalletAddress } from '@/wallet/getPosPrivateKeyHex'
import {
	signStripeTerminalAuthorization,
	type StripeTerminalAuthorization,
} from '@/utils/stripeTerminalAuthorization'

export type StripePhysicalPaymentResult = {
	paymentIntentId: string
	txHash?: string
}

type StripePhysicalPaymentKind = 'topup' | 'charge'

function wait(ms: number): Promise<void> {
	return new Promise((resolve) => window.setTimeout(resolve, ms))
}

async function waitForFulfillment(paymentIntentId: string): Promise<StripePhysicalPaymentResult> {
	const deadline = Date.now() + 120_000
	let lastError = ''
	while (Date.now() < deadline) {
		const status = await pollMerchantCardStripePayment(paymentIntentId)
		if (status.fulfillmentStatus === 'fulfillment_succeeded') {
			return { paymentIntentId, txHash: status.txHash }
		}
		if (status.fulfillmentStatus === 'fulfillment_failed' || status.status === 'failed') {
			throw new Error(status.error || 'Stripe payment was received, but top-up fulfillment failed.')
		}
		lastError = status.error || ''
		await wait(1_000)
	}
	throw new Error(lastError || 'Stripe payment was received, but top-up confirmation timed out.')
}

async function collectStripePhysicalPayment(params: {
	cardAddress: string
	buyerEoa: string
	amountFiat6: string
	currency: string
	kind: StripePhysicalPaymentKind
	readerMode?: StripePhysicalReaderMode
	onProgress?: (message: string) => void
}): Promise<StripePhysicalPaymentResult> {
	if (!hasStripePhysicalPaymentBridge()) {
		throw new Error('Physical card payments require the Beamio POS app.')
	}
	params.onProgress?.('Preparing secure card payment...')
	const requestId = newCashTreesScanRequestId()
	/* Reuse the same hydrated session signer as Program Card Charge. Never
	 * rehydrate from IndexedDB mid-flow: that can overwrite the active session
	 * with a stale wallet and produce a different POS admin EOA. */
	const privateKeyHex = await getPosPrivateKeyHex()
	const posAdmin = await getPosSigningWalletAddress()
	if (!privateKeyHex || !posAdmin) {
		throw new Error('POS admin wallet is not initialized.')
	}
	const authorization: StripeTerminalAuthorization = {
		cardAddress: params.cardAddress,
		buyerEoa: params.buyerEoa,
		amountFiat6: params.amountFiat6,
		currency: params.currency,
		kind: params.kind,
		businessIdempotencyKey: `pos-terminal:${requestId}`,
		deadline: Math.floor(Date.now() / 1000) + 300,
		nonce: `0x${Array.from(crypto.getRandomValues(new Uint8Array(32)), (b) => b.toString(16).padStart(2, '0')).join('')}`,
	}
	const authorizationSignature = await signStripeTerminalAuthorization(privateKeyHex, authorization)
	const intent = await createMerchantCardStripeTerminalPaymentIntent({
		cardAddress: params.cardAddress,
		buyerEoa: params.buyerEoa,
		amountFiat6: params.amountFiat6,
		currency: params.currency,
		businessIdempotencyKey: authorization.businessIdempotencyKey,
		posAdmin,
		authorizationSignature,
		authorizationDeadline: authorization.deadline,
		authorizationNonce: authorization.nonce,
	})
	if (!intent.locationId) throw new Error('Stripe Terminal location is not configured for this merchant.')
	const detailPromise = new Promise<void>((resolve, reject) => {
		const remove = listenStripePhysicalPayment((detail) => {
			if (detail.requestId !== requestId) return
			remove()
			if (!detail.ok) {
				reject(new Error(detail.error || 'Physical card payment failed.'))
				return
			}
			resolve()
		})
	})
	params.onProgress?.('Present the physical card...')
	startStripePhysicalPayment({
		requestId,
		clientSecret: intent.clientSecret,
		paymentIntentId: intent.paymentIntentId,
		cardAddress: params.cardAddress,
		locationId: intent.locationId,
		buyerEoa: params.buyerEoa,
		amountFiat6: params.amountFiat6,
		currency: params.currency,
		kind: params.kind,
		businessIdempotencyKey: authorization.businessIdempotencyKey,
		posAdmin,
		authorizationSignature,
		authorizationDeadline: authorization.deadline,
		authorizationNonce: authorization.nonce,
		readerMode: params.readerMode ?? 'auto',
	})
	try {
		await detailPromise
		params.onProgress?.(params.kind === 'charge' ? 'Confirming card payment...' : 'Confirming top-up...')
		return await waitForFulfillment(intent.paymentIntentId)
	} catch (error) {
		cancelStripePhysicalPayment(requestId)
		throw error
	}
}

export function collectStripePhysicalTopup(params: Omit<Parameters<typeof collectStripePhysicalPayment>[0], 'kind'>) {
	return collectStripePhysicalPayment({ ...params, kind: 'topup' })
}

export function collectStripePhysicalCharge(params: Omit<Parameters<typeof collectStripePhysicalPayment>[0], 'kind'>) {
	return collectStripePhysicalPayment({ ...params, kind: 'charge' })
}
