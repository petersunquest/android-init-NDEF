/**
 * CoNET merchant-card module upgrade: Unified Reward Points #13
 *
 * Deploys (same task, complete set):
 *   1) BeamioUserCardReferrerLib — mint #13 + referrerRefereeLedger (link existing ReferrerRegistryLib)
 *   2) ChargeRewardModuleV2 — topupActor ratio, recordTopupCumulativeStat, recordChargeReferrerReward
 *      (link new ReferrerLib + existing TransferLib)
 *   3) AdminStatsReferrerViews — registry reads + getReferrerRefereeLedger (link new ReferrerLib)
 *   4) AdminStatsQueryModuleV6 — router(keep V5, new ReferrerViews); routes ledger to views
 *
 * Factory bind:
 *   setChargeRewardModule + setAdminStatsQueryModule
 *
 * Does **not** redeploy AdminStats V5 (membership fee stays).
 * Does **not** change UpdateLib on existing cards.
 *
 * Env:
 *   CONET_RPC_URL — default https://rpc1.conet.network
 *   DRY_RUN=1 — deploy only, skip factory setters
 *   SKIP_VERIFY=1 — forbidden unless user explicitly authorizes in same message
 *
 * Usage:
 *   npm run compile
 *   npx tsx scripts/upgradeUnifiedRewardPoints13Conet.ts
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

const EXISTING_TRANSFER_LIB =
	process.env.CONET_TRANSFER_LIB || '0xBcf3f8C5994B02B89fB743e1dee6AFDD5a49a664'
const EXISTING_REFERRER_REGISTRY_LIB =
	process.env.CONET_REFERRER_REGISTRY_LIB || '0x739eAA77A4Fae311d81Eb47f5E0Fff8bbACAF947'
/** Membership-fee AdminStats V5 — never replace with V4. */
const EXISTING_ADMIN_STATS_V5 =
	process.env.ADMIN_STATS_V5 || '0x444626D20214b7c4aF7BDb43E93cBc1727963719'

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

async function codeSize(provider: ethers.Provider, addr: string): Promise<number> {
	return ((await provider.getCode(addr)).length - 2) / 2
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
	const c = new ethers.Contract(
		moduleAddr,
		['function selectorModuleKind(bytes4) view returns (uint8)'],
		provider,
	)
	const sel = ethers.id(sig).slice(0, 10)
	const kind = Number(await c.selectorModuleKind(sel))
	if (kind !== expectRoute) {
		throw new Error(`selectorModuleKind(${sig}) => ${kind}, expected ${expectRoute}`)
	}
	console.log(`[smoke] ${moduleAddr.slice(0, 10)}… ${sig} → route ${kind}`)
}

