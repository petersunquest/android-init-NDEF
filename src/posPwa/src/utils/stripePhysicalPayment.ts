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

export type StripePhysicalPaymentResult = {
	paymentIntentId: string
	txHash?: string
}

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

export async function collectStripePhysicalTopup(params: {
	cardAddress: string
	buyerEoa: string
	amountFiat6: string
	currency: string
	readerMode?: StripePhysicalReaderMode
	onProgress?: (message: string) => void
}): Promise<StripePhysicalPaymentResult> {
	if (!hasStripePhysicalPaymentBridge()) {
		throw new Error('Physical card payments require the Beamio POS app.')
	}
	params.onProgress?.('Preparing secure card payment...')
	const requestId = newCashTreesScanRequestId()
	const intent = await createMerchantCardStripeTerminalPaymentIntent({
		cardAddress: params.cardAddress,
		buyerEoa: params.buyerEoa,
		amountFiat6: params.amountFiat6,
		currency: params.currency,
		businessIdempotencyKey: `pos-terminal:${requestId}`,
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
		readerMode: params.readerMode ?? 'auto',
	})
	try {
		await detailPromise
		params.onProgress?.('Confirming top-up...')
		return await waitForFulfillment(intent.paymentIntentId)
	} catch (error) {
		cancelStripePhysicalPayment(requestId)
		throw error
	}
}
