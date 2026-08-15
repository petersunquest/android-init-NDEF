/**
 * Deploy ReferralPurchaseSplitV1 (UUPS) on CoNET and wire BUnitAirdropV2.purchaseSplit.
 *
 *   npm run compile
 *   npx tsx scripts/deployReferralPurchaseSplitConet.ts
 *
 * Env:
 *   DRY_RUN=1 — skip txs
 *   SKIP_AIRDROP_UPGRADE=1 — deploy split only
 *   REFERRAL_SPLIT_ADMIN_PAYOUT — default owner 0x87cAeD…
 */

import fs from 'fs'
import path from 'path'
import { homedir } from 'os'
import { ethers } from 'ethers'

const RPC = process.env.CONET_RPC_URL || 'https://rpc1.conet.network'
const CHAIN_ID = 224422
const OWNER = '0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1'
const AIRDROP_PROXY = '0x305f90A7f38289219BA1b4be98CB5b47e7b15Ac2'
const VAULT = '0xD6252Cbf266B80231397Ac2a4f25ed2d9b01DEE6'
const CONET_USDC = '0x5209865D404aA5646eDe5B91CD4218909eA72eDA'
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
		throw new Error(`Missing artifact ${rel} — run: npm run compile`)
	}
	return JSON.parse(fs.readFileSync(artifactPath, 'utf-8')) as {
		abi: ethers.InterfaceAbi
		bytecode: string
	}
}

