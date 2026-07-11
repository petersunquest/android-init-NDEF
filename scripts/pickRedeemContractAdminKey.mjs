#!/usr/bin/env node
/**
 * Print the first private key from ~/.master.json (or MASTER_JSON path) that is
 * ValidatorDepositRedeem contract admin on CoNET. Used to install a minimal
 * secret file on daemon hosts — does NOT copy full master.json.
 *
 * Usage:
 *   node scripts/pickRedeemContractAdminKey.mjs > /tmp/redeem_contract_admin.txt
 *   MASTER_JSON=~/.master.json CONET_RPC_URL=https://publicrpc.conet.network node scripts/pickRedeemContractAdminKey.mjs
 */
import fs from 'node:fs'
import os from 'node:os'
import { ethers } from 'ethers'

const REDEEM = process.env.CONET_VALIDATOR_DEPOSIT_REDEEM?.trim() || '0xc71e246DD78B37C2fABc905D340932F28F503433'
const RPC = process.env.CONET_RPC_URL || 'https://publicrpc.conet.network'
const masterPath = process.env.MASTER_JSON?.trim() || `${os.homedir()}/.master.json`

if (!fs.existsSync(masterPath)) {
	console.error(`missing ${masterPath}`)
	process.exit(1)
}

const m = JSON.parse(fs.readFileSync(masterPath, 'utf8'))
const raw = [
	...(Array.isArray(m.settle_contractAdmin) ? m.settle_contractAdmin : []),
	...(Array.isArray(m.beamio_Admins) ? m.beamio_Admins : []),
	...(Array.isArray(m.admin) ? m.admin : []),
]
const keys = [
	...new Set(
		raw.filter((k) => typeof k === 'string' && k.length > 0).map((k) => (k.startsWith('0x') ? k : `0x${k}`))
	),
]

if (!keys.length) {
	console.error('no admin key candidates in master.json')
	process.exit(1)
}

const provider = new ethers.JsonRpcProvider(RPC)
const redeem = new ethers.Contract(REDEEM, ['function admins(address) view returns (bool)'], provider)

for (const pk of keys) {
	const w = new ethers.Wallet(pk)
	if (await redeem.admins(w.address)) {
		process.stdout.write(`${pk}\n`)
		process.exit(0)
	}
}

console.error('no master.json key is Redeem contract admin')
process.exit(1)
