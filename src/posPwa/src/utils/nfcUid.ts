/** 14 hex chars — NFC tag UID for `/api/nfcTopup` and `/api/getUIDAssets`. */
export function isNfcUid14Hex(raw: string | undefined | null): boolean {
	const s = raw?.trim() ?? ''
	return /^[0-9a-fA-F]{14}$/.test(s)
}

export function normalizeNfcUid14(raw: string): string {
	return raw.trim().toLowerCase()
}