async function main() {
	if (process.env.DRY_RUN === '1') {
		console.log('DRY_RUN=1 — skip deploy')
		return
	}

	const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID)
	const wallet = new ethers.Wallet(loadOwnerKey(), provider)
	const net = await provider.getNetwork()
	if (Number(net.chainId) !== CHAIN_ID) throw new Error(`Unexpected chainId ${net.chainId}`)
	const adminPayout = process.env.REFERRAL_SPLIT_ADMIN_PAYOUT || OWNER

	console.log('deployer', wallet.address)
	console.log('rpc', RPC)
	console.log('adminPayout', adminPayout)
	console.log('balance', ethers.formatEther(await provider.getBalance(wallet.address)), 'CNET')

	const splitArt = loadArtifact('artifacts/src/mainnet/ReferralPurchaseSplitV1.sol/ReferralPurchaseSplitV1.json')
	const proxyArt = loadArtifact(
		'artifacts/src/mainnet/ReferralPurchaseSplitV1Proxy.sol/ReferralPurchaseSplitV1Proxy.json',
	)
	const airdropArt = loadArtifact('artifacts/src/b-unit/BUnitAirdropV2.sol/BUnitAirdropV2.json')

	const splitFactory = new ethers.ContractFactory(splitArt.abi, splitArt.bytecode, wallet)
	console.log('[1] deploying ReferralPurchaseSplitV1 impl…')
	const splitImpl = await splitFactory.deploy()
	await splitImpl.waitForDeployment()
	const splitImplAddr = await splitImpl.getAddress()
	console.log('splitImpl', splitImplAddr)

	const initData = splitFactory.interface.encodeFunctionData('initialize', [
		OWNER,
		CONET_USDC,
		VAULT,
		AIRDROP_PROXY,
		adminPayout,
	])
	const proxyFactory = new ethers.ContractFactory(proxyArt.abi, proxyArt.bytecode, wallet)
	console.log('[2] deploying ReferralPurchaseSplitV1 proxy…')
	const proxy = await proxyFactory.deploy(splitImplAddr, initData)
	await proxy.waitForDeployment()
	const splitProxyAddr = await proxy.getAddress()
	console.log('splitProxy', splitProxyAddr)

	const split = new ethers.Contract(
		splitProxyAddr,
		[
			'function adminPayout() view returns (address)',
			'function adminBps() view returns (uint256)',
			'function airdrop() view returns (address)',
			'function vault() view returns (address)',
		],
		provider,
	)
	console.log('[3] adminPayout', await split.adminPayout(), 'adminBps', (await split.adminBps()).toString())
	console.log('    airdrop', await split.airdrop(), 'vault', await split.vault())

	let airdropImplAddr: string | null = null
	let upgradeTxHash: string | null = null
	let setSplitTxHash: string | null = null
	const beforeSlot = await provider.getStorage(AIRDROP_PROXY, EIP1967_IMPL_SLOT)
	const beforeAirdropImpl = ethers.getAddress('0x' + beforeSlot.slice(-40))
	console.log('airdrop currentImpl', beforeAirdropImpl)

	if (process.env.SKIP_AIRDROP_UPGRADE !== '1') {
		const airdropProxy = new ethers.Contract(
			AIRDROP_PROXY,
			[
				'function owner() view returns (address)',
				'function upgradeToAndCall(address,bytes)',
				'function setPurchaseSplit(address)',
				'function purchaseSplit() view returns (address)',
			],
			wallet,
		)
		const airdropOwner = await airdropProxy.owner()
		if (ethers.getAddress(airdropOwner) !== wallet.address) {
			throw new Error(`Signer ${wallet.address} is not airdrop owner ${airdropOwner}`)
		}
		const airdropFactory = new ethers.ContractFactory(airdropArt.abi, airdropArt.bytecode, wallet)
		console.log('[4] deploying BUnitAirdropV2 impl…')
		const airdropImpl = await airdropFactory.deploy()
		await airdropImpl.waitForDeployment()
		airdropImplAddr = await airdropImpl.getAddress()
		console.log('airdropImpl', airdropImplAddr)

		const upgradeTx = await airdropProxy.upgradeToAndCall(airdropImplAddr, '0x')
		upgradeTxHash = upgradeTx.hash
		const upgradeRc = await upgradeTx.wait()
		if (upgradeRc?.status !== 1) throw new Error('airdrop upgradeToAndCall failed')
		console.log('[5] airdrop upgraded', upgradeTx.hash)

		const setTx = await airdropProxy.setPurchaseSplit(splitProxyAddr)
		setSplitTxHash = setTx.hash
		const setRc = await setTx.wait()
		if (setRc?.status !== 1) throw new Error('setPurchaseSplit failed')
		console.log('[6] purchaseSplit', await airdropProxy.purchaseSplit(), setTx.hash)
	}

	const deployBlock = await provider.getBlockNumber()
	const out = {
		network: 'conet',
		chainId: '224422',
		deployer: wallet.address,
		timestamp: new Date().toISOString(),
		deployBlock,
		implementation: splitImplAddr,
		proxy: splitProxyAddr,
		initializeArgs: {
			owner: OWNER,
			conetUsdc: CONET_USDC,
			vault: VAULT,
			airdrop: AIRDROP_PROXY,
			adminPayout,
		},
		airdropProxy: AIRDROP_PROXY,
		airdropPreviousImplementation: beforeAirdropImpl,
		airdropImplementation: airdropImplAddr,
		upgradeTx: upgradeTxHash,
		setPurchaseSplitTx: setSplitTxHash,
		nextSteps: {
			exportFull: 'node scripts/exportStandardJsonFromBuildInfo.mjs ReferralPurchaseSplitV1 --full',
			verify: 'npx tsx scripts/verifyReferralPurchaseSplitConet.ts',
		},
	}
	const outPath = path.join(process.cwd(), 'deployments/conet-ReferralPurchaseSplitV1.json')
	fs.mkdirSync(path.dirname(outPath), { recursive: true })
	fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + '\n')
	console.log('saved', outPath)

	const addressesPath = path.join(process.cwd(), 'deployments/conet-addresses.json')
	const addresses = fs.existsSync(addressesPath)
		? (JSON.parse(fs.readFileSync(addressesPath, 'utf-8')) as Record<string, unknown>)
		: {}
	addresses.ReferralPurchaseSplitV1 = splitProxyAddr
	addresses.ReferralPurchaseSplitV1Impl = splitImplAddr
	if (airdropImplAddr) addresses.BUnitAirdropV2Impl = airdropImplAddr
	addresses.BUnitAirdropV2 = AIRDROP_PROXY
	fs.writeFileSync(addressesPath, JSON.stringify(addresses, null, 2) + '\n')
	console.log('updated', addressesPath)
	console.log('\nExplorer proxy:', `https://mainnet.conet.network/address/${splitProxyAddr}`)
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
