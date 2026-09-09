/**
 * CoNET: redeploy ChargeRewardModuleV2 + AdminStats V6
 * (#13 → #0 / #13 → Conet-USDC to AA / atomic peer+#13 container top-up).
 *
 * Same-task complete set:
 *   - ChargeRewardModuleV2 — convertReward13* + peerRedeem13ForContainerTopup + topupWithReward13Container
 *   - AdminStatsQueryModuleV6(existing V5, existing referrerViews) — routes new selectors → kind=5
 *   - Factory setChargeRewardModule + setAdminStatsQueryModule(new V6)
 * Reuses ReferrerLib + TransferLib + V5 + referrerViews. Does **not** bind bare V5.
 *
 * Usage:
 *   npm run clean && npm run compile
 *   npx tsx scripts/upgradeChargeReward13ConvertConet.ts
 *
 * Env:
 *   CONET_RPC_URL — default https://rpc1.conet.network
 *   DRY_RUN=1 — deploy only, skip factory setter
 *   CONET_REFERRER_LIB — default from deployments/conet-UnifiedRewardPoints13Modules.json
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
const ROUTE_CHARGE_REWARD = 5
const ROUTE_STATS_QUERY = 254
const EIP170_MAX = 24576
const EXISTING_ADMIN_STATS_V5 =
	process.env.CONET_ADMIN_STATS_V5 || '0xA439F4E513A241D62687abdBaF37e5Ba61D9889e'
const EXISTING_REFERRER_VIEWS =
	process.env.CONET_ADMIN_STATS_REFERRER_VIEWS || '0x6c7648B1d5339ea844089d2d7c9da72acab2cC9C'

const EXISTING_TRANSFER_LIB =
	process.env.CONET_TRANSFER_LIB || '0xBcf3f8C5994B02B89fB743e1dee6AFDD5a49a664'
const EXISTING_REFERRER_REGISTRY_LIB =
	process.env.CONET_REFERRER_REGISTRY_LIB || '0x739eAA77A4Fae311d81Eb47f5E0Fff8bbACAF947'

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

async function checkVerified(addr: string): Promise<boolean> {
	const r = await fetch(`${BLOCKSCOUT}/api/v2/smart-contracts/${addr}`)
	if (!r.ok) return false
	const d = (await r.json()) as { is_verified?: boolean; is_partially_verified?: boolean }
	return Boolean(d.is_verified || d.is_partially_verified)
}

async function smokeSelector(
	provider: ethers.Provider,
	moduleAddr: string,
	sig: string,
	expectRoute: number,
): Promise<void> {
	const sel = ethers.id(sig).slice(0, 10)
	const c = new ethers.Contract(
		moduleAddr,
		['function selectorModuleKind(bytes4) view returns (uint8)'],
		provider,
	)
	const kind = Number(await c.selectorModuleKind(sel))
	if (kind !== expectRoute) {
		throw new Error(`${sig} on ${moduleAddr}: kind=${kind} want ${expectRoute}`)
	}
	console.log(`[smoke] ${sig} → route ${kind} OK`)
}

function resolveExistingReferrerLib(): string {
	if (process.env.CONET_REFERRER_LIB) return process.env.CONET_REFERRER_LIB
	const snapPath = path.join(process.cwd(), 'deployments/conet-UnifiedRewardPoints13Modules.json')
	if (fs.existsSync(snapPath)) {
		const snap = JSON.parse(fs.readFileSync(snapPath, 'utf-8')) as {
			modules?: { referrerLib?: string }
			libraryLinks?: { BeamioUserCardReferrerLib?: string }
		}
		const addr = snap.modules?.referrerLib || snap.libraryLinks?.BeamioUserCardReferrerLib
		if (addr) return addr
	}
	return '0x5E16bCFdFA9c41666528b68f475772A8D4a42124'
}

async function main(): Promise<void> {
	const dryRun = process.env.DRY_RUN === '1'
	const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID)
	const wallet = new ethers.Wallet(loadOwnerKey(), provider)
	console.log(`[upgrade] signer=${wallet.address} factory=${FACTORY} dryRun=${dryRun}`)

	const net = await provider.getNetwork()
	if (Number(net.chainId) !== CHAIN_ID) {
		throw new Error(`Wrong chainId ${net.chainId}, expected ${CHAIN_ID}`)
	}

	const referrerLibAddr = resolveExistingReferrerLib()
	const transferAddr = EXISTING_TRANSFER_LIB
	const registryLibAddr = EXISTING_REFERRER_REGISTRY_LIB

	const refCode = await provider.getCode(referrerLibAddr)
	if (!refCode || refCode === '0x') {
		throw new Error(`ReferrerLib has no code at ${referrerLibAddr}`)
	}
	console.log(`[upgrade] reuse ReferrerLib=${referrerLibAddr}`)
	console.log(`[upgrade] reuse TransferLib=${transferAddr}`)

	const factoryReader = new ethers.Contract(
		FACTORY,
		[
			'function defaultChargeRewardModule() view returns (address)',
			'function defaultAdminStatsQueryModule() view returns (address)',
			'function setChargeRewardModule(address)',
			'function setAdminStatsQueryModule(address)',
			'function owner() view returns (address)',
		],
		wallet,
	)
	const ownerOnChain = String(await factoryReader.owner())
	if (ownerOnChain.toLowerCase() !== wallet.address.toLowerCase()) {
		throw new Error(`Signer ${wallet.address} is not factory owner ${ownerOnChain}`)
	}
	const prevCharge = String(await factoryReader.defaultChargeRewardModule())
	const prevAdmin = String(await factoryReader.defaultAdminStatsQueryModule())
	console.log(`[upgrade] prev chargeReward=${prevCharge}`)
	console.log(`[upgrade] prev adminStats=${prevAdmin}`)
	console.log(`[upgrade] reuse AdminStats V5=${EXISTING_ADMIN_STATS_V5}`)
	console.log(`[upgrade] reuse referrerViews=${EXISTING_REFERRER_VIEWS}`)
	const v5Code = await provider.getCode(EXISTING_ADMIN_STATS_V5)
	const viewsCode = await provider.getCode(EXISTING_REFERRER_VIEWS)
	if (!v5Code || v5Code === '0x') {
		throw new Error(`AdminStats V5 has no code at ${EXISTING_ADMIN_STATS_V5}`)
	}
	if (!viewsCode || viewsCode === '0x') {
		throw new Error(`referrerViews has no code at ${EXISTING_REFERRER_VIEWS}`)
	}

	let chargeAddr: string
	let chargeTx: string | undefined
	const reuseCharge = process.env.CONET_CHARGE_REWARD_MODULE
	if (reuseCharge) {
		chargeAddr = ethers.getAddress(reuseCharge)
		const code = await provider.getCode(chargeAddr)
		if (!code || code === '0x') {
			throw new Error(`CONET_CHARGE_REWARD_MODULE ${chargeAddr} has no code`)
		}
		console.log(`[upgrade] reuse ChargeRewardModuleV2=${chargeAddr} (skip deploy)`)
	} else {
		const chargeArt = loadArtifact(
			'src/BeamioUserCard/ChargeRewardModuleV2.sol/BeamioUserCardChargeRewardModuleV2.json',
		)
		const chargeLinked = linkLibrary(chargeArt.bytecode, chargeArt.linkReferences, {
			'project/src/BeamioUserCard/BeamioUserCardReferrerLib.sol:BeamioUserCardReferrerLib':
				referrerLibAddr,
			BeamioUserCardReferrerLib: referrerLibAddr,
			'project/src/BeamioUserCard/BeamioUserCardTransferLib.sol:BeamioUserCardTransferLib':
				transferAddr,
			BeamioUserCardTransferLib: transferAddr,
		})
		const chargeSize = (chargeLinked.length - 2) / 2
		if (chargeSize > EIP170_MAX) {
			throw new Error(`ChargeRewardModuleV2 bytecode ${chargeSize} > EIP-170 ${EIP170_MAX}`)
		}
		console.log(`[upgrade] deploying ChargeRewardModuleV2 (size=${chargeSize})…`)
		const chargeMod = await new ethers.ContractFactory(chargeArt.abi, chargeLinked, wallet).deploy()
		await chargeMod.waitForDeployment()
		chargeAddr = await chargeMod.getAddress()
		chargeTx = chargeMod.deploymentTransaction()?.hash
		console.log(`[upgrade] ChargeRewardModuleV2=${chargeAddr} tx=${chargeTx}`)
	}

	let routerAddr: string
	let routerTx: string | undefined
	const reuseRouter = process.env.CONET_ADMIN_STATS_V6
	if (reuseRouter) {
		routerAddr = ethers.getAddress(reuseRouter)
		const code = await provider.getCode(routerAddr)
		if (!code || code === '0x') {
			throw new Error(`CONET_ADMIN_STATS_V6 ${routerAddr} has no code`)
		}
		console.log(`[upgrade] reuse AdminStatsQueryModuleV6=${routerAddr} (skip deploy)`)
	} else {
		const routerArt = loadArtifact(
			'src/BeamioUserCard/AdminStatsQueryModuleV6.sol/BeamioUserCardAdminStatsQueryModuleV6.json',
		)
		const routerSize = (routerArt.bytecode.length - 2) / 2
		if (routerSize > EIP170_MAX) {
			throw new Error(`AdminStats V6 bytecode ${routerSize} > EIP-170 ${EIP170_MAX}`)
		}
		console.log(
			`[upgrade] deploying AdminStatsQueryModuleV6(${EXISTING_ADMIN_STATS_V5}, ${EXISTING_REFERRER_VIEWS}) size=${routerSize}…`,
		)
		const router = await new ethers.ContractFactory(routerArt.abi, routerArt.bytecode, wallet).deploy(
			EXISTING_ADMIN_STATS_V5,
			EXISTING_REFERRER_VIEWS,
		)
		await router.waitForDeployment()
		routerAddr = await router.getAddress()
		routerTx = router.deploymentTransaction()?.hash
		console.log(`[upgrade] AdminStatsQueryModuleV6=${routerAddr} tx=${routerTx}`)
	}

	await smokeSelector(provider, routerAddr, 'topupReward(uint256,uint256)', ROUTE_CHARGE_REWARD)
	await smokeSelector(provider, routerAddr, 'topupReward(uint256,uint256,uint256)', ROUTE_CHARGE_REWARD)
	await smokeSelector(provider, routerAddr, 'setTopupPromotionBonusRatio(uint256)', ROUTE_CHARGE_REWARD)
	await smokeSelector(
		provider,
		routerAddr,
		'setTopupPromotionBonusRatioByAdmin(uint256)',
		ROUTE_CHARGE_REWARD,
	)
	await smokeSelector(provider, routerAddr, 'chargeReward(uint256,uint256)', ROUTE_CHARGE_REWARD)
	await smokeSelector(provider, routerAddr, 'setTopupActorRewardRatio(uint256)', ROUTE_CHARGE_REWARD)
	await smokeSelector(
		provider,
		routerAddr,
		'recordTopupCumulativeStat(address,uint256)',
		ROUTE_CHARGE_REWARD,
	)
	await smokeSelector(
		provider,
		routerAddr,
		'recordChargeReferrerReward(address,uint256)',
		ROUTE_CHARGE_REWARD,
	)
	await smokeSelector(provider, routerAddr, 'convertReward13ToPointsRatioE6()', ROUTE_CHARGE_REWARD)
	await smokeSelector(provider, routerAddr, 'convertReward13ToUsdcRatioE6()', ROUTE_CHARGE_REWARD)
	await smokeSelector(provider, routerAddr, 'merchantOracleSpreadBps()', ROUTE_CHARGE_REWARD)
	await smokeSelector(provider, routerAddr, 'quoteUsdcDepositForFiat6(uint256)', ROUTE_CHARGE_REWARD)
	await smokeSelector(provider, routerAddr, 'quoteUsdcWithdrawForFiat6(uint256)', ROUTE_CHARGE_REWARD)
	await smokeSelector(provider, routerAddr, 'applyDepositSpreadUsdc6(uint256)', ROUTE_CHARGE_REWARD)
	await smokeSelector(provider, routerAddr, 'applyWithdrawSpreadUsdc6(uint256)', ROUTE_CHARGE_REWARD)
	await smokeSelector(provider, routerAddr, 'setConvertReward13ToPointsRatio(uint256)', ROUTE_CHARGE_REWARD)
	await smokeSelector(provider, routerAddr, 'setConvertReward13ToUsdcRatio(uint256)', ROUTE_CHARGE_REWARD)
	await smokeSelector(provider, routerAddr, 'setMerchantOracleSpreadBps(uint256)', ROUTE_CHARGE_REWARD)
	await smokeSelector(
		provider,
		routerAddr,
		'setMerchantOracleSpreadBpsByAdmin(uint256)',
		ROUTE_CHARGE_REWARD,
	)
	await smokeSelector(
		provider,
		routerAddr,
		'convertReward13ToProgramPoints(address,uint256)',
		ROUTE_CHARGE_REWARD,
	)
	await smokeSelector(
		provider,
		routerAddr,
		'convertReward13ToUsdcToAa(address,uint256)',
		ROUTE_CHARGE_REWARD,
	)
	await smokeSelector(
		provider,
		routerAddr,
		'peerRedeem13ForContainerTopup(address,uint256,uint256,address)',
		ROUTE_CHARGE_REWARD,
	)
	await smokeSelector(
		provider,
		routerAddr,
		'topupWithReward13Container(address,uint256,uint256,uint256,uint256,uint256,bytes32)',
		ROUTE_CHARGE_REWARD,
	)
	await smokeSelector(provider, routerAddr, 'referrerTotalCount()', ROUTE_STATS_QUERY)

	const snap = {
		network: 'conet',
		chainId: CHAIN_ID,
		timestamp: new Date().toISOString(),
		signer: wallet.address,
		factory: FACTORY,
		modules: {
			referrerLib: referrerLibAddr,
			chargeRewardModule: chargeAddr,
			adminStatsQueryModule: routerAddr,
			adminStatsQueryModuleV5: EXISTING_ADMIN_STATS_V5,
			adminStatsReferrerViews: EXISTING_REFERRER_VIEWS,
		},
		constructorArgs: {
			v5: EXISTING_ADMIN_STATS_V5,
			referrerViews: EXISTING_REFERRER_VIEWS,
		},
		libraryLinks: {
			ReferrerRegistryLib: registryLibAddr,
			BeamioUserCardReferrerLib: referrerLibAddr,
			BeamioUserCardTransferLib: transferAddr,
		},
		replaced: {
			chargeRewardModule: prevCharge,
			adminStatsQueryModule: prevAdmin,
		},
		txs: {
			chargeRewardModule: chargeTx,
			adminStatsQueryModule: routerTx,
		},
		note:
			'ChargeRewardModuleV2 + AdminStats V6: convertReward13ToProgramPoints / convertReward13ToUsdcToAa + ratio storage; reuse V5 + referrerViews; never bind bare V5',
	}

	const outPath = path.join(process.cwd(), 'deployments/conet-ChargeReward13Convert.json')
	fs.mkdirSync(path.dirname(outPath), { recursive: true })
	fs.writeFileSync(outPath, JSON.stringify(snap, null, 2) + '\n')
	console.log(`[upgrade] wrote ${outPath}`)

	if (dryRun) {
		console.log('[upgrade] DRY_RUN=1 — skip factory setters')
		console.log(
			`[upgrade] Next: unset DRY_RUN and re-run, or setChargeRewardModule(${chargeAddr}) + setAdminStatsQueryModule(${routerAddr})`,
		)
		return
	}

	console.log('[upgrade] factory.setChargeRewardModule…')
	const tx1 = await factoryReader.setChargeRewardModule(chargeAddr)
	await tx1.wait()
	console.log(`[upgrade] setChargeRewardModule tx=${tx1.hash}`)

	console.log('[upgrade] factory.setAdminStatsQueryModule (V6 router, not bare V5)…')
	const tx2 = await factoryReader.setAdminStatsQueryModule(routerAddr)
	await tx2.wait()
	console.log(`[upgrade] setAdminStatsQueryModule tx=${tx2.hash}`)

	const boundCharge = String(await factoryReader.defaultChargeRewardModule())
	const boundAdmin = String(await factoryReader.defaultAdminStatsQueryModule())
	if (boundCharge.toLowerCase() !== chargeAddr.toLowerCase()) {
		throw new Error(`setChargeRewardModule did not stick: got ${boundCharge}`)
	}
	if (boundAdmin.toLowerCase() !== routerAddr.toLowerCase()) {
		throw new Error(`setAdminStatsQueryModule did not stick: got ${boundAdmin}`)
	}
	if (boundAdmin.toLowerCase() === EXISTING_ADMIN_STATS_V5.toLowerCase()) {
		throw new Error('Factory bound bare AdminStats V5 — abort')
	}
	;(snap as { bound?: unknown; txs: Record<string, string | undefined> }).bound = {
		chargeRewardModule: boundCharge,
		adminStatsQueryModule: boundAdmin,
		adminStatsQueryModuleV5: EXISTING_ADMIN_STATS_V5,
		setChargeRewardModuleTx: tx1.hash,
		setAdminStatsQueryModuleTx: tx2.hash,
	}
	snap.txs.setChargeRewardModule = tx1.hash
	snap.txs.setAdminStatsQueryModule = tx2.hash
	fs.writeFileSync(outPath, JSON.stringify(snap, null, 2) + '\n')

	const membershipSnapPath = path.join(process.cwd(), 'deployments/conet-MembershipFeeModules.json')
	if (fs.existsSync(membershipSnapPath)) {
		const membership = JSON.parse(fs.readFileSync(membershipSnapPath, 'utf-8')) as Record<string, any>
		membership.replacedAdminStatsQueryModule = membership.adminStatsQueryModule
		membership.adminStatsQueryModule = routerAddr
		membership.bound = {
			...(membership.bound || {}),
			adminStatsQueryModule: boundAdmin,
			adminStatsQueryModuleV5: EXISTING_ADMIN_STATS_V5,
		}
		membership.combinedRewardSettersUpgrade = {
			timestamp: snap.timestamp,
			adminStatsQueryModule: routerAddr,
			chargeRewardModule: chargeAddr,
			note: 'V6 routes convertReward13* → ChargeReward; V5 + referrerViews unchanged',
		}
		fs.writeFileSync(membershipSnapPath, JSON.stringify(membership, null, 2) + '\n')
		console.log(`[upgrade] updated ${membershipSnapPath}`)
	}

	const modulesPath = path.join(process.cwd(), 'deployments/conet-UserCardModules.json')
	if (fs.existsSync(modulesPath)) {
		const modulesSnap = JSON.parse(fs.readFileSync(modulesPath, 'utf-8')) as Record<string, any>
		modulesSnap.modules = {
			...(modulesSnap.modules || {}),
			chargeRewardModule: chargeAddr,
			adminStatsQueryModule: routerAddr,
			adminStatsQueryModuleV5: EXISTING_ADMIN_STATS_V5,
			adminStatsReferrerViews: EXISTING_REFERRER_VIEWS,
		}
		modulesSnap.bound = {
			...(modulesSnap.bound || {}),
			chargeRewardModule: boundCharge,
			adminStatsQueryModule: boundAdmin,
		}
		modulesSnap.combinedRewardSettersUpgrade = {
			timestamp: snap.timestamp,
			referrerLib: referrerLibAddr,
			chargeRewardModule: chargeAddr,
			adminStatsQueryModule: routerAddr,
			adminStatsQueryModuleV5: EXISTING_ADMIN_STATS_V5,
			adminStatsReferrerViews: EXISTING_REFERRER_VIEWS,
			replaced: snap.replaced,
			bound: (snap as { bound?: unknown }).bound,
			note: snap.note,
		}
		fs.writeFileSync(modulesPath, JSON.stringify(modulesSnap, null, 2) + '\n')
		console.log(`[upgrade] updated ${modulesPath}`)
	}

	// Card fallback smoke: selector routes to charge module
	try {
		const card = new ethers.Contract(
			SMOKE_CARD,
			['function selectorModuleKind(bytes4) view returns (uint8)'],
			provider,
		)
		const sel = ethers.id('convertReward13ToProgramPoints(address,uint256)').slice(0, 10)
		const kind = Number(await card.selectorModuleKind(sel))
		console.log(`[smoke] card ${SMOKE_CARD} convertReward13ToProgramPoints → route ${kind}`)
	} catch (e) {
		console.warn(`[smoke] card soft-fail (pre-route cards OK): ${(e as Error).message}`)
	}

	const verifiedCharge = await checkVerified(chargeAddr)
	const verifiedRouter = await checkVerified(routerAddr)
	console.log(
		`[upgrade] Blockscout probe ChargeReward ${chargeAddr}: ${verifiedCharge ? 'yes' : 'no (run verify next)'}`,
	)
	console.log(
		`[upgrade] Blockscout probe AdminStats V6 ${routerAddr}: ${verifiedRouter ? 'yes' : 'no (run verify next)'}`,
	)
	console.log('[upgrade] Next:')
	console.log('  node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardChargeRewardModuleV2 --full')
	console.log('  node scripts/exportStandardJsonFromBuildInfo.mjs AdminStatsQueryModuleV6 --full')
	console.log('  CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyChargeReward13ConvertConet.ts')
	console.log(
		'  CONET_VERIFY_ONLY=AdminStatsQueryModuleV6 CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyMembershipFeeModulesConet.ts',
	)
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
