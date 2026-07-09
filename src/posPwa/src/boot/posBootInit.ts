import { checkPosWalletStorage } from '@/wallet/posWalletService'
import type { PosWalletInitRecord } from '@/wallet/posWalletStorage'
import {
	findPosTerminalSessionWithoutMnemonic,
	hasLocalPlaintextMnemonicFromRecord,
} from '@/utils/posConsumerWalletGate'

export type PosBootPhase = 'no_wallet' | 'wallet_recover' | 'permission' | 'home'

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
	needsWalletRecover: boolean
	recoverHint: ReturnType<typeof findPosTerminalSessionWithoutMnemonic>
}> {
	const record = await checkPosWalletStorage()
	const hasStoredWallet = hasLocalPlaintextMnemonicFromRecord(record)
	const recoverHint = hasStoredWallet ? null : findPosTerminalSessionWithoutMnemonic()
	const walletAddress =
		record?.profiles[0]?.keyID ?? recoverHint?.walletAddress ?? null
	return {
		hasStoredWallet,
		walletAddress,
		walletRecord: record,
		needsWalletRecover: !hasStoredWallet && recoverHint != null,
		recoverHint,
	}
}

/** Resolve post-boot route from trusted admin flag + local perm cache.
 * Trusted `accessGranted === false` (not on merchant card admin list) always wins over stale perm cache.
 */
export function resolvePosBootPhase(params: {
	hasStoredWallet: boolean
	accessGranted: boolean | null
	permCached: boolean | null
}): PosBootPhase {
	if (!params.hasStoredWallet) return 'no_wallet'
	if (params.accessGranted === false || params.permCached === false) return 'permission'
	if (params.accessGranted === true || params.permCached === true) return 'home'
	// Untrusted chain/API — prefer last trusted cache; default to permission (safe wait).
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
