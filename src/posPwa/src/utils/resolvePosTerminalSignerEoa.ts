import { posNativeBridge } from '@/bridge/nativeBridge'
import { isPlausibleEvmAddress } from '@/utils/evmAddress'

/** POS terminal EOA for `signerEOA` on QR/wallet coupon claim & consume (iOS `walletAddress`). */
export async function resolvePosTerminalSignerEoa(
	sessionWallet: string | null | undefined,
): Promise<string | null> {
	const fromSession = sessionWallet?.trim()
	if (isPlausibleEvmAddress(fromSession)) return fromSession!
	const fromNative = (await posNativeBridge.getWalletAddress())?.trim()
	if (isPlausibleEvmAddress(fromNative)) return fromNative!
	return null
}
