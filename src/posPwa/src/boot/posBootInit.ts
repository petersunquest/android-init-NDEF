import { posNativeBridge } from '@/bridge/nativeBridge'
import {
	findPosTerminalSessionWithoutMnemonic,
	hasLocalPlaintextMnemonicFromRecord,
} from '@/utils/posConsumerWalletGate'
import { checkPosWalletStorage } from '@/wallet/posWalletService'
import type { PosWalletInitRecord } from '@/wallet/posWalletStorage'
import { getSessionPrivateKeyHex, getSessionWalletAddress } from '@/wallet/posWalletSession'

export type PosBootPhase = 'no_wallet' | 'wallet_recover' | 'permission' | 'home'

export type PosBootInitResult = {
	phase: PosBootPhase
	walletAddress: string | null
	walletRecord: PosWalletInitRecord | null
}

/**
 * SilentPassUI `App.tsx` `init` → `checkStorage` parity for POS PWA.
 * Loads IndexedDB init doc, hydrates session key, reports whether a local wallet exists.
 * Native Keychain / session key also counts as an unlocked terminal wallet (no recover flash).
 */
export async function runPosBootWalletCheck(): Promise<{
	hasStoredWallet: boolean
	walletAddress: string | null
	walletRecord: PosWalletInitRecord | null
	needsWalletRecover: boolean
	recoverHint: ReturnType<typeof findPosTerminalSessionWithoutMnemonic>
}> {
	let record = await checkPosWalletStorage()
	let hasStoredWallet = hasLocalPlaintextMnemonicFromRecord(record)
	let walletAddress = record?.profiles[0]?.keyID ?? null

	if (!hasStoredWallet) {
		/* Brief retry — WKWebView IndexedDB can lag one tick after process restore. */
		await new Promise<void>((r) => {
			window.setTimeout(r, 40)
		})
		record = (await checkPosWalletStorage()) ?? record
		hasStoredWallet = hasLocalPlaintextMnemonicFromRecord(record)
		walletAddress = record?.profiles[0]?.keyID ?? walletAddress
	}

	if (!hasStoredWallet) {
		const nativePk = (await posNativeBridge.getWalletPrivateKeyHex())?.trim()
		const nativeAddr = (await posNativeBridge.getWalletAddress())?.trim()
		const sessionPk = getSessionPrivateKeyHex()
		const sessionAddr = getSessionWalletAddress()
		if ((nativePk || sessionPk) && (nativeAddr || sessionAddr)) {
			hasStoredWallet = true
			walletAddress = nativeAddr || sessionAddr
		}
	}

	const recoverHint = hasStoredWallet ? null : findPosTerminalSessionWithoutMnemonic()
	if (!walletAddress && recoverHint) walletAddress = recoverHint.walletAddress

	return {
		hasStoredWallet,
		walletAddress,
		walletRecord: record,
		needsWalletRecover: !hasStoredWallet && recoverHint != null,
		recoverHint,
	}
}

/** Resolve post-boot route from trusted admin flag + local perm cache. */
export function resolvePosBootPhase(params: {
	hasStoredWallet: boolean
	accessGranted: boolean | null
	permCached: boolean | null
}): PosBootPhase {
	if (!params.hasStoredWallet) return 'no_wallet'
	if (params.accessGranted === true || params.permCached === true) return 'home'
	if (params.accessGranted === false || params.permCached === false) return 'permission'
	// Untrusted chain/API — prefer last trusted cache; default to permission (safe wait).
	if (params.permCached === true) return 'home'
	return 'permission'
}

export function bootPathForPhase(phase: PosBootPhase): string {
	switch (phase) {
		case 'no_wallet':
			return '/'
		case 'wallet_recover':
			return '/recover'
		case 'permission':
			return '/permission'
		case 'home':
			return '/home'
	}
}
