#!/usr/bin/env node
/**
 * After guardian-recycle upgrade: adminReleaseGuardianIds for ConetLabMiningPool hollow ids.
 * Default range 342–476 (341 reserved for remediateGuardian477To341 unless CONET_RELEASE_FROM=341).
 *
 * Prereq: recordNodeValidatorExit already done (validator inactive on each id).
 *
 * Usage:
 *   DRY_RUN=1 node scripts/releaseMiningPoolGuardianDePIN207.mjs
 *   node scripts/releaseMiningPoolGuardianDePIN207.mjs
 *   CONET_RELEASE_FROM=342 CONET_RELEASE_TO=476 CHUNK=20 node scripts/releaseMiningPoolGuardianDePIN207.mjs
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { ethers } from 'ethers'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = path.join(__dirname, '..')

const REDEEM = process.env.VALIDATOR_DEPOSIT_REDEEM || '0xc71e246DD78B37C2fABc905D340932F28F503433'
const POOL = process.env.CONET_LAB_MINING_POOL || '0x32bE583C8e778FFfC5107BF34820c2B225336201'
const RPC = process.env.CONET_RPC_URL || 'https://publicrpc.conet.network'
const DRY_RUN = process.env.DRY_RUN === '1'
const FROM = Number(process.env.CONET_RELEASE_FROM || '342')
const TO = Number(process.env.CONET_RELEASE_TO || '476')
const CHUNK = Math.max(1, Number(process.env.CHUNK || '25'))

const abi = [
	'function redeemAdmins(address) view returns (bool)',
	'function adminReleaseGuardianIds(address from, uint256[] guardianIds) external',
	'function guardianIdBeneficiary(uint256) view returns (address)',
	'function getNodeValidator(uint256) view returns (bytes,address,uint64,uint64,bool)',
	'function validatorNodeCountOf(address) view returns (uint256)',
]

function loadAdminPk() {
	const masterPath = path.join(os.homedir(), '.master.json')
	if (!fs.existsSync(masterPath)) throw new Error(`missing ${masterPath}`)
	const m = JSON.parse(fs.readFileSync(masterPath, 'utf8'))
	const k = m['key_38.102.85.33']
	if (!k) throw new Error('missing key_38.102.85.33 in ~/.master.json')
	return k.startsWith('0x') ? k : `0x${k}`
}

function chunkIds(ids, size) {
	const out = []
	for (let i = 0; i < ids.length; i += size) out.push(ids.slice(i, i + size))
	return out
}

async function main() {
	const provider = new ethers.JsonRpcProvider(RPC)
	const admin = new ethers.Wallet(loadAdminPk(), provider)
	const c = new ethers.Contract(REDEEM, abi, admin)

	if (!(await c.redeemAdmins(admin.address))) {
		throw new Error(`${admin.address} is not redeemAdmins`)
	}

	const ids = []
	for (let id = FROM; id <= TO; id++) ids.push(BigInt(id))

	console.log('admin', admin.address)
	console.log('pool', POOL)
	console.log('release ids', FROM, '..', TO, `(${ids.length} total)`)
	console.log('chunk', CHUNK, 'DRY_RUN', DRY_RUN)

	for (const id of ids) {
		const owner = await c.guardianIdBeneficiary(id)
		if (owner.toLowerCase() !== POOL.toLowerCase()) {
			console.warn(`skip ${id}: beneficiary ${owner} (not pool)`)
			continue
		}
		const nv = await c.getNodeValidator(id)
		if (nv[4]) throw new Error(`guardian ${id} validator still active — run recordNodeValidatorExit first`)
	}

	const batches = chunkIds(ids, CHUNK)
	for (let bi = 0; bi < batches.length; bi++) {
		const batch = batches[bi]
		console.log(`batch ${bi + 1}/${batches.length} ids ${batch[0]}..${batch[batch.length - 1]}`)
		if (DRY_RUN) continue
		const tx = await c.adminReleaseGuardianIds(POOL, batch)
		console.log('  tx', tx.hash)
		await tx.wait()
	}

	if (!DRY_RUN) {
		const count = await c.validatorNodeCountOf(POOL)
		console.log('pool validatorNodeCountOf after', count.toString())
		const sample = await c.guardianIdBeneficiary(342n)
		console.log('guardianIdBeneficiary(342)', sample)
	}
	console.log('done')
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
