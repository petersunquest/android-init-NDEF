/**
 * Deploy the membership-fee complete set on CoNET UserCard Factory:
 *   MembershipFeeOpsLib → AdminStats V5 (linked) → AdminStats **V6 router**
 *   (new V5 + existing referrerViews) → MembershipStats → bind Factory.
 *
 * Factory `defaultAdminStatsQueryModule` MUST stay a **V6 router**. Binding the
 * new V5 directly drops Referrer Registry reads (BM_CallFailed).
 *
 * Env:
 *   CONET_RPC_URL — default https://rpc1.conet.network
 *   CONET_ADMIN_STATS_REFERRER_VIEWS — override reused referrerViews
 *   DRY_RUN=1 — deploy only, do not set factory modules
 *   SKIP_VERIFY=1 — skip Blockscout verify probe (default FORBIDDEN)
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
const EIP170_MAX = 24576
const LIVE_REFERRER_VIEWS =
	process.env.CONET_ADMIN_STATS_REFERRER_VIEWS || '0x6c7648B1d5339ea844089d2d7c9da72acab2cC9C'
const SMOKE_CARD =
	process.env.SMOKE_CARD || '0x971f740d78b2602A5aE163C535e52cED54ED7e71'
const SMOKE_AA =
	process.env.SMOKE_AA || '0x3F38F68Bf03aF3C1d7bC67893DeA172574B36EAC'

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
	const feeData = await provider.getFeeData()
	const gas: { maxFeePerGas?: bigint; maxPriorityFeePerGas?: bigint } = {}
	if (feeData.maxFeePerGas) gas.maxFeePerGas = feeData.maxFeePerGas * 2n
	if (feeData.maxPriorityFeePerGas) {
		gas.maxPriorityFeePerGas = feeData.maxPriorityFeePerGas * 2n
	} else if (feeData.gasPrice) {
		gas.maxFeePerGas = feeData.gasPrice * 2n
		gas.maxPriorityFeePerGas = feeData.gasPrice * 2n
	}
	console.log(
		`[upgrade] deployer=${wallet.address} factory=${FACTORY} maxFee=${gas.maxFeePerGas ?? 'auto'}`,
	)

	const membershipArt = loadArtifact(
		'src/BeamioUserCard/MembershipStatsModule.sol/BeamioUserCardMembershipStatsModuleV1.json',
	)
	const adminArt = loadArtifact(
		'src/BeamioUserCard/AdminStatsQueryModuleV5.sol/BeamioUserCardAdminStatsQueryModuleV5.json',
	)
	const libArt = loadArtifact('src/BeamioUserCard/MembershipFeeOpsLib.sol/MembershipFeeOpsLib.json')

	console.log('[upgrade] deploying MembershipFeeOpsLib…')
	const feeLib = await new ethers.ContractFactory(libArt.abi, libArt.bytecode, wallet).deploy(gas)
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
	).deploy(gas)
	await membership.waitForDeployment()
	const membershipAddr = await membership.getAddress()
	const membershipSize = ((await provider.getCode(membershipAddr)).length - 2) / 2
	console.log(`[upgrade] MembershipStatsModule=${membershipAddr} deployedSize=${membershipSize}`)
	if (membershipSize > 24576) throw new Error(`EIP-170 exceeded membership=${membershipSize}`)

	console.log('[upgrade] deploying AdminStatsQueryModuleV5 (linked)…')
	const admin = await new ethers.ContractFactory(adminArt.abi, linkedBytecode, wallet).deploy(gas)
	await admin.waitForDeployment()
	const adminAddr = await admin.getAddress()
	const adminSize = ((await provider.getCode(adminAddr)).length - 2) / 2
	console.log(`[upgrade] AdminStatsQueryModuleV5=${adminAddr} deployedSize=${adminSize}`)
	if (adminSize > EIP170_MAX) throw new Error(`EIP-170 exceeded admin=${adminSize}`)

	const factoryRead = new ethers.Contract(
		FACTORY,
		['function defaultAdminStatsQueryModule() view returns (address)'],
		provider,
	)
	const liveAdmin = String(await factoryRead.defaultAdminStatsQueryModule())
	let referrerViews = LIVE_REFERRER_VIEWS
	try {
		const liveV6 = new ethers.Contract(
			liveAdmin,
			['function referrerViews() view returns (address)', 'function v5() view returns (address)'],
			provider,
		)
		const rv = String(await liveV6.referrerViews())
		if (ethers.isAddress(rv) && rv !== ethers.ZeroAddress) {
			referrerViews = ethers.getAddress(rv)
		}
		console.log(`[upgrade] live AdminStats=${liveAdmin} referrerViews=${referrerViews}`)
	} catch {
		console.log(`[upgrade] live admin ${liveAdmin} is not V6; reuse ${referrerViews}`)
	}
	const viewsCode = await provider.getCode(referrerViews)
	if (!viewsCode || viewsCode === '0x') {
		throw new Error(`referrerViews has no code: ${referrerViews}`)
	}

	const routerArt = loadArtifact(
		'src/BeamioUserCard/AdminStatsQueryModuleV6.sol/BeamioUserCardAdminStatsQueryModuleV6.json',
	)
	console.log(`[upgrade] deploying AdminStatsQueryModuleV6(${adminAddr}, ${referrerViews})…`)
	const router = await new ethers.ContractFactory(routerArt.abi, routerArt.bytecode, wallet).deploy(
		adminAddr,
		referrerViews,
		gas,
	)
	await router.waitForDeployment()
	const routerAddr = await router.getAddress()
	const routerSize = ((await provider.getCode(routerAddr)).length - 2) / 2
	console.log(`[upgrade] AdminStatsQueryModuleV6=${routerAddr} deployedSize=${routerSize}`)
	if (routerSize > EIP170_MAX) throw new Error(`EIP-170 exceeded router=${routerSize}`)

	const stageSel = ethers.id('stageMembershipFeePurchase(address,uint256,uint256,uint256)').slice(0, 10)
	const bootstrapSel = ethers
		.id('stageMembershipFeePurchaseWithBootstrap(address,uint256,uint256,uint256,uint8)')
		.slice(0, 10)
	const setSel = ethers.id('setMembershipFees(uint256[],uint8[])').slice(0, 10)
	const referrerCountSel = ethers.id('referrerTotalCount()').slice(0, 10)
	const adminReader = new ethers.Contract(
		routerAddr,
		['function selectorModuleKind(bytes4) view returns (uint8)'],
		provider,
	)
	const stageRoute = Number(await adminReader.selectorModuleKind(stageSel))
	const bootstrapRoute = Number(await adminReader.selectorModuleKind(bootstrapSel))
	const setRoute = Number(await adminReader.selectorModuleKind(setSel))
	const referrerRoute = Number(await adminReader.selectorModuleKind(referrerCountSel))
	console.log(`[upgrade] stage ${stageSel} → route ${stageRoute}`)
	console.log(`[upgrade] bootstrap ${bootstrapSel} → route ${bootstrapRoute}`)
	console.log(`[upgrade] setFees ${setSel} → route ${setRoute}`)
	console.log(`[upgrade] referrerTotalCount ${referrerCountSel} → route ${referrerRoute}`)
	if (
		stageRoute !== ROUTE_STATS_QUERY ||
		bootstrapRoute !== ROUTE_STATS_QUERY ||
		setRoute !== ROUTE_STATS_QUERY ||
		referrerRoute !== ROUTE_STATS_QUERY
	) {
		throw new Error(
			`Unexpected routes stage=${stageRoute} bootstrap=${bootstrapRoute} set=${setRoute} referrer=${referrerRoute}`,
		)
	}

	const outPath = path.join(process.cwd(), 'deployments', 'conet-MembershipFeeModules.json')
	const snapshot: Record<string, unknown> = {
		network: 'conet',
		chainId: CHAIN_ID,
		timestamp: new Date().toISOString(),
		factory: FACTORY,
		membershipFeeOpsLib: feeLibAddr,
		membershipStatsModule: membershipAddr,
		adminStatsQueryModuleV5: adminAddr,
		adminStatsQueryModule: routerAddr,
		adminStatsReferrerViews: referrerViews,
		replacedAdminStatsQueryModule: liveAdmin,
		stageSelector: stageSel,
		bootstrapStageSelector: bootstrapSel,
		setFeesSelector: setSel,
		constructorArgs: { v5: adminAddr, referrerViews },
		libraryLinks: {
			'project/src/BeamioUserCard/MembershipFeeOpsLib.sol:MembershipFeeOpsLib': feeLibAddr,
		},
		note:
			'Membership fee diamond + stage via AdminStats V5; Factory binds V6 router(newV5, existing referrerViews); issue via MembershipStats',
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
	await (await factory.setMembershipStatsModule(membershipAddr, gas)).wait()
	console.log('[upgrade] setAdminStatsQueryModule(V6 router)…')
	await (await factory.setAdminStatsQueryModule(routerAddr, gas)).wait()

	const boundMembership = await factory.defaultMembershipStatsModule()
	const boundAdmin = await factory.defaultAdminStatsQueryModule()
	console.log(`[upgrade] bound membership=${boundMembership}`)
	console.log(`[upgrade] bound admin=${boundAdmin}`)
	if (String(boundMembership).toLowerCase() !== membershipAddr.toLowerCase()) {
		throw new Error('setMembershipStatsModule did not stick')
	}
	if (String(boundAdmin).toLowerCase() !== routerAddr.toLowerCase()) {
		throw new Error('setAdminStatsQueryModule did not stick — expected V6 router')
	}

	snapshot.bound = {
		membershipStatsModule: boundMembership,
		adminStatsQueryModule: boundAdmin,
		adminStatsQueryModuleV5: adminAddr,
	}
	fs.writeFileSync(outPath, JSON.stringify(snapshot, null, 2))

	const modulesPath = path.join(process.cwd(), 'deployments', 'conet-UserCardModules.json')
	if (fs.existsSync(modulesPath)) {
		const modules = JSON.parse(fs.readFileSync(modulesPath, 'utf-8')) as Record<string, any>
		modules.membershipFeeUpgrade = {
			timestamp: new Date().toISOString(),
			membershipFeeOpsLib: feeLibAddr,
			membershipStatsModule: membershipAddr,
			adminStatsQueryModuleV5: adminAddr,
			adminStatsQueryModule: routerAddr,
			adminStatsReferrerViews: referrerViews,
			note: 'Membership fee mode: V6 router + fee-aware MembershipStats (issue #100+)',
		}
		if (modules.modules) {
			modules.modules.membershipStatsModule = membershipAddr
			modules.modules.adminStatsQueryModuleV5 = adminAddr
			modules.modules.adminStatsQueryModule = routerAddr
			modules.modules.adminStatsReferrerViews = referrerViews
		}
		fs.writeFileSync(modulesPath, JSON.stringify(modules, null, 2))
		console.log(`[upgrade] updated ${modulesPath}`)
	}

	const card = new ethers.Contract(
		SMOKE_CARD,
		[
			'function membershipFeeMode() view returns (bool)',
			'function membershipFees() view returns (uint256[] memory, uint8[] memory)',
			'function referrerTotalCount() view returns (uint256)',
			'function activeMembershipId(address) view returns (uint256)',
		],
		provider,
	)
	const feeMode = Boolean(await card.membershipFeeMode())
	const [feeE6, durationKind] = (await card.membershipFees()) as [bigint[], number[]]
	const referrerTotal = await card.referrerTotalCount()
	const activeId = await card.activeMembershipId(SMOKE_AA)
	console.log(
		`[smoke] card=${SMOKE_CARD} membershipFeeMode=${feeMode} feeTiers=${feeE6.length} fee0=${feeE6[0] ?? 0n} duration0=${durationKind[0] ?? 0} referrerTotalCount=${referrerTotal} activeMembershipId(AA)=${activeId}`,
	)
	if (!feeMode) throw new Error('smoke: membershipFeeMode() is false after bind')
	if (!feeE6.length || feeE6[0] === 0n) throw new Error('smoke: membershipFees() missing base fee')

	if (process.env.SKIP_VERIFY === '1') {
		throw new Error('SKIP_VERIFY=1 is forbidden unless the same user message authorizes skip')
	}

	const okL = await checkVerified(feeLibAddr)
	const okM = await checkVerified(membershipAddr)
	const okA = await checkVerified(adminAddr)
	const okR = await checkVerified(routerAddr)
	console.log(`[verify] MembershipFeeOpsLib ${feeLibAddr} verified=${okL}`)
	console.log(`[verify] MembershipStatsModule ${membershipAddr} verified=${okM}`)
	console.log(`[verify] AdminStatsQueryModuleV5 ${adminAddr} verified=${okA}`)
	console.log(`[verify] AdminStatsQueryModuleV6 ${routerAddr} verified=${okR}`)
	if (!okM || !okA || !okL || !okR) {
		console.log('  Next: node scripts/exportStandardJsonFromBuildInfo.mjs MembershipFeeOpsLib --full')
		console.log('  Next: node scripts/exportStandardJsonFromBuildInfo.mjs MembershipStatsModule --full')
		console.log('  Next: node scripts/exportStandardJsonFromBuildInfo.mjs AdminStatsQueryModuleV5 --full')
		console.log('  Next: node scripts/exportStandardJsonFromBuildInfo.mjs AdminStatsQueryModuleV6 --full')
		console.log('  Next: CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyMembershipFeeModulesConet.ts')
	}
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
