import { Wallet, type TypedDataDomain } from 'ethers'

export const STRIPE_TERMINAL_AUTH_CHAIN_ID = 224422
export const STRIPE_TERMINAL_AUTH_DOMAIN = {
	name: 'Beamio Stripe Terminal',
	version: '1',
	chainId: STRIPE_TERMINAL_AUTH_CHAIN_ID,
} satisfies TypedDataDomain

export const STRIPE_TERMINAL_AUTH_TYPES = {
	StripeTerminalAuthorization: [
		{ name: 'cardAddress', type: 'address' },
		{ name: 'buyerEoa', type: 'address' },
		{ name: 'amountFiat6', type: 'uint256' },
		{ name: 'currency', type: 'string' },
		{ name: 'kind', type: 'string' },
		{ name: 'businessIdempotencyKey', type: 'string' },
		{ name: 'deadline', type: 'uint256' },
		{ name: 'nonce', type: 'bytes32' },
	],
}

export type StripeTerminalAuthorization = {
	cardAddress: string
	buyerEoa: string
	amountFiat6: string
	currency: string
	kind: 'topup' | 'membership' | 'charge'
	businessIdempotencyKey: string
	deadline: number
	nonce: string
}

export async function signStripeTerminalAuthorization(
	privateKeyHex: string,
	value: StripeTerminalAuthorization,
): Promise<string> {
	const wallet = new Wallet(`0x${privateKeyHex.replace(/^0x/i, '')}`)
	return wallet.signTypedData(STRIPE_TERMINAL_AUTH_DOMAIN, STRIPE_TERMINAL_AUTH_TYPES, value)
}
