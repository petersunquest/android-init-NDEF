import { posNativeBridge } from '@/bridge/nativeBridge'
import { checkPosWalletStorage } from '@/wallet/posWalletService'
import type { PosWalletInitRecord } from '@/wallet/posWalletStorage'

export type PosBootPhase = 'no_wallet' | 'permission' | 'home'

export type PosBootInitResult = {
	phase: PosBootPhase
	walletAddress: string | null
	walletRecord: PosWalletInitRecord | null
}

/**
 * SilentPassUI `App.tsx` `init` → `checkStorage` parity for POS PWA.
 * Loads IndexedDB init doc, hydrates session key, reports whether a local wallet exists.
 */
export async function runPosBootWalletCheck(): Promise<{
	hasStoredWallet: boolean
	walletAddress: string | null
	walletRecord: PosWalletInitRecord | null
}> {
	await posNativeBridge.hasStoredWallet()
	const record = await checkPosWalletStorage()
	const walletAddress = (await posNativeBridge.getWalletAddress()) ?? record?.profiles[0]?.keyID ?? null
	const hasStoredWallet = Boolean(record?.mnemonicPhrase?.trim()) || (await posNativeBridge.hasStoredWallet())
	return {
		hasStoredWallet,
		walletAddress,
		walletRecord: record,
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
		case 'permission':
			return '/permission'
		case 'home':
			return '/home'
	}
}
