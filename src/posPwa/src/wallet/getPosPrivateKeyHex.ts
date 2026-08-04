import { Wallet } from 'ethers'
import {
	checkPosWalletStorage,
	getSessionPrivateKeyHex,
	getSessionWalletAddress,
} from '@/wallet/posWalletService'

/**
 * Terminal **global** signing key (one EOA for all workspaces).
 *
 * Order (prefer session — IndexedDB mnemonic hydrate):
 *   1) `posWalletSession` private key
 *   2) IndexedDB / localStorage mnemonic → hydrate session
 *
 * Native Keychain is intentionally **not** used for signing. Workspace switch must
 * never change this key.
 */
export async function getPosPrivateKeyHex(): Promise<string | null> {
	const session = getSessionPrivateKeyHex()
	if (session) return session

	await checkPosWalletStorage()
	return getSessionPrivateKeyHex()
}

/** True when session or IndexedDB mnemonic can supply a signing key. */
export async function hasPosSigningKeyReady(): Promise<boolean> {
	return Boolean(await getPosPrivateKeyHex())
}

/**
 * EOA that will sign Top-up / ExecuteForAdmin — derived from the session private key.
 * Prefer this over React `walletAddress` when checking `isAdmin` (they can diverge).
 */
export async function getPosSigningWalletAddress(): Promise<string | null> {
	const pk = await getPosPrivateKeyHex()
	if (!pk) return getSessionWalletAddress()
	try {
		return new Wallet(`0x${pk}`).address
	} catch {
		return getSessionWalletAddress()
	}
}
