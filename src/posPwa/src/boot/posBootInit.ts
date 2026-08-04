import { hasLocalPlaintextMnemonicFromRecord } from '@/utils/posConsumerWalletGate'
import { getPosPrivateKeyHex } from '@/wallet/getPosPrivateKeyHex'
import {
	checkPosWalletStorage,
	getSessionWalletAddress,
	unlockPosWalletFromIndexedDbMnemonic,
} from '@/wallet/posWalletService'
import type { PosWalletInitRecord } from '@/wallet/posWalletStorage'
import { hasPosWalletInIndexedDb } from '@/wallet/posWalletStorage'

/**
 * - `home` — signing EOA is card admin (or owner / upper)
 * - `workspace` — not admin on active merchant card; user may re-send join / switch
 * - `permission` — legacy wait gate (onboarding); prefer `workspace` for denied admin
 * - `no_wallet` — onboarding / recover
 */
export type PosBootPhase = 'no_wallet' | 'permission' | 'workspace' | 'home'

export type PosBootInitResult = {
	phase: PosBootPhase
	walletAddress: string | null
	walletRecord: PosWalletInitRecord | null
}

/**
 * SilentPassUI `App.tsx` `init` → `checkStorage` parity for POS PWA.
 *
 * Terminal wallet = **one global EOA** via IndexedDB mnemonic → `posWalletSession`.
 * Native Keychain is not used for boot/signing. Only when **no** local key → onboarding.
 */
export async function runPosBootWalletCheck(): Promise<{
	hasStoredWallet: boolean
	walletAddress: string | null
	walletRecord: PosWalletInitRecord | null
}> {
	let record = await checkPosWalletStorage()
	let hasMnemonic = hasLocalPlaintextMnemonicFromRecord(record)

	if (!hasMnemonic) {
		/* Brief retry — WKWebView IndexedDB can lag one tick after process restore. */
		await new Promise<void>((r) => {
			window.setTimeout(r, 40)
		})
		record = (await checkPosWalletStorage()) ?? record
		hasMnemonic = hasLocalPlaintextMnemonicFromRecord(record)
	}

	/* Always attempt unlock — covers raw JSON / envelope / LS that first checkStorage may miss. */
	if (hasMnemonic || (await hasPosWalletInIndexedDb())) {
		const unlocked = await unlockPosWalletFromIndexedDbMnemonic()
		if (unlocked.ok) {
			const after = await checkPosWalletStorage()
			return {
				hasStoredWallet: true,
				walletAddress: getSessionWalletAddress() ?? unlocked.address,
				walletRecord: after ?? record,
			}
		}
	} else {
		/* First open after deploy: still try unlock once (LS fallback / delayed IDB). */
		const unlocked = await unlockPosWalletFromIndexedDbMnemonic()
		if (unlocked.ok) {
			const after = await checkPosWalletStorage()
			return {
				hasStoredWallet: true,
				walletAddress: getSessionWalletAddress() ?? unlocked.address,
				walletRecord: after ?? record,
			}
		}
	}

	const signingKey = await getPosPrivateKeyHex()
	if (signingKey) {
		return {
			hasStoredWallet: true,
			walletAddress: getSessionWalletAddress() ?? record?.profiles[0]?.keyID ?? null,
			walletRecord: record,
		}
	}

	/* No local mnemonic / signing key → onboarding (Welcome → create or restore terminal). */
	return {
		hasStoredWallet: false,
		walletAddress: null,
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
	/* Not card admin → Workspaces (re-send join / switch merchant). */
	if (params.accessGranted === false || params.permCached === false) return 'workspace'
	// Untrusted chain/API — prefer last trusted cache; default to workspace (safe).
	if (params.permCached === true) return 'home'
	return 'workspace'
}

export function bootPathForPhase(phase: PosBootPhase): string {
	switch (phase) {
		case 'no_wallet':
			return '/'
		case 'permission':
			return '/permission'
		case 'workspace':
			return '/workspace'
		case 'home':
			return '/home'
	}
}
