/**
 * Upgrade BUnitAirdropV2 proxy with usedUsdcPurchaseHash (Stripe / off-chain payment reuse guard).
 *
 *   npm run clean && npm run compile
 *   npx tsx scripts/upgradeBUnitAirdropV2UsdcPurchaseHashConet.ts
 *
 * Env:
 *   DRY_RUN=1 — skip txs
 *   SKIP_VERIFY=1 — skip Blockscout verify (forbidden unless user authorized)
 */

import fs from 'fs'
import path from 'path'
import { homedir } from 'os'
import { ethers } from 'ethers'
import { spawnSync } from 'child_process'

const RPC = process.env.CONET_RPC_URL || 'https://rpc1.conet.network'
const CHAIN_ID = 224422
const OWNER = '0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1'
const AIRDROP_PROXY = '0x305f90A7f38289219BA1b4be98CB5b47e7b15Ac2'
const EIP1967_IMPL_SLOT =
	'0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'

function loadOwnerKey(): string {
	const masterPath = path.join(homedir(), '.master.json')
	const master = JSON.parse(fs.readFileSync(masterPath, 'utf-8')) as {
		settle_contractAdmin?: string[]
		beamio_Admins?: string[]
	}
	const keys = [...(master.settle_contractAdmin ?? []), ...(master.beamio_Admins ?? [])]
	const ownerWanted = OWNER.toLowerCase()
	for (const raw of keys) {
		const key = raw.startsWith('0x') ? raw : `0x${raw}`
		try {
			if (new ethers.Wallet(key).address.toLowerCase() === ownerWanted) return key
		} catch {
			/* skip */
		}
	}
	throw new Error('Owner key for 0x87cAeD… not found in ~/.master.json')
}

function loadArtifact(rel: string): { abi: ethers.InterfaceAbi; bytecode: string } {
	const artifactPath = path.join(process.cwd(), rel)
	if (!fs.existsSync(artifactPath)) {
		throw new Error(`Missing artifact ${rel} — run: npm run clean && npm run compile`)
	}
	return JSON.parse(fs.readFileSync(artifactPath, 'utf-8')) as {
		abi: ethers.InterfaceAbi
		bytecode: string
	}
}

