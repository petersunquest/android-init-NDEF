/**
 * Charge Referrer #1 gateway path (existing cards):
 * 1) Redeploy ChargeRewardModuleV2 with recordChargeReferrerReward (link existing ReferrerLib + TransferLib)
 * 2) Redeploy AdminStatsQueryModuleV4 (inherits V2 selector → ROUTE_CHARGE_REWARD)
 * 3) factory.setChargeRewardModule + setAdminStatsQueryModule
 *
 * Does NOT redeploy ReferrerLib (reuse Ce84… amountFiat6 mint).
 * Does NOT change UpdateLib on existing cards (immutable); new cards also mint via gateway only.
 *
 * Usage:
 *   npm run compile
 *   npx tsx scripts/upgradeChargeReferrerRewardGatewayConet.ts
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
const ROUTE_CHARGE_REWARD = 5

const EXISTING_TRANSFER_LIB =
	process.env.CONET_TRANSFER_LIB || '0xBcf3f8C5994B02B89fB743e1dee6AFDD5a49a664'
const EXISTING_REFERRER_LIB =
	process.env.CONET_REFERRER_LIB || '0xCe84D26C8C9c81cF401532c776e2a986042F36E6'

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
	linkReferences?: Record<string, unknown>
} {
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

	const transferAddr = ethers.getAddress(EXISTING_TRANSFER_LIB)
	const referrerLibAddr = ethers.getAddress(EXISTING_REFERRER_LIB)
	console.log(`[upgrade] reuse ReferrerLib=${referrerLibAddr}`)
	console.log(`[upgrade] reuse TransferLib=${transferAddr}`)

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
	const chargeSel = ethers.id('recordChargeReferrerReward(address,uint256)').slice(0, 10)
	const topupSel = ethers.id('recordTopupCumulativeStat(address,uint256)').slice(0, 10)
	for (const [sig, sel] of [
		['recordChargeReferrerReward(address,uint256)', chargeSel],
		['recordTopupCumulativeStat(address,uint256)', topupSel],
	] as const) {
		const route = Number(await adminReader.selectorModuleKind(sel))
		console.log(`[upgrade] ${sig} ${sel} → route ${route}`)
		if (route !== ROUTE_CHARGE_REWARD) throw new Error(`Unexpected route for ${sig}: ${route}`)
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

	const outPath = path.join(process.cwd(), 'deployments', 'conet-ChargeReferrerRewardGateway.json')
	const snapshot: Record<string, unknown> = {
		network: 'conet',
		chainId: CHAIN_ID,
		timestamp: new Date().toISOString(),
		factory: FACTORY,
		signer: wallet.address,
		libraryLinks: {
			BeamioUserCardReferrerLib: referrerLibAddr,
			BeamioUserCardTransferLib: transferAddr,
		},
		replaced: {
			chargeRewardModule: oldCharge,
			adminStatsQueryModule: oldAdmin,
		},
		modules: {
			chargeRewardModule: chargeAddr,
			adminStatsQueryModule: adminAddr,
			referrerLib: referrerLibAddr,
		},
		note:
			'Charge Referrer #1 via ChargeRewardModule.recordChargeReferrerReward gateway (Plan A EntryPoint). Consumption #2 remains UpdateLib.',
	}
	fs.writeFileSync(outPath, JSON.stringify(snapshot, null, 2))
	console.log(`[upgrade] wrote ${outPath}`)

	if (process.env.DRY_RUN === '1') {
		console.log('[upgrade] DRY_RUN=1 — skip factory setters')
		return
	}

	const factory = factoryReader.connect(wallet) as ethers.Contract
	const tx1 = await factory.setChargeRewardModule(chargeAddr)
	console.log(`[upgrade] setChargeRewardModule tx=${tx1.hash}`)
	await tx1.wait()
	const tx2 = await factory.setAdminStatsQueryModule(adminAddr)
	console.log(`[upgrade] setAdminStatsQueryModule tx=${tx2.hash}`)
	await tx2.wait()

	const nowCharge = (await factoryReader.defaultChargeRewardModule()) as string
	const nowAdmin = (await factoryReader.defaultAdminStatsQueryModule()) as string
	if (ethers.getAddress(nowCharge) !== ethers.getAddress(chargeAddr)) {
		throw new Error(`Factory charge module mismatch: ${nowCharge}`)
	}
	if (ethers.getAddress(nowAdmin) !== ethers.getAddress(adminAddr)) {
		throw new Error(`Factory admin module mismatch: ${nowAdmin}`)
	}
	console.log('[upgrade] factory defaults updated')

	;(snapshot as { bound?: unknown }).bound = {
		chargeRewardModule: nowCharge,
		adminStatsQueryModule: nowAdmin,
		setChargeRewardModuleTx: tx1.hash,
		setAdminStatsQueryModuleTx: tx2.hash,
	}
	fs.writeFileSync(outPath, JSON.stringify(snapshot, null, 2))

	if (process.env.SKIP_VERIFY === '1') {
		console.log('[upgrade] SKIP_VERIFY=1')
		console.log(
			`Next: verify ChargeReward ${chargeAddr} + AdminStats ${adminAddr} on Blockscout, then backfill failed charge referrer #1.`,
		)
		return
	}

	for (const [label, addr] of [
		['ChargeRewardModuleV2', chargeAddr],
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
	console.log(`  ChargeRewardModuleV2=${chargeAddr}`)
	console.log(`  AdminStatsQueryModuleV4=${adminAddr}`)
	console.log('Next: export Standard JSON + verify; backfill charge referrer for missed txs; rebuild x402sdk.')
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
