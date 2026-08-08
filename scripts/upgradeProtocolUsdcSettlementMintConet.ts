/**
 * Protocol CONET-USDC settlement mint (treasuryBridge / CoNET usdcTopup):
 * 1) Redeploy IssuedNftModuleV2 with mintPointsForProtocolUsdcSettlement
 * 2) Redeploy AdminStatsQueryModuleV4 (inherits V2 selector → ROUTE_ISSUED_NFT)
 * 3) factory.setIssuedNftModule + setAdminStatsQueryModule
 *
 * Usage:
 *   npm run compile
 *   npx tsx scripts/upgradeProtocolUsdcSettlementMintConet.ts
 *
 * Env:
 *   CONET_RPC_URL — default https://rpc1.conet.network
 *   DRY_RUN=1 — deploy only, skip factory setters
 *   SKIP_VERIFY=1 — skip Blockscout verified probe
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
const ROUTE_ISSUED_NFT = 2

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

function loadArtifact(rel: string): {
	abi: ethers.InterfaceAbi
	bytecode: string
} {
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

	const issuedArt = loadArtifact(
		'src/BeamioUserCard/IssuedNftModuleV2.sol/BeamioUserCardIssuedNftModuleV2.json',
	)
	const IssuedFactory = new ethers.ContractFactory(issuedArt.abi, issuedArt.bytecode, wallet)
	console.log('[upgrade] deploying IssuedNftModuleV2…')
	const issued = await IssuedFactory.deploy()
	await issued.waitForDeployment()
	const issuedAddr = await issued.getAddress()
	const issuedCode = await provider.getCode(issuedAddr)
	const issuedSize = (issuedCode.length - 2) / 2
	console.log(`[upgrade] IssuedNftModuleV2=${issuedAddr} deployedSize=${issuedSize}`)
	if (issuedSize > 24576) throw new Error(`EIP-170 exceeded IssuedNft: ${issuedSize}`)

	const adminArt = loadArtifact(
		'src/BeamioUserCard/AdminStatsQueryModuleV4.sol/BeamioUserCardAdminStatsQueryModuleV4.json',
	)
	const AdminFactory = new ethers.ContractFactory(adminArt.abi, adminArt.bytecode, wallet)
	console.log('[upgrade] deploying AdminStatsQueryModuleV4…')
	const admin = await AdminFactory.deploy()
	await admin.waitForDeployment()
	const adminAddr = await admin.getAddress()
	const adminCode = await provider.getCode(adminAddr)
	const adminSize = (adminCode.length - 2) / 2
	console.log(`[upgrade] AdminStatsQueryModuleV4=${adminAddr} deployedSize=${adminSize}`)
	if (adminSize > 24576) throw new Error(`EIP-170 exceeded AdminStats: ${adminSize}`)

	const adminReader = new ethers.Contract(
		adminAddr,
		['function selectorModuleKind(bytes4) view returns (uint8)'],
		provider,
	)
	const mintSel = ethers.id('mintPointsForProtocolUsdcSettlement(address,uint256)').slice(0, 10)
	const likeSel = ethers
		.id('applyUserLikeWithSignature(address,uint8,uint256,bool,uint256,bytes32,bytes)')
		.slice(0, 10)
	for (const [sig, sel] of [
		['mintPointsForProtocolUsdcSettlement(address,uint256)', mintSel],
		['applyUserLikeWithSignature(address,uint8,uint256,bool,uint256,bytes32,bytes)', likeSel],
	] as const) {
		const route = Number(await adminReader.selectorModuleKind(sel))
		console.log(`[upgrade] ${sig} ${sel} → route ${route}`)
		if (route !== ROUTE_ISSUED_NFT) throw new Error(`Unexpected route for ${sig}: ${route}`)
	}

	const factoryReader = new ethers.Contract(
		FACTORY,
		[
			'function defaultIssuedNftModule() view returns (address)',
			'function defaultAdminStatsQueryModule() view returns (address)',
			'function setIssuedNftModule(address m) external',
			'function setAdminStatsQueryModule(address m) external',
		],
		provider,
	)
	const oldIssued = (await factoryReader.defaultIssuedNftModule()) as string
	const oldAdmin = (await factoryReader.defaultAdminStatsQueryModule()) as string
	console.log(`[upgrade] replacing IssuedNft ${oldIssued} → ${issuedAddr}`)
	console.log(`[upgrade] replacing AdminStats ${oldAdmin} → ${adminAddr}`)

	const outPath = path.join(process.cwd(), 'deployments', 'conet-ProtocolUsdcSettlementMint.json')
	const snapshot: Record<string, unknown> = {
		network: 'conet',
		chainId: CHAIN_ID,
		timestamp: new Date().toISOString(),
		factory: FACTORY,
		signer: wallet.address,
		replaced: {
			issuedNftModule: oldIssued,
			adminStatsQueryModule: oldAdmin,
		},
		modules: {
			issuedNftModule: issuedAddr,
			adminStatsQueryModule: adminAddr,
		},
		note:
			'mintPointsForProtocolUsdcSettlement via IssuedNftModule (Factory owner/paymaster); gateway USDC accounting, not admin airdrop.',
	}
	fs.writeFileSync(outPath, JSON.stringify(snapshot, null, 2))
	console.log(`[upgrade] wrote ${outPath}`)

	if (process.env.DRY_RUN === '1') {
		console.log('[upgrade] DRY_RUN=1 — skip factory setters')
		return
	}

	const factory = factoryReader.connect(wallet) as ethers.Contract
	const tx1 = await factory.setIssuedNftModule(issuedAddr)
	console.log(`[upgrade] setIssuedNftModule tx=${tx1.hash}`)
	await tx1.wait()
	const tx2 = await factory.setAdminStatsQueryModule(adminAddr)
	console.log(`[upgrade] setAdminStatsQueryModule tx=${tx2.hash}`)
	await tx2.wait()

	const nowIssued = (await factoryReader.defaultIssuedNftModule()) as string
	const nowAdmin = (await factoryReader.defaultAdminStatsQueryModule()) as string
	if (ethers.getAddress(nowIssued) !== ethers.getAddress(issuedAddr)) {
		throw new Error(`Factory issued module mismatch: ${nowIssued}`)
	}
	if (ethers.getAddress(nowAdmin) !== ethers.getAddress(adminAddr)) {
		throw new Error(`Factory admin module mismatch: ${nowAdmin}`)
	}
	console.log('[upgrade] factory defaults updated')

	;(snapshot as { bound?: unknown }).bound = {
		issuedNftModule: nowIssued,
		adminStatsQueryModule: nowAdmin,
		setIssuedNftModuleTx: tx1.hash,
		setAdminStatsQueryModuleTx: tx2.hash,
	}
	fs.writeFileSync(outPath, JSON.stringify(snapshot, null, 2))

	const modulesPath = path.join(process.cwd(), 'deployments', 'conet-UserCardModules.json')
	if (fs.existsSync(modulesPath)) {
		const modulesJson = JSON.parse(fs.readFileSync(modulesPath, 'utf-8')) as Record<string, unknown>
		const modules = (modulesJson.modules as Record<string, string>) || {}
		modules.issuedNftModule = issuedAddr
		modules.adminStatsQueryModule = adminAddr
		modulesJson.modules = modules
		modulesJson.protocolUsdcSettlementMintUpgrade = {
			timestamp: new Date().toISOString(),
			issuedNftModule: issuedAddr,
			adminStatsQueryModule: adminAddr,
			replaced: { issuedNftModule: oldIssued, adminStatsQueryModule: oldAdmin },
			note: 'mintPointsForProtocolUsdcSettlement gateway mint',
		}
		fs.writeFileSync(modulesPath, JSON.stringify(modulesJson, null, 2) + '\n')
		console.log(`[upgrade] updated ${modulesPath}`)
	}

	if (process.env.SKIP_VERIFY === '1') {
		console.log('[upgrade] SKIP_VERIFY=1')
		console.log(
			`Next: export FULL JSON + npx tsx scripts/verifyProtocolUsdcSettlementMintConet.ts`,
		)
		return
	}

	for (const [label, addr] of [
		['IssuedNftModuleV2', issuedAddr],
		['AdminStatsQueryModuleV4', adminAddr],
	] as const) {
		let ok = false
		for (let i = 0; i < 6; i++) {
			ok = await checkVerified(addr)
			if (ok) break
			await new Promise((r) => setTimeout(r, 5000))
		}
		console.log(`[upgrade] Blockscout ${label} ${addr} verified=${ok} (run verify script if false)`)
	}

	console.log('[upgrade] done')
	console.log(`  IssuedNftModuleV2=${issuedAddr}`)
	console.log(`  AdminStatsQueryModuleV4=${adminAddr}`)
	console.log('  Verify: npx tsx scripts/verifyProtocolUsdcSettlementMintConet.ts')
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
