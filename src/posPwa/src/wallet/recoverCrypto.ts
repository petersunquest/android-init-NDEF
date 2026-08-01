import { argon2id } from '@noble/hashes/argon2'
import { randomBytes } from '@noble/hashes/utils'
import { ethers } from 'ethers'
import { fromBase64Utf8, toBase64Utf8 } from '@/conet/crypto'

export type Argon2idHash = {
	algo: 'argon2id'
	v: 19
	m: number
	t: number
	p: number
	salt: string
	hash: string
}

const enc = new TextEncoder()
const dec = new TextDecoder()

const DEFAULT_ARGON2: { memoryKB: number; iterations: number; parallelism: number; hashLen: number } =
	{
		memoryKB: 32 * 1024,
		iterations: 3,
		parallelism: 1,
		hashLen: 32,
	}

function bytesToB64(bytes: Uint8Array): string {
	return btoa(Array.from(bytes, (b) => String.fromCharCode(b)).join(''))
}

function b64ToBytes(b64: string): Uint8Array {
	const bin = atob(b64)
	return Uint8Array.from(bin, (c) => c.charCodeAt(0))
}

export function hashPasswordBrowser(password: string): Argon2idHash {
	const salt = randomBytes(16)
	const hash = argon2id(enc.encode(password), salt, {
		m: DEFAULT_ARGON2.memoryKB,
		t: DEFAULT_ARGON2.iterations,
		p: DEFAULT_ARGON2.parallelism,
		dkLen: DEFAULT_ARGON2.hashLen,
	})
	return {
		algo: 'argon2id',
		v: 19,
		m: DEFAULT_ARGON2.memoryKB,
		t: DEFAULT_ARGON2.iterations,
		p: DEFAULT_ARGON2.parallelism,
		salt: bytesToB64(salt),
		hash: bytesToB64(hash),
	}
}

async function deriveAesKeyFromPassword(password: string, stored: Argon2idHash): Promise<CryptoKey> {
	const passwordBytes = enc.encode(password)
	const salt = b64ToBytes(stored.salt)
	const keyBytes = Uint8Array.from(
		argon2id(passwordBytes, salt, {
			m: stored.m,
			t: stored.t,
			p: stored.p,
			dkLen: 32,
		}),
	)
	return crypto.subtle.importKey('raw', keyBytes, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt'])
}

export async function aesGcmEncryptWithStored(
	plaintext: string,
	password: string,
	stored: Argon2idHash,
): Promise<string> {
	const key = await deriveAesKeyFromPassword(password, stored)
	const iv = crypto.getRandomValues(new Uint8Array(12))
	const encrypted = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, enc.encode(plaintext))
	const cipherBytes = new Uint8Array(encrypted)
	const combined = new Uint8Array(iv.length + cipherBytes.length)
	combined.set(iv, 0)
	combined.set(cipherBytes, iv.length)
	return bytesToB64(combined)
}

export async function aesGcmDecryptWithStored(
	cipherB64: string,
	password: string,
	stored: Argon2idHash,
): Promise<string> {
	const key = await deriveAesKeyFromPassword(password, stored)
	const combined = b64ToBytes(cipherB64)
	const iv = combined.slice(0, 12)
	const cipherBytes = combined.slice(12)
	const decrypted = await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, key, cipherBytes)
	return dec.decode(decrypted)
}

export type RecoverStoragePayload = {
	stored: Argon2idHash
	img: string
}

export function encodeRecoverStoragePayload(stored: Argon2idHash, img: string): string {
	return toBase64Utf8(JSON.stringify({ stored, img } satisfies RecoverStoragePayload))
}

export function decodeRecoverStoragePayload(encoded: string): RecoverStoragePayload | null {
	try {
		const obj = JSON.parse(fromBase64Utf8(encoded)) as RecoverStoragePayload
		if (!obj?.stored || typeof obj.img !== 'string') return null
		return obj
	} catch {
		return null
	}
}

/** bizSite `generateCODE('')` — random recovery code + keccak hash for on-chain recover slot. */
export function generateRecoveryCode(passcode = ''): { code: string; hash: string } {
	const code = crypto.randomUUID().replace(/-/g, '')
	const hash = ethers.solidityPackedKeccak256(['string', 'string'], [code, passcode])
	return { code, hash }
}

export type RecoverEntry = { hash: string; encrypto: string }

/** iOS `BeamioRecoverPayload.build` / bizSite `createRecover` recover[] for `/api/addUser`. */
export async function buildRecoverEntriesForNewUser(
	accountName: string,
	pin: string,
	mnemonicPhrase: string,
): Promise<{ recover: RecoverEntry[]; recoveryCode: string }> {
	const stored = hashPasswordBrowser(pin)
	const phraseBase64 = toBase64Utf8(mnemonicPhrase)
	const recoveryCode = generateRecoveryCode('')
	const img = await aesGcmEncryptWithStored(phraseBase64, recoveryCode.code, stored)
	const img1 = await aesGcmEncryptWithStored(phraseBase64, pin, stored)
	const enc0 = encodeRecoverStoragePayload(stored, img)
	const enc1 = encodeRecoverStoragePayload(stored, img1)
	const tagHash = ethers.solidityPackedKeccak256(['string'], [accountName])
	return {
		recover: [
			{ hash: recoveryCode.hash, encrypto: enc0 },
			{ hash: tagHash, encrypto: enc1 },
		],
		recoveryCode: recoveryCode.code,
	}
}
