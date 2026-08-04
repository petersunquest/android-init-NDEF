/**
 * Dual Referrer charge/topup amount ratios:
 * 1) Redeploy BeamioUserCardReferrerLib (amountFiat6 bases + AA-only mint)
 * 2) Redeploy ChargeRewardModuleV2 (link new ReferrerLib + existing TransferLib)
 * 3) Redeploy AdminStatsQueryModuleV4 (setReferrerCharge/TopupAmountRatio)
 * 4) factory.setChargeRewardModule + setAdminStatsQueryModule
 *
 * Usage:
 *   npm run compile
 *   npx tsx scripts/upgradeReferrerRewardRatiosConet.ts
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
const ROUTE_STATS_QUERY = 254

/** Existing CoNET libs (unchanged); ReferrerLib is redeployed and re-linked. */
const EXISTING_TRANSFER_LIB =
	process.env.CONET_TRANSFER_LIB || '0xBcf3f8C5994B02B89fB743e1dee6AFDD5a49a664'
const EXISTING_REFERRER_REGISTRY_LIB =
	process.env.CONET_REFERRER_REGISTRY_LIB || '0x1A4D7F46B553528e3e0b64425079cCcD8E15e5Ca'
const OLD_REFERRER_LIB =
	process.env.CONET_OLD_REFERRER_LIB || '0x9aBB24d2a3760241a22616DECedA7ab04B452345'

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

function loadArtifact(rel: string): { abi: ethers.InterfaceAbi; bytecode: string; linkReferences?: Record<string, unknown> } {
	const p = path.join(process.cwd(), 'artifacts', rel)
	const j = JSON.parse(fs.readFileSync(p, 'utf-8')) as {
		abi: ethers.InterfaceAbi
		bytecode: string
		linkReferences?: Record<string, unknown>
	}
	if (!j.bytecode || j.bytecode === '0x') throw new Error(`Missing bytecode: ${rel}`)
	return j
}

