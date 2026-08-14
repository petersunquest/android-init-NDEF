/**
 * Deploy MembershipFeeOpsLib + MembershipStatsModule (fee-aware issue) +
 * AdminStatsQueryModuleV5 (fee config / stage) and bind on CoNET UserCard Factory.
 *
 * Env:
 *   CONET_RPC_URL — default https://rpc1.conet.network
 *   DRY_RUN=1 — deploy only, do not set factory modules
 *   SKIP_VERIFY=1 — skip Blockscout verify probe
 *
 * Usage:
 *   npm run compile
 *   npx tsx scripts/upgradeMembershipFeeModulesConet.ts
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
const ROUTE_STATS_QUERY = 254

type ArtifactJson = {
	abi: ethers.InterfaceAbi
	bytecode: string
	linkReferences?: Record<string, Record<string, Array<{ start: number; length: number }>>>
}

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

function loadArtifact(rel: string): ArtifactJson {
	const p = path.join(process.cwd(), 'artifacts', rel)
	const j = JSON.parse(fs.readFileSync(p, 'utf-8')) as ArtifactJson
	if (!j.bytecode || j.bytecode === '0x') throw new Error(`Missing bytecode: ${rel}`)
	return j
}

function linkLibrary(
	bytecode: string,
	linkReferences: ArtifactJson['linkReferences'],
	libraries: Record<string, string>,
): string {
	let bc = bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode
	for (const file of Object.keys(linkReferences || {})) {
		for (const libName of Object.keys(linkReferences![file])) {
			const addr = libraries[`${file}:${libName}`] || libraries[libName]
			if (!addr) throw new Error(`Missing link for ${file}:${libName}`)
			const clean = addr.toLowerCase().replace(/^0x/, '')
			if (clean.length !== 40) throw new Error(`Bad library address ${addr}`)
			for (const { start, length } of linkReferences![file][libName]) {
				if (length !== 20) throw new Error(`Unexpected link length ${length}`)
				bc = bc.slice(0, start * 2) + clean + bc.slice((start + length) * 2)
			}
		}
	}
	if (bc.includes('_')) throw new Error('Unlinked placeholders remain in bytecode')
	return `0x${bc}`
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

	const membershipArt = loadArtifact(
		'src/BeamioUserCard/MembershipStatsModule.sol/BeamioUserCardMembershipStatsModuleV1.json',
	)
	const adminArt = loadArtifact(
		'src/BeamioUserCard/AdminStatsQueryModuleV5.sol/BeamioUserCardAdminStatsQueryModuleV5.json',
	)
	const libArt = loadArtifact('src/BeamioUserCard/MembershipFeeOpsLib.sol/MembershipFeeOpsLib.json')

	console.log('[upgrade] deploying MembershipFeeOpsLib…')
	const feeLib = await new ethers.ContractFactory(libArt.abi, libArt.bytecode, wallet).deploy()
	await feeLib.waitForDeployment()
	const feeLibAddr = await feeLib.getAddress()
	console.log(`[upgrade] MembershipFeeOpsLib=${feeLibAddr}`)

	const linkedBytecode = linkLibrary(adminArt.bytecode, adminArt.linkReferences, {
		'project/src/BeamioUserCard/MembershipFeeOpsLib.sol:MembershipFeeOpsLib': feeLibAddr,
		MembershipFeeOpsLib: feeLibAddr,
	})

	console.log('[upgrade] deploying MembershipStatsModule…')
	const membership = await new ethers.ContractFactory(
		membershipArt.abi,
		membershipArt.bytecode,
		wallet,
	).deploy()
	await membership.waitForDeployment()
	const membershipAddr = await membership.getAddress()
	const membershipSize = ((await provider.getCode(membershipAddr)).length - 2) / 2
	console.log(`[upgrade] MembershipStatsModule=${membershipAddr} deployedSize=${membershipSize}`)
	if (membershipSize > 24576) throw new Error(`EIP-170 exceeded membership=${membershipSize}`)

	console.log('[upgrade] deploying AdminStatsQueryModuleV5 (linked)…')
	const admin = await new ethers.ContractFactory(adminArt.abi, linkedBytecode, wallet).deploy()
	await admin.waitForDeployment()
	const adminAddr = await admin.getAddress()
	const adminSize = ((await provider.getCode(adminAddr)).length - 2) / 2
	console.log(`[upgrade] AdminStatsQueryModuleV5=${adminAddr} deployedSize=${adminSize}`)
	if (adminSize > 24576) throw new Error(`EIP-170 exceeded admin=${adminSize}`)

	const stageSel = ethers.id('stageMembershipFeePurchase(address,uint256,uint256,uint256)').slice(0, 10)
	const setSel = ethers.id('setMembershipFees(uint256[],uint8[])').slice(0, 10)
	const adminReader = new ethers.Contract(
		adminAddr,
		['function selectorModuleKind(bytes4) view returns (uint8)'],
		provider,
	)
	const stageRoute = Number(await adminReader.selectorModuleKind(stageSel))
	const setRoute = Number(await adminReader.selectorModuleKind(setSel))
	console.log(`[upgrade] stage ${stageSel} → route ${stageRoute}`)
	console.log(`[upgrade] setFees ${setSel} → route ${setRoute}`)
	if (stageRoute !== ROUTE_STATS_QUERY || setRoute !== ROUTE_STATS_QUERY) {
		throw new Error(`Unexpected fee routes stage=${stageRoute} set=${setRoute}`)
	}

	const outPath = path.join(process.cwd(), 'deployments', 'conet-MembershipFeeModules.json')
	const snapshot: Record<string, unknown> = {
		network: 'conet',
		chainId: CHAIN_ID,
		timestamp: new Date().toISOString(),
		factory: FACTORY,
		membershipFeeOpsLib: feeLibAddr,
		membershipStatsModule: membershipAddr,
		adminStatsQueryModule: adminAddr,
		stageSelector: stageSel,
		setFeesSelector: setSel,
		libraryLinks: {
			'project/src/BeamioUserCard/MembershipFeeOpsLib.sol:MembershipFeeOpsLib': feeLibAddr,
		},
		note: 'Membership fee diamond storage + stage via AdminStats V5; issue via MembershipStats',
	}
	fs.writeFileSync(outPath, JSON.stringify(snapshot, null, 2))
	console.log(`[upgrade] wrote ${outPath}`)

	if (process.env.DRY_RUN === '1') {
		console.log('[upgrade] DRY_RUN=1 — skip factory module setters')
		return
	}

	const factory = new ethers.Contract(
		FACTORY,
		[
			'function setMembershipStatsModule(address m) external',
			'function setAdminStatsQueryModule(address m) external',
			'function defaultMembershipStatsModule() view returns (address)',
			'function defaultAdminStatsQueryModule() view returns (address)',
		],
		wallet,
	)

	console.log('[upgrade] setMembershipStatsModule…')
	await (await factory.setMembershipStatsModule(membershipAddr)).wait()
	console.log('[upgrade] setAdminStatsQueryModule…')
	await (await factory.setAdminStatsQueryModule(adminAddr)).wait()

	const boundMembership = await factory.defaultMembershipStatsModule()
	const boundAdmin = await factory.defaultAdminStatsQueryModule()
	console.log(`[upgrade] bound membership=${boundMembership}`)
	console.log(`[upgrade] bound admin=${boundAdmin}`)
	if (String(boundMembership).toLowerCase() !== membershipAddr.toLowerCase()) {
		throw new Error('setMembershipStatsModule did not stick')
	}
	if (String(boundAdmin).toLowerCase() !== adminAddr.toLowerCase()) {
		throw new Error('setAdminStatsQueryModule did not stick')
	}

	snapshot.bound = {
		membershipStatsModule: boundMembership,
		adminStatsQueryModule: boundAdmin,
	}
	fs.writeFileSync(outPath, JSON.stringify(snapshot, null, 2))

	const modulesPath = path.join(process.cwd(), 'deployments', 'conet-UserCardModules.json')
	if (fs.existsSync(modulesPath)) {
		const modules = JSON.parse(fs.readFileSync(modulesPath, 'utf-8')) as Record<string, any>
		modules.membershipFeeUpgrade = {
			timestamp: new Date().toISOString(),
			membershipFeeOpsLib: feeLibAddr,
			membershipStatsModule: membershipAddr,
			adminStatsQueryModule: adminAddr,
			note: 'Membership fee mode: stage + fee-aware MembershipStats',
		}
		if (modules.modules) {
			modules.modules.membershipStatsModule = membershipAddr
			modules.modules.adminStatsQueryModule = adminAddr
		}
		fs.writeFileSync(modulesPath, JSON.stringify(modules, null, 2))
		console.log(`[upgrade] updated ${modulesPath}`)
	}

	if (process.env.SKIP_VERIFY === '1') {
		console.log('[upgrade] SKIP_VERIFY=1')
		return
	}

	const okL = await checkVerified(feeLibAddr)
	const okM = await checkVerified(membershipAddr)
	const okA = await checkVerified(adminAddr)
	console.log(`[verify] MembershipFeeOpsLib ${feeLibAddr} verified=${okL}`)
	console.log(`[verify] MembershipStatsModule ${membershipAddr} verified=${okM}`)
	console.log(`[verify] AdminStatsQueryModuleV5 ${adminAddr} verified=${okA}`)
	if (!okM || !okA || !okL) {
		console.log('  Next: node scripts/exportStandardJsonFromBuildInfo.mjs MembershipStatsModule --full')
		console.log('  Next: node scripts/exportStandardJsonFromBuildInfo.mjs AdminStatsQueryModuleV5 --full')
	}
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
