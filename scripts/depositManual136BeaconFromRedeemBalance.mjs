#!/usr/bin/env node
/**
 * Manual 136 beacon deposits WITHOUT contract upgrade or fundAndDepositValidators.
 *
 * 1) Optional: contract admin calls ValidatorDepositRedeem.withdrawNative(depositWallet, need)
 * 2) depositWallet sends 136 × deposit() to beacon deposit contract (32 CNET each)
 *
 * No guardian ledger updates on Redeem. Beacon validators still use wc=Redeem; VA fee_recipient is separate.
 *
 * Keys:
 *   withdraw — contract admin from ~/.master.json (settle_contractAdmin / beamio_Admins / admin)
 *   deposit  — redeem admin key_38.102.85.33 → 0xE974… (or DEPOSIT_PK / deposit_sender file on 74)
 *
 * Usage:
 *   node scripts/depositManual136BeaconFromRedeemBalance.mjs
 *   SKIP_WITHDRAW=1 node scripts/depositManual136BeaconFromRedeemBalance.mjs   # wallet already funded
 *   DEPOSIT_OFFSET=20 DEPOSIT_LIMIT=20 node scripts/depositManual136BeaconFromRedeemBalance.mjs
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
const DEPOSIT_CONTRACT = '0x4242424242424242424242424242424242424242'
const DEPOSIT_WALLET = '0xE974c5d10cc36738bC2619FC73b075504D5c6d1E'
const RPC = process.env.CONET_RPC_URL || 'https://publicrpc.conet.network'
const HOST =
	process.env.VALIDATOR_HOST || process.env.VALIDATOR_HOST_74 || '74.208.224.45'
const SSH_USER = process.env.VALIDATOR_SSH_USER || 'peter'
const NEWCONET = process.env.VALIDATOR_NEWCONET_DIR || '/home/peter/ethereum-pos-mainnet'
const COUNT = Number(process.env.VALIDATOR_COUNT || '136')
const STAKE = ethers.parseEther('32')
const SELF_CRED =
	process.env.SELF_WITHDRAWAL_CREDENTIALS ||
	'0x010000000000000000000000c71e246dd78b37c2fabc905d340932f28f503433'
const OFFSET = Number(process.env.DEPOSIT_OFFSET || '0')
const LIMIT = process.env.DEPOSIT_LIMIT ? Number(process.env.DEPOSIT_LIMIT) : COUNT

const redeemAbi = [
	'function withdrawNative(address to, uint256 amount) external',
	'function admins(address) view returns (bool)',
]
const depositAbi = [
	'function deposit(bytes pubkey, bytes withdrawal_credentials, bytes signature, bytes32 deposit_data_root) payable',
]

function normalizeHex(h) {
	const s = String(h || '')
	return s.startsWith('0x') ? s : `0x${s}`
}

function loadMaster() {
	const p = path.join(os.homedir(), '.master.json')
	if (!fs.existsSync(p)) throw new Error(`missing ${p}`)
	return JSON.parse(fs.readFileSync(p, 'utf8'))
}

function loadDepositPk() {
	if (process.env.DEPOSIT_PK?.trim()) {
		const pk = process.env.DEPOSIT_PK.trim()
		return pk.startsWith('0x') ? pk : `0x${pk}`
	}
	const m = loadMaster()
	const k = m['key_38.102.85.33']
	if (!k) throw new Error('missing key_38.102.85.33 in ~/.master.json')
	const pk = k.startsWith('0x') ? k : `0x${k}`
	const addr = new ethers.Wallet(pk).address
	if (addr.toLowerCase() !== DEPOSIT_WALLET.toLowerCase()) {
		throw new Error(`deposit key mismatch: ${addr} expected ${DEPOSIT_WALLET}`)
	}
	return pk
}

function loadContractAdminPks() {
	const m = loadMaster()
	const raw = [
		...(Array.isArray(m.settle_contractAdmin) ? m.settle_contractAdmin : []),
		...(Array.isArray(m.beamio_Admins) ? m.beamio_Admins : []),
		...(Array.isArray(m.admin) ? m.admin : []),
	]
	const keys = [...new Set(raw.filter((k) => typeof k === 'string' && k.length > 0).map((k) => (k.startsWith('0x') ? k : `0x${k}`)))]
	if (!keys.length) throw new Error('no contract admin keys in ~/.master.json')
	return keys
}

function loadDepositJson() {
	if (process.env.DEPOSIT_JSON_FILE) {
		return JSON.parse(fs.readFileSync(process.env.DEPOSIT_JSON_FILE, 'utf8'))
	}
	const raw = execSync(
		`ssh -o ConnectTimeout=20 ${SSH_USER}@${HOST} "cat '${NEWCONET}/validator_deposits.json'"`,
		{ encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }
	)
	return JSON.parse(raw)
}

async function withdrawFromRedeem(provider, to, amount) {
	const keys = loadContractAdminPks()
	for (const pk of keys) {
		const w = new ethers.Wallet(pk, provider)
		const c = new ethers.Contract(REDEEM, redeemAbi, w)
		if (!(await c.admins(w.address))) continue
		const bal = await provider.getBalance(REDEEM)
		console.log(`contract admin ${w.address} → withdrawNative(${to}, ${ethers.formatEther(amount)} CNET)`)
		console.log(`redeem balance before: ${ethers.formatEther(bal)}`)
		if (bal < amount) throw new Error('insufficient redeem contract balance')
		const tx = await c.withdrawNative(to, amount)
		console.log('withdraw tx:', tx.hash)
		const rc = await tx.wait()
		console.log('withdraw confirmed block', rc?.blockNumber)
		return w.address
	}
	throw new Error('no ~/.master.json key is contract admin on ValidatorDepositRedeem')
}

async function main() {
	const provider = new ethers.JsonRpcProvider(RPC)
	const all = loadDepositJson()
	if (!Array.isArray(all) || all.length < COUNT) {
		throw new Error(`deposit json entries ${all?.length ?? 0} < ${COUNT}`)
	}
	const entries = all.slice(-COUNT).slice(OFFSET, OFFSET + LIMIT)
	console.log(`deposit batch: offset=${OFFSET} limit=${LIMIT} slice=${entries.length} (of last ${COUNT})`)

	const selfCred = SELF_CRED.toLowerCase()
	for (const e of entries) {
		if (normalizeHex(e.withdrawal_credentials).toLowerCase() !== selfCred) {
			throw new Error(`withdrawal mismatch: ${e.withdrawal_credentials}`)
		}
	}

	const need = STAKE * BigInt(entries.length)
	if (process.env.SKIP_WITHDRAW !== '1') {
		const walletBal = await provider.getBalance(DEPOSIT_WALLET)
		console.log(`deposit wallet ${DEPOSIT_WALLET} balance: ${ethers.formatEther(walletBal)} CNET; need ${ethers.formatEther(need)}`)
		if (walletBal < need) {
			const totalNeed = STAKE * BigInt(COUNT)
			if (OFFSET === 0 && LIMIT === COUNT) {
				await withdrawFromRedeem(provider, DEPOSIT_WALLET, totalNeed)
			} else {
				await withdrawFromRedeem(provider, DEPOSIT_WALLET, need)
			}
		} else {
			console.log('SKIP withdraw: deposit wallet already has enough CNET')
		}
	} else {
		console.log('SKIP_WITHDRAW=1: not calling withdrawNative')
	}

	const depositPk = loadDepositPk()
	const signer = new ethers.Wallet(depositPk, provider)
	if (signer.address.toLowerCase() !== DEPOSIT_WALLET.toLowerCase()) {
		throw new Error('deposit signer address mismatch')
	}
	const dep = new ethers.Contract(DEPOSIT_CONTRACT, depositAbi, signer)
	const bal2 = await provider.getBalance(signer.address)
	if (bal2 < need) throw new Error(`deposit wallet still insufficient: ${ethers.formatEther(bal2)} < ${ethers.formatEther(need)}`)

	const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

	for (let i = 0; i < entries.length; i++) {
		const e = entries[i]
		const idx = OFFSET + i
		console.log(`[${idx + 1}/${COUNT}] deposit pubkey ${String(e.pubkey).slice(0, 16)}…`)
		let lastErr
		for (let attempt = 0; attempt < 8; attempt++) {
			try {
				const nonce = await provider.getTransactionCount(signer.address, 'pending')
				const tx = await dep.deposit(
					normalizeHex(e.pubkey),
					normalizeHex(e.withdrawal_credentials),
					normalizeHex(e.signature),
					normalizeHex(e.deposit_data_root),
					{
						value: STAKE,
						gasLimit: 500_000,
						nonce,
						maxFeePerGas: ethers.parseUnits(String(30 + attempt * 10), 'gwei'),
						maxPriorityFeePerGas: ethers.parseUnits(String(2 + attempt), 'gwei'),
					}
				)
				console.log('  tx:', tx.hash, 'nonce', nonce)
				const rc = await tx.wait()
				if (!rc || rc.status !== 1) throw new Error(`deposit reverted block ${rc?.blockNumber}`)
				lastErr = undefined
				break
			} catch (err) {
				lastErr = err
				const msg = String(err?.message ?? err)
				if (!/replacement|underpriced|nonce/i.test(msg) || attempt >= 7) throw err
				console.warn(`  retry ${attempt + 1}/8 after nonce/gas conflict: ${msg.slice(0, 120)}`)
				await sleep(3000 + attempt * 2000)
			}
		}
		if (lastErr) throw lastErr
		await sleep(500)
	}
	console.log(`Done: ${entries.length} beacon deposits (no Redeem guardian ledger).`)
}

main().catch((e) => {
	console.error('DEPOSIT_FAILED:', e?.message ?? e)
	process.exit(1)
})