async function main() {
	if (process.env.DRY_RUN === '1') {
		console.log('DRY_RUN=1 — skip upgrade')
		return
	}

	const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID)
	const wallet = new ethers.Wallet(loadOwnerKey(), provider)
	const net = await provider.getNetwork()
	if (Number(net.chainId) !== CHAIN_ID) throw new Error(`Unexpected chainId ${net.chainId}`)

	console.log('deployer', wallet.address)
	console.log('rpc', RPC)
	console.log('proxy', AIRDROP_PROXY)
	console.log('balance', ethers.formatEther(await provider.getBalance(wallet.address)), 'CNET')

	const beforeSlot = await provider.getStorage(AIRDROP_PROXY, EIP1967_IMPL_SLOT)
	const beforeImpl = ethers.getAddress('0x' + beforeSlot.slice(-40))
	console.log('currentImpl', beforeImpl)

	const airdropArt = loadArtifact('artifacts/src/b-unit/BUnitAirdropV2.sol/BUnitAirdropV2.json')
	const airdropProxy = new ethers.Contract(
		AIRDROP_PROXY,
		[
			'function owner() view returns (address)',
			'function upgradeToAndCall(address,bytes)',
			'function purchaseSplit() view returns (address)',
			'function usedUsdcPurchaseHash(bytes32) view returns (bool)',
		],
		wallet,
	)
	const airdropOwner = await airdropProxy.owner()
	if (ethers.getAddress(airdropOwner) !== wallet.address) {
		throw new Error(`Signer ${wallet.address} is not airdrop owner ${airdropOwner}`)
	}

	const airdropFactory = new ethers.ContractFactory(airdropArt.abi, airdropArt.bytecode, wallet)
	console.log('[1] deploying BUnitAirdropV2 impl…')
	const airdropImpl = await airdropFactory.deploy()
	await airdropImpl.waitForDeployment()
	const airdropImplAddr = await airdropImpl.getAddress()
	console.log('newImpl', airdropImplAddr)

	console.log('[2] upgradeToAndCall…')
	const upgradeTx = await airdropProxy.upgradeToAndCall(airdropImplAddr, '0x')
	const upgradeRc = await upgradeTx.wait()
	if (upgradeRc?.status !== 1) throw new Error('upgradeToAndCall failed')
	console.log('upgradeTx', upgradeTx.hash)

	const afterSlot = await provider.getStorage(AIRDROP_PROXY, EIP1967_IMPL_SLOT)
	const afterImpl = ethers.getAddress('0x' + afterSlot.slice(-40))
	if (afterImpl.toLowerCase() !== airdropImplAddr.toLowerCase()) {
		throw new Error(`impl slot mismatch: want ${airdropImplAddr} got ${afterImpl}`)
	}

	// Smoke: usedUsdcPurchaseHash view exists (zero hash → false)
	const zeroUsed = await airdropProxy.usedUsdcPurchaseHash(ethers.ZeroHash)
	if (zeroUsed !== false) throw new Error('usedUsdcPurchaseHash(0) unexpected')
	console.log('[3] usedUsdcPurchaseHash view ok; purchaseSplit', await airdropProxy.purchaseSplit())

	const deployBlock = await provider.getBlockNumber()
	const out = {
		network: 'conet',
		chainId: '224422',
		deployer: wallet.address,
		timestamp: new Date().toISOString(),
		deployBlock,
		proxy: AIRDROP_PROXY,
		previousImplementation: beforeImpl,
		implementation: airdropImplAddr,
		upgradeTx: upgradeTx.hash,
		feature: 'usedUsdcPurchaseHash — one-time Stripe / off-chain payment hash for mintForUsdcPurchase',
		nextSteps: {
			exportFull: 'node scripts/exportStandardJsonFromBuildInfo.mjs BUnitAirdropV2 --full',
			verify: 'npx tsx scripts/verifyReferralPurchaseSplitConet.ts',
		},
	}
	const outPath = path.join(process.cwd(), 'deployments/conet-BUnitAirdropV2-usedUsdcPurchaseHash.json')
	fs.mkdirSync(path.dirname(outPath), { recursive: true })
	fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + '\n')
	console.log('saved', outPath)

	const addressesPath = path.join(process.cwd(), 'deployments/conet-addresses.json')
	const addresses = fs.existsSync(addressesPath)
		? (JSON.parse(fs.readFileSync(addressesPath, 'utf-8')) as Record<string, unknown>)
		: {}
	addresses.BUnitAirdropV2Impl = airdropImplAddr
	addresses.BUnitAirdropV2 = AIRDROP_PROXY
	fs.writeFileSync(addressesPath, JSON.stringify(addresses, null, 2) + '\n')
	console.log('updated', addressesPath)

	// Keep ReferralPurchaseSplit deploy snapshot in sync so verifyReferralPurchaseSplitConet can verify airdropImpl.
	const splitSnapPath = path.join(process.cwd(), 'deployments/conet-ReferralPurchaseSplitV1.json')
	if (fs.existsSync(splitSnapPath)) {
		const splitSnap = JSON.parse(fs.readFileSync(splitSnapPath, 'utf-8')) as Record<string, unknown>
		splitSnap.airdropPreviousImplementation = beforeImpl
		splitSnap.airdropImplementation = airdropImplAddr
		splitSnap.upgradeTx = upgradeTx.hash
		splitSnap.airdropUsedUsdcPurchaseHashUpgradeAt = out.timestamp
		fs.writeFileSync(splitSnapPath, JSON.stringify(splitSnap, null, 2) + '\n')
		console.log('patched', splitSnapPath, 'airdropImplementation')
	}

	if (process.env.SKIP_VERIFY === '1') {
		console.log(ColorsYellow('SKIP_VERIFY=1 — Blockscout verify skipped (must complete in same task)'))
		return
	}

	console.log('[4] export Standard JSON + verify airdropImpl…')
	const exportRc = spawnSync(
		'node',
		['scripts/exportStandardJsonFromBuildInfo.mjs', 'BUnitAirdropV2', '--full'],
		{ cwd: process.cwd(), stdio: 'inherit' },
	)
	if (exportRc.status !== 0) throw new Error('exportStandardJsonFromBuildInfo failed')

	const verifyRc = spawnSync('npx', ['tsx', 'scripts/verifyBUnitAirdropV2ImplConet.ts'], {
		cwd: process.cwd(),
		stdio: 'inherit',
		env: {
			...process.env,
			BUNIT_AIRDROP_V2_IMPL: airdropImplAddr,
			CONET_VERIFY_POLL_MAX: process.env.CONET_VERIFY_POLL_MAX || '180',
		},
	})
	if (verifyRc.status !== 0) {
		throw new Error('verifyBUnitAirdropV2ImplConet failed — fix and re-verify before claiming done')
	}

	console.log('\nExplorer proxy:', `https://mainnet.conet.network/address/${AIRDROP_PROXY}`)
	console.log('Explorer impl:', `https://mainnet.conet.network/address/${airdropImplAddr}`)
}

function ColorsYellow(s: string): string {
	return `\x1b[33m${s}\x1b[0m`
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
