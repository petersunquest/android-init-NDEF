/** Session-only signing material — never written to IndexedDB. */

let sessionPrivateKeyHex: string | null = null
let sessionAddress: string | null = null
/** Key Program Card Charge last signed with. Survives a later session overwrite. */
let programCardChargePrivateKeyHex: string | null = null

export function forgetProgramCardChargePrivateKey(): void {
	programCardChargePrivateKeyHex = null
}

export function rememberProgramCardChargePrivateKey(privateKeyHex: string): void {
	const hex = privateKeyHex.replace(/^0x/i, '').trim()
	if (hex) programCardChargePrivateKeyHex = hex
}

/** Stripe Charge signer: remembered Program Card key, else current session. No IndexedDB. */
export function getProgramCardChargePrivateKeyHex(): string | null {
	if (programCardChargePrivateKeyHex) return programCardChargePrivateKeyHex
	return sessionPrivateKeyHex
}

export function setSessionWallet(privateKeyHex: string, address: string): void {
	const pk = privateKeyHex.replace(/^0x/i, '').trim()
	sessionPrivateKeyHex = pk.length === 64 ? pk.toLowerCase() : null
	sessionAddress = address.trim() || null
}

export function clearSessionWallet(): void {
	sessionPrivateKeyHex = null
	sessionAddress = null
}

export function getSessionPrivateKeyHex(): string | null {
	return sessionPrivateKeyHex
}

export function getSessionWalletAddress(): string | null {
	return sessionAddress
}

export function hasSessionWallet(): boolean {
	return Boolean(sessionPrivateKeyHex && sessionAddress)
}
