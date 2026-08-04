#!/usr/bin/env node
/**
 * Diagnose CoNET L1 node CNET income for a validator BLS pubkey.
 * Usage: node scripts/diagValidatorCnetIncome.mjs <pubkey-hex>
 */
import { ethers } from 'ethers'

const REDEEM = '0xc71e246DD78B37C2fABc905D340932F28F503433'
const RPC = process.env.CONET_RPC ?? 'https://rpc1.conet.network'
const LOG_CHUNK = 4999

const rawArg = String(process.argv[2] ?? '').trim()
const PUBKEY_HEX = rawArg.toLowerCase().replace(/^0x/, '')
if (!/^[0-9a-f]{96}$/.test(PUBKEY_HEX)) {
	console.error('Expected 48-byte BLS pubkey hex (96 chars). Got length', PUBKEY_HEX.length)
	process.exit(1)
}

const provider = new ethers.JsonRpcProvider(RPC)
const ABI = [
	'function resolveNodeBundle(address maybeWallet, string conetDepinNodeIp) view returns (tuple(address beneficiary, uint256[] guardianNodeIds, string[] depinNodeIps, address[] nodeWallets, bytes[] validatorPubkeys, bool[] validatorActive, uint256 validatorNodeCount, uint256 gbMiningNodeCount, uint256 claimCount, uint256 nativeBalance, uint256 gbBalance, uint256 usdcBalance))',
	'function resolveUnifiedIncomeStats(address maybeWallet, string conetDepinNodeIp, uint256 anchorTs) view returns (tuple(address beneficiary, tuple(uint256,uint256,uint256,uint256,uint256,uint256) gbBeneficiary, tuple(uint256,uint256,uint256,uint256,uint256,uint256) cnetBeneficiary, tuple(address nodeWallet, string depinNodeIp, tuple(uint256,uint256,uint256,uint256,uint256,uint256) gb, tuple(uint256,uint256,uint256,uint256,uint256,uint256) cnet)[] nodes))',
	'function clRewardPaid(address beneficiary) view returns (uint256)',
	'function guardianIdBeneficiary(uint256 guardianId) view returns (address)',
	'event NodeRewardSettled(uint256 indexed guardianId, address indexed beneficiary, uint256 amount, bytes32 indexed eventKey)',
]
const redeem = new ethers.Contract(REDEEM, ABI, provider)

function normPk(pk) {
	if (!pk) return ''
	return ethers.hexlify(pk).toLowerCase().replace(/^0x/, '')
}

async function queryLogsChunked(beneficiary) {
	const filter = redeem.filters.NodeRewardSettled(null, beneficiary)
	const latest = await provider.getBlockNumber()
	const out = new Map()
	let total = 0
	for (let from = 0; from <= latest; from += LOG_CHUNK) {
		const to = Math.min(from + LOG_CHUNK, latest)
		const logs = await redeem.queryFilter(filter, from, to)
		total += logs.length
		for (const log of logs) {
			const gid = Number(log.args.guardianId)
			const amt = BigInt(log.args.amount)
			out.set(gid, (out.get(gid) ?? 0n) + amt)
		}
	}
	return { out, total, latest }
}

async function findBeneficiaryByPubkey(maxGuardianId = 12000) {
	const seen = new Set()
	for (let gid = 1; gid <= maxGuardianId; gid++) {
		let ben
		try {
			ben = await redeem.guardianIdBeneficiary(gid)
		} catch {
			continue
		}
		if (!ben || ben === ethers.ZeroAddress) continue
		const key = ben.toLowerCase()
		if (seen.has(key)) continue
		seen.add(key)
		const bundle = await redeem.resolveNodeBundle(ben, '')
		const idx = bundle.validatorPubkeys.findIndex((pk) => normPk(pk) === PUBKEY_HEX)
		if (idx >= 0) {
			return {
				ben,
				guardianId: Number(bundle.guardianNodeIds[idx]),
				idx,
				bundle,
			}
		}
		if (gid % 1000 === 0) {
			console.log(`  scanned guardianId ≤ ${gid}, unique beneficiaries ${seen.size}`)
		}
	}
	return null
}

async function main() {
	console.log('RPC:', RPC)
	console.log('Pubkey:', '0x' + PUBKEY_HEX)

	try {
		await redeem.queryFilter(redeem.filters.NodeRewardSettled(), 0, 'latest')
		console.log('full-range eth_getLogs (0..latest): OK')
	} catch (e) {
		console.log('full-range eth_getLogs (0..latest): FAIL —', e.message?.slice(0, 180))
	}

	console.log('Searching guardianIdBeneficiary for pubkey owner...')
	const hit = await findBeneficiaryByPubkey()
	if (!hit) {
		console.log('Pubkey not found in guardianIdBeneficiary scan (increase max?)')
		return
	}

	const { ben, guardianId, idx, bundle } = hit
	console.log('\n=== Owner ===')
	console.log('beneficiary:', ben)
	console.log('guardianId:', guardianId)
	console.log('depinIp:', bundle.depinNodeIps[idx])
	console.log('nodeWallet:', bundle.nodeWallets[idx])
	console.log('validatorActive:', bundle.validatorActive[idx])

	const clPaid = await redeem.clRewardPaid(ben)
	console.log('\n=== On-chain CL ===')
	console.log('clRewardPaid(beneficiary):', ethers.formatEther(clPaid), 'CNET')

	const stats = await redeem.resolveUnifiedIncomeStats(ben, '', 0n).catch(() => null)
	if (stats) {
		const row = stats.nodes[idx]
		console.log('\n=== Indexer (ValidatorNodeRewardIndexer) ===')
		console.log('beneficiary cumulative:', ethers.formatEther(stats.cnetBeneficiary[0]), 'CNET')
		if (row) {
			console.log(`node[${idx}] indexer cumulative:`, ethers.formatEther(row.cnet[0]), 'CNET')
		}
	}

	console.log('\n=== NodeRewardSettled (chunked eth_getLogs) ===')
	const { out, total, latest } = await queryLogsChunked(ben)
	console.log('events through block', latest, ':', total)
	for (const [gid, wei] of [...out.entries()].sort((a, b) => a[0] - b[0])) {
		console.log(`  guardianId ${gid}: ${ethers.formatEther(wei)} CNET`)
	}
	const nodeCl = out.get(guardianId)
	console.log(
		`this node (guardianId ${guardianId}):`,
		nodeCl !== undefined ? `${ethers.formatEther(nodeCl)} CNET` : 'NO events',
	)
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
