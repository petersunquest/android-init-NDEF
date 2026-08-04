/**
 * Map getUIDAssets / getWalletAssets error strings to POS user-facing English.
 * Network/transport failures stay as the generic network message at the call site.
 */
export function formatPosAssetsQueryError(raw: string | undefined | null): string {
	const e = (raw ?? '').trim()
	if (!e) return 'Balance query failed. Check network and try again.'
	const lower = e.toLowerCase()

	if (lower.includes('sun verification failed') || lower.includes('sun verification error')) {
		return 'This NFC card is not initialized or is not a valid Beamio card.'
	}
	if (lower.includes('requires sun params')) {
		return 'Could not verify this NFC card. Use a Beamio NFC card and try again.'
	}
	if (lower.includes('not registered')) {
		return 'This NFC card is not registered with Beamio.'
	}
	if (lower.includes('not linked to a wallet')) {
		return 'This NFC card is not linked to a Beamio wallet.'
	}
	if (lower.includes('missing uid') || lower.includes('missing tagid')) {
		return 'Cannot read UID from this card.'
	}
	if (lower.startsWith('http ') || lower === 'query failed' || lower === 'invalid response') {
		return 'Balance query failed. Check network and try again.'
	}
	if (e.length > 160) {
		return 'Balance query failed. Please try again.'
	}
	return e
}
