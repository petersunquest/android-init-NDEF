/**
 * 将用户在已废弃 BeamioBUnits 上的余额迁移至 canonical CONET_BUint（0x54ac…）。
 * 流程：legacy.consumeFuel(user, total) → canonical.mintReward(user, total)（均须 admin）。
 *
 * 运行:
 *   MIGRATE_BUINT_ACCOUNTS=0x363D8263ac5898ae3b363564F6ED0dD11aA9A61F npx hardhat run scripts/migrateLegacyBuintBalancesToCanonicalConet.ts --network conet
 *
 * 可选:
 *   MIGRATE_BUINT_DRY_RUN=1  只读不写链
 *   MIGRATE_BUINT_ONLY=0xf5484F11b7De647E17aea1089e3CbD6BF15dfC0f  仅迁指定废弃合约
 */

import { network as networkModule } from 'hardhat'
import * as fs from 'fs'
import * as path from 'path'
import { fileURLToPath } from 'url'
import { ethers } from 'ethers'
import { mergeConetAdminPrivateKeysFromMasterFile } from './utils/conetMasterAdmins.js'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

const BUINT_ABI = [
	'function balanceOfAll(address) view returns (uint256 total, uint256 free, uint256 paid)',
	'function consumeFuel(address user, uint256 amount) external returns (uint256 paidBurned)',
	'function mintReward(address to, uint256 amount) external',
	'function admins(address) view returns (bool)',
] as const

function loadAddresses(): {
	canonicalBuint: string
	deprecated: string[]
} {
	const addrPath = path.join(__dirname, '..', 'deployments', 'conet-addresses.json')
	const data = JSON.parse(fs.readFileSync(addrPath, 'utf-8'))
	const canonicalBuint = data.BUint as string
	const deprecated: string[] = Array.isArray(data.DEPRECATED_BUINT) ? data.DEPRECATED_BUINT : []
	const only = process.env.MIGRATE_BUINT_ONLY?.trim()
	if (only && ethers.isAddress(only)) {
		return { canonicalBuint, deprecated: [ethers.getAddress(only)] }
	}
	return { canonicalBuint, deprecated: deprecated.filter((a) => ethers.isAddress(a)).map((a) => ethers.getAddress(a)) }
}

function parseAccounts(): string[] {
	const raw = process.env.MIGRATE_BUINT_ACCOUNTS?.trim()
	if (!raw) {
		throw new Error('Set MIGRATE_BUINT_ACCOUNTS=0x… (comma-separated EOAs)')
	}
	return raw
		.split(',')
		.map((s) => s.trim())
		.filter(Boolean)
		.map((a) => ethers.getAddress(a))
}

async function pickAdminSigner(
	ethersHH: Awaited<ReturnType<typeof networkModule.connect>>['ethers'],
	contractAddr: string
): Promise<ethers.Signer> {
	const pks = mergeConetAdminPrivateKeysFromMasterFile()
	const probe = new ethers.Contract(contractAddr, BUINT_ABI, ethersHH.provider)
	for (const pk of pks) {
		const w = new ethers.Wallet(pk, ethersHH.provider)
		try {
			if (await probe.admins(w.address)) {
				return w
			}
		} catch {
			// continue
		}
	}
	throw new Error(`No admin signer for BUint ${contractAddr}`)
}

async function main() {
	const { ethers: ethersHH } = await networkModule.connect()
	const accounts = parseAccounts()
	const { canonicalBuint, deprecated } = loadAddresses()
	const dryRun = process.env.MIGRATE_BUINT_DRY_RUN === '1'

	console.log('canonical BUint:', canonicalBuint)
	console.log('deprecated sources:', deprecated.length)
	console.log('accounts:', accounts.join(', '))
	console.log('dryRun:', dryRun)

	const canonicalSigner = dryRun ? null : await pickAdminSigner(ethersHH, canonicalBuint)
	const canonicalWrite = canonicalSigner
		? new ethers.Contract(canonicalBuint, BUINT_ABI, canonicalSigner)
		: null

	for (const user of accounts) {
		console.log('\n---', user)
		for (const legAddr of deprecated) {
			if (legAddr.toLowerCase() === canonicalBuint.toLowerCase()) continue
			const legRead = new ethers.Contract(legAddr, BUINT_ABI, ethersHH.provider)
			const [total] = (await legRead.balanceOfAll(user)) as [bigint, bigint, bigint]
			if (total <= 0n) continue
			console.log(`  legacy ${legAddr} total=${total.toString()} (${ethers.formatUnits(total, 6)} B-Unit)`)
			if (dryRun) continue

			const legSigner = await pickAdminSigner(ethersHH, legAddr)
			const legWrite = new ethers.Contract(legAddr, BUINT_ABI, legSigner)
			const burnTx = await legWrite.consumeFuel(user, total)
			await burnTx.wait()
			console.log('    consumeFuel tx:', burnTx.hash)

			const mintTx = await canonicalWrite!.mintReward(user, total)
			await mintTx.wait()
			console.log('    mintReward tx:', mintTx.hash)
		}
	}

	console.log('\nDone.')
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
