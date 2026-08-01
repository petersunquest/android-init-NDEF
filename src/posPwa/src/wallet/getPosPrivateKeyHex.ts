import { posNativeBridge } from '@/bridge/nativeBridge'
import { checkPosWalletStorage } from '@/wallet/posWalletService'
import { getSessionPrivateKeyHex } from '@/wallet/posWalletSession'

/**
 * Terminal global signing key: native Keychain (if any) → session → IndexedDB mnemonic hydrate.
 * Same path as Charge / Top-up / ParentPermissionGate — do not use session-only reads for gossip sign.
 */
export async function getPosPrivateKeyHex(): Promise<string | null> {
	const fromNative = await posNativeBridge.getWalletPrivateKeyHex()
	if (fromNative?.trim()) {
		return fromNative.replace(/^0x/i, '').trim()
	}
	const session = getSessionPrivateKeyHex()
	if (session) return session
	await checkPosWalletStorage()
	return getSessionPrivateKeyHex()
}
