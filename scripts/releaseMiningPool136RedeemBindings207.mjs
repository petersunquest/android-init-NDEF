#!/usr/bin/env node
/**
 * Release ValidatorDepositRedeem contract bindings for ConetLabMiningPool 136 guardians
 * (undo fundAndDepositValidators *ledger* on guardian nodes) WITHOUT beacon voluntary-exit.
 *
 * Calls recordNodeValidatorExit(guardianId) per node — sets validatorActive=false on-chain;
 * does NOT call requestFullExit / settleFullExitPayout; 207 Prysm VA keeps attesting.
 *
 * Usage:
 *   node scripts/releaseMiningPool136RedeemBindings207.mjs
 *   DRY_RUN=1 node scripts/releaseMiningPool136RedeemBindings207.mjs
 *   CONET_RELEASE_ONLY_IDS=341,342 node scripts/releaseMiningPool136RedeemBindings207.mjs
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { ethers } from 'ethers'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = path.join(__dirname, '..')

const REDEEM = '0xc71e246DD78B37C2fABc905D340932F28F503433'
const POOL = '0x32bE583C8e778FFfC5107BF34820c2B225336201'
const RPC = process.env.CONET_RPC_URL || 'https://publicrpc.conet.network'
const DRY_RUN = process.env.DRY_RUN === '1'
const DEPLOY_JSON = path.join(
	REPO_ROOT,
	'deployments/conet-ConetLabMiningPool-136validators-207.json'
)

const abi = [
	'function redeemAdmins(address) view returns (bool)',
	'function recordNodeValidatorExit(uint256 guardianId) external',
	'function getBeneficiaryNodeBundle(address) view returns (tuple(address beneficiary,uint256[] guardianNodeIds,string[] depinNodeIps,address[] nodeWallets,bytes[] validatorPubkeys,bool[] validatorActive,uint256 validatorNodeCount,uint256 gbMiningNodeCount,uint256 claimCount,uint256 nativeBalance,uint256 gbBalance,uint256 usdcBalance))',
	'function stakedValidatorCountOf(address) view returns (uint256)',
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

async function resolveGuardianIds(c) {
	const only = process.env.CONET_RELEASE_ONLY_IDS?.trim()
	if (only) {
		return only.split(',').map((s) => BigInt(s.trim()))
	}
	const bundle = await c.getBeneficiaryNodeBundle(POOL)
	const ids = bundle.guardianNodeIds.map((x) => BigInt(x))
	if (ids.length === 0) throw new Error('empty guardianNodeIds on pool bundle')
	const deploy = JSON.parse(fs.readFileSync(DEPLOY_JSON, 'utf8'))
	const expected = Number(deploy.validatorCount || 136)
	if (ids.length !== expected) {
		console.warn(`warn: bundle ids=${ids.length} expected=${expected}`)
	}
	return ids
}

async function bundleStats(c) {
	const b = await c.getBeneficiaryNodeBundle(POOL)
	const active = b.validatorActive.filter(Boolean).length
	const staked = await c.stakedValidatorCountOf(POOL)
	return { guardianCount: b.guardianNodeIds.length, validatorActive: active, staked: staked.toString() }
}

async function main() {
	const provider = new ethers.JsonRpcProvider(RPC)
	const admin = new ethers.Wallet(loadAdminPk(), provider)
	const c = new ethers.Contract(REDEEM, abi, admin)

	const isAdmin = await c.redeemAdmins(admin.address)
	if (!isAdmin) throw new Error(`${admin.address} is not redeemAdmins`)

	console.log('admin', admin.address)
	console.log('beneficiary', POOL)
	console.log('before', await bundleStats(c))

	const guardianIds = await resolveGuardianIds(c)
	console.log(`guardian ids to release: ${guardianIds.length} (${guardianIds[0]} … ${guardianIds[guardianIds.length - 1]})`)

	let released = 0
	let skipped = 0
	const errors = []

	for (const gid of guardianIds) {
		const [, , , , active] = await c.getNodeValidator(gid)
		if (!active) {
			skipped++
			continue
		}
		if (DRY_RUN) {
			console.log(`[dry-run] recordNodeValidatorExit(${gid})`)
			released++
			continue
		}
		try {
			const tx = await c.recordNodeValidatorExit(gid)
			console.log(`tx ${gid}:`, tx.hash)
			await tx.wait()
			released++
		} catch (e) {
			const msg = e?.shortMessage || e?.message || String(e)
			console.error(`FAIL ${gid}:`, msg)
			errors.push({ gid: gid.toString(), msg })
		}
	}

	console.log('summary', { released, skipped, errors: errors.length })
	console.log('after', await bundleStats(c))

	if (errors.length) {
		console.error('errors sample', errors.slice(0, 5))
		process.exit(1)
	}
}

main().catch((e) => {
	console.error('RELEASE_FAILED:', e?.message ?? e)
	process.exit(1)
})
