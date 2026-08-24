/**
 * Fix MembershipStats ↔ BeamioUserCard linear storage mismatch (missing `deployer`).
 * Redeploy MembershipStats only; do NOT touch AdminStats (Factory may be V6 router).
 *
 * Env:
 *   CONET_RPC_URL — default https://rpc1.conet.network
 *   DRY_RUN=1 — deploy only, skip factory setter
 *   SKIP_VERIFY=1 — skip Blockscout probe (still print next commands)
 *   SMOKE_CARD — optional card to eth_call mintPointsByAdmin after bind
 *
 * Usage:
 *   npm run clean && npm run compile
 *   npx tsx scripts/upgradeMembershipStatsLayoutFixConet.ts
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
/** Card that failed membership fee issue (POS). */
const DEFAULT_SMOKE_CARD = '0x971f740d78b2602A5aE163C535e52cED54ED7e71'

type ArtifactJson = {
	abi: ethers.InterfaceAbi
	bytecode: string
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

async function main(): Promise<void> {
	const provider = new ethers.JsonRpcProvider(RPC)
	const net = await provider.getNetwork()
	if (Number(net.chainId) !== CHAIN_ID) {
		throw new Error(`Wrong chainId ${net.chainId}; expected ${CHAIN_ID}`)
	}

	const wallet = new ethers.Wallet(loadOwnerKey(), provider)
	console.log(`[upgrade] deployer=${wallet.address} factory=${FACTORY}`)

	const prevPath = path.join(process.cwd(), 'deployments', 'conet-MembershipFeeModules.json')
	const prev = fs.existsSync(prevPath)
		? (JSON.parse(fs.readFileSync(prevPath, 'utf-8')) as Record<string, unknown>)
		: {}

	const factoryRO = new ethers.Contract(
		FACTORY,
		[
			'function defaultMembershipStatsModule() view returns (address)',
			'function defaultAdminStatsQueryModule() view returns (address)',
		],
		provider,
	)
	const oldMembership = String(await factoryRO.defaultMembershipStatsModule())
	const adminBound = String(await factoryRO.defaultAdminStatsQueryModule())
	console.log(`[upgrade] current MembershipStats=${oldMembership}`)
	console.log(`[upgrade] current AdminStats (unchanged)=${adminBound}`)

	const membershipArt = loadArtifact(
		'src/BeamioUserCard/MembershipStatsModule.sol/BeamioUserCardMembershipStatsModuleV1.json',
	)

	console.log('[upgrade] deploying MembershipStatsModule (layout-aligned)…')
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

	const outPath = prevPath
	const snapshot: Record<string, unknown> = {
		...prev,
		network: 'conet',
		chainId: CHAIN_ID,
		timestamp: new Date().toISOString(),
		factory: FACTORY,
		membershipStatsModule: membershipAddr,
		replacedMembershipStatsModule: oldMembership,
		layoutFixNote:
			'BeamioUserCardBase now mirrors card linear slots (deployer, _initializationLocked, upgradeType)',
		note: 'MembershipStats layout fix only; AdminStats / FeeOpsLib unchanged',
	}
	fs.writeFileSync(outPath, JSON.stringify(snapshot, null, 2))
	console.log(`[upgrade] wrote ${outPath}`)

	if (process.env.DRY_RUN === '1') {
		console.log('[upgrade] DRY_RUN=1 — skip factory setMembershipStatsModule')
		return
	}

	const factory = new ethers.Contract(
		FACTORY,
		[
			'function setMembershipStatsModule(address m) external',
			'function defaultMembershipStatsModule() view returns (address)',
			'function defaultAdminStatsQueryModule() view returns (address)',
		],
		wallet,
	)

	console.log('[upgrade] setMembershipStatsModule…')
	await (await factory.setMembershipStatsModule(membershipAddr)).wait()
	const boundMembership = await factory.defaultMembershipStatsModule()
	const boundAdminAfter = await factory.defaultAdminStatsQueryModule()
	console.log(`[upgrade] bound membership=${boundMembership}`)
	console.log(`[upgrade] admin still=${boundAdminAfter}`)
	if (String(boundMembership).toLowerCase() !== membershipAddr.toLowerCase()) {
		throw new Error('setMembershipStatsModule did not stick')
	}
	if (String(boundAdminAfter).toLowerCase() !== adminBound.toLowerCase()) {
		throw new Error('AdminStats module changed unexpectedly — abort semantics violated')
	}

	snapshot.bound = {
		...(typeof prev.bound === 'object' && prev.bound ? (prev.bound as object) : {}),
		membershipStatsModule: boundMembership,
		adminStatsQueryModule: boundAdminAfter,
	}
	fs.writeFileSync(outPath, JSON.stringify(snapshot, null, 2))

	const modulesPath = path.join(process.cwd(), 'deployments', 'conet-UserCardModules.json')
	if (fs.existsSync(modulesPath)) {
		const modules = JSON.parse(fs.readFileSync(modulesPath, 'utf-8')) as Record<string, any>
		modules.membershipStatsLayoutFix = {
			timestamp: new Date().toISOString(),
			membershipStatsModule: membershipAddr,
			replaced: oldMembership,
			note: 'Align Base storage with BeamioUserCard deployer slot',
		}
		if (modules.modules) {
			modules.modules.membershipStatsModule = membershipAddr
		}
		fs.writeFileSync(modulesPath, JSON.stringify(modules, null, 2))
		console.log(`[upgrade] updated ${modulesPath}`)
	}

	const smokeCard = process.env.SMOKE_CARD || DEFAULT_SMOKE_CARD
	if (smokeCard && ethers.isAddress(smokeCard)) {
		console.log(`[smoke] mintPointsByAdmin eth_call on ${smokeCard} (from factory)…`)
		const card = new ethers.Contract(
			smokeCard,
			['function mintPointsByAdmin(address to, uint256 points6)'],
			provider,
		)
		const dummy = '0xe16A2F6b00000000000000000000000000000000'
		try {
			await card.mintPointsByAdmin.staticCall(dummy, 1n, { from: FACTORY })
			console.log('[smoke] staticCall returned (unexpected success without pending — ok if no revert shape)')
		} catch (e: unknown) {
			const msg = e instanceof Error ? e.message : String(e)
			const data =
				typeof e === 'object' && e && 'data' in e ? String((e as { data?: unknown }).data) : ''
			const blob = `${msg} ${data}`
			if (blob.includes('UC_RedeemDelegateFailed') || blob.includes('dccff669')) {
				throw new Error(`[smoke] STILL UC_RedeemDelegateFailed — layout fix failed: ${msg}`)
			}
			// Expected: membership fee pending / no pending / other business revert — not empty delegate fail
			console.log(`[smoke] reverted (expected business path): ${msg.slice(0, 200)}`)
		}
	}

	if (process.env.SKIP_VERIFY === '1') {
		console.log('[upgrade] SKIP_VERIFY=1')
		console.log(
			`  Next: npm run clean && npm run compile && node scripts/exportStandardJsonFromBuildInfo.mjs MembershipStatsModule --full`,
		)
		console.log(`  Next: CONET_VERIFY_ONLY=MembershipStatsModule npx tsx scripts/verifyMembershipFeeModulesConet.ts`)
		return
	}

	const okM = await checkVerified(membershipAddr)
	console.log(`[verify] MembershipStatsModule ${membershipAddr} verified=${okM}`)
	if (!okM) {
		console.log(
			'  Next: npm run clean && npm run compile && node scripts/exportStandardJsonFromBuildInfo.mjs MembershipStatsModule --full',
		)
		console.log('  Next: CONET_VERIFY_POLL_MAX=180 npx tsx scripts/verifyMembershipFeeModulesConet.ts')
	}
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
