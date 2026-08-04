import { keccak256, Wallet } from 'ethers'

/**
 * Merchant program cards are CoNET-only (chainId 224422).
 * EIP-712 domain.chainId MUST match server `chainIdForUserCardChain` / Cluster recover,
 * otherwise recoverAddress yields a wrong EOA → "Signer is not card admin".
 */
export const BEAMIO_USER_CARD_EIP712_CHAIN_ID = 224422

/** EIP-712 ExecuteForAdmin — domain aligned with x402sdk `verifyExecuteForAdminSignerIsAdmin`. */
export async function signExecuteForAdmin(params: {
	privateKeyHex: string
	cardAddress: string
	dataHex: string
	deadline: number
	nonceHex: string
	factoryGateway?: string | null
	/** Override only for tests; production merchant cards use CoNET 224422. */
	chainId?: number
}): Promise<string> {
	const pk = params.privateKeyHex.replace(/^0x/i, '').trim()
	const wallet = new Wallet(`0x${pk}`)
	const verifyingContract = params.factoryGateway?.trim()
	if (!verifyingContract) {
		throw new Error('Missing factory gateway for EIP-712 signature.')
	}
	const domain = {
		name: 'BeamioUserCardFactory',
		version: '1',
		chainId: params.chainId ?? BEAMIO_USER_CARD_EIP712_CHAIN_ID,
		verifyingContract,
	}
	const types = {
		ExecuteForAdmin: [
			{ name: 'cardAddress', type: 'address' },
			{ name: 'dataHash', type: 'bytes32' },
			{ name: 'deadline', type: 'uint256' },
			{ name: 'nonce', type: 'bytes32' },
		],
	}
	const dataHash = keccak256(params.dataHex)
	const value = {
		cardAddress: params.cardAddress,
		dataHash,
		deadline: params.deadline,
		nonce: params.nonceHex,
	}
	return wallet.signTypedData(domain, types, value)
}
