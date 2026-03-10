import { createCipheriv, createDecipheriv } from 'node:crypto'

export interface VerifyBeamioSunInput {
	url: string
	globalKey2Hex: string
	uidHex: string
	expectedTagIdHex?: string
	lastCounterHex?: string
}

export interface VerifyBeamioSunResult {
	url: string
	uidHex: string
	counterHex: string
	counterValue: number
	tagIdHex: string
	version: number
	eHex: string
	cHex: string
	mHex: string | null
	macInputAscii: string
	expectedMacHex: string
	macValid: boolean
	tagIdMatchesExpected: boolean
	counterFresh: boolean
	embeddedUidMatchesInput: boolean
	embeddedCounterMatchesInput: boolean
	valid: boolean
}

const hexToBytes = (hex: string): Buffer => {
	return Buffer.from(hex, 'hex')
}

const bytesToHex = (data: Uint8Array): string => {
	return Buffer.from(data).toString('hex').toUpperCase()
}

const normalizeHex = (value: string, expectedLength?: number): string => {
	const hex = value.trim().replace(/\s+/g, '').toUpperCase()
	if (hex.length === 0 || hex.length % 2 !== 0 || /[^0-9A-F]/.test(hex)) {
		throw new Error(`Invalid hex string: ${value}`)
	}
	if (expectedLength != null && hex.length !== expectedLength) {
		throw new Error(`Expected hex length ${expectedLength}, got ${hex.length}: ${value}`)
	}
	return hex
}

const ENC_SV_PREFIX = hexToBytes('C33C00010080')
const MAC_SV_PREFIX = hexToBytes('3CC300010080')

export const verifyBeamioSun = (input: VerifyBeamioSunInput): VerifyBeamioSunResult => {
	const uidHex = normalizeHex(input.uidHex, 14)
	const key = hexToBytes(normalizeHex(input.globalKey2Hex, 32))
	const eHex = normalizeHex(getQueryParam(input.url, 'e') ?? '', 64)
	const cHex = normalizeHex(getQueryParam(input.url, 'c') ?? '', 6)
	const mHexRaw = getQueryParam(input.url, 'm')
	const mHex = mHexRaw ? normalizeHex(mHexRaw, 16) : null
	const counterMsb = hexToBytes(cHex)
	const counterLsb = Buffer.from(counterMsb).reverse()
	const uid = hexToBytes(uidHex)

	const sesEncKey = aesCmac(key, Buffer.concat([ENC_SV_PREFIX, uid, counterLsb]))
	const sesMacKey = aesCmac(key, Buffer.concat([MAC_SV_PREFIX, uid, counterLsb]))
	const iv = deriveSdmEncIv(sesEncKey, counterLsb)
	const plain = aesCbcDecryptNoPadding(hexToBytes(eHex), sesEncKey, iv)

	if (plain.length !== 32) {
		throw new Error(`Decrypted SDMENCFileData must be 32 bytes, got ${plain.length}`)
	}

	const embeddedUidHex = bytesToHex(plain.subarray(0, 7))
	const embeddedCounterMsbHex = bytesToHex(Buffer.from(plain.subarray(7, 10)).reverse())
	const tagIdHex = bytesToHex(plain.subarray(10, 18))
	const version = plain[18]

	// Current Beamio template stores encrypted file data first, then "&c=", then the dynamic counter.
	const macInputAscii = `${eHex}&c=${cHex}&m=`
	const macFull = aesCmac(sesMacKey, Buffer.from(macInputAscii, 'ascii'))
	const expectedMacHex = bytesToHex(truncateMac16To8(macFull))

	const macValid = mHex != null && expectedMacHex === mHex
	const tagIdMatchesExpected = !input.expectedTagIdHex ||
		tagIdHex === normalizeHex(input.expectedTagIdHex, 16)
	const counterValue = parseInt(cHex, 16)
	const counterFresh = !input.lastCounterHex ||
		counterValue > parseInt(normalizeHex(input.lastCounterHex, 6), 16)
	const embeddedUidMatchesInput = embeddedUidHex === uidHex
	const embeddedCounterMatchesInput = embeddedCounterMsbHex === cHex

	return {
		url: input.url,
		uidHex,
		counterHex: cHex,
		counterValue,
		tagIdHex,
		version,
		eHex,
		cHex,
		mHex,
		macInputAscii,
		expectedMacHex,
		macValid,
		tagIdMatchesExpected,
		counterFresh,
		embeddedUidMatchesInput,
		embeddedCounterMatchesInput,
		valid:
			macValid &&
			tagIdMatchesExpected &&
			counterFresh &&
			embeddedUidMatchesInput &&
			embeddedCounterMatchesInput
	}
}