async function main(): Promise<void> {
	if (process.env.SKIP_VERIFY === '1' && process.env.ALLOW_SKIP_VERIFY !== '1') {
		console.warn(
			'[upgrade] SKIP_VERIFY=1 set but ALLOW_SKIP_VERIFY unset — verification still required after deploy',
		)
	}

	const provider = new ethers.JsonRpcProvider(RPC)
	const net = await provider.getNetwork()
	if (Number(net.chainId) !== CHAIN_ID) {
		throw new Error(`Wrong chainId ${net.chainId}; expected ${CHAIN_ID}`)
	}

	const wallet = new ethers.Wallet(loadOwnerKey(), provider)
	const transferAddr = ethers.getAddress(EXISTING_TRANSFER_LIB)
	const registryLibAddr = ethers.getAddress(EXISTING_REFERRER_REGISTRY_LIB)
	const v5Addr = ethers.getAddress(EXISTING_ADMIN_STATS_V5)

	const factoryReader = new ethers.Contract(
		FACTORY,
		[
			'function defaultChargeRewardModule() view returns (address)',
			'function defaultAdminStatsQueryModule() view returns (address)',
			'function setChargeRewardModule(address)',
			'function setAdminStatsQueryModule(address)',
		],
		wallet,
	)
	const prevCharge = await factoryReader.defaultChargeRewardModule()
	const prevAdmin = await factoryReader.defaultAdminStatsQueryModule()

	console.log(`[upgrade] deployer=${wallet.address} factory=${FACTORY}`)
	console.log(`[upgrade] reuse TransferLib=${transferAddr}`)
	console.log(`[upgrade] reuse ReferrerRegistryLib=${registryLibAddr}`)
	console.log(`[upgrade] keep AdminStats V5=${v5Addr}`)
	console.log(`[upgrade] prev ChargeReward=${prevCharge}`)
	console.log(`[upgrade] prev AdminStats(V6)=${prevAdmin}`)

	const v5Size = await codeSize(provider, v5Addr)
	if (v5Size < 100) throw new Error(`No code at AdminStats V5 ${v5Addr}`)

	// --- 1) ReferrerLib (#13 + ledger) ---
	const referrerArt = loadArtifact(
		'src/BeamioUserCard/BeamioUserCardReferrerLib.sol/BeamioUserCardReferrerLib.json',
	)
	const referrerLinked = linkLibrary(referrerArt.bytecode, referrerArt.linkReferences, {
		'project/src/BeamioUserCard/ReferrerRegistryLib.sol:ReferrerRegistryLib': registryLibAddr,
		ReferrerRegistryLib: registryLibAddr,
	})
	console.log('[upgrade] deploying BeamioUserCardReferrerLib…')
	const referrerLib = await new ethers.ContractFactory(referrerArt.abi, referrerLinked, wallet).deploy()
	await referrerLib.waitForDeployment()
	const referrerLibAddr = await referrerLib.getAddress()
	const referrerTx = referrerLib.deploymentTransaction()?.hash
	console.log(`[upgrade] ReferrerLib=${referrerLibAddr} tx=${referrerTx}`)

	// --- 2) ChargeRewardModuleV2 ---
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
	const chargeAddr = await chargeMod.getAddress()
	const chargeTx = chargeMod.deploymentTransaction()?.hash
	console.log(`[upgrade] ChargeRewardModuleV2=${chargeAddr} tx=${chargeTx}`)

	// --- 3) AdminStatsReferrerViews ---
	const viewsArt = loadArtifact(
		'src/BeamioUserCard/AdminStatsReferrerViews.sol/BeamioUserCardAdminStatsReferrerViews.json',
	)
	const viewsLinked = linkLibrary(viewsArt.bytecode, viewsArt.linkReferences, {
		'project/src/BeamioUserCard/BeamioUserCardReferrerLib.sol:BeamioUserCardReferrerLib':
			referrerLibAddr,
		BeamioUserCardReferrerLib: referrerLibAddr,
	})
	console.log('[upgrade] deploying AdminStatsReferrerViews…')
	const viewsMod = await new ethers.ContractFactory(viewsArt.abi, viewsLinked, wallet).deploy()
	await viewsMod.waitForDeployment()
	const viewsAddr = await viewsMod.getAddress()
	const viewsTx = viewsMod.deploymentTransaction()?.hash
	console.log(`[upgrade] AdminStatsReferrerViews=${viewsAddr} tx=${viewsTx}`)

	// --- 4) AdminStats V6 router ---
	const v6Art = loadArtifact(
		'src/BeamioUserCard/AdminStatsQueryModuleV6.sol/BeamioUserCardAdminStatsQueryModuleV6.json',
	)
	console.log('[upgrade] deploying AdminStatsQueryModuleV6…')
	const v6Mod = await new ethers.ContractFactory(v6Art.abi, v6Art.bytecode, wallet).deploy(
		v5Addr,
		viewsAddr,
	)
	await v6Mod.waitForDeployment()
	const v6Addr = await v6Mod.getAddress()
	const v6Tx = v6Mod.deploymentTransaction()?.hash
	const v6Size = await codeSize(provider, v6Addr)
	console.log(`[upgrade] AdminStatsQueryModuleV6=${v6Addr} size=${v6Size} tx=${v6Tx}`)
	if (v6Size > EIP170_MAX) throw new Error(`V6 size ${v6Size} > EIP-170`)

	// Module-level selector smoke (on modules themselves)
	await smokeSelector(provider, v6Addr, 'getReferrerRefereeLedger(address,address)', ROUTE_STATS_QUERY)
	await smokeSelector(provider, v6Addr, 'referrerTotalCount()', ROUTE_STATS_QUERY)
	await smokeSelector(provider, v6Addr, 'setTopupActorRewardRatio(uint256)', ROUTE_CHARGE_REWARD)
	await smokeSelector(provider, v6Addr, 'recordTopupCumulativeStat(address,uint256)', ROUTE_CHARGE_REWARD)
	await smokeSelector(provider, v6Addr, 'recordChargeReferrerReward(address,uint256)', ROUTE_CHARGE_REWARD)
	await smokeSelector(provider, v6Addr, 'setMembershipFees(uint256[],uint8[])', ROUTE_STATS_QUERY)

	const snap = {
		network: 'conet',
		chainId: CHAIN_ID,
		timestamp: new Date().toISOString(),
		signer: wallet.address,
		factory: FACTORY,
		modules: {
			referrerLib: referrerLibAddr,
			chargeRewardModule: chargeAddr,
			adminStatsReferrerViews: viewsAddr,
			adminStatsQueryModule: v6Addr,
			adminStatsV5: v5Addr,
		},
		libraryLinks: {
			ReferrerRegistryLib: registryLibAddr,
			BeamioUserCardReferrerLib: referrerLibAddr,
			BeamioUserCardTransferLib: transferAddr,
		},
		replaced: {
			chargeRewardModule: String(prevCharge),
			adminStatsQueryModule: String(prevAdmin),
			priorChargeRewardReferrerLib: '0xCe84D26C8C9c81cF401532c776e2a986042F36E6',
			priorRegistryViewsReferrerLib: '0x78939FF276f1cCcE5E3fdbED9b86355910105aE2',
			priorAdminStatsReferrerViews: '0x20845FF9Ee9EA9e65e33d827C51BB118efA32276',
		},
		txs: {
			referrerLib: referrerTx,
			chargeRewardModule: chargeTx,
			adminStatsReferrerViews: viewsTx,
			adminStatsQueryModule: v6Tx,
		},
		note:
			'Unified Reward Points #13: ReferrerLib mint #13 + ledger; ChargeReward topupActor/record*; V6+Views keep V5 membership fee',
	}

	const outPath = path.join(process.cwd(), 'deployments/conet-UnifiedRewardPoints13Modules.json')
	fs.writeFileSync(outPath, JSON.stringify(snap, null, 2) + '\n')
	console.log(`[upgrade] wrote ${outPath}`)

	if (process.env.DRY_RUN === '1') {
		console.log('[upgrade] DRY_RUN=1 — skip factory bind')
		return
	}

	console.log('[upgrade] factory.setChargeRewardModule…')
	const tx1 = await factoryReader.setChargeRewardModule(chargeAddr)
	await tx1.wait()
	console.log(`[upgrade] setChargeRewardModule tx=${tx1.hash}`)

	console.log('[upgrade] factory.setAdminStatsQueryModule…')
	const tx2 = await factoryReader.setAdminStatsQueryModule(v6Addr)
	await tx2.wait()
	console.log(`[upgrade] setAdminStatsQueryModule tx=${tx2.hash}`)

	const boundCharge = await factoryReader.defaultChargeRewardModule()
	const boundAdmin = await factoryReader.defaultAdminStatsQueryModule()
	if (String(boundCharge).toLowerCase() !== chargeAddr.toLowerCase()) {
		throw new Error(`Factory charge module mismatch: ${boundCharge}`)
	}
	if (String(boundAdmin).toLowerCase() !== v6Addr.toLowerCase()) {
		throw new Error(`Factory admin module mismatch: ${boundAdmin}`)
	}
	console.log('[upgrade] factory bind OK')

	// Live card smoke: AdminStats / ReferrerViews must work on any card using factory default.
	// ChargeReward views need MODULE_CHARGE_REWARD in card bytecode — older cards (~24kB) lack
	// that route and return BM_CallFailed; soft-warn only (new cards / new initCode work).
	const card = new ethers.Contract(
		SMOKE_CARD,
		[
			'function topupActorRewardRatioE6() view returns (uint256)',
			'function chargeRewardRatioE6() view returns (uint256)',
			'function getReferrerRefereeLedger(address,address) view returns (uint256,uint256,uint256,uint256)',
			'function referrerTotalCount() view returns (uint256)',
		],
		provider,
	)
	const refCount = await card.referrerTotalCount()
	const ledger = await card.getReferrerRefereeLedger(ethers.ZeroAddress, ethers.ZeroAddress)
	console.log(
		`[smoke] card ${SMOKE_CARD} referrers=${refCount} ledger0=${ledger[0]} (AdminStats/Views OK)`,
	)
	try {
		const topupRatio = await card.topupActorRewardRatioE6()
		const chargeRatio = await card.chargeRewardRatioE6()
		console.log(`[smoke] ChargeReward views OK topupActor=${topupRatio} charge=${chargeRatio}`)
	} catch (e) {
		const msg = e instanceof Error ? e.message : String(e)
		console.warn(
			`[smoke] ChargeReward views unavailable on this card (likely pre-CHARGE-route bytecode): ${msg.slice(0, 200)}`,
		)
	}

	snap.bound = {
		chargeRewardModule: String(boundCharge),
		adminStatsQueryModule: String(boundAdmin),
		setChargeRewardModuleTx: tx1.hash,
		setAdminStatsQueryModuleTx: tx2.hash,
	}
	fs.writeFileSync(outPath, JSON.stringify(snap, null, 2) + '\n')

	// Mirror into conet-UserCardModules.json
	const modulesPath = path.join(process.cwd(), 'deployments/conet-UserCardModules.json')
	const modulesSnap = JSON.parse(fs.readFileSync(modulesPath, 'utf-8')) as Record<string, any>
	modulesSnap.modules = {
		...(modulesSnap.modules || {}),
		chargeRewardModule: chargeAddr,
		adminStatsQueryModule: v6Addr,
	}
	modulesSnap.unifiedRewardPoints13Upgrade = {
		timestamp: snap.timestamp,
		referrerLib: referrerLibAddr,
		chargeRewardModule: chargeAddr,
		adminStatsReferrerViews: viewsAddr,
		adminStatsQueryModule: v6Addr,
		adminStatsV5: v5Addr,
		libraryLinks: snap.libraryLinks,
		replaced: snap.replaced,
		bound: snap.bound,
		note: snap.note,
	}
	fs.writeFileSync(modulesPath, JSON.stringify(modulesSnap, null, 2) + '\n')
	console.log(`[upgrade] updated ${modulesPath}`)

	console.log('[upgrade] deploy complete. Next: verify script')
	console.log('  npx tsx scripts/verifyUnifiedRewardPoints13ModulesConet.ts')
	for (const [name, addr] of Object.entries({
		ReferrerLib: referrerLibAddr,
		ChargeReward: chargeAddr,
		ReferrerViews: viewsAddr,
		AdminStatsV6: v6Addr,
	})) {
		const ok = await checkVerified(addr)
		console.log(`[verify-probe] ${name} ${addr} verified=${ok}`)
	}
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
