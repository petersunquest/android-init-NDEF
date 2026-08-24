/**
 * Deploy AdminStats V6 **router** + Referrer Registry read views and bind on CoNET Factory.
 *
 * Closes the gap where V4/V5 wrote ShareReferee binds into ReferrerStorage but never
 * routed referrerTotalCount / getReferrersPage / … → BM_CallFailed on existing cards.
 *
 * Architecture (EIP-170):
 *   - Keep existing AdminStats **V5** as-is (membership fee etc.)
 *   - Deploy **ReferrerRegistryLib** → link into new **ReferrerLib**
 *   - Deploy tiny **AdminStatsReferrerViews** (linked → new ReferrerLib)
 *   - Deploy **AdminStatsQueryModuleV6** router(v5, referrerViews) as factory default
 *   - Do **not** overwrite ChargeReward’s prior ReferrerLib link
 *
 * Env:
 *   CONET_RPC_URL — default https://rpc1.conet.network
 *   DRY_RUN=1 — deploy only, do not set factory module
 *   SKIP_VERIFY=1 — skip Blockscout verify probe (default FORBIDDEN; only with user auth)
 *
 * Usage:
 *   npm run compile
 *   npx tsx scripts/upgradeAdminStatsReferrerRegistryViewsConet.ts
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
const EIP170_MAX = 24576

/** Smoke card that already has on-chain ShareReferee binds. */
const SMOKE_CARD =
	process.env.SMOKE_CARD || '0x086bdCC6840f2C65f4e6F100c507266339990112'

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

function readJson(rel: string): Record<string, any> {
	return JSON.parse(fs.readFileSync(path.join(process.cwd(), rel), 'utf-8')) as Record<string, any>
}

