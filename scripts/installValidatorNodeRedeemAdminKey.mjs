#!/usr/bin/env node
import fs from 'node:fs'
import { Wallet } from 'ethers'

const masterPath = process.argv[2]
const expected = process.argv[3]
if (!masterPath || !expected) {
	console.error('usage: installValidatorNodeRedeemAdminKey.mjs <master.json> <expectedAddress>')
	process.exit(1)
}
const m = JSON.parse(fs.readFileSync(masterPath, 'utf8'))
const k = m['key_38.102.85.33']
if (!k) throw new Error('missing key_38.102.85.33 in master.json')
const pk = k.startsWith('0x') ? k : `0x${k}`
const addr = new Wallet(pk).address
if (addr.toLowerCase() !== expected.toLowerCase()) {
	throw new Error(`address mismatch: got ${addr} expected ${expected}`)
}
process.stdout.write(pk)
