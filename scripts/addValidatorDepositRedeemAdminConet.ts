/**
 * Add a redeemAdmin on CoNET ValidatorDepositRedeem (proxy).
 * Redeem admins can createRedeem / createRedeemFor validator tickets.
 *
 * Env:
 *   NEW_REDEEM_ADMIN — address to grant (required unless passed as argv[2])
 *   CONET_RPC_URL — default https://rpc1.conet.network
 *   REDEEM_ADMIN_SIGNER — existing redeemAdmin EOA whose key is in ~/.master.json
 *                         (default 0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1)
 *
 * Usage:
 *   npx tsx scripts/addValidatorDepositRedeemAdminConet.ts 0x82DADaeC25bebB58D6FaD2B91f394Ad10A9b0eE1
 */
import fs from 'fs'
import path from 'path'
import { homedir } from 'os'
import { ethers } from 'ethers'

const RPC = process.env.CONET_RPC_URL || 'https://rpc1.conet.network'
const VDR =
	process.env.CONET_VALIDATOR_DEPOSIT_REDEEM || '0xc71e246DD78B37C2fABc905D340932F28F503433'
const DEFAULT_SIGNER = '0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1'

const ABI = [
	'function redeemAdmins(address) view returns (bool)',
	'function addRedeemAdmin(address account)',
	'event RedeemAdminAdded(address indexed account)',
] as const

function loadSignerKey(wanted: string): string {
	const masterPath = path.join(homedir(), '.master.json')
	const master = JSON.parse(fs.readFileSync(masterPath, 'utf-8')) as {
		settle_contractAdmin?: string[]
		beamio_Admins?: string[]
	}
	const keys = [...(master.settle_contractAdmin ?? []), ...(master.beamio_Admins ?? [])]
	const want = wanted.toLowerCase()
	for (const raw of keys) {
		const key = raw.startsWith('0x') ? raw : `0x${raw}`
		try {
			if (new ethers.Wallet(key).address.toLowerCase() === want) return key
		} catch {
			/* skip */
		}
	}
	throw new Error(`Signer key for ${wanted} not found in ~/.master.json`)
}

async function main() {
	const rawNew = process.env.NEW_REDEEM_ADMIN || process.argv[2]
	if (!rawNew || !ethers.isAddress(rawNew)) {
		throw new Error('Pass NEW_REDEEM_ADMIN or argv address')
	}
	const newAdmin = ethers.getAddress(rawNew)
	const signerAddr = ethers.getAddress(process.env.REDEEM_ADMIN_SIGNER || DEFAULT_SIGNER)

	const provider = new ethers.JsonRpcProvider(RPC, 224422)
	const wallet = new ethers.Wallet(loadSignerKey(signerAddr), provider)
	if (wallet.address.toLowerCase() !== signerAddr.toLowerCase()) {
		throw new Error('wallet address mismatch')
	}

	const vdr = new ethers.Contract(VDR, ABI, wallet)
	const signerIsAdmin = Boolean(await vdr.redeemAdmins!(signerAddr))
	if (!signerIsAdmin) throw new Error(`signer ${signerAddr} is not redeemAdmin`)

	const already = Boolean(await vdr.redeemAdmins!(newAdmin))
	if (already) {
		console.log('Already redeemAdmin:', newAdmin)
		console.log(`https://mainnet.conet.network/address/${VDR}`)
		return
	}

	const bal = await provider.getBalance(wallet.address)
	console.log('VDR', VDR)
	console.log('signer', wallet.address, 'balance', ethers.formatEther(bal), 'CNET')
	console.log('addRedeemAdmin', newAdmin)

	const tx = await vdr.addRedeemAdmin!(newAdmin)
	console.log('tx', tx.hash)
	const receipt = await tx.wait()
	if (!receipt || receipt.status !== 1) throw new Error(`tx failed ${tx.hash}`)

	const ok = Boolean(await vdr.redeemAdmins!(newAdmin))
	if (!ok) throw new Error('post-check redeemAdmins == false')
	console.log('✅ redeemAdmins =', ok)
	console.log(`https://mainnet.conet.network/tx/${tx.hash}`)
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
