/**
 * CoNET Discover Gift redeem complete set:
 *   - RedeemModule — createGiftRedeemForPayer (isPaymaster / factory owner; no card owner sig)
 *   - AdminStatsQueryModuleV6(existing V5, existing referrerViews) — hardcodes gift selectors → ROUTE_REDEEM
 *   - Factory setRedeemModule + setAdminStatsQueryModule(new V6)
 *   - UserCard beacon V21 (RedeemGatewayLib gift fee/topup claim) via upgradeUserCardBeaconConet.ts
 *
 * Does **not** change Factory bytecode. Does **not** bind bare V5.
 *
 * Usage:
 *   npm run clean && npm run compile
 *   npx tsx scripts/upgradeMerchantGiftRedeemConet.ts
 *   # then (if SKIP_BEACON≠1):
 *   npx tsx scripts/upgradeUserCardBeaconConet.ts
 *
 * Env:
 *   CONET_RPC_URL — default https://rpc1.conet.network
 *   DRY_RUN=1 — deploy only, skip factory setters
 *   SKIP_BEACON=1 — do not spawn beacon upgrade
 *   SKIP_VERIFY=1 — forbidden unless the user authorized skip in the same message
 *   CONET_REDEEM_MODULE / CONET_ADMIN_STATS_V6 — reuse deployed addresses
 */
import fs from 'fs'
import path from 'path'
import { homedir } from 'os'
import { spawnSync } from 'child_process'
import { ethers } from 'ethers'

const CHAIN_ID = 224422
const RPC = process.env.CONET_RPC_URL || 'https://rpc1.conet.network'
const FACTORY =
	process.env.CONET_CARD_FACTORY || '0xfA52a0CcC96C19cF4b6Ea864615F6d52BD0774FB'
const FACTORY_OWNER = '0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1'
const BLOCKSCOUT = process.env.CONET_BLOCKSCOUT_URL || 'https://mainnet.conet.network'
const ROUTE_REDEEM = 0
const EIP170_MAX = 24576
const EXISTING_ADMIN_STATS_V5 =
	process.env.CONET_ADMIN_STATS_V5 || '0xA439F4E513A241D62687abdBaF37e5Ba61D9889e'
const EXISTING_REFERRER_VIEWS =
	process.env.CONET_ADMIN_STATS_REFERRER_VIEWS || '0x6c7648B1d5339ea844089d2d7c9da72acab2cC9C'
const SMOKE_CARD =
	process.env.SMOKE_CARD || '0x086bdCC6840f2C65f4e6F100c507266339990112'

const GIFT_CREATE_SIG = 'createGiftRedeemForPayer(bytes32,uint256,uint256,uint64,uint64)'
const GIFT_CREDIT_CREATE_SIG =
	'createGiftRedeemWithCreditBurn(bytes32,uint256,uint256,uint256,address,uint64,uint64)'
const GIFT_SPLIT_SIG = 'getGiftRedeemSplit(bytes32)'

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