async function codeSize(provider: ethers.Provider, addr: string): Promise<number> {
	return ((await provider.getCode(addr)).length - 2) / 2
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

	const feeSnap = readJson('deployments/conet-MembershipFeeModules.json')
	const modulesSnap = readJson('deployments/conet-UserCardModules.json')
	const priorReferrerLibAddr = String(
		modulesSnap.chargeReferrerRewardGatewayUpgrade?.referrerLib ||
			modulesSnap.referrerRewardRatiosUpgrade?.referrerLib ||
			'',
	)

	const factoryReader = new ethers.Contract(
		FACTORY,
		['function defaultAdminStatsQueryModule() view returns (address)'],
		provider,
	)
	const v5Addr = String(
		process.env.ADMIN_STATS_V5 ||
			(await factoryReader.defaultAdminStatsQueryModule()) ||
			feeSnap.adminStatsQueryModule ||
			'',
	)
	if (!ethers.isAddress(v5Addr)) throw new Error('Could not resolve current AdminStats V5 address')

	const wallet = new ethers.Wallet(loadOwnerKey(), provider)
	console.log(`[upgrade] deployer=${wallet.address} factory=${FACTORY}`)
	console.log(`[upgrade] reuse AdminStats V5=${v5Addr}`)
	if (ethers.isAddress(priorReferrerLibAddr)) {
		console.log(`[upgrade] prior ReferrerLib (ChargeReward keeps)=${priorReferrerLibAddr}`)
	}

	const v5Size = await codeSize(provider, v5Addr)
	if (v5Size < 100) throw new Error(`No code at AdminStats V5 ${v5Addr}`)
	console.log(`[upgrade] V5 deployedSize=${v5Size}`)

	const registryArt = loadArtifact(
		'src/BeamioUserCard/ReferrerRegistryLib.sol/ReferrerRegistryLib.json',
	)
	console.log('[upgrade] deploying ReferrerRegistryLib…')
	const registryLib = await new ethers.ContractFactory(
		registryArt.abi,
		registryArt.bytecode,
		wallet,
	).deploy()
	await registryLib.waitForDeployment()
	const registryLibAddr = await registryLib.getAddress()
	console.log(`[upgrade] ReferrerRegistryLib=${registryLibAddr}`)

	const referrerArt = loadArtifact(
		'src/BeamioUserCard/BeamioUserCardReferrerLib.sol/BeamioUserCardReferrerLib.json',
	)
	const referrerLinked = linkLibrary(referrerArt.bytecode, referrerArt.linkReferences, {
		'project/src/BeamioUserCard/ReferrerRegistryLib.sol:ReferrerRegistryLib': registryLibAddr,
		ReferrerRegistryLib: registryLibAddr,
	})
	console.log('[upgrade] deploying BeamioUserCardReferrerLib (registry views)…')
	const referrerLib = await new ethers.ContractFactory(referrerArt.abi, referrerLinked, wallet).deploy()
	await referrerLib.waitForDeployment()
	const referrerLibAddr = await referrerLib.getAddress()
	console.log(`[upgrade] BeamioUserCardReferrerLib=${referrerLibAddr}`)

	const viewsArt = loadArtifact(
		'src/BeamioUserCard/AdminStatsReferrerViews.sol/BeamioUserCardAdminStatsReferrerViews.json',
	)
	const viewsLinked = linkLibrary(viewsArt.bytecode, viewsArt.linkReferences, {
		'project/src/BeamioUserCard/BeamioUserCardReferrerLib.sol:BeamioUserCardReferrerLib': referrerLibAddr,
		BeamioUserCardReferrerLib: referrerLibAddr,
	})
	console.log('[upgrade] deploying AdminStatsReferrerViews…')
	const views = await new ethers.ContractFactory(viewsArt.abi, viewsLinked, wallet).deploy()
	await views.waitForDeployment()
	const viewsAddr = await views.getAddress()
	const viewsSize = await codeSize(provider, viewsAddr)
	console.log(`[upgrade] AdminStatsReferrerViews=${viewsAddr} deployedSize=${viewsSize}`)
	if (viewsSize > EIP170_MAX) throw new Error(`EIP-170 exceeded referrerViews=${viewsSize}`)

	const routerArt = loadArtifact(
		'src/BeamioUserCard/AdminStatsQueryModuleV6.sol/BeamioUserCardAdminStatsQueryModuleV6.json',
	)
	console.log('[upgrade] deploying AdminStatsQueryModuleV6 router(v5, referrerViews)…')
	const router = await new ethers.ContractFactory(routerArt.abi, routerArt.bytecode, wallet).deploy(
		v5Addr,
		viewsAddr,
	)
	await router.waitForDeployment()
	const routerAddr = await router.getAddress()
	const routerSize = await codeSize(provider, routerAddr)
	console.log(`[upgrade] AdminStatsQueryModuleV6=${routerAddr} deployedSize=${routerSize}`)
	if (routerSize > EIP170_MAX) throw new Error(`EIP-170 exceeded router=${routerSize}`)

	const viewSels = [
		'referrerTotalCount()',
		'registeredRefereeTotalCount()',
		'refereeCountByReferrer(address)',
		'getReferrersPage(uint256,uint256)',
		'getRefereesByReferrerPage(address,uint256,uint256)',
		'getRegisteredRefereesPage(uint256,uint256)',
		'refereeReferrer(address)',
		'refereeChargePointsTotal6(address)',
		'stageMembershipFeePurchase(address,uint256,uint256,uint256)',
	]
	const routerReader = new ethers.Contract(
		routerAddr,
		['function selectorModuleKind(bytes4) view returns (uint8)'],
		provider,
	)
	for (const sig of viewSels) {
		const sel = ethers.id(sig).slice(0, 10)
		const route = Number(await routerReader.selectorModuleKind(sel))
		console.log(`[upgrade] ${sig} ${sel} → route ${route}`)
		if (route !== ROUTE_STATS_QUERY) {
			throw new Error(`Expected ROUTE_STATS_QUERY(254) for ${sig}, got ${route}`)
		}
	}

	const outPath = path.join(process.cwd(), 'deployments', 'conet-AdminStatsReferrerRegistryViews.json')
	const snapshot: Record<string, unknown> = {
		network: 'conet',
		chainId: CHAIN_ID,
		timestamp: new Date().toISOString(),
		factory: FACTORY,
		adminStatsV5: v5Addr,
		adminStatsReferrerViews: viewsAddr,
		beamioUserCardReferrerLib: referrerLibAddr,
		referrerRegistryLib: registryLibAddr,
		priorChargeRewardReferrerLib: ethers.isAddress(priorReferrerLibAddr) ? priorReferrerLibAddr : undefined,
		adminStatsQueryModule: routerAddr,
		replacedAdminStatsQueryModule: v5Addr,
		libraryLinks: {
			'project/src/BeamioUserCard/ReferrerRegistryLib.sol:ReferrerRegistryLib': registryLibAddr,
			'project/src/BeamioUserCard/BeamioUserCardReferrerLib.sol:BeamioUserCardReferrerLib': referrerLibAddr,
		},
		constructorArgs: { v5: v5Addr, referrerViews: viewsAddr },
		note: 'AdminStats V6 router: referrer reads → ReferrerViews; else → V5',
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

	console.log('[upgrade] setAdminStatsQueryModule(router)…')
	await (await factory.setAdminStatsQueryModule(routerAddr)).wait()
	const boundAdmin = await factory.defaultAdminStatsQueryModule()
	console.log(`[upgrade] bound admin=${boundAdmin}`)
	if (String(boundAdmin).toLowerCase() !== routerAddr.toLowerCase()) {
		throw new Error('setAdminStatsQueryModule did not stick')
	}

	snapshot.bound = { adminStatsQueryModule: boundAdmin }
	fs.writeFileSync(outPath, JSON.stringify(snapshot, null, 2))

	const modulesPath = path.join(process.cwd(), 'deployments', 'conet-UserCardModules.json')
	if (fs.existsSync(modulesPath)) {
		const modules = JSON.parse(fs.readFileSync(modulesPath, 'utf-8')) as Record<string, any>
		modules.adminStatsReferrerRegistryViewsUpgrade = {
			timestamp: new Date().toISOString(),
			adminStatsQueryModule: routerAddr,
			adminStatsV5: v5Addr,
			adminStatsReferrerViews: viewsAddr,
			beamioUserCardReferrerLib: referrerLibAddr,
			referrerRegistryLib: registryLibAddr,
			note: 'V6 router + Referrer Registry read views',
		}
		if (modules.modules) {
			modules.modules.adminStatsQueryModule = routerAddr
		}
		fs.writeFileSync(modulesPath, JSON.stringify(modules, null, 2))
		console.log(`[upgrade] updated ${modulesPath}`)
	}

	const feePath = path.join(process.cwd(), 'deployments', 'conet-MembershipFeeModules.json')
	if (fs.existsSync(feePath)) {
		const fee = JSON.parse(fs.readFileSync(feePath, 'utf-8')) as Record<string, any>
		fee.adminStatsQueryModule = routerAddr
		fee.adminStatsV5Kept = v5Addr
		fee.bound = { ...(fee.bound || {}), adminStatsQueryModule: boundAdmin }
		fee.adminStatsV6Note =
			'Factory default is V6 router; V5 kept as immutable backend for membership-fee selectors'
		fs.writeFileSync(feePath, JSON.stringify(fee, null, 2))
	}

	const card = new ethers.Contract(
		SMOKE_CARD,
		[
			'function referrerTotalCount() view returns (uint256)',
			'function registeredRefereeTotalCount() view returns (uint256)',
			'function membershipFeeMode() view returns (bool)',
		],
		provider,
	)
	const rt = await card.referrerTotalCount()
	const rr = await card.registeredRefereeTotalCount()
	let feeMode: boolean | string = 'n/a'
	try {
		feeMode = Boolean(await card.membershipFeeMode())
	} catch (e) {
		feeMode = `err:${(e as Error).message?.slice(0, 80)}`
	}
	console.log(
		`[smoke] card=${SMOKE_CARD} referrerTotalCount=${rt} registeredRefereeTotalCount=${rr} membershipFeeMode=${feeMode}`,
	)

	if (process.env.SKIP_VERIFY === '1') {
		console.log('[upgrade] SKIP_VERIFY=1')
		console.log('  Next: node scripts/exportStandardJsonFromBuildInfo.mjs <Key> --full ×4')
		console.log(
			'  Then: CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyAdminStatsReferrerRegistryViewsConet.ts',
		)
		return
	}

	let allOk = true
	for (const [label, addr] of [
		['AdminStatsQueryModuleV6', routerAddr],
		['AdminStatsReferrerViews', viewsAddr],
		['BeamioUserCardReferrerLib', referrerLibAddr],
		['ReferrerRegistryLib', registryLibAddr],
	] as const) {
		const ok = await checkVerified(addr)
		console.log(`[verify] ${label} ${addr} verified=${ok}`)
		if (!ok) {
			allOk = false
			console.log(
				`  Next: CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyAdminStatsReferrerRegistryViewsConet.ts`,
			)
		}
	}
	if (allOk) console.log('[verify] all four addresses verified on Blockscout ✅')
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
