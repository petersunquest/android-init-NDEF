#!/usr/bin/env node
/**
 * One-shot fundAndDepositValidators for ConetLabMiningPool 136 claim on 207.90.192.71.
 * Reads validator_deposits.json from remote host (or local path via DEPOSIT_JSON_FILE).
 *
 * Usage:
 *   node scripts/fundMiningPool136Validators207.mjs
 *   DEPOSIT_JSON_FILE=/path/to/validator_deposits.json node scripts/fundMiningPool136Validators207.mjs
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { ethers } from 'ethers'
import { execSync } from 'node:child_process'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = path.join(__dirname, '..')

const REDEEM = '0xc71e246DD78B37C2fABc905D340932F28F503433'
const POOL = '0x32bE583C8e778FFfC5107BF34820c2B225336201'
const ADMIN = '0xE974c5d10cc36738bC2619FC73b075504D5c6d1E'
const RPC = process.env.CONET_RPC_URL || 'https://publicrpc.conet.network'
const HOST = process.env.VALIDATOR_LISTENER_HOST || '207.90.192.71'
const SSH_USER = process.env.VALIDATOR_LISTENER_USER || 'peter'
const NEWCONET = process.env.VALIDATOR_NEWCONET_DIR || '/home/peter/ethereum-pos-mainnet'
const COUNT = 136

const deployJson = JSON.parse(
	fs.readFileSync(path.join(REPO_ROOT, 'deployments/conet-ConetLabMiningPool-136validators-207.json'), 'utf8')
)

const abi = [
	'function getBeneficiaryNodeBundle(address) view returns (tuple(address beneficiary,uint256[] guardianNodeIds,string[] depinNodeIps,address[] nodeWallets,bytes[] validatorPubkeys,bool[] validatorActive,uint256 validatorNodeCount,uint256 gbMiningNodeCount,uint256 claimCount,uint256 nativeBalance,uint256 gbBalance,uint256 usdcBalance))',
	'function fundAndDepositValidators(uint256[] guardianIds,bytes[] pubkeys,bytes[] withdrawalCredentials,bytes[] signatures,bytes32[] depositDataRoots) external',
	'function stakedValidatorCountOf(address) view returns (uint256)',
]

function loadAdminPk() {
	const masterPath = path.join(os.homedir(), '.master.json')
	if (!fs.existsSync(masterPath)) throw new Error(`missing ${masterPath}`)
	const m = JSON.parse(fs.readFileSync(masterPath, 'utf8'))
	const k = m['key_38.102.85.33']
	if (!k) throw new Error('missing key_38.102.85.33 in ~/.master.json')
	const pk = k.startsWith('0x') ? k : `0x${k}`
	const addr = new ethers.Wallet(pk).address
	if (addr.toLowerCase() !== ADMIN.toLowerCase()) {
		throw new Error(`admin key mismatch: got ${addr} expected ${ADMIN}`)
	}
	return pk
}

function loadDepositJson() {
	if (process.env.DEPOSIT_JSON_FILE) {
		return JSON.parse(fs.readFileSync(process.env.DEPOSIT_JSON_FILE, 'utf8'))
	}
	const remote = `${SSH_USER}@${HOST}:${NEWCONET}/validator_deposits.json`
	const raw = execSync(`ssh -o ConnectTimeout=20 ${SSH_USER}@${HOST} "cat '${NEWCONET}/validator_deposits.json'"`, {
		encoding: 'utf8',
		maxBuffer: 64 * 1024 * 1024,
	})
	return JSON.parse(raw)
}

function normalizeIp(ip) {
	return String(ip || '')
		.trim()
		.toLowerCase()
}

async function resolveGuardianIds(provider) {
	const c = new ethers.Contract(REDEEM, abi, provider)
	const bundle = await c.getBeneficiaryNodeBundle(POOL)
	const ips = bundle.depinNodeIps.map(normalizeIp)
	const ids = bundle.guardianNodeIds
	const map = new Map()
	ips.forEach((ip, i) => {
		const gid = ids[i]
		if (ip && gid !== undefined && gid > 0n) map.set(ip, gid)
	})
	const claimIps = deployJson.depinNodeIps.map(normalizeIp)
	const guardianIds = []
	for (let i = 0; i < COUNT; i++) {
		const ip = claimIps[i]
		const gid = map.get(ip)
		if (gid === undefined) throw new Error(`no guardian id for depin ip ${ip}`)
		guardianIds.push(gid)
	}
	return guardianIds
}

function normalizeHex(h) {
	const s = String(h || '')
	return (s.startsWith('0x') ? s : `0x${s}`).toLowerCase()
}

function readLastN(entries, n) {
	if (!Array.isArray(entries)) throw new Error('deposit json must be array')
	if (entries.length < n) throw new Error(`deposit entries ${entries.length} < ${n}`)
	return entries.slice(-n)
}

async function main() {
	const provider = new ethers.JsonRpcProvider(RPC)
	const admin = new ethers.Wallet(loadAdminPk(), provider)
	const c = new ethers.Contract(REDEEM, abi, admin)

	const all = loadDepositJson()
	const entries = readLastN(all, COUNT)
	console.log(`deposit entries: total=${all.length} using last ${entries.length}`)

	const selfCred = deployJson.selfWithdrawalCredentials.toLowerCase()
	for (const e of entries) {
		const wc = normalizeHex(e.withdrawal_credentials)
		if (wc !== selfCred) {
			throw new Error(`withdrawal mismatch: got ${wc} expected ${selfCred}`)
		}
	}

	const guardianIds = await resolveGuardianIds(provider)
	console.log(`guardian ids: ${guardianIds[0]} … ${guardianIds[guardianIds.length - 1]} (${guardianIds.length})`)

	const need = ethers.parseEther('32') * BigInt(COUNT)
	const bal = await provider.getBalance(REDEEM)
	console.log(`redeem balance: ${ethers.formatEther(bal)} CNET; need ${ethers.formatEther(need)}`)
	if (bal < need) throw new Error('insufficient redeem contract balance')

	const before = await c.stakedValidatorCountOf(POOL)
	console.log(`stakedValidatorCountOf(pool) before: ${before}`)

	const gasLimit = 800_000 + 350_000 * COUNT
	console.log(`sending fundAndDepositValidators gasLimit=${gasLimit}`)
	const tx = await c.fundAndDepositValidators(
		guardianIds,
		entries.map((e) => normalizeHex(e.pubkey)),
		entries.map((e) => normalizeHex(e.withdrawal_credentials)),
		entries.map((e) => normalizeHex(e.signature)),
		entries.map((e) => normalizeHex(e.deposit_data_root)),
		{ gasLimit }
	)
	console.log('tx sent:', tx.hash)
	const rc = await tx.wait()
	console.log('confirmed block', rc?.blockNumber, 'status', rc?.status)

	const after = await c.stakedValidatorCountOf(POOL)
	console.log(`stakedValidatorCountOf(pool) after: ${after}`)
	if (after < before + BigInt(COUNT)) {
		throw new Error(`expected +${COUNT} staked, got ${after - before}`)
	}
}

main().catch((e) => {
	console.error('FUND_FAILED:', e?.message ?? e)
	process.exit(1)
})