async function main(): Promise<void> {
	const dryRun = process.env.DRY_RUN === '1'
	const skipBeacon = process.env.SKIP_BEACON === '1'
	const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID)
	const wallet = new ethers.Wallet(loadOwnerKey(), provider)
	console.log(`[upgrade] signer=${wallet.address} factory=${FACTORY} dryRun=${dryRun}`)

	const net = await provider.getNetwork()
	if (Number(net.chainId) !== CHAIN_ID) {
		throw new Error(`Wrong chainId ${net.chainId}, expected ${CHAIN_ID}`)
	}

	const factoryReader = new ethers.Contract(
		FACTORY,
		[
			'function defaultRedeemModule() view returns (address)',
			'function defaultAdminStatsQueryModule() view returns (address)',
			'function setRedeemModule(address)',
			'function setAdminStatsQueryModule(address)',
			'function owner() view returns (address)',
		],
		wallet,
	)
	const ownerOnChain = String(await factoryReader.owner())
	if (ownerOnChain.toLowerCase() !== wallet.address.toLowerCase()) {
		throw new Error(`Signer ${wallet.address} is not factory owner ${ownerOnChain}`)
	}
	const prevRedeem = String(await factoryReader.defaultRedeemModule())
	const prevAdmin = String(await factoryReader.defaultAdminStatsQueryModule())
	console.log(`[upgrade] prev redeemModule=${prevRedeem}`)
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

	let redeemAddr: string
	let redeemTx: string | undefined
	const reuseRedeem = process.env.CONET_REDEEM_MODULE
	if (reuseRedeem) {
		redeemAddr = ethers.getAddress(reuseRedeem)
		const code = await provider.getCode(redeemAddr)
		if (!code || code === '0x') {
			throw new Error(`CONET_REDEEM_MODULE ${redeemAddr} has no code`)
		}
		console.log(`[upgrade] reuse RedeemModule=${redeemAddr} (skip deploy)`)
	} else {
		const redeemArt = loadArtifact(
			'src/BeamioUserCard/RedeemModule.sol/BeamioUserCardRedeemModuleVNext.json',
		)
		const redeemSize = (redeemArt.bytecode.length - 2) / 2
		if (redeemSize > EIP170_MAX) {
			throw new Error(`RedeemModule bytecode ${redeemSize} > EIP-170 ${EIP170_MAX}`)
		}
		console.log(`[upgrade] deploying RedeemModule (size=${redeemSize})…`)
		const redeemMod = await new ethers.ContractFactory(
			redeemArt.abi,
			redeemArt.bytecode,
			wallet,
		).deploy()
		await redeemMod.waitForDeployment()
		redeemAddr = await redeemMod.getAddress()
		redeemTx = redeemMod.deploymentTransaction()?.hash
		console.log(`[upgrade] RedeemModule=${redeemAddr} tx=${redeemTx}`)
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

	await smokeSelector(provider, routerAddr, GIFT_CREATE_SIG, ROUTE_REDEEM)
	await smokeSelector(provider, routerAddr, GIFT_CREDIT_CREATE_SIG, ROUTE_REDEEM)
	await smokeSelector(provider, routerAddr, GIFT_SPLIT_SIG, ROUTE_REDEEM)
	// Legacy createRedeem (V5 route) must still resolve through the V6 router.
	await smokeSelector(
		provider,
		routerAddr,
		'createRedeem(bytes32,uint256,uint256,uint64,uint64,uint256[],uint256[])',
		ROUTE_REDEEM,
	)

	if (!dryRun) {
		if (prevRedeem.toLowerCase() !== redeemAddr.toLowerCase()) {
			console.log(`[upgrade] setRedeemModule(${redeemAddr})…`)
			const tx = await factoryReader.setRedeemModule(redeemAddr)
			await tx.wait()
			console.log(`[upgrade] setRedeemModule tx=${tx.hash}`)
		} else {
			console.log(`[upgrade] redeemModule already bound`)
		}
		if (prevAdmin.toLowerCase() !== routerAddr.toLowerCase()) {
			console.log(`[upgrade] setAdminStatsQueryModule(${routerAddr})…`)
			const tx = await factoryReader.setAdminStatsQueryModule(routerAddr)
			await tx.wait()
			console.log(`[upgrade] setAdminStatsQueryModule tx=${tx.hash}`)
		} else {
			console.log(`[upgrade] adminStats already bound`)
		}
		const boundRedeem = String(await factoryReader.defaultRedeemModule())
		const boundAdmin = String(await factoryReader.defaultAdminStatsQueryModule())
		if (boundRedeem.toLowerCase() !== redeemAddr.toLowerCase()) {
			throw new Error(`Factory redeem bind failed: ${boundRedeem}`)
		}
		if (boundAdmin.toLowerCase() !== routerAddr.toLowerCase()) {
			throw new Error(`Factory adminStats bind failed: ${boundAdmin}`)
		}
		console.log(`[upgrade] factory bound OK`)
	} else {
		console.log(`[upgrade] DRY_RUN — skipped factory setters`)
	}

	// Live card: gift create selector must route (read via card fallback → AdminStats).
	const card = new ethers.Contract(
		SMOKE_CARD,
		['function selectorModuleKind(bytes4) view returns (uint8)'],
		provider,
	)
	try {
		const kind = Number(await card.selectorModuleKind(ethers.id(GIFT_CREATE_SIG).slice(0, 10)))
		console.log(`[smoke] card ${SMOKE_CARD} ${GIFT_CREATE_SIG} → ${kind}`)
		if (kind !== ROUTE_REDEEM) {
			console.warn(`[smoke] WARN card route kind=${kind} (want ${ROUTE_REDEEM}) — check factory bind`)
		}
		const creditKind = Number(
			await card.selectorModuleKind(ethers.id(GIFT_CREDIT_CREATE_SIG).slice(0, 10)),
		)
		console.log(`[smoke] card ${SMOKE_CARD} ${GIFT_CREDIT_CREATE_SIG} → ${creditKind}`)
		if (creditKind !== ROUTE_REDEEM) {
			console.warn(
				`[smoke] WARN card credit route kind=${creditKind} (want ${ROUTE_REDEEM}) — check factory bind`,
			)
		}
	} catch (e) {
		console.warn(`[smoke] card selectorModuleKind failed (may need beacon V21 first):`, e)
	}

	const outPath = path.join(process.cwd(), 'deployments/conet-MerchantGiftRedeem.json')
	const snap = {
		network: 'conet',
		chainId: CHAIN_ID,
		timestamp: new Date().toISOString(),
		factory: FACTORY,
		signer: wallet.address,
		modules: {
			redeemModule: redeemAddr,
			adminStatsQueryModuleV6: routerAddr,
			adminStatsV5: EXISTING_ADMIN_STATS_V5,
			referrerViews: EXISTING_REFERRER_VIEWS,
		},
		replaced: {
			redeemModule: prevRedeem,
			adminStatsQueryModule: prevAdmin,
		},
		txs: { redeemModule: redeemTx, adminStatsV6: routerTx },
		dryRun,
	}
	fs.mkdirSync(path.dirname(outPath), { recursive: true })
	fs.writeFileSync(outPath, JSON.stringify(snap, null, 2) + '\n')
	console.log(`[upgrade] wrote ${outPath}`)

	// Mirror into conet-UserCardModules.json if present
	const modulesPath = path.join(process.cwd(), 'deployments/conet-UserCardModules.json')
	if (fs.existsSync(modulesPath)) {
		const mods = JSON.parse(fs.readFileSync(modulesPath, 'utf-8')) as Record<string, unknown>
		mods.redeemModule = redeemAddr
		mods.adminStatsQueryModule = routerAddr
		mods.adminStatsQueryModuleV6 = routerAddr
		mods.updatedAt = snap.timestamp
		mods.merchantGiftRedeem = snap
		fs.writeFileSync(modulesPath, JSON.stringify(mods, null, 2) + '\n')
		console.log(`[upgrade] updated ${modulesPath}`)
	}

	if (process.env.SKIP_VERIFY === '1') {
		console.warn('[verify] SKIP_VERIFY=1 — forbidden by default; verify in same task')
	} else {
		for (const [label, addr] of [
			['RedeemModule', redeemAddr],
			['AdminStatsQueryModuleV6', routerAddr],
		] as const) {
			const ok = await checkVerified(addr)
			console.log(`[verify] ${label} ${addr} verified=${ok}`)
			if (!ok) {
				console.log(`  Next: node scripts/exportStandardJsonFromBuildInfo.mjs ${label === 'RedeemModule' ? 'RedeemModule' : 'AdminStatsQueryModuleV6'} --full`)
				console.log(
					`  Then: CONET_VERIFY_ONLY=${label === 'RedeemModule' ? 'RedeemModule' : 'AdminStatsQueryModuleV6'} CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyMerchantGiftRedeemConet.ts`,
				)
			}
		}
	}

	if (!skipBeacon && !dryRun) {
		console.log('[upgrade] spawning upgradeUserCardBeaconConet.ts (VERSION 21)…')
		const r = spawnSync('npx', ['tsx', 'scripts/upgradeUserCardBeaconConet.ts'], {
			cwd: process.cwd(),
			stdio: 'inherit',
			env: process.env,
		})
		if (r.status !== 0) {
			throw new Error(`beacon upgrade exited ${r.status}`)
		}
	} else if (skipBeacon) {
		console.log('[upgrade] SKIP_BEACON=1 — run: npx tsx scripts/upgradeUserCardBeaconConet.ts')
	}

	console.log('[upgrade] done')
	console.log('  Next: node scripts/syncBeamioUserCardToX402sdk.mjs')
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
