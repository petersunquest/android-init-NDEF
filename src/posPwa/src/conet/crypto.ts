/** bizSite `beamio.ts` / iOS `aesGcmEncryptBeamioStyle` parity. */
export async function aesGcmEncrypt(plaintext: string, password: string): Promise<string> {
	const pwUtf8 = new TextEncoder().encode(password)
	const pwHash = await crypto.subtle.digest('SHA-256', pwUtf8)
	const iv = crypto.getRandomValues(new Uint8Array(12))
	const alg = { name: 'AES-GCM', iv }
	const key = await crypto.subtle.importKey('raw', pwHash, alg, false, ['encrypt'])
	const ptUint8 = new TextEncoder().encode(plaintext)
	const ctBuffer = await crypto.subtle.encrypt(alg, key, ptUint8)
	const ivStr = Array.from(iv)
		.map((b) => String.fromCharCode(b))
		.join('')
	const ctStr = Array.from(new Uint8Array(ctBuffer))
		.map((byte) => String.fromCharCode(byte))
		.join('')
	return btoa(ivStr + ctStr)
}

/** Decrypt on-chain AddressPGP encrypted private key (AES-GCM, password = EOA pk hex with `0x`). */
export async function aesGcmDecrypt(ciphertextB64: string, password: string): Promise<string> {
	const pwUtf8 = new TextEncoder().encode(password)
	const pwHash = await crypto.subtle.digest('SHA-256', pwUtf8)
	const ctStr = atob(ciphertextB64)
	const iv = new Uint8Array(12)
	const ct = new Uint8Array(ctStr.length - 12)
	for (let i = 0; i < 12; i++) iv[i] = ctStr.charCodeAt(i)
	for (let i = 12; i < ctStr.length; i++) ct[i - 12] = ctStr.charCodeAt(i)
	const alg = { name: 'AES-GCM', iv }
	const key = await crypto.subtle.importKey('raw', pwHash, alg, false, ['decrypt'])
	const ptBuffer = await crypto.subtle.decrypt(alg, key, ct)
	return new TextDecoder().decode(ptBuffer)
}

export function utf8ToBase64(s: string): string {
	return btoa(Array.from(new TextEncoder().encode(s), (c) => String.fromCharCode(c)).join(''))
}

export function randomBase64Bytes(byteLen: number): string {
	const bytes = crypto.getRandomValues(new Uint8Array(byteLen))
	return btoa(String.fromCharCode(...bytes))
}

export function toBase64Utf8(s: string): string {
	return btoa(Array.from(new TextEncoder().encode(s), (c) => String.fromCharCode(c)).join(''))
}

export function fromBase64Utf8(b64: string): string {
	const bin = atob(b64)
	const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0))
	return new TextDecoder().decode(bytes)
}

export function randomPick<T>(items: readonly T[]): T {
	return items[Math.floor(Math.random() * items.length)]!
}

export function shuffleTake<T>(items: readonly T[], count: number): T[] {
	const copy = [...items].sort(() => Math.random() - 0.5)
	return copy.slice(0, Math.min(count, copy.length))
}

export function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms))
}

export function normalizePrivateKeyHex(raw: string): string | null {
	let pk = raw.trim()
	if (pk.startsWith('0x') || pk.startsWith('0X')) pk = pk.slice(2)
	if (!/^[0-9a-fA-F]{64}$/.test(pk)) return null
	return pk.toLowerCase()
}

export function normalizeEoaLower40(raw: string): string | null {
	let h = raw.trim().toLowerCase()
	if (h.startsWith('0x')) h = h.slice(2)
	if (h.length !== 40 || !/^[0-9a-f]{40}$/.test(h)) return null
	return h
}
