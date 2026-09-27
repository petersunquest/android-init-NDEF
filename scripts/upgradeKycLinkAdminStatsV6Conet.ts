/**
 * CoNET: redeploy AdminStats V6 router with KYC link views/writes.
 *
 * Same-task set:
 *   - KycLinkOps (internal, inlined into V6; no library link)
 *   - AdminStatsQueryModuleV6(existing V5, existing referrerViews)
 *   - factory.setAdminStatsQueryModule(new V6)
 * Reuses live V5 + referrerViews read from the currently bound V6.
 * Does not bind bare V5. Does not touch ChargeReward.
 *
 * Usage:
 *   npm run clean && npm run compile
 *   npx tsx scripts/upgradeKycLinkAdminStatsV6Conet.ts
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
const ROUTE_STATS_QUERY = 254
const EIP170_MAX = 24576
const SMOKE_CARD =
	process.env.SMOKE_CARD || '0x086bdCC6840f2C65f4e6F100c507266339990112'

const KYC_SELECTORS = [
	'kycIpfsHashOf(address)',
	'kycPolicy()',
	'setKycPolicy(bool,uint8,uint8,uint8)',
	'linkKycIpfsHashWithSignature(address,bytes32,uint256,uint256,bytes)',
	'linkKycIpfsHashByAdmin(address,bytes32,uint256,uint256,bytes)',
]

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

async function smokeSelector(
	provider: ethers.Provider,
	moduleAddr: string,
	sig: string,
	expect: number,
) {
	const mod = new ethers.Contract(
		moduleAddr,
		['function selectorModuleKind(bytes4) view returns (uint8)'],
		provider,
	)
	const sel = ethers.id(sig).slice(0, 10)
	const kind = Number(await mod.selectorModuleKind(sel))
	if (kind !== expect) {
		throw new Error(`${sig} selectorModuleKind=${kind} expected ${expect}`)
	}
	console.log(`[smoke] ${sig} → ${kind}`)
}

async function main() {
	const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID)
	const net = await provider.getNetwork()
	if (Number(net.chainId) !== CHAIN_ID) {
		throw new Error(`RPC chainId ${net.chainId} != ${CHAIN_ID}`)
	}
	const wallet = new ethers.Wallet(loadOwnerKey(), provider)
	const factory = new ethers.Contract(
		FACTORY,
		[
			'function owner() view returns (address)',
			'function defaultAdminStatsQueryModule() view returns (address)',
			'function setAdminStatsQueryModule(address m) external',
		],
		wallet,
	)
	const owner = String(await factory.owner())
	if (owner.toLowerCase() !== wallet.address.toLowerCase()) {
		throw new Error(`Signer ${wallet.address} is not factory owner ${owner}`)
	}

	const prevAdmin = String(await factory.defaultAdminStatsQueryModule())
	const prev = new ethers.Contract(
		prevAdmin,
		[
			'function v5() view returns (address)',
			'function referrerViews() view returns (address)',
		],
		provider,
	)
	const v5 = String(await prev.v5())
	const referrerViews = String(await prev.referrerViews())
	console.log(`[upgrade] live V6=${prevAdmin} v5=${v5} referrerViews=${referrerViews}`)
	if ((await provider.getCode(v5)) === '0x') throw new Error(`V5 ${v5} has no code`)
	if ((await provider.getCode(referrerViews)) === '0x') {
		throw new Error(`referrerViews ${referrerViews} has no code`)
	}

	const art = loadArtifact(
		'src/BeamioUserCard/AdminStatsQueryModuleV6.sol/BeamioUserCardAdminStatsQueryModuleV6.json',
	)
	const size = (art.bytecode.length - 2) / 2
	if (size > EIP170_MAX) throw new Error(`V6 bytecode ${size} > EIP-170 ${EIP170_MAX}`)
	console.log(`[upgrade] deploying AdminStatsQueryModuleV6 size=${size}`)
	const deployed = await new ethers.ContractFactory(art.abi, art.bytecode, wallet).deploy(
		v5,
		referrerViews,
	)
	await deployed.waitForDeployment()
	const routerAddr = await deployed.getAddress()
	const routerTx = deployed.deploymentTransaction()?.hash
	console.log(`[upgrade] AdminStatsQueryModuleV6=${routerAddr} tx=${routerTx}`)

	for (const sig of KYC_SELECTORS) {
		await smokeSelector(provider, routerAddr, sig, ROUTE_STATS_QUERY)
	}
	await smokeSelector(provider, routerAddr, 'referrerTotalCount()', ROUTE_STATS_QUERY)
	await smokeSelector(provider, routerAddr, 'getReferrersPage(uint256,uint256)', ROUTE_STATS_QUERY)

	const snap = {
		network: 'conet',
		chainId: CHAIN_ID,
		timestamp: new Date().toISOString(),
		signer: wallet.address,
		factory: FACTORY,
		modules: {
			adminStatsQueryModule: routerAddr,
			adminStatsQueryModuleV5: v5,
			adminStatsReferrerViews: referrerViews,
		},
		constructorArgs: { v5, referrerViews },
		replaced: { adminStatsQueryModule: prevAdmin },
		txs: { adminStatsQueryModule: routerTx },
		note: 'AdminStats V6 routes KYC link selectors to STATS_QUERY; reuses live V5 + referrerViews; never bind bare V5',
	}
	const outPath = path.join(process.cwd(), 'deployments/conet-KycLinkModules.json')
	fs.writeFileSync(outPath, JSON.stringify(snap, null, 2) + '\n')

	console.log('[upgrade] factory.setAdminStatsQueryModule…')
	const tx = await factory.setAdminStatsQueryModule(routerAddr)
	await tx.wait()
	console.log(`[upgrade] setAdminStatsQueryModule tx=${tx.hash}`)
	const bound = String(await factory.defaultAdminStatsQueryModule())
	if (bound.toLowerCase() !== routerAddr.toLowerCase()) {
		throw new Error(`setAdminStatsQueryModule did not stick: got ${bound}`)
	}
	if (bound.toLowerCase() === v5.toLowerCase()) {
		throw new Error('Factory bound bare AdminStats V5 — abort')
	}

	const card = new ethers.Contract(
		SMOKE_CARD,
		['function kycPolicy() view returns (bool,uint8,uint8,uint8)', 'function kycIpfsHashOf(address) view returns (bytes32)'],
		provider,
	)
	const policy = await card.kycPolicy()
	const hash = await card.kycIpfsHashOf(wallet.address)
	console.log(`[smoke] card ${SMOKE_CARD} kycPolicy=${policy} hash=${hash}`)

	const boundSnap = {
		...snap,
		bound: { adminStatsQueryModule: bound, setAdminStatsQueryModuleTx: tx.hash },
		txs: { ...snap.txs, setAdminStatsQueryModule: tx.hash },
		smoke: { card: SMOKE_CARD, kycPolicy: policy.map((x: unknown) => String(x)), kycIpfsHashOf: hash },
	}
	fs.writeFileSync(outPath, JSON.stringify(boundSnap, null, 2) + '\n')

	for (const rel of [
		'deployments/conet-MembershipFeeModules.json',
		'deployments/conet-UserCardModules.json',
	]) {
		const p = path.join(process.cwd(), rel)
		if (!fs.existsSync(p)) continue
		const j = JSON.parse(fs.readFileSync(p, 'utf-8')) as Record<string, unknown>
		j.replacedAdminStatsQueryModule = j.adminStatsQueryModule
		j.adminStatsQueryModule = routerAddr
		if (j.bound && typeof j.bound === 'object') {
			;(j.bound as Record<string, unknown>).adminStatsQueryModule = routerAddr
		}
		j.kycLinkUpgrade = {
			timestamp: snap.timestamp,
			adminStatsQueryModule: routerAddr,
			adminStatsQueryModuleV5: v5,
			adminStatsReferrerViews: referrerViews,
			setAdminStatsQueryModuleTx: tx.hash,
		}
		fs.writeFileSync(p, JSON.stringify(j, null, 2) + '\n')
		console.log(`[upgrade] updated ${rel}`)
	}
	console.log('[upgrade] factory bind complete')
}

main().catch((err) => {
	console.error(err)
	process.exit(1)
})
