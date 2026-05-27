import { posNativeBridge } from '@/bridge/nativeBridge'
import { getSessionPrivateKeyHex } from '@/wallet/posWalletSession'

export async function getPosPrivateKeyHex(): Promise<string | null> {
	const fromNative = await posNativeBridge.getWalletPrivateKeyHex()
	if (fromNative?.trim()) {
		return fromNative.replace(/^0x/i, '').trim()
	}
	return getSessionPrivateKeyHex()
}