export const getQueryParam = (url: string, key: string): string | null => {
	const marker = `${key}=`
	const idx = url.indexOf(marker)
	if (idx < 0) {
		return null
	}
	const start = idx + marker.length
	const end = url.indexOf('&', start)
	return url.substring(start, end < 0 ? url.length : end)
}

const deriveSdmEncIv = (sessionEncKey: Buffer, ctrLsb: Buffer): Buffer => {
	const ivInput = Buffer.alloc(16)
	ctrLsb.copy(ivInput, 0)
	return aesEcbEncrypt(sessionEncKey, ivInput)
}

const aesCbcDecryptNoPadding = (ciphertext: Buffer, key: Buffer, iv: Buffer): Buffer => {
	const cipher = createDecipheriv('aes-128-cbc', key, iv)
	cipher.setAutoPadding(false)
	return Buffer.concat([cipher.update(ciphertext), cipher.final()])
}

const aesEcbEncrypt = (key: Buffer, block16: Buffer): Buffer => {
	const cipher = createCipheriv('aes-128-ecb', key, null)
	cipher.setAutoPadding(false)
	return Buffer.concat([cipher.update(block16), cipher.final()])
}

const aesCmac = (key: Buffer, message: Buffer): Buffer => {
	const zero = Buffer.alloc(16, 0)
	const l = aesEcbEncrypt(key, zero)
	const [k1, k2] = cmacSubkeys(l)
	const blockCount = message.length === 0 ? 1 : Math.ceil(message.length / 16)
	const lastComplete = message.length > 0 && message.length % 16 === 0
	const mLast = Buffer.alloc(16, 0)

	if (lastComplete) {
		const last = message.subarray((blockCount - 1) * 16, blockCount * 16)
		xorInto(mLast, last, k1)
	} else {
		const start = (blockCount - 1) * 16
		const last = Buffer.alloc(16, 0)
		const remain = start < message.length ? message.subarray(start) : Buffer.alloc(0)
		remain.copy(last, 0)
		last[remain.length] = 0x80
		xorInto(mLast, last, k2)
	}

	let x: any = Buffer.alloc(16, 0)
	for (let i = 0; i < blockCount - 1; i += 1) {
		const block = Buffer.from(message.subarray(i * 16, (i + 1) * 16))
		x = aesEcbEncrypt(key, xor16(x, block))
	}
	return aesEcbEncrypt(key, xor16(x, mLast))
}

const cmacSubkeys = (l: Buffer): [Buffer, Buffer] => {
	const k1 = leftShiftOneBit(l)
	if ((l[0] & 0x80) !== 0) {
		k1[15] ^= 0x87
	}
	const k2 = leftShiftOneBit(k1)
	if ((k1[0] & 0x80) !== 0) {
		k2[15] ^= 0x87
	}
	return [Buffer.from(k1), Buffer.from(k2)]
}

const leftShiftOneBit = (input: Buffer): Buffer => {
	const out = Buffer.alloc(16, 0)
	let carry = 0
	for (let i = 15; i >= 0; i -= 1) {
		const b = input[i]
		out[i] = ((b << 1) & 0xFF) | carry
		carry = (b & 0x80) !== 0 ? 1 : 0
	}
	return out
}

const xorInto = (out: Buffer, a: Buffer, b: Buffer) => {
	for (let i = 0; i < 16; i += 1) {
		out[i] = a[i] ^ b[i]
	}
}

const xor16 = (a: Buffer, b: Buffer): Buffer => {
	const out = Buffer.alloc(16, 0)
	xorInto(out, a, b)
	return out
}

const truncateMac16To8 = (full: Buffer): Buffer => {
	return Buffer.from([
		full[1], full[3], full[5], full[7],
		full[9], full[11], full[13], full[15]
	])
}