function linkBytecode(
	bytecode: string,
	linkReferences: Record<string, Record<string, Array<{ start: number; length: number }>>>,
	libraries: Record<string, string>,
): string {
	let linked = bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode
	for (const fileRefs of Object.values(linkReferences || {})) {
		for (const [libName, places] of Object.entries(fileRefs)) {
			const addr = libraries[libName]
			if (!addr) throw new Error(`Missing library address for ${libName}`)
			const hex = addr.replace(/^0x/, '').toLowerCase().padStart(40, '0')
			if (hex.length !== 40) throw new Error(`Bad library address ${libName}=${addr}`)
			for (const { start, length } of places) {
				if (length !== 20) throw new Error(`Unexpected link length ${length} for ${libName}`)
				const startHex = start * 2
				linked = linked.slice(0, startHex) + hex + linked.slice(startHex + 40)
			}
		}
	}
	if (linked.includes('__')) {
		throw new Error('Bytecode still has unresolved library placeholders')
	}
	return `0x${linked}`
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

	const referrerArt = loadArtifact(
		'src/BeamioUserCard/BeamioUserCardReferrerLib.sol/BeamioUserCardReferrerLib.json',
	)
	const transferAddr = ethers.getAddress(EXISTING_TRANSFER_LIB)
	const registryLibAddr = ethers.getAddress(EXISTING_REFERRER_REGISTRY_LIB)

	const linkedReferrer = linkBytecode(
		referrerArt.bytecode,
		referrerArt.linkReferences as Record<string, Record<string, Array<{ start: number; length: number }>>>,
		{ ReferrerRegistryLib: registryLibAddr },
	)
	console.log('[upgrade] deploying BeamioUserCardReferrerLib…')
	const ReferrerFactory = new ethers.ContractFactory(referrerArt.abi, linkedReferrer, wallet)
	const referrerLib = await ReferrerFactory.deploy()
	await referrerLib.waitForDeployment()
	const referrerLibAddr = await referrerLib.getAddress()
	console.log(`[upgrade] ReferrerLib=${referrerLibAddr} (was ${OLD_REFERRER_LIB})`)
	console.log(`[upgrade] linked ReferrerRegistryLib=${registryLibAddr}`)

	const chargeArt = loadArtifact(
		'src/BeamioUserCard/ChargeRewardModuleV2.sol/BeamioUserCardChargeRewardModuleV2.json',
	)
	const linkedCharge = linkBytecode(
		chargeArt.bytecode,
		chargeArt.linkReferences as Record<string, Record<string, Array<{ start: number; length: number }>>>,
		{
			BeamioUserCardReferrerLib: referrerLibAddr,
			BeamioUserCardTransferLib: transferAddr,
		},
	)
	const ChargeFactory = new ethers.ContractFactory(chargeArt.abi, linkedCharge, wallet)
	console.log('[upgrade] deploying ChargeRewardModuleV2…')
	const charge = await ChargeFactory.deploy()
	await charge.waitForDeployment()
	const chargeAddr = await charge.getAddress()
	console.log(`[upgrade] ChargeRewardModuleV2=${chargeAddr}`)

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
	if (adminSize > 24576) throw new Error(`EIP-170 exceeded: ${adminSize}`)

	const adminReader = new ethers.Contract(
		adminAddr,
		['function selectorModuleKind(bytes4) view returns (uint8)'],
		provider,
	)
	const sels = [
		'setReferrerChargeAmountRatio(uint256)',
		'setReferrerTopupAmountRatio(uint256)',
		'referrerChargeAmountRatioE6()',
		'referrerTopupAmountRatioE6()',
		'bindShareRefereeWithSignature(address,address,uint256,bytes32,bytes)',
	]
	for (const sig of sels) {
		const sel = ethers.id(sig).slice(0, 10)
		const route = Number(await adminReader.selectorModuleKind(sel))
		console.log(`[upgrade] ${sig} ${sel} → route ${route}`)
		if (route !== ROUTE_STATS_QUERY) throw new Error(`Unexpected route for ${sig}: ${route}`)
	}

	const factoryReader = new ethers.Contract(
		FACTORY,
		[
			'function defaultChargeRewardModule() view returns (address)',
			'function defaultAdminStatsQueryModule() view returns (address)',
			'function setChargeRewardModule(address m) external',
			'function setAdminStatsQueryModule(address m) external',
		],
		provider,
	)
	const oldCharge = (await factoryReader.defaultChargeRewardModule()) as string
	const oldAdmin = (await factoryReader.defaultAdminStatsQueryModule()) as string
	console.log(`[upgrade] replacing ChargeReward ${oldCharge} → ${chargeAddr}`)
	console.log(`[upgrade] replacing AdminStats ${oldAdmin} → ${adminAddr}`)

	const outPath = path.join(process.cwd(), 'deployments', 'conet-ReferrerRewardRatiosModules.json')
	const snapshot: Record<string, unknown> = {
		network: 'conet',
		chainId: CHAIN_ID,
		timestamp: new Date().toISOString(),
		factory: FACTORY,
		signer: wallet.address,
		libraryLinks: {
			ReferrerRegistryLib: registryLibAddr,
			BeamioUserCardReferrerLib: referrerLibAddr,
			BeamioUserCardTransferLib: transferAddr,
		},
		replaced: {
			referrerLib: OLD_REFERRER_LIB,
			chargeRewardModule: oldCharge,
			adminStatsQueryModule: oldAdmin,
		},
		modules: {
			referrerLib: referrerLibAddr,
			chargeRewardModule: chargeAddr,
			adminStatsQueryModule: adminAddr,
		},
		note:
			'Charge/Top-up referrer #1 ratios are % of amountFiat6 (0=off); mint to Referrer AA only. Charge slot reuses referrerRewardFromChargeRewardRatioE6 semantics.',
	}
	fs.writeFileSync(outPath, JSON.stringify(snapshot, null, 2))
	console.log(`[upgrade] wrote ${outPath}`)

	// Keep bind snapshot in sync for AdminStats address
	const bindPath = path.join(process.cwd(), 'deployments', 'conet-ReferrerShareBindModules.json')
	fs.writeFileSync(
		bindPath,
		JSON.stringify(
			{
				network: 'conet',
				chainId: CHAIN_ID,
				timestamp: new Date().toISOString(),
				factory: FACTORY,
				adminStatsQueryModule: adminAddr,
				bindSelector: ethers.id(
					'bindShareRefereeWithSignature(address,address,uint256,bytes32,bytes)',
				).slice(0, 10),
				bindRoute: ROUTE_STATS_QUERY,
				note: 'AdminStats V4: bind + dual referrer amount ratios',
				bound: { adminStatsQueryModule: adminAddr },
			},
			null,
			2,
		),
	)

	const sdkAddrPath = path.join(process.cwd(), 'src/x402sdk/src/chainAddresses.ts')
	if (fs.existsSync(sdkAddrPath)) {
		let src = fs.readFileSync(sdkAddrPath, 'utf-8')
		const re = /export const CONET_BEAMIO_USER_CARD_REFERRER_LIB = '0x[a-fA-F0-9]{40}'/
		if (re.test(src)) {
			src = src.replace(
				re,
				`export const CONET_BEAMIO_USER_CARD_REFERRER_LIB = '${referrerLibAddr}'`,
			)
			fs.writeFileSync(sdkAddrPath, src)
			console.log(`[upgrade] updated CONET_BEAMIO_USER_CARD_REFERRER_LIB in chainAddresses.ts`)
		}
	}

	if (process.env.DRY_RUN === '1') {
		console.log('[upgrade] DRY_RUN=1 — skip factory setters')
		return
	}

	const factory = factoryReader.connect(wallet) as ethers.Contract
	console.log('[upgrade] setChargeRewardModule…')
	await (await factory.setChargeRewardModule(chargeAddr)).wait()
	console.log('[upgrade] setAdminStatsQueryModule…')
	await (await factory.setAdminStatsQueryModule(adminAddr)).wait()

	const boundCharge = await factory.defaultChargeRewardModule()
	const boundAdmin = await factory.defaultAdminStatsQueryModule()
	if (String(boundCharge).toLowerCase() !== chargeAddr.toLowerCase()) {
		throw new Error('setChargeRewardModule did not stick')
	}
	if (String(boundAdmin).toLowerCase() !== adminAddr.toLowerCase()) {
		throw new Error('setAdminStatsQueryModule did not stick')
	}
	console.log(`[upgrade] bound charge=${boundCharge}`)
	console.log(`[upgrade] bound admin=${boundAdmin}`)

	snapshot.bound = {
		chargeRewardModule: boundCharge,
		adminStatsQueryModule: boundAdmin,
	}
	fs.writeFileSync(outPath, JSON.stringify(snapshot, null, 2))

	if (process.env.SKIP_VERIFY === '1') {
		console.log('[upgrade] SKIP_VERIFY=1')
		return
	}

	for (const [name, addr] of [
		['ReferrerLib', referrerLibAddr],
		['ChargeRewardModuleV2', chargeAddr],
		['AdminStatsQueryModuleV4', adminAddr],
	] as const) {
		const ok = await checkVerified(addr)
		console.log(`[verify] ${name} ${addr} verified=${ok}`)
	}

	console.log('\nNext verify steps:')
	console.log('  node scripts/exportStandardJsonFromBuildInfo.mjs BeamioUserCardChargeRewardModuleV2 --full')
	console.log('  node scripts/exportStandardJsonFromBuildInfo.mjs AdminStatsQueryModuleV4 --full')
	console.log('  # then prune + local bytecode precheck + Blockscout v2 submit')
	console.log(
		'  CONET_VERIFY_POLL_MAX=180 CONET_VERIFY_ONLY=BeamioUserCardChargeRewardModuleV2,AdminStatsQueryModuleV4 npx tsx scripts/verifyConetUserCardModulesOnScan.ts',
	)
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
