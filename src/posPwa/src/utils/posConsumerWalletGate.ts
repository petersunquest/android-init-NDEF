import { hasPosWalletInIndexedDb } from '@/wallet/posWalletStorage'
import { posHomeTrustedCache } from '@/utils/trustedCache'

const LS_PREFIX = 'beamio:pos-pwa:v1:registeredTag:'

export function hasLocalPlaintextMnemonicFromRecord(
	record: { mnemonicPhrase?: string } | null | undefined,
): boolean {
	return Boolean(record?.mnemonicPhrase?.trim())
}

/** Prior terminal session in trusted cache but IndexedDB has no mnemonic — must chain-recover. */
export function findPosTerminalSessionWithoutMnemonic(): {
	walletAddress: string
	registeredTag: string
	parentTag: string | null
} | null {
	if (typeof localStorage === 'undefined') return null
	for (let i = 0; i < localStorage.length; i++) {
		const k = localStorage.key(i)
		if (!k?.startsWith(LS_PREFIX)) continue
		const walletAddress = k.slice(LS_PREFIX.length).trim()
		const registeredTag = localStorage.getItem(k)?.trim() ?? ''
		if (!walletAddress || !registeredTag) continue
		return {
			walletAddress,
			registeredTag,
			parentTag: posHomeTrustedCache.loadParentTag(walletAddress),
		}
	}
	return null
}

export async function posAppNeedsWalletRecover(): Promise<boolean> {
	if (await hasPosWalletInIndexedDb()) return false
	return findPosTerminalSessionWithoutMnemonic() != null
}
