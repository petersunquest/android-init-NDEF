import { CONET_RPC } from '@/constants'
import { CONET_ADDRESS_PGP_MANAGER } from '@/conet/constants'
import { fromBase64Utf8, normalizeEoaLower40 } from '@/conet/crypto'

const SEARCH_KEY_SELECTOR = '052f2778'

function hexToBytes(hex: string): Uint8Array | null {
	const s = hex.trim().replace(/^0x/i, '')
	if (s.length % 2 !== 0) return null
	const out = new Uint8Array(s.length / 2)
	for (let i = 0; i < s.length; i += 2) {
		const b = Number.parseInt(s.slice(i, i + 2), 16)
		if (Number.isNaN(b)) return null
		out[i / 2] = b
	}
	return out
}

function u256Tail8AsBigInt(data: Uint8Array, byteOffset: number): bigint {
	if (byteOffset + 32 > data.length) return 0n
	let v = 0n
	for (let i = 24; i < 32; i++) {
		v = (v << 8n) | BigInt(data[byteOffset + i]!)
	}
	return v
}

function readAbiString(data: Uint8Array, headWordByteOffset: number): string | null {
	const ptr = Number(u256Tail8AsBigInt(data, headWordByteOffset))
	if (ptr < 0 || ptr + 32 > data.length) return null
	const len = Number(u256Tail8AsBigInt(data, ptr))
	if (len < 0 || ptr + 32 + len > data.length) return null
	return new TextDecoder().decode(data.slice(ptr + 32, ptr + 32 + len))
}

/** `searchKey(address)` calldata — iOS `BeamioConetSearchKeyAbi.encodeSearchKeyCall`. */
export function encodeSearchKeyCall(recipientEoa: string): string | null {
	const h = normalizeEoaLower40(recipientEoa)
	if (!h) return null
	return `0x${SEARCH_KEY_SELECTOR}${'0'.repeat(24)}${h}`
}

/** Decode `userPublicKeyArmored` field → armored PGP public key block. */
export function decodeSearchKeyUserPublicArmored(hex: string): string | null {
	const data = hexToBytes(hex)
	if (!data || data.length < 160) return null
	const userPubB64 = readAbiString(data, 32)
	if (!userPubB64) return null
	try {
		const armored = fromBase64Utf8(userPubB64)
		if (!armored.includes('BEGIN PGP')) return null
		return armored
	} catch {
		return null
	}
}

export async function conetEthCall(to: string, dataHex: string): Promise<string | null> {
	const toLower = to.startsWith('0x') ? to.toLowerCase() : `0x${to.toLowerCase()}`
	const data = dataHex.startsWith('0x') ? dataHex.toLowerCase() : `0x${dataHex.toLowerCase()}`
	try {
		const res = await fetch(CONET_RPC, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				jsonrpc: '2.0',
				id: 1,
				method: 'eth_call',
				params: [{ to: toLower, data }, 'latest'],
			}),
		})
		if (!res.ok) return null
		const json = (await res.json()) as { error?: unknown; result?: string }
		if (json.error) return null
		const result = String(json.result ?? '')
		if (!result || result === '0x') return null
		return result
	} catch {
		return null
	}
}

export async function fetchRecipientPublicArmored(recipientEoa: string): Promise<string | null> {
	const dataHex = encodeSearchKeyCall(recipientEoa)
	if (!dataHex) return null
	const hex = await conetEthCall(CONET_ADDRESS_PGP_MANAGER, dataHex)
	if (!hex) return null
	return decodeSearchKeyUserPublicArmored(hex)
}

export async function hasOnChainUserPgpPublic(walletEoa: string): Promise<boolean> {
	const armored = await fetchRecipientPublicArmored(walletEoa)
	return Boolean(armored)
}
