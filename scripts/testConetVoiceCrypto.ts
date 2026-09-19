import assert from 'node:assert/strict'
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto'

const key = randomBytes(32)
const nonce = randomBytes(12)
const plain = Buffer.from('voice-frame-mvp')
const cipher = createCipheriv('aes-256-gcm', key, nonce)
const ciphertext = Buffer.concat([cipher.update(plain), cipher.final()])
const tag = cipher.getAuthTag()
const packed = Buffer.concat([nonce, ciphertext, tag]).toString('base64')

const raw = Buffer.from(packed, 'base64')
const decipher = createDecipheriv('aes-256-gcm', key, raw.subarray(0, 12))
decipher.setAuthTag(raw.subarray(raw.length - 16))
assert.deepEqual(
	Buffer.concat([decipher.update(raw.subarray(12, raw.length - 16)), decipher.final()]),
	plain,
)

const tampered = Buffer.from(raw)
tampered[tampered.length - 1] ^= 1
const failed = createDecipheriv('aes-256-gcm', key, tampered.subarray(0, 12))
failed.setAuthTag(tampered.subarray(tampered.length - 16))
assert.throws(() => {
	failed.update(tampered.subarray(12, tampered.length - 16))
	failed.final()
})

console.log('voice AES-GCM frame roundtrip and tamper rejection: ok')
