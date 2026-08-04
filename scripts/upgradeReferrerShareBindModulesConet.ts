/**
 * Deploy AdminStatsQueryModuleV4 (bindShareRefereeWithSignature on ROUTE_STATS_QUERY)
 * and bind via factory.setAdminStatsQueryModule on CoNET UserCard Factory.
 *
 * Bind lives on AdminStats (not IssuedNft) to stay under EIP-170.
 *
 * Env:
 *   CONET_RPC_URL — default https://rpc1.conet.network
 *   DRY_RUN=1 — deploy only, do not set factory module
 *   SKIP_VERIFY=1 — skip Blockscout verify probe
 *
 * Usage:
 *   npm run compile
 *   npx tsx scripts/upgradeReferrerShareBindModulesConet.ts
 */
import fs from 'fs'
import path from 'path'
import { homedir } from 'os'
import { ethers } from 'ethers'

const CHAIN_ID = 224422
const RPC = process.env.CONET_RPC_URL || 'https://rpc1.conet.network'
const FACTORY =
	process.env.CONET_CARD_FACTORY || '0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB'
const FACTORY_OWNER = '0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1'
const BLOCKSCOUT = process.env.CONET_BLOCKSCOUT_URL || 'https://mainnet.conet.network'
const ROUTE_STATS_QUERY = 254 // type(uint8).max - 1

function loadOwnerKey(): string {
	const masterPath = path.join(homedir(), '.master.json')
	const master = JSON.parse(fs.readFileSync(masterPath, 'utf-8')) as {
		settle_contractAdmin?: string[]
		beamio_Admins?: string[]
	}
	const keys = [...(master.settle_contractAdmin ?? []), ...(master.beamio_Admins ?? [])]
	const wanted = (process.env.FACTORY_OWNER || FACTORY_OWNER).toLowerCase()
	for (const raw of keys) {
		const key = raw.startsWith('0x') ? raw : `0x${raw}`
		try {
			if (new ethers.Wallet(key).address.toLowerCase() === wanted) return key
		} catch {
			/* skip */
		}
	}
	throw new Error(`Factory owner key for ${wanted} not found in ~/.master.json`)
}

function loadArtifact(rel: string): { abi: ethers.InterfaceAbi; bytecode: string } {
	const p = path.join(process.cwd(), 'artifacts', rel)
	const j = JSON.parse(fs.readFileSync(p, 'utf-8')) as {
		abi: ethers.InterfaceAbi
		bytecode: string
	}
	if (!j.bytecode || j.bytecode === '0x') throw new Error(`Missing bytecode: ${rel}`)
	return j
}

async function checkVerified(addr: string): Promise<boolean> {
	const r = await fetch(`${BLOCKSCOUT}/api/v2/smart-contracts/${addr}`)
	if (!r.ok) return false
	const d = (await r.json()) as { is_verified?: boolean; is_partially_verified?: boolean }
	return Boolean(d.is_verified || d.is_partially_verified)
}

async function main(): Promise<void> {
	const provider = new ethers.JsonRpcProvider(RPC)
	const net = await provider.getNetwork()
	if (Number(net.chainId) !== CHAIN_ID) {
		throw new Error(`Wrong chainId ${net.chainId}; expected ${CHAIN_ID}`)
	}

	const wallet = new ethers.Wallet(loadOwnerKey(), provider)
	console.log(`[upgrade] deployer=${wallet.address} factory=${FACTORY}`)

	const adminArt = loadArtifact(
		'src/BeamioUserCard/AdminStatsQueryModuleV4.sol/BeamioUserCardAdminStatsQueryModuleV4.json',
	)
	const runtimeBytes = (adminArt.bytecode.startsWith('0x') ? adminArt.bytecode.slice(2) : adminArt.bytecode)
		.length / 2
	console.log(`[upgrade] AdminStatsQueryModuleV4 create bytecode length≈${runtimeBytes} (EIP-170 limit is deployed size)`)

	const AdminFactory = new ethers.ContractFactory(adminArt.abi, adminArt.bytecode, wallet)

	console.log('[upgrade] deploying AdminStatsQueryModuleV4…')
	const admin = await AdminFactory.deploy()
	await admin.waitForDeployment()
	const adminAddr = await admin.getAddress()
	const deployedCode = await provider.getCode(adminAddr)
	const deployedSize = (deployedCode.length - 2) / 2
	console.log(`[upgrade] AdminStatsQueryModuleV4=${adminAddr} deployedSize=${deployedSize}`)
	if (deployedSize > 24576) {
		throw new Error(`EIP-170 exceeded: deployedSize=${deployedSize}`)
	}

	const bindSel = ethers.id('bindShareRefereeWithSignature(address,address,uint256,bytes32,bytes)').slice(0, 10)
	const adminReader = new ethers.Contract(
		adminAddr,
		['function selectorModuleKind(bytes4) view returns (uint8)'],
		provider,
	)
	const route = Number(await adminReader.selectorModuleKind(bindSel))
	console.log(`[upgrade] bind selector ${bindSel} → route ${route} (expect ${ROUTE_STATS_QUERY}=STATS_QUERY)`)
	if (route !== ROUTE_STATS_QUERY) throw new Error(`Unexpected bind route ${route}`)

	const outPath = path.join(process.cwd(), 'deployments', 'conet-ReferrerShareBindModules.json')
	const snapshot: Record<string, unknown> = {
		network: 'conet',
		chainId: CHAIN_ID,
		timestamp: new Date().toISOString(),
		factory: FACTORY,
		adminStatsQueryModule: adminAddr,
		bindSelector: bindSel,
		bindRoute: ROUTE_STATS_QUERY,
		note: 'bindShareRefereeWithSignature on AdminStats V4 (ROUTE_STATS_QUERY); IssuedNft unchanged',
	}
	fs.writeFileSync(outPath, JSON.stringify(snapshot, null, 2))
	console.log(`[upgrade] wrote ${outPath}`)

	if (process.env.DRY_RUN === '1') {
		console.log('[upgrade] DRY_RUN=1 — skip factory.setAdminStatsQueryModule')
		return
	}

	const factory = new ethers.Contract(
		FACTORY,
		[
			'function setAdminStatsQueryModule(address m) external',
			'function defaultAdminStatsQueryModule() view returns (address)',
		],
		wallet,
	)

	console.log('[upgrade] setAdminStatsQueryModule…')
	await (await factory.setAdminStatsQueryModule(adminAddr)).wait()

	const boundAdmin = await factory.defaultAdminStatsQueryModule()
	console.log(`[upgrade] bound admin=${boundAdmin}`)
	if (String(boundAdmin).toLowerCase() !== adminAddr.toLowerCase()) {
		throw new Error('setAdminStatsQueryModule did not stick')
	}

	snapshot.bound = { adminStatsQueryModule: boundAdmin }
	fs.writeFileSync(outPath, JSON.stringify(snapshot, null, 2))

	if (process.env.SKIP_VERIFY === '1') {
		console.log('[upgrade] SKIP_VERIFY=1')
		return
	}

	const ok = await checkVerified(adminAddr)
	console.log(`[verify] AdminStatsQueryModuleV4 ${adminAddr} verified=${ok}`)
	if (!ok) {
		console.log(
			'  Next: node scripts/exportStandardJsonFromBuildInfo.mjs AdminStatsQueryModuleV4 --full',
		)
	}
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
