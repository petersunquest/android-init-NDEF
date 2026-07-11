#!/usr/bin/env node
/**
 * Remediate: real redeem user should own guardian 341 (207 pool IP), not 477.
 * Requires guardian-recycle upgrade (adminTransferGuardianIds + adminReleaseGuardianIds).
 *
 * Steps (see RUNBOOK-ValidatorDepositRedeem-guardian-recycle.md §七):
 *   1 adminTransferGuardianIds(pool → user, [341])
 *   2 adminReleaseGuardianIds(pool, [342..476])
 *   3 recordNodeValidatorExit(477)
 *   4 adminReleaseGuardianIds(user, [477])
 *
 * Usage:
 *   DRY_RUN=1 node scripts/remediateGuardian477To341.mjs
 *   node scripts/remediateGuardian477To341.mjs
 */
import os from 'node:os'
import path from 'node:path'
import fs from 'node:fs'
import { fileURLToPath } from 'node:url'
import { ethers } from 'ethers'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

const REDEEM = process.env.VALIDATOR_DEPOSIT_REDEEM || '0xc71e246DD78B37C2fABc905D340932F28F503433'
const POOL = process.env.CONET_LAB_MINING_POOL || '0x32bE583C8e778FFfC5107BF34820c2B225336201'
const USER = process.env.CONET_REMEDIATE_USER || '0x300775172ae56f301988C6eF583A8Ef5427A0DE2'
const RPC = process.env.CONET_RPC_URL || 'https://publicrpc.conet.network'
const DRY_RUN = process.env.DRY_RUN === '1'
const SKIP_RELEASE_POOL_HOLLOW = process.env.SKIP_RELEASE_POOL_HOLLOW === '1'

const abi = [
	'function redeemAdmins(address) view returns (bool)',
	'function adminTransferGuardianIds(address from, address to, uint256[] guardianIds) external',
	'function adminReleaseGuardianIds(address from, uint256[] guardianIds) external',
	'function recordNodeValidatorExit(uint256 guardianId) external',
	'function guardianIdBeneficiary(uint256) view returns (address)',
	'function getNodeValidator(uint256) view returns (bytes,address,uint64,uint64,bool)',
]

function loadAdminPk() {
	const masterPath = path.join(os.homedir(), '.master.json')
	if (!fs.existsSync(masterPath)) throw new Error(`missing ${masterPath}`)
	const m = JSON.parse(fs.readFileSync(masterPath, 'utf8'))
	const k = m['key_38.102.85.33']
	if (!k) throw new Error('missing key_38.102.85.33 in ~/.master.json')
	return k.startsWith('0x') ? k : `0x${k}`
}

function rangeIds(from, to) {
	const out = []
	for (let i = from; i <= to; i++) out.push(BigInt(i))
	return out
}

async function send(label, fn) {
	console.log('—', label)
	if (DRY_RUN) return
	const tx = await fn()
	console.log('  tx', tx.hash)
	await tx.wait()
}

async function main() {
	const provider = new ethers.JsonRpcProvider(RPC)
	const admin = new ethers.Wallet(loadAdminPk(), provider)
	const c = new ethers.Contract(REDEEM, abi, admin)

	if (!(await c.redeemAdmins(admin.address))) throw new Error('not redeemAdmins')

	console.log('admin', admin.address)
	console.log('pool', POOL, 'user', USER, 'DRY_RUN', DRY_RUN)

	const b341 = await c.guardianIdBeneficiary(341n)
	const b477 = await c.guardianIdBeneficiary(477n)
	console.log('before: beneficiary(341)', b341, 'beneficiary(477)', b477)

	await send('1 transfer 341 pool→user', () =>
		c.adminTransferGuardianIds(POOL, USER, [341n])
	)

	if (!SKIP_RELEASE_POOL_HOLLOW) {
		const hollow = rangeIds(342, 476)
		const CHUNK = 25
		for (let i = 0; i < hollow.length; i += CHUNK) {
			const batch = hollow.slice(i, i + CHUNK)
			await send(`2 release pool hollow ${batch[0]}..${batch[batch.length - 1]}`, () =>
				c.adminReleaseGuardianIds(POOL, batch)
			)
		}
	}

	const nv477 = await c.getNodeValidator(477n)
	if (nv477[4]) {
		await send('3 recordNodeValidatorExit(477)', () => c.recordNodeValidatorExit(477n))
	} else {
		console.log('— 3 skip recordNodeValidatorExit(477) (already inactive)')
	}

	await send('4 release 477 from user', () => c.adminReleaseGuardianIds(USER, [477n]))

	const a341 = await c.guardianIdBeneficiary(341n)
	const a477 = await c.guardianIdBeneficiary(477n)
	console.log('after: beneficiary(341)', a341, 'beneficiary(477)', a477)
	console.log('done')
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
