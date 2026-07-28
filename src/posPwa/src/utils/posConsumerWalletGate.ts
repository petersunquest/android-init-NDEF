import { hasPosWalletInIndexedDb } from '@/wallet/posWalletStorage'
import { POS_REGISTERED_TAG_LS_PREFIXES, posHomeTrustedCache } from '@/utils/trustedCache'

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
		if (!k) continue
		let walletAddress = ''
		for (const prefix of POS_REGISTERED_TAG_LS_PREFIXES) {
			if (k.startsWith(prefix)) {
				walletAddress = k.slice(prefix.length).trim()
				break
			}
		}
		if (!walletAddress) continue
		const registeredTag = localStorage.getItem(k)?.trim() ?? ''
		if (!registeredTag) continue
		const activeUpper = posHomeTrustedCache.loadActiveUpper(walletAddress)
		return {
			walletAddress,
			registeredTag,
			parentTag: posHomeTrustedCache.loadParentTag(walletAddress, activeUpper),
		}
	}
	return null
}

export async function posAppNeedsWalletRecover(): Promise<boolean> {
	if (await hasPosWalletInIndexedDb()) return false
	return findPosTerminalSessionWithoutMnemonic() != null
}
