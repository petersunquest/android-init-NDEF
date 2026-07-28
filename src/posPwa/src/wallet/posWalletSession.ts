/** Session-only signing material — never written to IndexedDB. */

let sessionPrivateKeyHex: string | null = null
let sessionAddress: string | null = null

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
